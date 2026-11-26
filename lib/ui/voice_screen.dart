import 'dart:async';

import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../core/cost_breakdown.dart';
import '../core/dialog_machine.dart';
import '../core/pricing_calculator.dart';
import '../core/pt_br_parser.dart' show Measure, MeasureKind, speakDuration, speakMeasure;
import '../llm/llm_engine.dart';
import '../llm/smart_dialog.dart';
import '../memory/conversation_store.dart';
import '../vision/text_scanner.dart';
import '../voice/voice_engines.dart';
import 'photo_import.dart';

/// Mensagem da conversa. Nao aparece na tela (a tela mostra so a pergunta atual e as
/// listas), mas e salva para retomar a conversa se o app fechar.
class ChatMessage {
  ChatMessage(this.text, {required this.fromAssistant, this.answered});
  final String text;
  final bool fromAssistant;

  /// Para respostas do usuario: a pergunta que esta mensagem respondeu.
  final DialogState? answered;

  Map<String, Object?> toJson() =>
      {'text': text, 'fromAssistant': fromAssistant, 'answered': answered?.name};

  static ChatMessage? fromJson(Map<String, Object?> j) {
    final text = j['text'];
    if (text is! String) return null;
    final a = j['answered'] as String?;
    return ChatMessage(text,
        fromAssistant: j['fromAssistant'] == true,
        answered: a == null ? null : DialogState.values.asNameMap()[a]);
  }
}

/// Tela unica. Em vez do historico da conversa, mostra:
/// - a pergunta atual do assistente, em destaque;
/// - a ficha do produto (respostas da triagem), com lapis para corrigir cada item;
/// - a lista de ingredientes/materiais com valores, que vai sendo montada;
/// - o resultado (preco da unidade e preco do lote).
/// Embaixo: falar (botao grande), digitar ou mandar foto da receita/compra.
class VoiceScreen extends StatefulWidget {
  const VoiceScreen({
    super.key,
    required this.stt,
    required this.tts,
    required this.dialog,
    this.llm,
    this.store,
    this.scanner,
  });

  final SttEngine stt;
  final TtsEngine tts;
  final SmartDialog dialog;

  /// Memoria local (retomar conversa, empresa, produtos). Opcional.
  final ConversationStore? store;

  /// LLM local opcional. Sem ele (ou antes do download) o app usa so o fluxo deterministico.
  final InstallableLlm? llm;

  /// Leitor de texto das fotos. Sem ele, o botao de foto nao aparece.
  final TextScanner? scanner;

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> {
  final _messages = <ChatMessage>[];
  final _textCtrl = TextEditingController();

  bool _sttAvailable = false;
  bool _listening = false;
  bool _busy = false; // aguardando o LLM local ou a leitura de fotos
  int? _downloadPercent; // != null enquanto baixa o modelo
  String? _pendingTranscript; // aguardando "Esta certo" / "Editar texto"

  /// Pergunta atual do assistente (o que aparece em destaque).
  String _question = '';

  /// A ultima fala nao foi entendida: a pergunta aparece como pedido de repeticao.
  bool _retry = false;

  PricingResult? _lastResult;

  /// IA local descarregada enquanto a camera/galeria esta aberta (libera ~1 GB de
  /// memoria para o Android nao fechar o app). O aviso de "Baixar" nao aparece nesse meio.
  bool _llmPaused = false;

  DialogMachine get _machine => widget.dialog.machine;

  /// Conversa automatica: o microfone abre sozinho quando o assistente termina de falar,
  /// e o texto ouvido e enviado depois de alguns segundos (da para editar antes).
  bool _handsFree = true;

  /// O assistente esta falando (toque no microfone, na pergunta ou digite para interromper).
  bool _speaking = false;

  /// Muda a cada fala nova ou interrompida: a fala antiga nao abre o microfone ao acabar.
  int _speechGen = 0;

  /// Envio automatico do texto ouvido (contagem regressiva no cartao "Entendi").
  Timer? _autoSend;
  int _autoSendLeft = 0;
  static const _autoSendSeconds = 3;

  /// Fala o texto. Com [autoListen] e a conversa automatica ligada, abre o microfone
  /// quando a fala termina (se ninguem interrompeu).
  Future<void> _speak(String text, {bool autoListen = false}) async {
    final gen = ++_speechGen;
    setState(() => _speaking = true);
    await widget.tts.speak(text);
    if (!mounted || gen != _speechGen) return; // interrompida ou substituida
    setState(() => _speaking = false);
    if (autoListen &&
        _handsFree &&
        _sttAvailable &&
        !_listening &&
        !_busy &&
        _pendingTranscript == null &&
        _textCtrl.text.trim().isEmpty &&
        ModalRoute.of(context)?.isCurrent == true) {
      _toggleListen();
    }
  }

  /// Interrompe a fala do assistente (e o microfone automatico que viria depois dela).
  void _stopSpeaking() {
    _speechGen++;
    widget.tts.stop();
    if (_speaking && mounted) setState(() => _speaking = false);
  }

  void _cancelAutoSend() {
    _autoSend?.cancel();
    _autoSend = null;
    if (_autoSendLeft != 0 && mounted) setState(() => _autoSendLeft = 0);
  }

  void _startAutoSend() {
    _cancelAutoSend();
    if (!_handsFree) return;
    _autoSendLeft = _autoSendSeconds;
    _autoSend = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || _pendingTranscript == null) return _cancelAutoSend();
      setState(() => _autoSendLeft--);
      if (_autoSendLeft <= 0) {
        _cancelAutoSend();
        _confirmTranscript();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await widget.tts.init();
    final ok = await widget.stt.init();
    if (!mounted) return;
    setState(() => _sttAvailable = ok);
    _assistantSays(_resumeOrStart());
    final llm = widget.llm;
    if (llm != null) {
      await llm.load();
      if (mounted) setState(() {});
    }
    if (!ok) _notice('O microfone não está disponível neste aparelho. Você pode digitar.');
    await _recoverLostPhotos();
  }

  /// Se o Android fechou o app enquanto a camera estava aberta, a foto tirada fica
  /// guardada pelo sistema: busca e le agora, em vez de perder a foto.
  Future<void> _recoverLostPhotos() async {
    final scanner = widget.scanner;
    if (scanner == null) return;
    try {
      final lost = await ImagePicker().retrieveLostData();
      final files = lost.files ?? const <XFile>[];
      if (lost.isEmpty || files.isEmpty || !mounted) return;
      debugPrint('[AUGURE][FOTO] recuperando  foto(s) depois que o app foi fechado');
      await _openPhotoPage(initialPaths: [for (final f in files) f.path]);
    } catch (e) {
      debugPrint('[AUGURE][FOTO] sem foto para recuperar: $e');
    }
  }

  @override
  void dispose() {
    widget.stt.stop();
    _speechGen++;
    widget.tts.stop();
    _autoSend?.cancel();
    _textCtrl.dispose();
    super.dispose();
  }

  void _notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Retoma a conversa salva (se recente) ou comeca uma nova.
  DialogResponse _resumeOrStart() {
    final saved = widget.store?.resumable();
    if (saved != null && _machine.restore(saved.dialog)) {
      _messages.addAll(saved.messages.map(ChatMessage.fromJson).whereType<ChatMessage>());
      return _machine.resumePrompt();
    }
    return widget.dialog.start();
  }

  void _assistantSays(DialogResponse r) {
    _messages.add(ChatMessage(r.text, fromAssistant: true));
    setState(() {
      _question = r.text;
      _retry = !r.understood;
      if (r.result != null) _lastResult = r.result;
      if (dialogOrder.contains(r.state) && r.state != DialogState.result) {
        // Novo calculo em andamento: o resultado antigo sai da tela.
        _lastResult = null;
      }
    });
    _speak(r.text, autoListen: true);
    _persist(r);
  }

  /// Salva a conversa (para retomar), o cadastro e o ultimo preco.
  Future<void> _persist(DialogResponse r) async {
    final store = widget.store;
    if (store == null) return;
    await store.saveProfile(_machine.profile);
    if (r.result != null) await store.rememberResult(_machine.session, r.result!);
    await store.saveConversation(_machine.toJson(), [for (final m in _messages) m.toJson()]);
  }

  /// Lapis num item da ficha: volta para aquela pergunta e depois continua de onde
  /// estava. O valor atual vai para a caixa de texto, para editar se quiser.
  void _correctField(DialogState field, String? current) {
    if (_busy) return;
    _cancelListening();
    _cancelAutoSend();
    _stopSpeaking();
    _assistantSays(_machine.correct(field));
    setState(() {
      _pendingTranscript = null;
      _textCtrl.text = current ?? '';
    });
  }

  /// Limpa a tela e comeca a conversa com o cadastro que estiver na maquina.
  void _restartScreen() {
    _cancelListening();
    _cancelAutoSend();
    _stopSpeaking();
    setState(() {
      _messages.clear();
      _pendingTranscript = null;
      _lastResult = null;
      _textCtrl.clear();
    });
    _assistantSays(widget.dialog.start());
  }

  /// "Nova conversa": cadastra um produto novo do zero. O produto atual fica salvo em
  /// "Meus produtos" (ficha, tabela de custo e ultimo preco) para voltar depois.
  Future<void> _newConversation() async {
    if (_busy) return;
    final current = _machine.profile.product;
    if (current != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Cadastrar novo produto?'),
          content: Text('O produto atual ($current) fica salvo em "Meus produtos" e você '
              'pode voltar a ele quando quiser.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Novo produto')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    await widget.store?.startNewProduct();
    _machine.profile = SalesSession(company: _machine.profile.company);
    _restartScreen();
  }

  /// "Meus produtos": lista os produtos salvos para voltar a um deles.
  Future<void> _showProducts() async {
    final store = widget.store;
    if (store == null || _busy) return;
    final activeId = store.activeProduct?.id;
    final chosen = await showModalBottomSheet<ProductRecord>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Meus produtos', style: Theme.of(ctx).textTheme.titleLarge),
            ),
            for (final p in store.products)
              ListTile(
                leading: const Icon(Icons.inventory_2_outlined),
                title: Text(p.name),
                subtitle: Text([
                  if (p.lastUnitPriceCents != null)
                    'Último preço: ${formatBrl(p.lastUnitPriceCents!)}',
                  if (p.session.costs?.unitCostCents != null)
                    'custo ${formatBrl(p.session.costs!.unitCostCents!)}/un.',
                  if (p.lastUnitPriceCents == null && p.session.costs == null)
                    'Sem preço calculado ainda',
                ].join(' · ')),
                trailing: p.id == activeId
                    ? const Chip(label: Text('Atual'), visualDensity: VisualDensity.compact)
                    : const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(ctx, p),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || chosen.id == activeId || !mounted) return;
    await store.activate(chosen.id);
    _machine.profile = chosen.session;
    _restartScreen();
  }

  Future<void> _submit(String text) async {
    final t = text.trim();
    if (t.isEmpty || _busy) return;
    // Enviou com o microfone ainda ligado: desliga e descarta o resto da escuta.
    _cancelListening();
    _cancelAutoSend();
    _stopSpeaking();
    final state = _machine.state;
    _messages.add(ChatMessage(t,
        fromAssistant: false, answered: correctableStates.contains(state) ? state : null));
    setState(() => _busy = true);
    try {
      final r = await widget.dialog.handle(t);
      if (mounted) _assistantSays(r);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Fotos da receita ou da compra: le, mostra o que achou, pergunta se tem mais
  /// imagens e entrega tudo para a conversa.
  Future<void> _addPhotos() async {
    final scanner = widget.scanner;
    if (scanner == null || _busy) return;
    _cancelListening();
    _stopSpeaking();
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Foto da receita (ingredientes) ou da compra (nota, cupom)'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Tirar foto'),
            onTap: () => Navigator.pop(ctx, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Escolher da galeria (uma ou várias)'),
            onTap: () => Navigator.pop(ctx, ImageSource.gallery),
          ),
        ]),
      ),
    );
    if (source == null || !mounted) return;
    await _openPhotoPage(source: source);
  }

  /// Abre a tela de fotos. Descarrega a IA local antes (a camera do aparelho precisa de
  /// memoria) e recarrega em segundo plano na volta.
  Future<void> _openPhotoPage({ImageSource? source, List<String> initialPaths = const []}) async {
    final scanner = widget.scanner!;
    final llm = widget.llm;
    final pauseLlm = llm != null && llm.isReady;
    if (pauseLlm) {
      setState(() => _llmPaused = true);
      await llm.dispose();
      debugPrint('[AUGURE][FOTO] IA local descarregada para abrir a camera');
    }
    if (!mounted) return;
    final result = await Navigator.push<PhotoImport>(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoImportPage(
            scanner: scanner, first: source, initialPaths: initialPaths, onAsk: widget.tts.speak),
      ),
    );
    _stopSpeaking();
    if (pauseLlm) {
      llm.load().then((_) {
        if (mounted) setState(() => _llmPaused = false);
      });
    }
    debugPrint('[AUGURE][FOTO] fotos: ${result == null ? 'canceladas' : '${result.recipe.length} ingredientes, ${result.purchases.length} precos'}');
    if (result == null || !mounted) return;
    _messages.add(ChatMessage(
        '[fotos: ${result.recipe.length} ingredientes, ${result.purchases.length} preços]',
        fromAssistant: false));
    _assistantSays(_machine.importDocuments(result.recipe, result.purchases));
  }

  Future<void> _downloadModel() async {
    final llm = widget.llm;
    if (llm == null) return;
    setState(() => _downloadPercent = 0);
    try {
      await llm.install(onProgress: (p) {
        if (mounted) setState(() => _downloadPercent = p);
      });
      await llm.load();
      _notice('Pronto! O assistente inteligente está ativo e funciona sem internet.');
    } catch (_) {
      _notice('Não consegui baixar o modelo agora. O app continua funcionando normalmente.');
    } finally {
      if (mounted) setState(() => _downloadPercent = null);
    }
  }

  Widget _llmBanner(BuildContext context) {
    final llm = widget.llm;
    if (llm == null || llm.isReady || _llmPaused) return const SizedBox.shrink();
    final mb = (llm.approxDownloadBytes / 1000000).round();
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: _downloadPercent != null
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Baixando assistente inteligente… $_downloadPercent%'),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: _downloadPercent! / 100),
              ])
            : Row(children: [
                Expanded(
                  child: Text(
                      'Assistente inteligente (opcional): entende falas mais livres, '
                      'sem internet depois de baixar. Download de cerca de $mb MB — '
                      'use o Wi-Fi.'),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _downloadModel, child: const Text('Baixar')),
              ]),
      ),
    );
  }

  /// Muda a cada escuta nova ou cancelada: resultados atrasados de uma escuta antiga
  /// sao descartados, para nao virarem resposta da pergunta seguinte.
  int _listenGen = 0;

  /// Desliga o microfone e descarta o que ele ainda entregaria.
  void _cancelListening() {
    if (!_listening) return;
    _listenGen++;
    widget.stt.stop();
    setState(() {
      _listening = false;
      _pendingTranscript = null;
    });
  }

  Future<void> _toggleListen() async {
    if (_listening) {
      await widget.stt.stop();
      setState(() => _listening = false);
      return;
    }
    _stopSpeaking();
    _cancelAutoSend();
    final gen = ++_listenGen;
    setState(() {
      _listening = true;
      _pendingTranscript = null;
    });
    // Texto que ja estava na caixa (ex.: fechou o cartao no X): a fala nova e
    // ACRESCENTADA, em vez de apagar o que a pessoa ja tinha falado ou digitado.
    final before = _textCtrl.text.trim();
    String join(String heard) => [before, heard.trim()].where((s) => s.isNotEmpty).join(' ');
    await widget.stt.listen((text, isFinal) {
      if (!mounted || gen != _listenGen) return;
      setState(() {
        final full = join(text);
        _textCtrl.text = full;
        if (isFinal) {
          _listening = false;
          _pendingTranscript = full.isEmpty ? null : full;
        }
      });
      if (isFinal && _pendingTranscript != null) _startAutoSend();
    });
  }

  void _confirmTranscript() {
    _cancelAutoSend();
    final t = _pendingTranscript;
    setState(() {
      _pendingTranscript = null;
      _textCtrl.clear();
    });
    if (t != null) _submit(t);
  }

  /// "Editar texto" e o "X": fecham o cartao e deixam o que foi falado na caixa de texto
  /// (nada e apagado nem enviado). Tocar no microfone de novo continua o texto.
  void _closeTranscript() {
    _cancelAutoSend();
    setState(() => _pendingTranscript = null);
  }

  /// Nome curto da pergunta atual (mostra a quem o texto ouvido vai responder).
  static String _questionLabel(DialogState s) => switch (s) {
        DialogState.askCompany => 'nome da empresa',
        DialogState.askSector => 'ramo do negócio',
        DialogState.askProduct => 'produto',
        DialogState.askReuse => 'usar os dados salvos?',
        DialogState.askMaterials => 'materiais ou ingredientes',
        DialogState.askBatchYield => 'rendimento por lote',
        DialogState.askProductionTime => 'tempo de produção',
        DialogState.askCharacteristics => 'características',
        DialogState.askQuantity => 'quantidade',
        DialogState.askCost => 'custo total',
        DialogState.askMargin => 'margem',
        DialogState.confirm => 'confirmação',
        DialogState.result => 'próximo passo',
        DialogState.offerDetail => 'detalhar o custo?',
        DialogState.costDetail => 'tabela de custo',
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = _machine.session;
    final table = _machine.costTable;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Assistente de Vendas'),
            if (s.company != null)
              Text(s.company!,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _handsFree
                ? 'Conversa automática ligada: o microfone abre sozinho'
                : 'Conversa automática desligada: toque no microfone para falar',
            onPressed: () {
              setState(() => _handsFree = !_handsFree);
              if (!_handsFree) _cancelAutoSend();
              _notice(_handsFree
                  ? 'Conversa automática ligada: o microfone abre quando eu terminar de falar.'
                  : 'Conversa automática desligada: toque no microfone para falar.');
            },
            icon: Icon(_handsFree ? Icons.record_voice_over : Icons.voice_over_off),
          ),
          if ((widget.store?.products.length ?? 0) > 0)
            IconButton(
              tooltip: 'Meus produtos',
              onPressed: _busy ? null : _showProducts,
              icon: const Icon(Icons.inventory_2_outlined),
            ),
          IconButton(
            tooltip: 'Nova conversa (novo produto)',
            onPressed: _busy ? null : _newConversation,
            icon: const Icon(Icons.add_comment_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _llmBanner(context),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _QuestionCard(
                    text: _question,
                    retry: _retry,
                    busy: _busy,
                    speaking: _speaking,
                    onReplay: () => _speak(_question),
                    onInterrupt: _stopSpeaking,
                  ),
                  _ProfileCard(
                      session: s,
                      onCorrect: _busy || _listening ? null : _correctField),
                  if (table != null && table.materials.isNotEmpty) _CostTableCard(table),
                  if (_lastResult != null) _ResultCard(_lastResult!, s.batchYield),
                  if (_machine.simulation != null) _SimulationCard(_machine.simulation!),
                ],
              ),
            ),
            if (_pendingTranscript != null) _transcriptCard(context, scheme),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(children: [
                if (widget.scanner != null) ...[
                  IconButton.outlined(
                    tooltip: 'Foto da receita ou da compra',
                    onPressed: _busy ? null : _addPhotos,
                    icon: const Icon(Icons.add_a_photo_outlined),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: TextField(
                    controller: _textCtrl,
                    // Quebra de linha: o texto cresce ate 5 linhas e depois rola.
                    minLines: 1,
                    maxLines: 5,
                    keyboardType: TextInputType.text,
                    textInputAction: TextInputAction.send,
                    // Comecou a digitar: o assistente para de falar e o envio automatico
                    // do texto ouvido e cancelado (a pessoa esta editando).
                    onChanged: (_) {
                      if (_speaking) _stopSpeaking();
                      if (_autoSend != null) _cancelAutoSend();
                    },
                    onSubmitted: (v) {
                      _submit(v);
                      _textCtrl.clear();
                    },
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      hintText: 'Ou digite aqui',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Enviar',
                  onPressed: () {
                    _submit(_textCtrl.text);
                    _textCtrl.clear();
                  },
                  icon: const Icon(Icons.send),
                ),
              ]),
            ),
            if (_speaking && !_listening)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('Toque no microfone para me interromper e falar.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ),
            if (_listening)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('Ouvindo… fale à vontade. Eu paro quando você fizer uma pausa.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: scheme.primary)),
              ),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Semantics(
                button: true,
                label: _listening ? 'Parar de ouvir' : 'Falar',
                child: SizedBox(
                  width: 96,
                  height: 96,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      shape: const CircleBorder(),
                      backgroundColor: _listening ? scheme.error : scheme.primary,
                    ),
                    onPressed: _sttAvailable ? _toggleListen : null,
                    child: Icon(_listening ? Icons.stop : Icons.mic, size: 44),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _transcriptCard(BuildContext context, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Card(
          color: scheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text('Entendi: "$_pendingTranscript"',
                            style: Theme.of(context).textTheme.titleMedium),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Fechar (o texto fica na caixa)',
                      onPressed: _closeTranscript,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text('Isso responde: ${_questionLabel(_machine.state)}',
                    style: Theme.of(context).textTheme.bodySmall),
                if (_autoSendLeft > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                        'Enviando em $_autoSendLeft s… Toque em "Editar texto" para mudar antes.',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(fontWeight: FontWeight.bold)),
                  ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: FilledButton(
                        onPressed: _confirmTranscript, child: const Text('Está certo')),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                        onPressed: _closeTranscript, child: const Text('Editar texto')),
                  ),
                ]),
              ],
            ),
          ),
        ),
      );
}

/// Pergunta atual do assistente, em destaque.
class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.text,
    required this.retry,
    required this.busy,
    required this.speaking,
    required this.onReplay,
    required this.onInterrupt,
  });
  final String text;
  final bool retry;
  final bool busy;

  /// O assistente esta falando: tocar no cartao interrompe.
  final bool speaking;
  final VoidCallback onReplay;
  final VoidCallback onInterrupt;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: speaking ? onInterrupt : null,
      child: _card(context, scheme),
    );
  }

  Widget _card(BuildContext context, ColorScheme scheme) {
    return Card(
      color: retry ? scheme.tertiaryContainer : scheme.primaryContainer,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: busy
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: LinearProgressIndicator(),
                    )
                  : Text(text,
                      style: TextStyle(
                          fontSize: 20,
                          height: 1.35,
                          color: retry ? scheme.onTertiaryContainer : scheme.onPrimaryContainer)),
            ),
            IconButton(
              tooltip: speaking ? 'Parar de falar' : 'Ouvir de novo',
              onPressed: busy ? null : (speaking ? onInterrupt : onReplay),
              icon: Icon(speaking ? Icons.stop_circle_outlined : Icons.volume_up_outlined),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ficha do produto: o que ja foi respondido na triagem, com lapis para corrigir.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.session, required this.onCorrect});
  final SalesSession session;
  final void Function(DialogState field, String? current)? onCorrect;

  @override
  Widget build(BuildContext context) {
    final s = session;
    final rows = <(DialogState, String, String)>[
      if (s.company != null) (DialogState.askCompany, 'Empresa', s.company!),
      if (s.sector != null) (DialogState.askSector, 'Ramo', s.sector!),
      if (s.product != null) (DialogState.askProduct, 'Produto', s.product!),
      if (s.materials != null) (DialogState.askMaterials, 'Ingredientes', s.materials!),
      if (s.batchYield != null)
        (DialogState.askBatchYield, 'Rende por lote', '${s.batchYield} unidades'),
      if (s.productionMinutes != null)
        (DialogState.askProductionTime, 'Tempo por lote', speakDuration(s.productionMinutes!)),
      if (s.characteristics != null)
        (DialogState.askCharacteristics, 'Características', s.characteristics!),
      if (s.quantity != null) (DialogState.askQuantity, 'Quantidade', '${s.quantity} unidades'),
      if (s.totalCostCents != null)
        (DialogState.askCost, 'Custo total', formatBrl(s.totalCostCents!)),
      if (s.marginPercent != null) (DialogState.askMargin, 'Margem', '${s.marginPercent}%'),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    final muted = Theme.of(context)
        .textTheme
        .labelMedium
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Ficha do produto', style: Theme.of(context).textTheme.titleMedium),
            for (final (field, label, value) in rows)
              Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(label, style: muted),
                          Text(value, style: const TextStyle(fontSize: 16)),
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Corrigir $label',
                    onPressed: onCorrect == null ? null : () => onCorrect!(field, value),
                    icon: const Icon(Icons.edit_outlined, size: 20),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Lista de ingredientes/materiais (por parte do produto) com quantidade, preco e custo
/// no lote; no fim, custo do lote, custo da unidade, preco da unidade e preco do lote.
class _CostTableCard extends StatelessWidget {
  const _CostTableCard(this.t);
  final CostBreakdown t;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final parts = t.parts;
    final groups = <(String?, List<MaterialCost>)>[
      if (parts.isEmpty)
        (null, t.materials)
      else ...[
        for (final p in parts) (p, t.materials.where((m) => m.part == p).toList()),
        if (t.materials.any((m) => m.part == null))
          ('Outros', t.materials.where((m) => m.part == null).toList()),
      ],
    ];

    String detail(MaterialCost m) {
      final grams = m.usedGrams;
      final used = m.used != null
          ? 'usa ${speakMeasure(m.used!)}'
              '${grams != null ? ' (≈ ${speakMeasure(Measure(grams.roundToDouble(), MeasureKind.mass))})' : ''}'
          : 'falta a quantidade';
      final paid = m.priceCents != null && m.pack != null
          ? 'paga ${formatBrl(m.priceCents!)} por ${speakMeasure(m.pack!)}'
          : m.priceCents != null
              ? 'paga ${formatBrl(m.priceCents!)} (falta o tamanho)'
              : 'falta o preço';
      return '$used · $paid';
    }

    Widget line(String name, String? sub, String value, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: TextStyle(
                            fontSize: 16, fontWeight: bold ? FontWeight.bold : null)),
                    if (sub != null && sub.isNotEmpty) Text(sub, style: muted),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(value, style: TextStyle(fontWeight: bold ? FontWeight.bold : null)),
            ],
          ),
        );

    final complete = t.materials.every((m) => m.costCents != null);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Ingredientes e custos do lote', style: theme.textTheme.titleMedium),
            if (t.batchYield != null) Text('Lote de ${t.batchYield} unidades', style: muted),
            for (final (part, items) in groups) ...[
              if (part != null) ...[
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: Text(part,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(color: theme.colorScheme.primary)),
                  ),
                  Text(formatBrl(items.fold(0, (s, m) => s + (m.costCents ?? 0))),
                      style: theme.textTheme.titleSmall),
                ]),
              ],
              for (final m in items)
                line(m.name, detail(m), m.costCents != null ? formatBrl(m.costCents!) : '—'),
            ],
            if (t.packagingCents > 0)
              line('Embalagens', '${formatBrl(t.packagingPerUnitCents!)} por unidade',
                  formatBrl(t.packagingCents)),
            if ((t.freightCents ?? 0) > 0)
              line('Frete e transporte', null, formatBrl(t.freightCents!)),
            if ((t.wearCents ?? 0) > 0)
              line('Gás, energia e desgaste', null, formatBrl(t.wearCents!)),
            if ((t.laborCents ?? 0) > 0)
              line(
                  'Pró-labore',
                  t.laborHourlyCents != null
                      ? '${formatBrl(t.laborHourlyCents!)} por hora'
                      : null,
                  formatBrl(t.laborCents!)),
            if ((t.otherCents ?? 0) > 0) line('Outros custos', null, formatBrl(t.otherCents!)),
            const Divider(height: 20),
            line('Custo do lote', complete ? null : 'parcial: faltam dados de alguns itens',
                formatBrl(t.batchCents),
                bold: true),
            if (t.unitCostCents != null)
              line('Custo de produção da unidade', null, formatBrl(t.unitCostCents!)),
            if (t.unitPriceCents != null) ...[
              const Divider(height: 20),
              line('Preço da unidade', 'margem de ${t.marginPercent}%',
                  formatBrl(t.unitPriceCents!),
                  bold: true),
              line('Preço do lote', '${t.batchYield} unidades', formatBrl(t.batchPriceCents!),
                  bold: true),
              line('Lucro por unidade', null, formatBrl(t.unitProfitCents!)),
              line('Lucro do lote', null, formatBrl(t.batchProfitCents!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Simulacao com o preco escolhido pela pessoa: lucro, margem real e comparacao com o
/// preco sugerido. Em vermelho quando da prejuizo.
class _SimulationCard extends StatelessWidget {
  const _SimulationCard(this.s);
  final PriceSimulation s;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final loss = s.isLoss;
    final fg = loss ? scheme.onErrorContainer : null;
    Widget row(String a, String b, {bool big = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(child: Text(a, style: TextStyle(fontSize: big ? 17 : 15, color: fg))),
            Text(b,
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: big ? 18 : 15, color: fg)),
          ]),
        );
    return Card(
      color: loss ? scheme.errorContainer : scheme.secondaryContainer,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(loss ? 'Simulação: preço com PREJUÍZO' : 'Simulação com o seu preço',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(color: fg)),
            const SizedBox(height: 8),
            row('Preço da unidade', formatBrl(s.priceCents), big: true),
            row('Custo de produção da unidade', formatBrl(s.unitCostCents)),
            row(loss ? 'Prejuízo por unidade' : 'Lucro por unidade',
                formatBrl(s.unitProfitCents.abs())),
            row('Margem real', '%'),
            if (s.batchYield != null) ...[
              row('Preço do lote ( unidades)', formatBrl(s.batchRevenueCents!)),
              row(s.batchProfitCents! < 0 ? 'Prejuízo do lote' : 'Lucro do lote',
                  formatBrl(s.batchProfitCents!.abs())),
            ],
            if (s.suggestedCents != null) row('Preço sugerido', formatBrl(s.suggestedCents!)),
          ],
        ),
      ),
    );
  }
}

/// Resultado do calculo: preco da unidade separado do preco do lote.
class _ResultCard extends StatelessWidget {
  const _ResultCard(this.r, this.batchYield);
  final PricingResult r;
  final int? batchYield;

  @override
  Widget build(BuildContext context) {
    final y = batchYield;
    final q = r.input.quantity;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Preço', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _row(context, 'Custo de produção da unidade', formatBrl(r.unitCostCents)),
            _row(context, 'Preço da unidade', formatBrl(r.unitPriceCents), big: true),
            if (y != null && y > 0)
              _row(context, 'Preço do lote ($y unidades)', formatBrl(r.unitPriceCents * y),
                  big: true),
            if (y != q) _row(context, 'Total das $q unidades', formatBrl(r.totalRevenueCents)),
            _row(context, 'Lucro (nas $q unidades)', formatBrl(r.profitCents)),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String a, String b, {bool big = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(child: Text(a, style: TextStyle(fontSize: big ? 17 : 15))),
            Text(b,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: big ? 18 : 15,
                    color: big ? Theme.of(context).colorScheme.primary : null)),
          ],
        ),
      );
}

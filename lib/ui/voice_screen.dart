import 'package:material_ui/material_ui.dart';

import '../core/dialog_machine.dart';
import '../core/pricing_calculator.dart';
import '../core/pt_br_parser.dart' show speakDuration;
import '../llm/llm_engine.dart';
import '../llm/smart_dialog.dart';
import '../voice/voice_engines.dart';

class ChatMessage {
  ChatMessage(this.text, {required this.fromAssistant});
  final String text;
  final bool fromAssistant;
}

/// Tela unica: botao grande de falar, alternativa de digitar, leitura em voz alta e
/// confirmacao da transcricao antes de agir (riscos de erro de fala do documento AUGURE).
class VoiceScreen extends StatefulWidget {
  const VoiceScreen({
    super.key,
    required this.stt,
    required this.tts,
    required this.dialog,
    this.llm,
  });

  final SttEngine stt;
  final TtsEngine tts;
  final SmartDialog dialog;

  /// LLM local opcional. Sem ele (ou antes do download) o app usa so o fluxo deterministico.
  final InstallableLlm? llm;

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> {
  final _messages = <ChatMessage>[];
  final _textCtrl = TextEditingController();
  final _scroll = ScrollController();

  bool _sttAvailable = false;
  bool _listening = false;
  bool _busy = false; // aguardando o LLM local
  int? _downloadPercent; // != null enquanto baixa o modelo
  String? _pendingTranscript; // aguardando Confirmar/Corrigir
  PricingResult? _lastResult;
  SalesSession? _lastSession; // triagem do produto calculado (ficha)

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
    _assistantSays(widget.dialog.start());
    // Carrega o modelo se ja foi baixado antes (silencioso; falha = sem LLM).
    final llm = widget.llm;
    if (llm != null) {
      await llm.load();
      if (mounted) setState(() {});
    }
    if (!ok) {
      _addMessage(ChatMessage(
          'O microfone não está disponível neste aparelho. Você pode digitar abaixo.',
          fromAssistant: true));
    }
  }

  @override
  void dispose() {
    widget.stt.stop();
    widget.tts.stop();
    _textCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _addMessage(ChatMessage m) {
    setState(() => _messages.add(m));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  void _assistantSays(DialogResponse r) {
    _addMessage(ChatMessage(r.text, fromAssistant: true));
    setState(() {
      if (r.result != null) {
        _lastResult = r.result;
        _lastSession = widget.dialog.machine.session;
      } else if (r.state != DialogState.result) {
        // Novo calculo em andamento: o resumo antigo sai da tela.
        _lastResult = null;
        _lastSession = null;
      }
    });
    widget.tts.speak(r.text);
  }

  Future<void> _submit(String text) async {
    final t = text.trim();
    if (t.isEmpty || _busy) return;
    _addMessage(ChatMessage(t, fromAssistant: false));
    setState(() => _busy = true);
    try {
      final r = await widget.dialog.handle(t);
      if (mounted) _assistantSays(r);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
      _addMessage(ChatMessage(
          'Pronto! O assistente inteligente está ativo e funciona sem internet.',
          fromAssistant: true));
    } catch (_) {
      _addMessage(ChatMessage(
          'Não consegui baixar o modelo agora. O app continua funcionando normalmente.',
          fromAssistant: true));
    } finally {
      if (mounted) setState(() => _downloadPercent = null);
    }
  }

  Widget _llmBanner(BuildContext context) {
    final llm = widget.llm;
    if (llm == null || llm.isReady) return const SizedBox.shrink();
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

  Future<void> _toggleListen() async {
    if (_listening) {
      await widget.stt.stop();
      setState(() => _listening = false);
      return;
    }
    await widget.tts.stop();
    setState(() {
      _listening = true;
      _pendingTranscript = null;
    });
    await widget.stt.listen((text, isFinal) {
      if (!mounted) return;
      setState(() {
        _textCtrl.text = text;
        if (isFinal) {
          _listening = false;
          _pendingTranscript = text.trim().isEmpty ? null : text;
        }
      });
    });
  }

  void _confirmTranscript() {
    final t = _pendingTranscript;
    setState(() {
      _pendingTranscript = null;
      _textCtrl.clear();
    });
    if (t != null) _submit(t);
  }

  void _correctTranscript() {
    // Mantem o texto no campo para edicao, sem reiniciar o fluxo.
    setState(() => _pendingTranscript = null);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final company = widget.dialog.machine.session.company;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Assistente de Vendas'),
            if (company != null)
              Text(company,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            _llmBanner(context),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(16),
                itemCount: _messages.length + (_lastResult != null ? 1 : 0),
                itemBuilder: (_, i) {
                  if (i == _messages.length) {
                    return _ResultCard(_lastResult!, _lastSession);
                  }
                  return _Bubble(_messages[i]);
                },
              ),
            ),
            if (_pendingTranscript != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Card(
                  color: scheme.secondaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Entendi: "$_pendingTranscript"',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Row(children: [
                          Expanded(
                            child: FilledButton(
                                onPressed: _confirmTranscript,
                                child: const Text('Está certo')),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                                onPressed: _correctTranscript,
                                child: const Text('Corrigir')),
                          ),
                        ]),
                      ],
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _textCtrl,
                    textInputAction: TextInputAction.send,
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
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.m);
  final ChatMessage m;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: m.fromAssistant ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: m.fromAssistant ? scheme.surfaceContainerHighest : scheme.primaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(m.text, style: const TextStyle(fontSize: 18)),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard(this.r, this.s);
  final PricingResult r;
  final SalesSession? s;

  @override
  Widget build(BuildContext context) {
    final s = this.s;
    final specs = <(String, String)>[
      if (s?.company != null) ('Empresa', s!.company!),
      if (s?.product != null) ('Produto', s!.product!),
      if (s?.materials != null) ('Materiais', s!.materials!),
      if (s?.batchYield != null) ('Rende por lote', '${s!.batchYield} unidades'),
      if (s?.productionMinutes != null)
        ('Tempo por lote', speakDuration(s!.productionMinutes!)),
      if (s?.characteristics != null) ('Características', s!.characteristics!),
    ];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (specs.isNotEmpty) ...[
              Text('Ficha do produto', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              for (final (label, value) in specs) _spec(context, label, value),
              const Divider(height: 24),
            ],
            Text('Resumo', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            _row('Custo por unidade', formatBrl(r.unitCostCents)),
            _row('Preço sugerido', formatBrl(r.unitPriceCents)),
            _row('Total vendido', formatBrl(r.totalRevenueCents)),
            _row('Lucro', formatBrl(r.profitCents)),
          ],
        ),
      ),
    );
  }

  /// Linha de texto livre: rotulo em cima, valor embaixo (valores podem ser longos).
  Widget _spec(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            Text(value, style: const TextStyle(fontSize: 16)),
          ],
        ),
      );

  Widget _row(String a, String b) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [Text(a), Text(b, style: const TextStyle(fontWeight: FontWeight.bold))],
        ),
      );
}

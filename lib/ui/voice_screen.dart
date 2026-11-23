import 'package:flutter/material.dart';

import '../core/dialog_machine.dart';
import '../core/pricing_calculator.dart';
import '../voice/voice_engines.dart';

class ChatMessage {
  ChatMessage(this.text, {required this.fromAssistant});
  final String text;
  final bool fromAssistant;
}

/// Tela unica: botao grande de falar, alternativa de digitar, leitura em voz alta e
/// confirmacao da transcricao antes de agir (riscos de erro de fala do documento AUGURE).
class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key, required this.stt, required this.tts});

  final SttEngine stt;
  final TtsEngine tts;

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> {
  final _machine = DialogMachine();
  final _messages = <ChatMessage>[];
  final _textCtrl = TextEditingController();
  final _scroll = ScrollController();

  bool _sttAvailable = false;
  bool _listening = false;
  String? _pendingTranscript; // aguardando Confirmar/Corrigir
  PricingResult? _lastResult;

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
    _assistantSays(_machine.start());
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
    if (r.result != null) setState(() => _lastResult = r.result);
    widget.tts.speak(r.text);
  }

  void _submit(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    _addMessage(ChatMessage(t, fromAssistant: false));
    _assistantSays(_machine.handle(t));
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
    return Scaffold(
      appBar: AppBar(title: const Text('Assistente de Vendas')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.all(16),
                itemCount: _messages.length + (_lastResult != null ? 1 : 0),
                itemBuilder: (_, i) {
                  if (i == _messages.length) return _ResultCard(_lastResult!);
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
  const _ResultCard(this.r);
  final PricingResult r;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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

  Widget _row(String a, String b) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [Text(a), Text(b, style: const TextStyle(fontWeight: FontWeight.bold))],
        ),
      );
}

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'continuous_dictation.dart';
import 'voice_engines.dart';

/// STT do sistema (Android SpeechRecognizer / iOS Speech) em modo DITADO CONTINUO:
/// so para quando a pessoa fica em silencio (ver [ContinuousDictation]).
/// Funciona offline apenas se o pacote de idioma pt-BR estiver instalado no aparelho.
class SystemStt implements SttEngine {
  SystemStt() {
    _dictation = ContinuousDictation(_PluginSession(this),
        log: (m) => debugPrint('[AUGURE][STT] $m'));
  }

  final SpeechToText _stt = SpeechToText();
  late final ContinuousDictation _dictation;
  bool _ready = false;

  /// Reconhecimento no aparelho; desliga sozinho se o pacote pt-BR offline faltar.
  bool _onDevice = true;

  void Function(String? error)? _onEnd;

  @override
  Future<bool> init() async {
    _ready = await _stt.initialize(
      onStatus: (s) {
        if (s == SpeechToText.doneStatus || s == SpeechToText.notListeningStatus) {
          _onEnd?.call(null);
        }
      },
      onError: (e) {
        final msg = e.errorMsg;
        if (_onDevice &&
            (msg == 'error_language_unavailable' || msg == 'error_language_not_supported')) {
          debugPrint('[AUGURE][STT] pt-BR offline indisponivel; usando reconhecimento padrao');
          _onDevice = false;
        }
        _onEnd?.call(msg);
      },
    );
    return _ready;
  }

  @override
  bool get isListening => _dictation.isListening;

  @override
  Future<void> listen(void Function(String text, bool isFinal) onResult) async {
    if (!_ready) return;
    await _dictation.listen(onResult);
  }

  @override
  Future<void> stop() => _dictation.stop();

  /// Abre UMA sessao do reconhecedor do sistema (a [ContinuousDictation] encadeia varias).
  Future<bool> _startNative(
    void Function(String words, bool isFinal) onWords,
    void Function(String? error) onEnd,
  ) async {
    _onEnd = onEnd;
    await _stt.listen(
      listenOptions: SpeechListenOptions(
        localeId: 'pt_BR',
        listenFor: const Duration(seconds: 60),
        partialResults: true,
        listenMode: ListenMode.dictation,
        cancelOnError: false,
        onDevice: _onDevice,
      ),
      onResult: (r) => onWords(r.recognizedWords, r.finalResult),
    );
    return true;
  }
}

/// Ponte entre a [ContinuousDictation] e o plugin speech_to_text.
class _PluginSession implements RecognizerSession {
  _PluginSession(this._owner);
  final SystemStt _owner;

  @override
  Future<bool> start(
    void Function(String words, bool isFinal) onWords,
    void Function(String? error) onEnd,
  ) =>
      _owner._startNative(onWords, onEnd);

  @override
  Future<void> stop() => _owner._stt.stop();
}

/// TTS do sistema com a melhor voz pt-BR instalada no aparelho.
///
/// - Escolhe a voz de maior qualidade que funciona SEM internet (app offline-first).
/// - Fala frase por frase: pausas naturais entre as frases e parada imediata quando a
///   pessoa toca no microfone.
class SystemTts implements TtsEngine {
  final FlutterTts _tts = FlutterTts();

  /// Incrementado a cada nova fala/parada; frases de uma fala antiga sao descartadas.
  int _generation = 0;

  /// Velocidade: 0.5 e a fala normal do Android. Um pouco abaixo ajuda quem tem pouca
  /// familiaridade digital, sem soar arrastado.
  static const _rate = 0.48;

  @override
  Future<void> init() async {
    await _tts.setLanguage('pt-BR');
    await _selectBestVoice();
    await _tts.setSpeechRate(_rate);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);
    await _tts.awaitSpeakCompletion(true);
  }

  Future<void> _selectBestVoice() async {
    try {
      final raw = await _tts.getVoices;
      if (raw is! List) return;
      final voices = raw
          .whereType<Map>()
          .map((v) => v.map((k, val) => MapEntry('$k', '$val')))
          .where((v) => (v['locale'] ?? '').toLowerCase().replaceAll('_', '-') == 'pt-br')
          .toList();
      if (voices.isEmpty) {
        debugPrint('[AUGURE][TTS] nenhuma voz pt-BR encontrada; usando a padrao');
        return;
      }
      voices.sort((a, b) => _score(b).compareTo(_score(a)));
      final best = voices.first;
      debugPrint('[AUGURE][TTS] ${voices.length} vozes pt-BR. Escolhida: ${best['name']} '
          '(qualidade=${best['quality']}, internet=${best['network_required']})');
      await _tts.setVoice({'name': best['name']!, 'locale': best['locale']!});
    } catch (e) {
      debugPrint('[AUGURE][TTS] falha ao escolher voz: $e');
    }
  }

  /// Pontua a voz: instalada e offline primeiro, depois qualidade, depois latencia.
  static int _score(Map<String, String> v) {
    final features = v['features'] ?? '';
    final name = (v['name'] ?? '').toLowerCase();
    var s = 0;
    if (features.contains('notInstalled')) s -= 10000;
    if (v['network_required'] == '1') s -= 1000; // depende de internet: evita
    if (name.contains('local')) s += 50;
    s += switch (v['quality']) {
      'very high' => 400,
      'high' => 300,
      'normal' => 200,
      'low' => 100,
      _ => 0,
    };
    s += switch (v['latency']) {
      'very low' => 20,
      'low' => 15,
      'normal' => 10,
      'high' => 5,
      _ => 0,
    };
    return s;
  }

  @override
  Future<void> speak(String text) async {
    final gen = ++_generation;
    await _tts.stop();
    for (final sentence in splitSentences(prepareForSpeech(text))) {
      if (gen != _generation) return; // outra fala comecou ou o usuario parou
      await _tts.speak(sentence);
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    await _tts.stop();
  }
}

/// Ajusta o texto exibido para soar natural na voz (sem mudar o que aparece na tela).
@visibleForTesting
String prepareForSpeech(String text) => text
    // "diga: pular." -> pausa curta em vez de ler a pontuacao de forma truncada
    .replaceAll(RegExp(r':\s*'), ', ')
    .replaceAll('%', ' por cento')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Divide em frases (pausa natural entre elas).
@visibleForTesting
List<String> splitSentences(String text) => text
    .split(RegExp(r'(?<=[.!?])\s+'))
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toList();

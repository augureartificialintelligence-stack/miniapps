import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'voice_engines.dart';

/// STT do sistema (Android SpeechRecognizer / iOS Speech). Funciona offline apenas se o
/// pacote de idioma pt-BR estiver instalado no aparelho: validar no Experimento B.
class SystemStt implements SttEngine {
  final SpeechToText _stt = SpeechToText();
  bool _ready = false;

  @override
  Future<bool> init() async {
    _ready = await _stt.initialize();
    return _ready;
  }

  @override
  bool get isListening => _stt.isListening;

  @override
  Future<void> listen(void Function(String text, bool isFinal) onResult) async {
    if (!_ready) return;
    await _stt.listen(
      listenOptions: SpeechListenOptions(
        localeId: 'pt_BR',
        listenFor: const Duration(seconds: 20),
        pauseFor: const Duration(seconds: 3),
        partialResults: true,
        // Tenta reconhecimento no aparelho; se o sistema nao suportar, ele cai para o padrao.
        onDevice: true,
      ),
      onResult: (r) => onResult(r.recognizedWords, r.finalResult),
    );
  }

  @override
  Future<void> stop() => _stt.stop();
}

class SystemTts implements TtsEngine {
  final FlutterTts _tts = FlutterTts();

  @override
  Future<void> init() async {
    await _tts.setLanguage('pt-BR');
    await _tts.setSpeechRate(0.45); // mais devagar: publico com baixa familiaridade digital
    await _tts.awaitSpeakCompletion(true);
  }

  @override
  Future<void> speak(String text) async {
    await _tts.stop();
    await _tts.speak(text);
  }

  @override
  Future<void> stop() async {
    await _tts.stop();
  }
}

/// Interfaces de voz. A UI e o motor de dialogo dependem apenas destas abstracoes,
/// entao trocar o STT/TTS do sistema por whisper.cpp / sherpa-onnx / Piper (fase 2)
/// nao exige mexer no restante do app.
abstract class SttEngine {
  /// Prepara o reconhecedor. Retorna false se indisponivel (sem permissao/idioma).
  Future<bool> init();

  /// Escuta uma frase. [onResult] recebe texto parcial e, ao final, `isFinal = true`.
  Future<void> listen(void Function(String text, bool isFinal) onResult);

  Future<void> stop();
  bool get isListening;
}

abstract class TtsEngine {
  Future<void> init();
  Future<void> speak(String text);
  Future<void> stop();
}

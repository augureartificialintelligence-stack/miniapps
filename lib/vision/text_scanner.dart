import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Le o texto de uma foto (receita, nota, cupom). Interface para trocar o motor ou
/// simular nos testes.
abstract class TextScanner {
  Future<String> scan(String imagePath);
  Future<void> dispose();
}

/// Leitor de texto do Google (ML Kit), 100% no aparelho e sem internet.
/// Funciona bem com texto impresso; letra a mao e foto tremida saem pior.
class MlKitTextScanner implements TextScanner {
  final _recognizer = TextRecognizer(script: TextRecognitionScript.latin);

  @override
  Future<String> scan(String imagePath) async {
    final result = await _recognizer.processImage(InputImage.fromFilePath(imagePath));
    return result.text;
  }

  @override
  Future<void> dispose() => _recognizer.close();
}

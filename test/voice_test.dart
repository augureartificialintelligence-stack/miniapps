import 'package:augure_miniapps/voice/system_voice.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('preparo da fala', () {
    test('dois-pontos viram pausa e % vira "por cento"', () {
      expect(prepareForSpeech('Se não tiver, diga: pular.'), 'Se não tiver, diga, pular.');
      expect(prepareForSpeech('margem de 30%'), 'margem de 30 por cento');
    });

    test('divide em frases para pausas naturais', () {
      expect(splitSentences('Prazer, Ana! Qual produto? Fale agora.'),
          ['Prazer, Ana!', 'Qual produto?', 'Fale agora.']);
      // ponto decimal/milhar nao quebra a frase
      expect(splitSentences('Custa 12.50 reais. Certo?'), ['Custa 12.50 reais.', 'Certo?']);
    });
  });
}

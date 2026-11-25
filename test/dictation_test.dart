import 'package:augure_miniapps/voice/continuous_dictation.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reconhecedor falso: o teste controla quando chegam palavras e quando a sessao fecha.
class FakeRecognizer implements RecognizerSession {
  int starts = 0;
  int stops = 0;
  void Function(String words, bool isFinal)? _words;
  void Function(String? error)? _end;

  @override
  Future<bool> start(void Function(String, bool) onWords, void Function(String?) onEnd) async {
    starts++;
    _words = onWords;
    _end = onEnd;
    return true;
  }

  @override
  Future<void> stop() async => stops++;

  void say(String words, {bool isFinal = false}) => _words!(words, isFinal);

  /// O Android fechando a sessao sozinho numa pausa curta (ou com erro).
  void systemEnds([String? error]) => _end!(error);
}

void main() {
  late FakeRecognizer rec;
  late ContinuousDictation d;
  late List<(String, bool)> results;

  void setUpDictation() {
    rec = FakeRecognizer();
    d = ContinuousDictation(rec);
    results = [];
  }

  String? finalText() =>
      results.where((r) => r.$2).map((r) => r.$1).cast<String?>().firstOrNull;

  test('pausa curta do Android NAO encerra: junta as frases', () {
    fakeAsync((t) {
      setUpDictation();
      d.listen((text, fin) => results.add((text, fin)));
      t.flushMicrotasks();

      rec.say('quero vender');
      rec.say('quero vender', isFinal: true);
      rec.systemEnds(); // Android cortou na primeira pausa
      t.elapse(const Duration(milliseconds: 500)); // reabriu o microfone
      expect(rec.starts, 2);
      expect(d.isListening, isTrue);
      expect(finalText(), isNull);

      rec.say('marmitas de frango');
      expect(results.last, ('quero vender marmitas de frango', false));

      t.elapse(const Duration(seconds: 3)); // silencio de verdade
      expect(finalText(), 'quero vender marmitas de frango');
      expect(d.isListening, isFalse);
    });
  });

  test('so termina depois de 3 s SEM palavras novas', () {
    fakeAsync((t) {
      setUpDictation();
      d.listen((text, fin) => results.add((text, fin)));
      t.flushMicrotasks();
      rec.say('uma panela');
      t.elapse(const Duration(seconds: 2));
      rec.say('uma panela rende vinte'); // falou de novo antes dos 3 s
      t.elapse(const Duration(seconds: 2));
      expect(finalText(), isNull);
      t.elapse(const Duration(seconds: 1));
      expect(finalText(), 'uma panela rende vinte');
    });
  });

  test('ninguem falou: encerra em 10 s com texto vazio', () {
    fakeAsync((t) {
      setUpDictation();
      d.listen((text, fin) => results.add((text, fin)));
      t.flushMicrotasks();
      rec.systemEnds('error_speech_timeout');
      t.elapse(const Duration(seconds: 9));
      expect(d.isListening, isTrue);
      t.elapse(const Duration(seconds: 1));
      expect(finalText(), '');
    });
  });

  test('tocar em parar entrega o que foi ouvido', () {
    fakeAsync((t) {
      setUpDictation();
      d.listen((text, fin) => results.add((text, fin)));
      t.flushMicrotasks();
      rec.say('doces da ana');
      d.stop();
      t.flushMicrotasks();
      expect(finalText(), 'doces da ana');
      expect(rec.stops, 1);
      // Eventos atrasados da sessao antiga sao ignorados.
      rec.say('lixo atrasado');
      expect(results.where((r) => r.$2), hasLength(1));
    });
  });

  test('erro de permissao encerra sem reabrir', () {
    fakeAsync((t) {
      setUpDictation();
      d.listen((text, fin) => results.add((text, fin)));
      t.flushMicrotasks();
      rec.systemEnds('error_permission');
      t.elapse(const Duration(seconds: 1));
      expect(rec.starts, 1);
      expect(d.isListening, isFalse);
    });
  });

  test('status duplicado do sistema reabre o microfone uma vez so', () {
    fakeAsync((t) {
      setUpDictation();
      d.listen((text, fin) => results.add((text, fin)));
      t.flushMicrotasks();
      rec.say('vinte');
      rec.systemEnds(); // "notListening"
      rec.systemEnds(); // "done"
      t.elapse(const Duration(milliseconds: 500));
      expect(rec.starts, 2);
    });
  });
}

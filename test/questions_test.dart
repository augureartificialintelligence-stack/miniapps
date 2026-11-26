import 'package:augure_miniapps/core/cost_breakdown.dart';
import 'package:augure_miniapps/core/dialog_machine.dart';
import 'package:augure_miniapps/core/pt_br_parser.dart';
import 'package:augure_miniapps/llm/llm_engine.dart';
import 'package:augure_miniapps/llm/smart_dialog.dart';
import 'package:augure_miniapps/llm/utterance_interpreter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Precos registrados de outro produto (memoria).
const saved = [
  KnownPrice('farinha de trigo', 550, Measure(1000, MeasureKind.mass), from: 'bolo de cenoura'),
  KnownPrice('ovos', 900, Measure(12, MeasureKind.unit), from: 'bolo de cenoura'),
  KnownPrice('chocolate em pó', 2800, Measure(200, MeasureKind.mass), from: 'bolo de cenoura'),
];

/// Bolo de chocolate novo, no detalhamento de custo, pergunta do preco da farinha.
DialogMachine atPrices({List<KnownPrice> known = saved}) {
  final m = DialogMachine(
    knownPrices: () => known,
    savedProductNames: () => ['bolo de cenoura'],
  )..start();
  for (final a in [
    'Bolinho feliz',
    'confeitaria',
    'bolo de chocolate',
    '2 xícaras de farinha de trigo, 3 ovos, meia xícara de chocolate em pó, 1 xícara de leite',
    '12',
    '60 minutos',
    'pular',
    '12',
    '25 reais',
    '70',
    'sim',
    'sim', // detalhar
  ]) {
    m.handle(a);
  }
  expect(m.state, DialogState.costDetail);
  expect(m.lastPrompt, contains('Quanto você paga em farinha'));
  return m;
}

void main() {
  test('reconhece perguntas (com e sem "?")', () {
    expect(isQuestion('Você tem registro dos preços dos produtos listados?'), isTrue);
    expect(isQuestion('voce tem registro dos precos'), isTrue);
    expect(isQuestion('quanto paguei na farinha'), isTrue);
    expect(isQuestion('o que falta'), isTrue);
    expect(isQuestion('5 reais o quilo'), isFalse);
    expect(isQuestion('farinha e ovos'), isFalse);
  });

  test('frase real: "Você tem registro dos preços dos produtos listados?" e usar', () {
    final m = atPrices();
    final r = m.handle('Você tem registro dos preços dos produtos listados?');
    expect(r.understood, isTrue);
    expect(r.state, DialogState.costDetail); // nao saiu da entrevista
    expect(r.text, contains('farinha de trigo, 5 reais e 50 centavos por 1 quilo (do bolo de cenoura)'));
    expect(r.text, contains('ovos, 9 reais por 12 unidades'));
    expect(r.text, contains('Quer que eu use esses preços na tabela?'));

    final r2 = m.handle('sim');
    expect(r2.text, contains('Pronto, usei 3 preços salvos.'));
    expect(r2.text, contains('Quanto você paga em leite')); // so o que nao tinha registro
    final t = m.costTable!;
    expect(t.materials.firstWhere((i) => i.name == 'farinha de trigo').costCents, 132);
    expect(t.materials.firstWhere((i) => i.name == 'ovos').costCents, 225);
  });

  test('"nao" mantem a pergunta atual sem usar os precos', () {
    final m = atPrices();
    m.handle('voce tem registro dos precos');
    final r = m.handle('não');
    expect(r.text, contains('Quanto você paga em farinha'));
    expect(m.costTable!.materials.first.priceCents, isNull);
  });

  test('pergunta de um ingrediente e "o que falta"', () {
    final m = atPrices();
    var r = m.handle('quanto paguei na farinha?');
    expect(r.text, contains('Tenho registrado: farinha de trigo, 5 reais e 50 centavos'));
    expect(r.text, contains('Voltando: Quanto você paga em farinha'));
    r = m.handle('o que falta?');
    expect(r.text, contains('Falta completar: farinha de trigo (preço), ovos (preço)'));
  });

  test('sem registros', () {
    final m = atPrices(known: const []);
    final r = m.handle('você tem registro dos preços?');
    expect(r.text, contains('Ainda não tenho preços salvos'));
    expect(r.state, DialogState.costDetail);
  });

  test('pergunta nunca vira resposta da pergunta atual', () {
    final m = DialogMachine()..start();
    m.handle('Bolinho feliz');
    m.handle('confeitaria');
    m.handle('bolo');
    expect(m.state, DialogState.askMaterials);
    final r = m.handle('qual a diferença entre fermento químico e biológico?');
    expect(r.understood, isFalse); // o app nao sabe; a IA local pode responder
    expect(m.session.materials, isNull); // nao virou lista de ingredientes
    expect(m.state, DialogState.askMaterials);
  });

  test('pergunta livre respondida pela IA local, conversa continua', () async {
    final llm = _QaLlm('{"resposta": "O químico age no forno; o biológico precisa descansar."}');
    final d = SmartDialog(DialogMachine(), UtteranceInterpreter(llm))..start();
    for (final a in ['Bolinho feliz', 'confeitaria', 'bolo']) {
      await d.handle(a);
    }
    final r = await d.handle('qual a diferença entre fermento químico e biológico?');
    expect(r.text, startsWith('O químico age no forno'));
    expect(r.text, contains('Voltando: Do que bolo é feito'));
    expect(d.machine.state, DialogState.askMaterials);
    expect(llm.prompt, contains('NUNCA invente precos'));
  });

  test('"quanto devo cobrar?" depois do calculo', () {
    final m = DialogMachine(profile: const SalesSession(product: 'bolo', batchYield: 12))
      ..start();
    m.handle('12');
    m.handle('20 reais');
    m.handle('70');
    m.handle('sim');
    final r = m.handle('quanto devo cobrar?');
    expect(r.text, contains('O preço sugerido da unidade é 5 reais e 56 centavos'));
  });
}

class _QaLlm implements LlmEngine {
  _QaLlm(this.reply);
  final String reply;
  String prompt = '';
  @override
  bool get isReady => true;
  @override
  Future<bool> load() async => true;
  @override
  Future<String> complete(String prompt,
      {Map<String, Object?>? jsonSchema, int maxTokens = 48}) async {
    this.prompt = prompt;
    return reply;
  }

  @override
  Future<void> dispose() async {}
}

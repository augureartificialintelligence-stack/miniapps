import 'package:augure_miniapps/core/dialog_machine.dart';
import 'package:augure_miniapps/core/document_parser.dart';
import 'package:augure_miniapps/core/pt_br_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// Caso real: bolo de cenoura, 12 pedacos, R$ 18, 80%, detalhar custo, partes
/// "massa e cobertura".
DialogMachine atMassa() {
  final m = DialogMachine(
      profile: const SalesSession(
          company: 'Alfaprotein', product: 'bolo de cenoura', batchYield: 12))
    ..start();
  m.handle('12 pedaços de 1 bolo');
  m.handle('18 reais');
  m.handle('80 %');
  m.handle('sim');
  m.handle('sim'); // detalhar
  final r = m.handle('massa e cobertura');
  expect(r.text, contains('Para a massa, quais ingredientes'));
  return m;
}

const massaDitada = 'três cenouras médias descascadas total 300 G, três ovos inteiros uma '
    'xícara de chá de óleo uma xícara e meia de chá de Açúcar';

void main() {
  test('frase real: ingredientes da massa com quantidades viram itens certos', () {
    final m = atMassa();
    final r = m.handle(massaDitada);
    final items = [
      for (final i in m.costTable!.materials) '${i.part}|${i.name}|${i.used}',
    ];
    expect(items, [
      // "tres cenouras ... total 300 G": o peso total vale mais que a contagem
      'Massa|cenouras médias descascadas|${const Measure(300, MeasureKind.mass)}',
      'Massa|ovos inteiros|${const Measure(3, MeasureKind.unit)}',
      'Massa|óleo|${const Measure(240, MeasureKind.volume)}',
      'Massa|açúcar|${const Measure(360, MeasureKind.volume)}',
    ]);
    expect(r.text, contains('Para a cobertura'));
  });

  test('frase real: "faltaram ingredientes da massa" volta para a massa, nao vira cobertura',
      () {
    final m = atMassa()..handle(massaDitada);
    final r = m.handle('faltaram ingredientes da massa');
    expect(r.text, contains('Quais ingredientes faltaram na massa'));
    expect(m.costTable!.materials.where((i) => i.part == 'Cobertura'), isEmpty);

    final r2 = m.handle('duas xícaras de farinha de trigo e uma colher de sopa de fermento');
    expect(r2.text, contains('Anotei a massa: farinha de trigo (2 xícaras)'));
    expect(r2.text, contains('Para a cobertura')); // voltou para onde estava
    final massa = m.costTable!.materials.where((i) => i.part == 'Massa').map((i) => i.name);
    expect(massa, containsAll(['farinha de trigo', 'fermento']));
  });

  test('"faltou ... na massa" com os ingredientes ja anota sem sair da pergunta', () {
    final m = atMassa()..handle(massaDitada);
    final r = m.handle('faltou uma pitada de sal na massa');
    expect(r.text, contains('Anotei na massa: sal'));
    expect(r.text, contains('Para a cobertura'));
    expect(m.costTable!.materials.any((i) => i.name == 'sal' && i.part == 'Massa'), isTrue);
  });

  test('lista real digitada com virgulas e quantidade depois do nome', () {
    final m = DialogMachine()..start();
    m.handle('Alfaprotein');
    m.handle('confeitaria');
    m.handle('bolo de cenoura');
    m.handle('3 unidades de cenoura 300g, 3 ovos inteiros, 1 xícara de chá de óleo, 1 xícara '
        'e meia de chá de açúcar, 2 xicaras de chá de farinha de trigo, fermento químico em '
        'pó 1 colher de sopa, 1 pitada de sal, chocolate em pó 50% cacau meia xícara, '
        'manteiga 1 colher de sopa, leite 5 colheres de sopa');
    expect([for (final i in m.costTable!.materials) '${i.name}|${i.used}'], [
      'cenoura|${const Measure(300, MeasureKind.mass)}',
      'ovos inteiros|${const Measure(3, MeasureKind.unit)}',
      'óleo|${const Measure(240, MeasureKind.volume)}',
      'açúcar|${const Measure(360, MeasureKind.volume)}',
      'farinha de trigo|${const Measure(480, MeasureKind.volume)}',
      'fermento químico em pó|${const Measure(15, MeasureKind.volume)}',
      'sal|${const Measure(0.5, MeasureKind.mass)}',
      'chocolate em pó 50% cacau|${const Measure(120, MeasureKind.volume)}',
      'manteiga|${const Measure(15, MeasureKind.volume)}',
      'leite|${const Measure(75, MeasureKind.volume)}',
    ]);
  });

  test('lista real ditada so com nomes, sem virgula nem "e"', () {
    final items = parseSpokenRecipe('cenoura ovos óleo de soja açúcar refinado farinha de '
            'trigo fermento químico em pó sal chocolate em pó 50% Cacau manteiga leite integral')
        .map((i) => i.name)
        .toList();
    expect(items, [
      'cenoura',
      'ovos',
      'óleo de soja',
      'açúcar refinado',
      'farinha de trigo',
      'fermento químico em pó',
      'sal',
      'chocolate em pó 50% Cacau',
      'manteiga',
      'leite integral',
    ]);
    // "de leite" nao abre item novo
    expect(parseSpokenRecipe('creme de leite leite condensado doce de leite').map((i) => i.name),
        ['creme de leite', 'leite condensado', 'doce de leite']);
  });

  test('conversa nao vira ingrediente', () {
    final m = atMassa();
    final r = m.handle('eu acho que poderia ser uma subdivisão do Universal');
    expect(r.understood, isFalse);
    expect(m.costTable!.materials, isEmpty);
  });

  group('envio automatico so do que parece resposta', () {
    test('frases reais do teste', () {
      final m = DialogMachine(profile: const SalesSession(product: 'bolo'))..start();
      expect(m.state, DialogState.askQuantity);
      expect(m.looksLikeAnswer('12 pedaços de 1 bolo'), isTrue);
      m.handle('12');
      m.handle('18 reais');
      expect(m.state, DialogState.askMargin);
      expect(m.looksLikeAnswer('reproduzir'), isFalse); // ruido
      expect(m.looksLikeAnswer('80 %'), isTrue);
      m.handle('80');
      m.handle('sim');
      expect(m.state, DialogState.offerDetail);
      expect(m.looksLikeAnswer('Então olha só primeira'), isFalse); // frase cortada
      expect(m.looksLikeAnswer('sim'), isTrue);
      expect(m.looksLikeAnswer('quero vender o pedaço por 6 reais'), isTrue);
      m.handle('sim');
      expect(m.looksLikeAnswer('eu acho que poderia ser uma subdivisão do Universal'),
          isFalse);
      expect(m.looksLikeAnswer('massa e cobertura'), isTrue);
      m.handle('não'); // sem partes, sem materiais: pergunta a lista
      m.handle('farinha');
      expect(m.looksLikeAnswer('myselfie detec'), isFalse); // quantidade da farinha
      expect(m.looksLikeAnswer('2 xícaras'), isTrue);
    });

    test('frase real de conversa paralela na confirmacao nao e enviada sozinha', () {
      final m = DialogMachine(profile: const SalesSession(product: 'bolo'))..start();
      m.handle('12');
      m.handle('20');
      m.handle('80');
      expect(m.state, DialogState.confirm);
      expect(
          m.looksLikeAnswer(
              'mais utilização de acaba usando dois aplicativos ao mesmo tempo é só multi melhor né'),
          isFalse);
      expect(m.looksLikeAnswer('dividir a tela'), isFalse);
      expect(m.looksLikeAnswer('o tempo é 2 horas'), isTrue); // informacao valida
    });

    test('frase real: conversa de fundo nao vira nome da empresa', () {
      const fala = 'não consigo localizá-la tem como fazer um baratinho para ela uma dor é '
          'uma 12 esses de segunda a terceira linha que ela não vai usar os recursos';
      final m = DialogMachine()..start();
      expect(m.state, DialogState.askCompany);
      expect(m.looksLikeAnswer(fala), isFalse); // nao envia sozinho
      expect(m.looksLikeAnswer('Bolinho feliz'), isTrue);
      final r = m.handle(fala); // mesmo enviada, nao vira nome
      expect(r.understood, isFalse);
      expect(m.state, DialogState.askCompany);
      expect(m.session.company, isNull);
      m.handle('Bolinho feliz');
      m.handle('confeitaria');
      expect(m.handle(fala).understood, isFalse);
      expect(m.session.product, isNull);
      expect(m.handle('bolo de cenoura com cobertura de chocolate').state,
          isNot(DialogState.askProduct));
    });

    test('correcoes e comandos sempre parecem resposta', () {
      final m = DialogMachine(profile: const SalesSession(product: 'bolo'))..start();
      expect(m.looksLikeAnswer('voltar'), isTrue);
      expect(m.looksLikeAnswer('a margem é 40%'), isTrue);
      expect(m.looksLikeAnswer('corrigir o produto'), isTrue);
    });
  });
}

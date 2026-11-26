import 'package:augure_miniapps/core/dialog_machine.dart';
import 'package:flutter_test/flutter_test.dart';

const lista = '3 unidades de cenoura 300g, 3 ovos inteiros, 1 xícara de chá de óleo, '
    '1 xícara e meia de chá de açúcar, 2 xicaras de chá de farinha de trigo, fermento '
    'químico em pó 1 colher de sopa, 1 pitada de sal, chocolate em pó 50% cacau meia '
    'xícara, manteiga 1 colher de sopa, leite 5 colheres de sopa';

/// Caso real: bolo de cenoura com a lista digitada, 12 pedacos, R$ 20, 70%, detalhar.
DialogMachine atPrices() {
  final m = DialogMachine()..start();
  for (final a in [
    'Alfaprotein',
    'confeitaria',
    'bolo de cenoura',
    lista,
    '12 unidades de 1 bolo',
    '70 minutos',
    'pular',
    '12 pedaços de 1 bolo',
    '20 reais',
    '70%',
    'sim',
    'sim', // detalhar
  ]) {
    m.handle(a);
  }
  expect(m.state, DialogState.costDetail);
  return m;
}

int? cost(DialogMachine m, String name) =>
    m.costTable!.materials.firstWhere((i) => i.name == name).costCents;

void main() {
  test('precos reais um a um, cada ingrediente no seu item', () {
    final m = atPrices();
    var r = m.handle('6,50 o quilo');
    expect(r.text, contains('cenoura'));
    m.handle('9 a duzia');
    m.handle('8,50 para 900ml');
    m.handle('5 reais o quilo');
    expect(cost(m, 'cenoura'), 195); // 300 g a R$ 6,50/kg
    expect(cost(m, 'ovos inteiros'), 225); // 3 de 12 a R$ 9
    expect(cost(m, 'óleo'), 227); // 240 ml de 900 ml a R$ 8,50
    expect(cost(m, 'açúcar'), 135); // ~270 g a R$ 5/kg
  });

  test('frase real com dois precos: farinha e fermento de uma vez', () {
    final m = atPrices();
    for (final a in ['6,50 o quilo', '9 a duzia', '8,50 para 900ml', '5 reais o quilo']) {
      m.handle(a);
    }
    final r = m.handle('5,50 o quilo da farinha e 4,50 reais 100 gramas de fermento');
    expect(r.text, contains('Anotei os preços'));
    expect(cost(m, 'farinha de trigo'), 132); // 240 g a R$ 5,50/kg
    expect(cost(m, 'fermento químico em pó'), 61); // ~13,5 g de 100 g a R$ 4,50
    expect(r.text, contains('Quanto você paga em sal')); // pulou o fermento, ja pago
  });

  test('chocolate, manteiga e leite com as quantidades certas', () {
    final m = atPrices();
    for (final a in [
      '6,50 o quilo', '9 a duzia', '8,50 para 900ml', '5 reais o quilo',
      '5,50 o quilo da farinha e 4,50 reais 100 gramas de fermento',
      '2 reais o quilo', // sal
      '28 reais 200 gramas de chocolate',
      '14 reais 200g',
      '5 reais o litro',
    ]) {
      m.handle(a);
    }
    expect(cost(m, 'chocolate em pó 50% cacau'), 638); // ~46 g de 200 g a R$ 28
    expect(cost(m, 'manteiga'), 100); // ~14 g de 200 g a R$ 14
    expect(cost(m, 'leite'), 38); // 75 ml a R$ 5/l
  });

  group('correcoes dentro do custo', () {
    DialogMachine atExtras() {
      final m = atPrices();
      for (final a in [
        '6,50 o quilo', '9 a duzia', '8,50 para 900ml', '5 reais o quilo',
        '5,50 o quilo da farinha e 4,50 reais 100 gramas de fermento',
        '2 reais o quilo', '28 reais 200 gramas de chocolate', '14 reais 200g',
        '5 reais o litro', 'não', // mais materiais
        '1,70', // embalagem
        'pular', // frete
        '3 reais', // gas
        '20 reais por hora',
      ]) {
        m.handle(a);
      }
      return m;
    }

    test('frase real: "quero alterar o valor da embalagem por unidade"', () {
      final m = atExtras();
      final r = m.handle('quero alterar o valor da embalagem por unidade');
      expect(r.understood, isTrue);
      expect(r.text, contains('Quanto custa a embalagem de CADA unidade'));
      final r2 = m.handle('1 real e 50 centavos');
      expect(m.costTable!.packagingPerUnitCents, 150);
      expect(r2.text, contains('Voltando: Tem mais algum custo')); // volta para "outros"
    });

    test('com o valor junto: aplica e continua na mesma pergunta', () {
      final m = atExtras();
      final r = m.handle('alterar a embalagem para 1,50');
      expect(m.costTable!.packagingPerUnitCents, 150);
      expect(r.text, contains('Corrigido: embalagem 1 real e 50 centavos'));
      expect(r.text, contains('Tem mais algum custo'));
      m.handle('mudar o pró-labore para 30 reais');
      expect(m.costTable!.laborHourlyCents, 3000);
      expect(m.costTable!.laborCents, 3500); // 70 minutos
    });

    test('ingrediente pelo nome: preco e quantidade', () {
      final m = atExtras();
      var r = m.handle('corrigir o preço da farinha');
      expect(r.text, contains('vamos corrigir farinha de trigo'));
      m.handle('6 reais o quilo');
      expect(cost(m, 'farinha de trigo'), 144);
      r = m.handle('na verdade a manteiga é 2 colheres de sopa');
      expect(r.text, contains('Corrigido: manteiga'));
      expect(cost(m, 'manteiga'), closeTo(200, 1)); // 2 colheres ~28 g de 200 g a R$ 14
    });

    test('tirar ingrediente pelo nome', () {
      final m = atExtras();
      final r = m.handle('tirar o sal');
      expect(r.text, contains('Tirei sal da tabela'));
      expect(m.costTable!.materials.any((i) => i.name == 'sal'), isFalse);
    });

    test('listando ingredientes, nome repetido nao vira correcao', () {
      final m = DialogMachine(
          profile: const SalesSession(product: 'bolo', batchYield: 12))
        ..start();
      for (final a in ['12', '20 reais', '70', 'sim', 'sim', 'massa e cobertura']) {
        m.handle(a);
      }
      m.handle('2 xícaras de farinha e 3 ovos');
      final r = m.handle('meia xícara de farinha e 100 gramas de chocolate');
      expect(r.state, DialogState.costDetail);
      final farinhas = m.costTable!.materials.where((i) => i.name == 'farinha');
      expect(farinhas, hasLength(2)); // uma na massa, outra na cobertura
    });
  });

  test('corrigir os ingredientes no meio do custo mantem os precos ja dados', () {
    final m = atPrices();
    m.handle('6,50 o quilo'); // cenoura
    m.handle('9 a duzia'); // ovos
    final r = m.handle('corrigir os ingredientes');
    expect(r.state, DialogState.askMaterials);
    final r2 = m.handle('300 gramas de cenoura, 4 ovos e 2 xícaras de farinha');
    expect(r2.state, DialogState.costDetail);
    expect(r2.text, contains('Voltando ao custo'));
    expect(cost(m, 'cenoura'), 195); // preco mantido
    expect(cost(m, 'ovos'), 300); // 4 de 12 a R$ 9 (preco mantido, quantidade nova)
    expect(r2.text, contains('Quanto você paga em farinha')); // so o que falta
  });

  test('"salvar estes dados" explica que ja fica salvo', () {
    final m = atPrices();
    m.handle('não'); // nada
    for (var i = 0; i < 20 && m.state == DialogState.costDetail; i++) {
      m.handle('pular');
    }
    expect(m.state, DialogState.result);
    final r = m.handle('salvar estes dados');
    expect(r.text, contains('tudo já fica salvo automaticamente'));
  });
}

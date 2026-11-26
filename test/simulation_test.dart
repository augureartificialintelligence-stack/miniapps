import 'package:augure_miniapps/core/cost_breakdown.dart';
import 'package:augure_miniapps/core/dialog_machine.dart';
import 'package:augure_miniapps/core/pt_br_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// Caso real do teste no celular: bolo de cenoura, 12 unidades, R$ 18 de custo, 30%.
DialogMachine atOffer() {
  final m = DialogMachine(
      profile: const SalesSession(
          company: 'Alfaprotein', product: 'bolo de cenoura', batchYield: 12))
    ..start();
  m.handle('12 unidades');
  m.handle('18 reais');
  m.handle('30%');
  final r = m.handle('sim');
  expect(r.state, DialogState.offerDetail);
  expect(r.result!.unitPriceCents, 215); // 18 / 0,7 = 25,72 -> /12 = 2,15
  return m;
}

void main() {
  test('frase real: "quero vender a unidade por 6 reais"', () {
    final m = atOffer();
    final r = m.handle('quero vender a unidade por 6 reais');
    expect(r.understood, isTrue);
    expect(r.state, DialogState.offerDetail); // continua podendo detalhar o custo
    final s = m.simulation!;
    expect(s.priceCents, 600);
    expect(s.unitCostCents, 150); // 18 / 12
    expect(s.unitProfitCents, 450);
    expect(s.marginPercent.round(), 75);
    expect(s.batchRevenueCents, 7200);
    expect(s.batchProfitCents, 5400);
    expect(r.text, contains('você lucra 4 reais e 50 centavos por unidade, uma margem de 75'));
    expect(r.text, contains('No lote de 12 unidades, você recebe 72 reais e lucra 54 reais'));
    expect(r.text, contains('acima do sugerido, que é 2 reais e 15 centavos'));
    expect(r.text, contains('Quer detalhar o custo')); // a pergunta segue de pe
  });

  test('outras formas de dizer o preco', () {
    final m = atOffer();
    m.handle('e se eu cobrar 2 reais?');
    expect(m.simulation!.priceCents, 200);
    m.handle('quero vender o lote por 30 reais');
    expect(m.simulation!.priceCents, 250); // 30 / 12
    m.handle('cobrar 3,50 cada');
    expect(m.simulation!.priceCents, 350);
  });

  test('preco abaixo do custo avisa prejuizo', () {
    final m = atOffer();
    final r = m.handle('quero vender por 1 real');
    expect(m.simulation!.isLoss, isTrue);
    expect(r.text, contains('prejuízo de 50 centavos por unidade'));
    expect(r.text, contains('abaixo do custo de produção'));
    expect(r.text, contains('abaixo do sugerido'));
  });

  test('sim/nao da oferta continuam funcionando depois da simulacao', () {
    final m = atOffer()..handle('quero vender a unidade por 6 reais');
    expect(m.handle('não').state, DialogState.result);
    m.handle('vender por 5 reais');
    expect(m.simulation!.priceCents, 500); // tambem no resultado
    expect(m.handle('recomeçar').state, DialogState.askQuantity);
    expect(m.simulation, isNull); // novo calculo limpa a simulacao
  });

  test('usa o custo da tabela detalhada quando ela esta completa', () {
    final m = atOffer();
    m.handle('sim'); // detalhar
    m.handle('não'); // sem partes
    m.handle('cenoura');
    m.handle('3 unidades');
    m.handle('6 reais o quilo'); // cenoura ~100 g cada (tabela): 300 g a R$ 6/kg
    m.handle('não'); // mais materiais
    for (final a in ['pular', 'pular', 'pular', 'pular', 'não']) {
      m.handle(a);
    }
    expect(m.state, DialogState.result);
    final t = m.session.costs!;
    expect(t.batchCents, 180);
    m.handle('quero vender a unidade por 1 real');
    expect(m.simulation!.unitCostCents, 15); // 180 / 12, e nao 150 do custo total informado
  });

  test('nao confunde com respostas de preco na entrevista de custo', () {
    final m = atOffer()
      ..handle('sim')
      ..handle('não')
      ..handle('cenoura')
      ..handle('3 unidades');
    final r = m.handle('6 reais o quilo'); // preco de compra, nao simulacao
    expect(m.simulation, isNull);
    expect(r.state, DialogState.costDetail);
    expect(parseMeasure('150 gramas'), const Measure(150, MeasureKind.mass));
    expect(CostBreakdown().materials, isEmpty);
  });
}

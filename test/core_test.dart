import 'package:augure_miniapps/core/dialog_machine.dart';
import 'package:augure_miniapps/core/pricing_calculator.dart';
import 'package:augure_miniapps/core/pt_br_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pricing', () {
    test('20 marmitas, R\$120 de custo, 30% de margem', () {
      final r = calculatePricing(const PricingInput(
          quantity: 20, totalCostCents: 12000, marginPercent: 30));
      expect(r.unitCostCents, 600);
      expect(r.unitPriceCents, 858); // 12000/0.7=17142,86 -> 17143 -> /20 = 857,15 -> 858
      expect(r.totalRevenueCents, 17160);
      expect(r.profitCents, 5160);
    });

    test('margem zero vende ao custo', () {
      final r = calculatePricing(const PricingInput(
          quantity: 4, totalCostCents: 1000, marginPercent: 0));
      expect(r.unitPriceCents, 250);
      expect(r.profitCents, 0);
    });

    test('nunca fica abaixo da margem pedida', () {
      for (final m in [5, 10, 33, 50, 90]) {
        final r = calculatePricing(PricingInput(
            quantity: 7, totalCostCents: 9999, marginPercent: m));
        expect(r.profitCents * 100 >= r.totalRevenueCents * m - 100 * 7, isTrue);
        expect(r.totalRevenueCents - r.profitCents, 9999);
      }
    });

    test('entradas invalidas', () {
      expect(
          () => calculatePricing(const PricingInput(
              quantity: 0, totalCostCents: 1, marginPercent: 10)),
          throwsA(isA<PricingException>()));
      expect(
          () => calculatePricing(const PricingInput(
              quantity: 1, totalCostCents: 1, marginPercent: 95)),
          throwsA(isA<PricingException>()));
    });

    test('formatacao', () {
      expect(formatBrl(1250), 'R\$ 12,50');
      expect(formatBrl(123456789), 'R\$ 1.234.567,89');
      expect(speakBrl(1250), '12 reais e 50 centavos');
      expect(speakBrl(100), '1 real');
    });
  });

  group('parser pt-BR', () {
    test('inteiros', () {
      expect(parseInteger('vinte'), 20);
      expect(parseInteger('vinte e cinco marmitas'), 25);
      expect(parseInteger('cento e vinte'), 120);
      expect(parseInteger('duas mil e quinhentas'), 2500);
      expect(parseInteger('mil'), 1000);
      expect(parseInteger('1.500'), 1500);
      expect(parseInteger('quero 30'), 30);
      expect(parseInteger('nada'), isNull);
      // ambiguos: recusa em vez de ler so o primeiro numero
      expect(parseInteger('duas dezenas'), isNull);
      expect(parseInteger('meia duzia'), isNull);
    });

    test('dinheiro', () {
      expect(parseMoneyCents('12,50'), 1250);
      expect(parseMoneyCents('R\$ 30'), 3000);
      expect(parseMoneyCents('cento e vinte reais'), 12000);
      expect(parseMoneyCents('doze reais e cinquenta'), 1250);
      expect(parseMoneyCents('cinquenta centavos'), 50);
      expect(parseMoneyCents('120'), 12000);
      expect(parseMoneyCents('abc'), isNull);
      expect(parseMoneyCents('oitenta e sete e meio'), isNull);
    });

    test('sim/nao e comandos', () {
      expect(parseYesNo('Sim, está certo'), YesNo.yes);
      expect(parseYesNo('não'), YesNo.no);
      expect(parseYesNo('talvez'), isNull);
      expect(parseCommand('repete por favor'), Command.repeat);
      expect(parseCommand('quero recomeçar'), Command.restart);
      expect(parseCommand('voltar'), Command.back);
    });

    test('nome do produto', () {
      expect(parseProductName('Quero vender marmitas'), 'marmitas');
      expect(parseProductName('bolo de pote.'), 'bolo de pote');
    });
  });

  group('dialog machine', () {
    test('fluxo completo ate o resultado', () {
      final m = DialogMachine();
      m.start();
      expect(m.handle('quero vender marmitas').state, DialogState.askQuantity);
      expect(m.handle('vinte').state, DialogState.askCost);
      expect(m.handle('cento e vinte reais').state, DialogState.askMargin);
      expect(m.handle('trinta').state, DialogState.confirm);
      final r = m.handle('sim');
      expect(r.state, DialogState.result);
      expect(r.result!.unitPriceCents, 858);
    });

    test('entrada invalida mantem estado e pede de novo', () {
      final m = DialogMachine()..start();
      m.handle('marmitas');
      final r = m.handle('blablabla');
      expect(r.state, DialogState.askQuantity);
      expect(m.session.quantity, isNull);
    });

    test('voltar, repetir e recomecar', () {
      final m = DialogMachine()..start();
      m.handle('marmitas');
      m.handle('10');
      expect(m.handle('voltar').state, DialogState.askQuantity);
      expect(m.handle('repetir').state, DialogState.askQuantity);
      expect(m.handle('recomeçar').state, DialogState.askProduct);
      expect(m.session.product, isNull);
    });

    test('nao na confirmacao reinicia', () {
      final m = DialogMachine()..start();
      m.handle('marmitas');
      m.handle('10');
      m.handle('50 reais');
      m.handle('20');
      expect(m.handle('não').state, DialogState.askProduct);
    });

    test('margem fora da faixa e rejeitada', () {
      final m = DialogMachine()..start();
      m.handle('marmitas');
      m.handle('10');
      m.handle('50 reais');
      expect(m.handle('noventa e cinco').state, DialogState.askMargin);
    });
  });
}

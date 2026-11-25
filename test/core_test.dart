import 'package:augure_miniapps/core/dialog_machine.dart';
import 'package:augure_miniapps/core/pricing_calculator.dart';
import 'package:augure_miniapps/core/pt_br_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// Passa pela triagem (empresa, produto, especificacoes) ate a pergunta de quantidade.
void triage(DialogMachine m) {
  m.handle('Doces da Ana');
  m.handle('marmitas');
  m.handle('arroz, feijão e frango');
  m.handle('uma panela rende vinte');
  m.handle('duas horas');
  m.handle('pular');
  expect(m.state, DialogState.askQuantity);
}

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

  group('parser pt-BR triagem', () {
    test('nome da empresa', () {
      expect(parseCompanyName('minha empresa se chama doces da ana'), 'Doces da Ana');
      expect(parseCompanyName('O nome é Padaria Pão Quente.'), 'Padaria Pão Quente');
      expect(parseCompanyName('marmitaria bom sabor'), 'Marmitaria Bom Sabor');
    });

    test('pular so quando a fala inteira pede', () {
      expect(isSkip('pular'), isTrue);
      expect(isSkip('Não sei.'), isTrue);
      expect(isSkip('não tenho'), isTrue);
      expect(isSkip('sem açúcar'), isFalse);
      expect(isSkip('nada de glúten'), isFalse);
    });

    test('materiais e caracteristicas', () {
      expect(parseMaterials('é feito de farinha, ovos e açúcar'), 'farinha, ovos e açúcar');
      expect(parseMaterials('leva arroz e feijão.'), 'arroz e feijão');
      expect(parseCharacteristics('é de 500 gramas, sabor frango'), 'de 500 gramas, sabor frango');
    });

    test('rendimento do lote', () {
      expect(parseBatchYield('uma fornada rende vinte'), 20); // nao le o "uma"
      expect(parseBatchYield('30'), 30);
      expect(parseBatchYield('saem 12 unidades'), 12);
      expect(parseBatchYield('rende duas dezenas'), isNull); // ambiguo -> LLM
    });

    test('tempo de producao', () {
      expect(parseDurationMinutes('duas horas'), 120);
      expect(parseDurationMinutes('uma hora e meia'), 90);
      expect(parseDurationMinutes('meia hora'), 30);
      expect(parseDurationMinutes('40 minutos'), 40);
      expect(parseDurationMinutes('vinte e cinco minutos'), 25);
      expect(parseDurationMinutes('2h30'), 150);
      expect(parseDurationMinutes('1,5 horas'), 90);
      expect(parseDurationMinutes('um dia'), 1440);
      expect(parseDurationMinutes('leva umas 3 horas.'), 180);
      expect(parseDurationMinutes('duas'), isNull); // sem unidade: ambiguo
    });

    test('duracao falada', () {
      expect(speakDuration(150), '2 horas e 30 minutos');
      expect(speakDuration(60), '1 hora');
      expect(speakDuration(1500), '1 dia e 1 hora');
      expect(speakDuration(1501), '1 dia, 1 hora e 1 minuto');
    });
  });

  group('dialog machine', () {
    test('triagem completa e fluxo ate o resultado', () {
      final m = DialogMachine();
      expect(m.start().state, DialogState.askCompany);
      expect(m.handle('minha empresa se chama doces da ana').state, DialogState.askProduct);
      expect(m.handle('quero vender marmitas').state, DialogState.askMaterials);
      expect(m.handle('arroz, feijão e frango').state, DialogState.askBatchYield);
      expect(m.handle('uma panela rende vinte').state, DialogState.askProductionTime);
      expect(m.handle('duas horas').state, DialogState.askCharacteristics);
      expect(m.handle('marmita de 500 gramas').state, DialogState.askQuantity);
      expect(m.handle('vinte').state, DialogState.askCost);
      expect(m.handle('cento e vinte reais').state, DialogState.askMargin);
      expect(m.handle('trinta').state, DialogState.confirm);
      final r = m.handle('sim');
      expect(r.state, DialogState.result);
      expect(r.result!.unitPriceCents, 858);

      final s = m.session;
      expect(s.company, 'Doces da Ana');
      expect(s.product, 'marmitas');
      expect(s.materials, 'arroz, feijão e frango');
      expect(s.batchYield, 20);
      expect(s.productionMinutes, 120);
      expect(s.characteristics, 'marmita de 500 gramas');
    });

    test('perguntas opcionais podem ser puladas; produto nao', () {
      final m = DialogMachine()..start();
      expect(m.handle('pular').state, DialogState.askProduct);
      expect(m.session.company, isNull);
      expect(m.handle('pular').state, DialogState.askProduct); // produto e obrigatorio
      m.handle('bolo de pote');
      expect(m.handle('não sei').state, DialogState.askBatchYield);
      expect(m.handle('pular').state, DialogState.askProductionTime);
      expect(m.handle('pular').state, DialogState.askCharacteristics);
      expect(m.handle('nenhuma').state, DialogState.askQuantity);
      expect(m.session.materials, isNull);
      expect(m.session.batchYield, isNull);
    });

    test('quantidade em lotes usa o rendimento', () {
      final m = DialogMachine()..start();
      triage(m);
      m.handle('um lote');
      expect(m.session.quantity, 20);

      final m2 = DialogMachine()..start();
      triage(m2);
      m2.handle('dois lotes');
      expect(m2.session.quantity, 40);
    });

    test('entrada invalida mantem estado e pede de novo', () {
      final m = DialogMachine()..start();
      triage(m);
      final r = m.handle('blablabla');
      expect(r.state, DialogState.askQuantity);
      expect(m.session.quantity, isNull);

      final m2 = DialogMachine()..start();
      m2.handle('Doces da Ana');
      m2.handle('bolos');
      m2.handle('farinha');
      m2.handle('vinte');
      expect(m2.handle('duas').state, DialogState.askProductionTime); // sem unidade
    });

    test('voltar, repetir e recomecar', () {
      final m = DialogMachine()..start();
      triage(m);
      m.handle('10');
      expect(m.handle('voltar').state, DialogState.askQuantity);
      expect(m.handle('voltar').state, DialogState.askCharacteristics);
      expect(m.handle('repetir').state, DialogState.askCharacteristics);
      expect(m.handle('recomeçar').state, DialogState.askCompany);
      expect(m.session.product, isNull);
      expect(m.session.company, isNull);
    });

    test('nao na confirmacao corrige so os numeros e mantem a triagem', () {
      final m = DialogMachine()..start();
      triage(m);
      m.handle('10');
      m.handle('50 reais');
      m.handle('20');
      expect(m.handle('não').state, DialogState.askQuantity);
      expect(m.session.product, 'marmitas');
      expect(m.session.batchYield, 20);
      expect(m.session.quantity, isNull);
    });

    test('outro produto mantem a empresa', () {
      final m = DialogMachine()..start();
      triage(m);
      m.handle('10');
      m.handle('50 reais');
      m.handle('20');
      m.handle('sim');
      expect(m.handle('outro produto').state, DialogState.askProduct);
      expect(m.session.company, 'Doces da Ana');
      expect(m.session.product, isNull);
    });

    test('margem fora da faixa e rejeitada', () {
      final m = DialogMachine()..start();
      triage(m);
      m.handle('10');
      m.handle('50 reais');
      expect(m.handle('noventa e cinco').state, DialogState.askMargin);
    });
  });
}

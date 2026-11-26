import 'package:augure_miniapps/core/cost_breakdown.dart';
import 'package:augure_miniapps/core/dialog_machine.dart';
import 'package:augure_miniapps/core/sale_unit.dart';
import 'package:flutter_test/flutter_test.dart';

/// Caso real: bolo de cenoura, 12 unidades, R$ 18, 30%, parado na confirmacao.
DialogMachine atConfirm() {
  final m = DialogMachine(
      profile: const SalesSession(company: 'Alfaprotein', product: 'bolo de cenoura'))
    ..start();
  m.handle('12');
  m.handle('18 reais');
  m.handle('30');
  expect(m.state, DialogState.confirm);
  return m;
}

void main() {
  group('reconhece a unidade de venda', () {
    test('frases', () {
      var s = parseSaleUnit('são 12 pedaços de 1 bolo de cenoura')!;
      expect((s.one, s.batch, s.perBatch, s.strong), ('pedaço', 'bolo', 12, true));
      s = parseSaleUnit('cada bolo rende 12 fatias')!;
      expect((s.one, s.batch, s.perBatch), ('fatia', 'bolo', 12));
      s = parseSaleUnit('uma torta dá doze fatias')!;
      expect((s.one, s.batch, s.batchFeminine, s.perBatch), ('fatia', 'torta', true, 12));
      s = parseSaleUnit('vendo por pote')!;
      expect((s.one, s.perBatch, s.strong), ('pote', null, true));
      s = parseSaleUnit('20 potes')!;
      expect((s.one, s.strong), ('pote', false)); // fraco: so vale em quantidade/rendimento
      expect(parseSaleUnit('quero vender marmitas'), isNull); // e o produto
      expect(parseSaleUnit('2 xícaras de farinha'), isNull);
    });

    test('palavras e genero', () {
      final u = unitWordsFor('pedaço', 'bolo');
      expect(u.count(1), '1 pedaço');
      expect(u.count(12), '12 pedaços');
      expect(u.ofTheOne, 'do pedaço');
      expect(u.ofBatch(12), 'do bolo inteiro (12 pedaços)');
      expect(u.howMany, 'Quantos pedaços');
      final f = unitWordsFor('fatia', 'torta');
      expect(f.ofTheOne, 'da fatia');
      expect(f.ofBatch(8), 'da torta inteira (8 fatias)');
      expect(f.howMany, 'Quantas fatias');
      expect(UnitWords.generic.ofBatch(20), 'do lote de 20 unidades'); // como antes
    });
  });

  group('na conversa', () {
    test('frase real na confirmacao: "são 12 pedaços de 1 bolo de cenoura"', () {
      final m = atConfirm();
      final r = m.handle('são 12 pedaços de 1 bolo de cenoura');
      expect(r.understood, isTrue);
      expect(r.state, DialogState.confirm);
      expect(r.text, contains('Anotei: você vende por pedaço, e um bolo rende 12 pedaços.'));
      expect(r.text, contains('Vou conferir: 12 pedaços de bolo de cenoura'));
      expect(m.session.batchYield, 12);
      expect(m.profile.saleUnit, 'pedaço'); // fica no cadastro

      final res = m.handle('sim');
      expect(res.text, contains('Para 12 pedaços de bolo de cenoura, cada pedaço custa'));
      expect(res.text, contains('O preço do pedaço é'));
      expect(res.text, contains('O preço do bolo inteiro (12 pedaços) é'));
      expect(res.text, contains('Vendendo os 12 pedaços'));
    });

    test('na pergunta da quantidade a mesma fala responde', () {
      final m = DialogMachine(
          profile: const SalesSession(product: 'bolo de cenoura', batchYield: 12))
        ..start();
      final r = m.handle('24 fatias');
      expect(m.session.quantity, 24); // "24 fatias" e a quantidade
      expect(m.session.saleUnit, 'fatia');
      expect(r.state, DialogState.askCost);
      expect(r.text, contains('para fazer 24 fatias'));
    });

    test('"um bolo" na quantidade usa o rendimento', () {
      final m = atConfirm()..handle('são 12 pedaços de 1 bolo de cenoura');
      m.handle('não'); // refaz os numeros
      expect(m.state, DialogState.askQuantity);
      m.handle('dois bolos');
      expect(m.session.quantity, 24);
    });

    test('simulacao e resumo de custo usam a unidade', () {
      final m = atConfirm()..handle('são 12 pedaços de 1 bolo de cenoura');
      m.handle('sim');
      final r = m.handle('quero vender o pedaço por 6 reais');
      expect(r.text, contains('Vendendo o pedaço por 6 reais: cada pedaço custa'));
      expect(r.text, contains('por pedaço, uma margem'));
      expect(r.text, contains('No bolo inteiro (12 pedaços), você recebe 72 reais'));
      final lot = m.handle('vender o bolo inteiro por 60 reais');
      expect(m.simulation!.priceCents, 500);
      expect(lot.text, contains('O bolo de 12 pedaços por 60 reais dá o pedaço a 5 reais'));

      final t = CostBreakdown(batchYield: 12, marginPercent: 30, otherCents: 1800);
      expect(speakBreakdown(t, units: unitWordsFor('pedaço', 'bolo')),
          contains('o preço do bolo inteiro (12 pedaços) é'));
    });

    test('"3 potes de doce de leite" nos ingredientes nao vira unidade de venda', () {
      final m = DialogMachine()..start();
      m.handle('Alfaprotein');
      m.handle('confeitaria');
      m.handle('bolo');
      m.handle('3 potes de doce de leite e 2 xícaras de farinha');
      expect(m.session.saleUnit, isNull);
      expect(m.state, DialogState.askBatchYield);
    });
  });
}

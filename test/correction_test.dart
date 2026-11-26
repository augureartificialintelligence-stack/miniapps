import 'package:augure_miniapps/core/dialog_machine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ate a pergunta de quantidade, com rendimento 20.
DialogMachine atQuantity() {
  final m = DialogMachine()..start();
  for (final t in [
    'Doces da Ana',
    'marmitaria',
    'marmitas',
    'arroz e frango',
    'rende vinte',
    'duas horas',
    'pular',
  ]) {
    m.handle(t);
  }
  expect(m.state, DialogState.askQuantity);
  return m;
}

void main() {
  group('deteccao de correcao', () {
    test('campo e valor', () {
      final a = parseCorrection('na verdade a empresa se chama Doces da Ana')!;
      expect(a.field, DialogState.askCompany);
      expect(a.value, 'Doces da Ana');

      final b = parseCorrection('quero mudar o tempo para 3 horas')!;
      expect(b.field, DialogState.askProductionTime);
      expect(b.value, '3 horas');

      final c = parseCorrection('na verdade os ingredientes são arroz e feijão')!;
      expect(c.field, DialogState.askMaterials);
      expect(c.value, 'arroz e feijão');
    });

    test('so o campo (perguntar de novo)', () {
      expect(parseCorrection('corrigir empresa')!.value, isNull);
      expect(parseCorrection('corrigir o nome da empresa')!.field, DialogState.askCompany);
      final p = parseCorrection('o produto está errado')!;
      expect(p.field, DialogState.askProduct);
      expect(p.value, isNull);
    });

    test('respostas normais nao sao correcao', () {
      expect(parseCorrection('arroz e feijão'), isNull);
      expect(parseCorrection('sem açúcar'), isNull);
      expect(parseCorrection('uma fornada rende vinte'), isNull); // sem verbo de correcao
      expect(parseCorrection('Doces da Ana'), isNull);
    });
  });

  group('correcao na conversa', () {
    test('bug relatado: corrigir a empresa NAO vira o nome do produto', () {
      final m = DialogMachine()..start();
      m.handle('doce da ana'); // STT entendeu errado
      m.handle('marmitaria');
      expect(m.state, DialogState.askProduct);

      final r = m.handle('na verdade a empresa se chama Doces da Ana');
      expect(r.state, DialogState.askProduct); // continua na pergunta do produto
      expect(m.session.company, 'Doces da Ana');
      expect(m.session.product, isNull);
      expect(r.text, contains('Corrigido: empresa Doces da Ana'));
    });

    test('corrigir sem valor pergunta de novo e volta para onde estava', () {
      final m = atQuantity();
      final r1 = m.handle('corrigir o nome da empresa');
      expect(r1.state, DialogState.askCompany);

      final r2 = m.handle('Doces da Bia');
      expect(r2.state, DialogState.askQuantity); // retomou, nao refez a triagem
      expect(r2.text, contains('Voltando'));
      expect(m.session.company, 'Doces da Bia');
      expect(m.session.materials, 'arroz e frango'); // o resto foi mantido
      expect(m.session.batchYield, 20);
    });

    test('lapis na tela: corrige o produto e volta para o custo', () {
      final m = atQuantity();
      m.handle('10');
      expect(m.state, DialogState.askCost);
      expect(m.correct(DialogState.askProduct).state, DialogState.askProduct);
      final r = m.handle('bolos');
      expect(r.state, DialogState.askCost);
      expect(m.session.product, 'bolos');
      expect(m.session.quantity, 10);
    });

    test('correcao com valor depois do resultado volta para a confirmacao', () {
      final m = atQuantity();
      m.handle('20');
      m.handle('120 reais');
      m.handle('30');
      m.handle('sim');
      expect(m.state, DialogState.offerDetail); // resultado + "quer detalhar o custo?"

      final r = m.handle('corrigir o custo para 60 reais');
      expect(r.state, DialogState.confirm);
      expect(m.session.totalCostCents, 6000);
      expect(r.text, contains('60 reais'));
      expect(m.handle('sim').result!.unitPriceCents, 429); // 6000/0.7/20 -> 428,58
    });

    test('nao corrige o que ainda nao foi respondido', () {
      final m = DialogMachine()..start();
      m.handle('Doces da Ana');
      m.handle('marmitaria');
      final r = m.handle('corrigir o custo');
      expect(r.state, DialogState.askProduct);
      expect(r.understood, isFalse);
      expect(m.session.product, isNull); // "corrigir o custo" nao virou produto
    });

    test('correcao avisa valor antigo e novo (sinal de aprendizado)', () {
      final events = <(DialogState, Object?, Object?)>[];
      final m = DialogMachine()..onCorrected = (f, o, n) => events.add((f, o, n));
      m.start();
      m.handle('doce da ana');
      m.handle('na verdade a empresa se chama Doces da Ana');
      m.handle('marmitaria');
      m.handle('marmitas');
      m.correct(DialogState.askProduct);
      m.handle('marmitex');
      expect(events, [
        (DialogState.askCompany, 'Doce da Ana', 'Doces da Ana'),
        (DialogState.askProduct, 'marmitas', 'marmitex'),
      ]);
    });

    test('"duas panelas" sao 2 lotes, nao 2 unidades', () {
      final m = atQuantity();
      m.handle('duas panelas');
      expect(m.session.quantity, 40);
    });

    test('voltar cancela a retomada pendente', () {
      final m = atQuantity();
      m.handle('corrigir a empresa');
      expect(m.state, DialogState.askCompany);
      m.handle('voltar');
      m.handle('Doces da Bia');
      // Seguiu a ordem sem repetir o que ja foi respondido (ramo, produto, ingredientes...):
      // vai para a primeira pergunta sem resposta (caracteristicas foram puladas).
      expect(m.state, DialogState.askCharacteristics);
    });
  });
}

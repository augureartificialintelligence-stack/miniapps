import 'package:augure_miniapps/core/dialog_machine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Triagem de um produto ate a pergunta indicada, com respostas normais.
DialogMachine machineAt(DialogState target) {
  final m = DialogMachine()..start();
  const answers = {
    DialogState.askCompany: 'Alfaprotein',
    DialogState.askSector: 'confeitaria',
    DialogState.askProduct: 'bolo de cenoura',
    DialogState.askMaterials: 'cenoura, ovos e farinha',
    DialogState.askBatchYield: '12',
    DialogState.askProductionTime: '70 minutos',
    DialogState.askCharacteristics: 'pular',
    DialogState.askQuantity: '12',
    DialogState.askCost: '18 reais',
    DialogState.askMargin: '30',
  };
  while (m.state != target) {
    m.handle(answers[m.state]!);
  }
  return m;
}

void main() {
  group('informacao de outra pergunta no meio da resposta', () {
    test('extrai pelo nome do campo', () {
      final s = parseFieldStatements('farinha e ovos, e rende 15 e leva 2 horas');
      expect(s[DialogState.askBatchYield], '15');
      expect(s[DialogState.askProductionTime], '2 horas');
      expect(parseFieldStatements('a margem é 40%')[DialogState.askMargin], '40%');
      expect(parseFieldStatements('o custo foi 20 reais')[DialogState.askCost], '20 reais');
      expect(parseFieldStatements('a empresa se chama Doces da Bia')[DialogState.askCompany],
          'Doces da Bia');
      expect(parseFieldStatements('farinha, ovos e açúcar'), isEmpty);
    });

    test('corrige dado ja respondido sem sair da pergunta atual', () {
      final m = machineAt(DialogState.askCost);
      final r = m.handle('o rendimento é 15');
      expect(r.state, DialogState.askCost); // continua no custo
      expect(m.session.batchYield, 15);
      expect(r.text, contains('Corrigido: rende 15 unidades por lote'));
      expect(r.text, contains('Quanto você gasta'));
    });

    test('responde a pergunta atual e corrige outra na mesma fala', () {
      final m = machineAt(DialogState.askCost);
      final r = m.handle('o custo foi 20 reais e a margem é 40%');
      // custo respondido; margem adiantada: pula a pergunta da margem
      expect(m.session.totalCostCents, 2000);
      expect(m.session.marginPercent, 40);
      expect(r.state, DialogState.confirm);
      expect(r.text, contains('Anotei: margem de 40 por cento'));
    });

    test('adianta dado ainda nao perguntado e pula a pergunta depois', () {
      final m = machineAt(DialogState.askMaterials);
      final r = m.handle('cenoura, ovos e farinha, e rende 12 e leva 70 minutos');
      expect(m.session.batchYield, 12);
      expect(m.session.productionMinutes, 70);
      expect(m.session.materials, contains('cenoura'));
      // pulou rendimento e tempo, que ja vieram na fala
      expect(r.state, DialogState.askCharacteristics);
    });

    test('so o dado adiantado (sem a resposta atual): continua na mesma pergunta', () {
      final m = machineAt(DialogState.askQuantity);
      final r = m.handle('a margem é 35%');
      expect(r.state, DialogState.askQuantity);
      expect(m.session.marginPercent, 35);
      m.handle('12');
      expect(m.handle('18 reais').state, DialogState.confirm); // nao pergunta a margem
    });

    test('depois do resultado, mudar um dado volta para a confirmacao', () {
      final m = machineAt(DialogState.confirm);
      expect(m.handle('sim').state, DialogState.offerDetail);
      final r = m.handle('a margem é 50%');
      expect(r.state, DialogState.confirm);
      expect(r.text, contains('margem de 50 por cento'));
    });

    test('"corrigir" com valor de campo ainda nao perguntado ja anota', () {
      final m = machineAt(DialogState.askBatchYield);
      final r = m.handle('corrigir a margem para 45%');
      expect(r.understood, isTrue);
      expect(m.session.marginPercent, 45);
      expect(r.state, DialogState.askBatchYield);
    });

    test('nao confunde texto livre com informacao', () {
      final m = machineAt(DialogState.askCharacteristics);
      final r = m.handle('bolo macio que rende bem');
      expect(r.state, DialogState.askQuantity);
      expect(m.session.batchYield, 12); // "rende bem" nao mudou o rendimento
    });
  });
}

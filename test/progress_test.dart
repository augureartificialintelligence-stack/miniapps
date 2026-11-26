import 'package:augure_miniapps/core/dialog_machine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tabela de custo fica salva a cada resposta e continua de onde parou', () {
    final m = DialogMachine()..start();
    for (final a in [
      'Bolinho feliz',
      'confeitaria',
      'bolo de chocolate',
      '2 xícaras de farinha de trigo, 3 ovos',
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
    expect(m.lastPrompt, contains('Quanto você paga em farinha'));
    m.handle('5 reais o quilo');

    // Ainda no meio da entrevista, o perfil ja guarda o preco.
    final saved = m.profile.costs!;
    expect(saved.materials.firstWhere((i) => i.name == 'farinha de trigo').priceCents, 500);

    // App reaberto: o detalhamento continua sem perguntar a farinha de novo.
    final m2 = DialogMachine(profile: m.profile)..start();
    for (final a in ['12', '25 reais', '70', 'sim', 'sim']) {
      m2.handle(a);
    }
    expect(m2.state, DialogState.costDetail);
    expect(m2.lastPrompt, isNot(contains('farinha')));
    expect(m2.lastPrompt, contains('ovos'));
    expect(
        m2.costTable!.materials.firstWhere((i) => i.name == 'farinha de trigo').priceCents, 500);
  });
}

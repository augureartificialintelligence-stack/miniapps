import 'package:augure_miniapps/core/cost_breakdown.dart';
import 'package:augure_miniapps/core/dialog_machine.dart';
import 'package:augure_miniapps/core/pt_br_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const g = MeasureKind.mass;
const ml = MeasureKind.volume;
const un = MeasureKind.unit;

/// Cadastro pronto + preco calculado: a conversa para na oferta de detalhar.
DialogMachine atOffer() {
  final m = DialogMachine(
    profile: const SalesSession(
      company: 'Doces da Ana',
      product: 'marmitas',
      materials: 'arroz e frango',
      batchYield: 20,
      productionMinutes: 120,
    ),
  )..start();
  m.handle('20');
  m.handle('120 reais');
  m.handle('30');
  final r = m.handle('sim');
  expect(r.state, DialogState.offerDetail);
  expect(r.result, isNotNull);
  return m;
}

void main() {
  group('quantidades', () {
    test('peso, volume e unidades', () {
      expect(parseMeasure('2 quilos'), const Measure(2000, g));
      expect(parseMeasure('uso 500 gramas'), const Measure(500, g));
      expect(parseMeasure('1,5 kg'), const Measure(1500, g));
      expect(parseMeasure('1.5kg'), const Measure(1500, g));
      expect(parseMeasure('meio quilo'), const Measure(500, g));
      expect(parseMeasure('um quilo e meio'), const Measure(1500, g));
      expect(parseMeasure('dois litros'), const Measure(2000, ml));
      expect(parseMeasure('300 ml'), const Measure(300, ml));
      expect(parseMeasure('6 ovos'), const Measure(6, un));
      expect(parseMeasure('uma dúzia'), const Measure(12, un));
      expect(parseMeasure('meia dúzia'), const Measure(6, un));
      expect(parseMeasure('nada'), isNull);
    });

    test('falar a quantidade', () {
      expect(speakMeasure(const Measure(1500, g)), '1,5 quilos');
      expect(speakMeasure(const Measure(1000, g)), '1 quilo');
      expect(speakMeasure(const Measure(300, ml)), '300 mililitros');
      expect(speakMeasure(const Measure(12, un)), '12 unidades');
    });
  });

  group('preco da embalagem', () {
    test('preco + tamanho, em varias ordens', () {
      expect(parsePriceWithPackage('25 reais o pacote de 5 quilos'),
          (cents: 2500, pack: const Measure(5000, g)));
      expect(parsePriceWithPackage('o pacote de 5 kg custa 25 reais'),
          (cents: 2500, pack: const Measure(5000, g)));
      expect(parsePriceWithPackage('vinte e cinco reais o saco de cinco quilos'),
          (cents: 2500, pack: const Measure(5000, g)));
      expect(parsePriceWithPackage('8 reais o quilo'), (cents: 800, pack: const Measure(1000, g)));
      expect(parsePriceWithPackage('doze reais e cinquenta o quilo'),
          (cents: 1250, pack: const Measure(1000, g)));
      expect(parsePriceWithPackage('12 reais a dúzia'), (cents: 1200, pack: const Measure(12, un)));
      expect(parsePriceWithPackage(r'R$ 3,50 cada'), (cents: 350, pack: const Measure(1, un)));
      expect(parsePriceWithPackage('paguei 25 no pacote de 5 quilos'),
          (cents: 2500, pack: const Measure(5000, g)));
      expect(parsePriceWithPackage('o pacote de 5 quilos sai por 25'),
          (cents: 2500, pack: const Measure(5000, g)));
    });

    test('so o preco: tamanho fica para perguntar', () {
      expect(parsePriceWithPackage('25 reais'), (cents: 2500, pack: null));
      expect(parsePriceWithPackage('sei la'), isNull);
    });

    test('lista de materiais vira itens', () {
      expect(splitMaterials('arroz, feijão e frango'), ['arroz', 'feijão', 'frango']);
      expect(splitMaterials('farinha de trigo; ovos'), ['farinha de trigo', 'ovos']);
    });
  });

  group('tabela de custo', () {
    test('custo proporcional e preco por unidade', () {
      final t = CostBreakdown(
        materials: [
          MaterialCost('arroz',
              used: const Measure(2000, g), priceCents: 2500, pack: const Measure(5000, g)),
          MaterialCost('frango',
              used: const Measure(3000, g), priceCents: 1800, pack: const Measure(1000, g)),
        ],
        packagingPerUnitCents: 100,
        freightCents: 1000,
        wearCents: 500,
        laborCents: 4000,
        batchYield: 20,
        marginPercent: 30,
      );
      expect(t.materials[0].costCents, 1000); // 2 de 5 kg x R$ 25
      expect(t.materials[1].costCents, 5400); // 3 kg x R$ 18
      expect(t.packagingCents, 2000);
      expect(t.batchCents, 1000 + 5400 + 2000 + 1000 + 500 + 4000);
      expect(t.unitCostCents, 695); // 13900 / 20
      expect(t.unitPriceCents, 993); // 13900 / 0,7 = 19857,15 -> /20 = 992,86 -> 993
    });

    test('converte unidade/volume para peso pela tabela; desconhecido nao calcula', () {
      // 6 ovos (~50 g cada) de um preco por quilo: 300 g de 1 kg a R$ 12 = R$ 3,60
      final ovos = MaterialCost('ovos',
          used: const Measure(6, un), priceCents: 1200, pack: const Measure(1000, g));
      expect(ovos.costCents, 360);
      // 2 xicaras de farinha de trigo (~120 g cada) de um pacote de 1 kg a R$ 6
      final farinha = MaterialCost('farinha de trigo',
          used: const Measure(480, ml), priceCents: 600, pack: const Measure(1000, g));
      expect(farinha.costCents, 144);
      expect(farinha.usedGrams, 240);
      // ingrediente fora da tabela: precisa perguntar quanto pesa
      final x = MaterialCost('pasta americana',
          used: const Measure(240, ml), priceCents: 3000, pack: const Measure(1000, g));
      expect(x.costCents, isNull);
      x.gramsPer = 1.2;
      expect(x.costCents, 864);
    });
  });

  group('entrevista de custo na conversa', () {
    test('fluxo completo ate o custo por unidade', () {
      final m = atOffer();
      var r = m.handle('sim');
      expect(r.state, DialogState.costDetail);
      expect(r.text, contains('dividido em partes'));
      r = m.handle('não'); // sem partes: usa os materiais da triagem
      expect(r.text, contains('Quanto de arroz'));

      r = m.handle('2 quilos');
      expect(r.text, contains('Quanto você paga em arroz'));
      r = m.handle('25 reais o pacote de 5 quilos');
      expect(r.text, contains('arroz: 10 reais por lote'));
      expect(r.text, contains('Quanto de frango'));

      m.handle('3 quilos');
      r = m.handle('18 reais'); // sem tamanho
      expect(r.text, contains('de que tamanho'));
      r = m.handle('o quilo');
      expect(r.text, contains('frango: 54 reais por lote'));
      expect(r.text, contains('mais algum material'));

      r = m.handle('óleo');
      expect(r.text, contains('Quanto de óleo'));
      m.handle('meio litro');
      m.handle('9 reais a garrafa de 900 ml'); // 500/900 x 9 = 5,00
      r = m.handle('não');
      expect(r.text, contains('embalagem de CADA unidade'));

      m.handle('1 real'); // embalagem por unidade
      m.handle('10 reais'); // frete
      m.handle('pular'); // gas/energia
      r = m.handle('20 reais por hora'); // 2 h de producao -> 40 reais
      expect(r.text, contains('40 reais por lote'));
      r = m.handle('não'); // outros
      expect(r.state, DialogState.result);
      expect(r.breakdown, isNotNull);

      final t = r.breakdown!;
      expect(t.materialsCents, 1000 + 5400 + 500);
      expect(t.batchCents, 6900 + 2000 + 1000 + 0 + 4000);
      expect(t.unitCostCents, 695);
      expect(r.text, contains('Cada unidade custa 6 reais e 95 centavos'));
      expect(r.text, contains('margem de 30 por cento'));

      // A tabela fica no cadastro (produto unico).
      expect(m.profile.costs!.batchCents, 13900);
    });

    test('nao detalhar termina normalmente; da para pedir depois', () {
      final m = atOffer();
      expect(m.handle('não').state, DialogState.result);
      expect(m.handle('quero detalhar o custo').state, DialogState.costDetail);
    });

    test('pular um material tira ele da tabela', () {
      final m = atOffer()
        ..handle('sim')
        ..handle('não');
      final r = m.handle('pular'); // arroz
      expect(r.text, contains('Quanto de frango'));
    });

    test('unidade incompativel pede o tamanho certo', () {
      final m = atOffer()
        ..handle('sim')
        ..handle('não');
      m.handle('2 quilos');
      // usa em peso e paga "cada": pergunta quanto pesa a unidade comprada
      final r = m.handle('5 reais cada');
      expect(r.text, contains('Quanto pesa 1 unidade de arroz'));
      expect(m.handle('5 quilos').text, contains('arroz: 2 reais por lote'));
    });

    test('voltar dentro da entrevista refaz a pergunta anterior', () {
      final m = atOffer()
        ..handle('sim')
        ..handle('não');
      m.handle('2 quilos');
      final r = m.handle('voltar');
      expect(r.state, DialogState.costDetail);
      expect(r.text, contains('Quanto de arroz'));
    });

    test('"o frete custa 20" na entrevista nao vira correcao do custo principal', () {
      final m = atOffer()
        ..handle('sim')
        ..handle('não');
      m.handle('pular');
      m.handle('pular'); // tira arroz e frango
      m.handle('não'); // sem mais materiais
      m.handle('pular'); // embalagem
      final r = m.handle('na verdade o frete custa 20 reais');
      expect(r.state, DialogState.costDetail);
      expect(m.session.totalCostCents, 12000);
    });

    test('entrevista em andamento e retomada depois que o app fecha', () {
      final m = atOffer()
        ..handle('sim')
        ..handle('não');
      m.handle('2 quilos');
      final again = DialogMachine();
      expect(again.restore(m.toJson()), isTrue);
      expect(again.state, DialogState.costDetail);
      expect(again.resumePrompt().text, contains('Quanto você paga em arroz'));
    });
  });
}

import 'package:augure_miniapps/core/cost_breakdown.dart';
import 'package:augure_miniapps/core/dialog_machine.dart';
import 'package:augure_miniapps/core/document_parser.dart';
import 'package:augure_miniapps/core/pt_br_parser.dart';
import 'package:augure_miniapps/core/sectors.dart';
import 'package:flutter_test/flutter_test.dart';

const g = MeasureKind.mass;
const ml = MeasureKind.volume;
const un = MeasureKind.unit;

const recipeText = '''
BOLO DE CHOCOLATE
Ingredientes
Massa:
- 2 xícaras de farinha de trigo
- 1 e 1/2 xícara de açúcar
- 3 ovos
- 1/2 xícara (chá) de óleo
- 1 colher (sopa) de fermento em pó
Cobertura:
- 1 lata de leite condensado (395 g)
- 2 colheres de sopa de chocolate em pó
Modo de preparo
Bata tudo no liquidificador e asse por 40 minutos.
''';

const receiptText = '''
SUPERMERCADO BOM PRECO LTDA
CNPJ 12.345.678/0001-90
CUPOM FISCAL
001 7891234567890 FARINHA TRIGO DONA BENTA 5KG 1 UN 25,90
002 7899876543210 ACUCAR REFINADO UNIAO 1KG 1 UN 4,99
003 OVOS BRANCOS C/12 1 UN 12,00
004 LEITE CONDENSADO MOCOCA 395G 2 UN X 5,49 10,98
TOTAL R\$ 53,87
CARTAO DEBITO 53,87
''';

void main() {
  group('medidas caseiras', () {
    test('xicara, colheres, copo e fracoes', () {
      expect(parseMeasure('2 xícaras'), const Measure(480, ml));
      expect(parseMeasure('1/2 xícara'), const Measure(120, ml));
      expect(parseMeasure('½ xícara'), const Measure(120, ml));
      expect(parseMeasure('meia xícara'), const Measure(120, ml));
      expect(parseMeasure('1 e 1/2 xícara'), const Measure(360, ml));
      expect(parseMeasure('1 colher de sopa'), const Measure(15, ml));
      expect(parseMeasure('2 colheres de chá'), const Measure(10, ml));
      expect(parseMeasure('1 copo americano'), const Measure(190, ml));
    });
  });

  group('ramo do negocio', () {
    test('reconhece pela fala', () {
      expect(parseSector('eu faço bolos e doces'), 'Confeitaria');
      expect(parseSector('marmitaria'), 'Marmitas e refeições');
      expect(parseSector('trabalho com salgados'), 'Salgados');
      expect(parseSector('sabonetes artesanais'), 'Cosméticos e sabonetes');
      expect(parseSector('meu ramo é pet shop'), 'Pet shop'); // fora da lista: guarda o texto
    });

    test('exemplos adaptados ao ramo', () {
      expect(partsExample('Salgados'), 'massa e recheio');
      expect(materialsExample('Artesanato'), contains('tecido'));
      expect(partsExample(null), 'massa, recheio e cobertura');
    });
  });

  group('leitura de foto', () {
    test('classifica receita e compra', () {
      expect(classifyDocument(recipeText), DocKind.recipe);
      expect(classifyDocument(receiptText), DocKind.purchase);
    });

    test('receita: ingredientes, quantidades e partes', () {
      final items = parseRecipe(recipeText);
      expect(items.map((i) => i.name), [
        'farinha de trigo',
        'açúcar',
        'ovos',
        'óleo',
        'fermento em pó',
        'leite condensado',
        'chocolate em pó',
      ]);
      expect(items[0], const RecipeItem('farinha de trigo', Measure(480, ml), part: 'Massa'));
      expect(items[1].used, const Measure(360, ml));
      expect(items[2].used, const Measure(3, un));
      expect(items[3].used, const Measure(120, ml));
      expect(items[4].used, const Measure(15, ml));
      // peso entre parenteses vale mais que "1 lata"
      expect(items[5], const RecipeItem('leite condensado', Measure(395, g), part: 'Cobertura'));
      expect(items[6].used, const Measure(30, ml));
    });

    test('compra: itens, precos e tamanho da embalagem', () {
      final items = parsePurchase(receiptText);
      expect(items, hasLength(4)); // TOTAL, CNPJ e cartao ficam de fora
      expect(items[0].cents, 2590);
      expect(items[0].pack, const Measure(5000, g));
      expect(items[0].name, contains('farinha trigo'));
      expect(items[2].pack, const Measure(12, un)); // C/12
      expect(items[3].cents, 549); // 2 latas x 5,49: vale o preco de UMA lata (395 g)
      expect(items[3].pack, const Measure(395, g));
    });

    test('casa o item da nota com o ingrediente da receita', () {
      expect(sameIngredient('farinha de trigo', 'farinha trigo dona benta'), isTrue);
      expect(sameIngredient('açúcar', 'acucar refinado uniao'), isTrue);
      expect(sameIngredient('ovos', 'ovos brancos'), isTrue);
      expect(sameIngredient('farinha de trigo', 'leite condensado mococa'), isFalse);
    });

    test('receita + nota viram a tabela de custo com conversao de volume', () {
      final t = CostBreakdown(batchYield: 12, marginPercent: 40)
        ..importRecipe(parseRecipe(recipeText))
        ..importPurchases(parsePurchase(receiptText));
      final farinha = t.materials.firstWhere((m) => m.name == 'farinha de trigo');
      // 2 xicaras ~ 240 g de um pacote de 5 kg a R$ 25,90 = R$ 1,24
      expect(farinha.costCents, 124);
      final ovos = t.materials.firstWhere((m) => m.name == 'ovos');
      expect(ovos.costCents, 300); // 3 de 12 por R$ 12
      final leite = t.materials.firstWhere((m) => m.name == 'leite condensado');
      expect(leite.costCents, 549); // usa 1 lata (395 g); cada lata custou R$ 5,49
      expect(t.parts, ['Massa', 'Cobertura']);
    });
  });

  group('conversa com fotos e partes', () {
    DialogMachine atOffer() {
      final m = DialogMachine(
          profile: const SalesSession(
              company: 'Doces da Ana', sector: 'Confeitaria', product: 'bolo', batchYield: 12))
        ..start();
      m.handle('12');
      m.handle('60 reais');
      m.handle('40');
      expect(m.handle('sim').state, DialogState.offerDetail);
      return m;
    }

    test('partes do produto: ingredientes por parte e subtotal', () {
      final m = atOffer();
      var r = m.handle('sim');
      expect(r.text, contains('massa, recheio e cobertura')); // exemplo do ramo
      r = m.handle('massa e cobertura');
      expect(r.text, contains('Para a massa, quais ingredientes'));
      r = m.handle('farinha e ovos');
      expect(r.text, contains('Para a cobertura'));
      r = m.handle('chocolate');
      expect(r.text, contains('Quanto de farinha (massa)'));
      m.handle('2 xícaras');
      r = m.handle('6 reais o quilo'); // xicara x quilo: converte pela tabela
      expect(r.text, contains('farinha (2 xícaras dá cerca de 240 gramas): 1 real e 44 centavos'));
      m.handle('4 ovos');
      m.handle('12 reais a dúzia');
      m.handle('200 gramas');
      m.handle('20 reais o quilo');
      expect(m.costTable!.partCents('Massa'), 144 + 400);
      expect(m.costTable!.partCents('Cobertura'), 400);
    });

    test('ingrediente fora da tabela de conversao: pergunta quanto pesa', () {
      final m = atOffer()
        ..handle('sim')
        ..handle('não'); // sem partes e sem materiais na triagem
      m.handle('pasta americana');
      m.handle('1 xícara');
      final r = m.handle('30 reais o quilo');
      expect(r.text, contains('Quanto pesa 1 xícara de pasta americana'));
      expect(m.handle('300 gramas').text, contains('9 reais por lote'));
    });

    test('foto da receita e da nota na entrevista pulam o que ja foi lido', () {
      final m = atOffer()..handle('sim');
      final r = m.importDocuments(parseRecipe(recipeText), parsePurchase(receiptText));
      expect(r.text, startsWith('Li 7 ingredientes da receita e 4 preços da compra.'));
      // farinha, acucar, ovos e leite condensado ja tem preco: pergunta o oleo
      expect(r.text, contains('Quanto você paga em óleo'));
    });

    test('foto da receita na pergunta dos materiais responde a triagem', () {
      final m = DialogMachine()..start();
      m.handle('Doces da Ana');
      m.handle('confeitaria');
      m.handle('bolo de chocolate');
      expect(m.state, DialogState.askMaterials);
      final r = m.importDocuments(parseRecipe(recipeText), const []);
      expect(r.state, DialogState.askBatchYield);
      expect(m.session.materials, contains('farinha de trigo'));
      expect(m.costTable!.materials, hasLength(7)); // rascunho da tabela de custo
    });

    test('foto sem nada legivel nao avanca', () {
      final m = atOffer();
      final r = m.importDocuments(const [], const []);
      expect(r.understood, isFalse);
      expect(r.state, DialogState.offerDetail);
    });
  });

  group('preco da unidade separado do preco do lote', () {
    test('resultado principal e tabela de custo', () {
      final m = DialogMachine(
          profile: const SalesSession(product: 'marmitas', batchYield: 20))
        ..start();
      m.handle('20');
      m.handle('120 reais');
      m.handle('30');
      final r = m.handle('sim');
      expect(r.text, contains('O preço da unidade é 8 reais e 58 centavos'));
      expect(r.text, contains('O preço do lote de 20 unidades é 171 reais e 60 centavos'));

      final t = CostBreakdown(batchYield: 20, marginPercent: 30, otherCents: 12000);
      expect(t.unitPriceCents, 858);
      expect(t.batchPriceCents, 17160);
      expect(speakBreakdown(t), contains('o preço do lote de 20 unidades é 171 reais'));
    });
  });
}

import 'conversions.dart';
import 'document_parser.dart';
import 'pricing_calculator.dart';
import 'pt_br_parser.dart';
import 'sale_unit.dart';
import 'sectors.dart';

int _ceilDiv(int a, int b) => (a + b - 1) ~/ b;

/// Um material/ingrediente do lote: quanto se usa e quanto custa a embalagem comprada.
class MaterialCost {
  MaterialCost(this.name, {this.used, this.priceCents, this.pack, this.part, this.gramsPer});

  final String name;
  Measure? used;
  int? priceCents;
  Measure? pack;

  /// Parte do produto (Massa, Recheio, Cobertura...). null = sem parte.
  String? part;

  /// Gramas por ml (ou por unidade) dito pela pessoa, quando o ingrediente nao esta na
  /// tabela de conversao. Vale para a medida que nao e peso.
  double? gramsPer;

  /// Usa e compra em medidas diferentes (ex.: xicara x quilo)?
  bool get mixedUnits => used != null && pack != null && used!.kind != pack!.kind;

  /// Custo deste material NO LOTE (proporcional ao que se usa da embalagem). Converte
  /// volume/unidade para peso quando a receita e a compra usam medidas diferentes.
  int? get costCents {
    final u = used, p = pack, price = priceCents;
    if (u == null || p == null || price == null || p.amount <= 0) return null;
    if (u.kind == p.kind) return (u.amount / p.amount * price).round();
    final ug = toGrams(name, u, override: gramsPer);
    final pg = toGrams(name, p, override: gramsPer);
    if (ug == null || pg == null || pg <= 0) return null;
    return (ug / pg * price).round();
  }

  /// Quantidade usada em gramas, quando houve conversao (para mostrar "≈ 240 g").
  double? get usedGrams =>
      mixedUnits && used!.kind != MeasureKind.mass ? toGrams(name, used!, override: gramsPer) : null;

  Map<String, Object?> toJson() => {
        'name': name,
        'used': used?.toJson(),
        'priceCents': priceCents,
        'pack': pack?.toJson(),
        'part': part,
        'gramsPer': gramsPer,
      };

  static MaterialCost fromJson(Map<String, Object?> j) => MaterialCost(
        j['name'] as String? ?? '',
        used: Measure.fromJson(j['used']),
        priceCents: (j['priceCents'] as num?)?.toInt(),
        pack: Measure.fromJson(j['pack']),
        part: j['part'] as String?,
        gramsPer: (j['gramsPer'] as num?)?.toDouble(),
      );
}

/// Tabela de custo de producao de UM lote e o preco por unidade que sai dela.
/// Tudo em centavos (int), sem ponto flutuante no dinheiro.
class CostBreakdown {
  CostBreakdown({
    List<MaterialCost>? materials,
    this.packagingPerUnitCents,
    this.freightCents,
    this.wearCents,
    this.laborCents,
    this.laborHourlyCents,
    this.otherCents,
    this.batchYield,
    this.marginPercent,
  }) : materials = materials ?? [];

  final List<MaterialCost> materials;
  int? packagingPerUnitCents;
  int? freightCents;
  int? wearCents;

  /// Pro-labore do lote (hora de trabalho x tempo de producao, ou valor direto).
  int? laborCents;
  int? laborHourlyCents;
  int? otherCents;
  int? batchYield;
  int? marginPercent;

  int get materialsCents =>
      materials.fold(0, (sum, m) => sum + (m.costCents ?? 0));

  /// Partes do produto, na ordem em que aparecem (vazio = sem partes).
  List<String> get parts => {
        for (final m in materials)
          if (m.part != null) m.part!,
      }.toList();

  /// Custo dos materiais de uma parte (null = materiais sem parte).
  int partCents(String? part) => materials
      .where((m) => m.part == part)
      .fold(0, (sum, m) => sum + (m.costCents ?? 0));

  int get packagingCents => (packagingPerUnitCents ?? 0) * (batchYield ?? 0);

  /// Custo total de producao do lote.
  int get batchCents =>
      materialsCents +
      packagingCents +
      (freightCents ?? 0) +
      (wearCents ?? 0) +
      (laborCents ?? 0) +
      (otherCents ?? 0);

  /// Custo de producao de cada unidade (arredonda para cima).
  int? get unitCostCents {
    final y = batchYield;
    return y == null || y < 1 ? null : _ceilDiv(batchCents, y);
  }

  /// Preco por unidade com a margem desejada (mesma regra da calculadora principal).
  int? get unitPriceCents {
    final y = batchYield, m = marginPercent;
    if (y == null || y < 1 || m == null) return null;
    return calculatePricing(PricingInput(
      quantity: y,
      totalCostCents: batchCents,
      marginPercent: m,
    )).unitPriceCents;
  }

  /// Preco do lote inteiro (preco da unidade x unidades do lote).
  int? get batchPriceCents {
    final p = unitPriceCents;
    return p == null ? null : p * batchYield!;
  }

  int? get unitProfitCents {
    final p = unitPriceCents;
    return p == null ? null : p - (batchCents / batchYield!).round();
  }

  /// Lucro do lote inteiro.
  int? get batchProfitCents {
    final p = batchPriceCents;
    return p == null ? null : p - batchCents;
  }

  /// Acrescenta ingredientes lidos de uma receita (foto). Ingrediente que ja existe
  /// recebe a quantidade e a parte da receita.
  void importRecipe(List<RecipeItem> items) {
    for (final it in items) {
      final existing = _find(it.name);
      if (existing != null) {
        existing.used = it.used ?? existing.used;
        existing.part = it.part ?? existing.part;
      } else {
        materials.add(MaterialCost(it.name, used: it.used, part: it.part));
      }
    }
  }

  /// Acrescenta precos lidos de uma compra (foto da nota/cupom). Casa com o ingrediente
  /// da receita pelo nome; item que nao casa entra como material novo.
  void importPurchases(List<PurchaseItem> items) {
    for (final it in items) {
      MaterialCost? target;
      for (final m in materials) {
        if (sameIngredient(m.name, it.name)) {
          target = m;
          break;
        }
      }
      if (target != null) {
        target
          ..priceCents = it.cents
          ..pack = it.pack ?? target.pack;
      } else {
        materials.add(MaterialCost(it.name, priceCents: it.cents, pack: it.pack));
      }
    }
  }

  MaterialCost? _find(String name) {
    for (final m in materials) {
      if (sameIngredient(m.name, name)) return m;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        'materials': [for (final m in materials) m.toJson()],
        'packagingPerUnitCents': packagingPerUnitCents,
        'freightCents': freightCents,
        'wearCents': wearCents,
        'laborCents': laborCents,
        'laborHourlyCents': laborHourlyCents,
        'otherCents': otherCents,
        'batchYield': batchYield,
        'marginPercent': marginPercent,
      };

  static CostBreakdown? fromJson(Object? j) {
    if (j is! Map) return null;
    int? i(String k) => (j[k] as num?)?.toInt();
    return CostBreakdown(
      materials: [
        for (final m in (j['materials'] as List? ?? const []))
          if (m is Map) MaterialCost.fromJson(m.cast<String, Object?>()),
      ],
      packagingPerUnitCents: i('packagingPerUnitCents'),
      freightCents: i('freightCents'),
      wearCents: i('wearCents'),
      laborCents: i('laborCents'),
      laborHourlyCents: i('laborHourlyCents'),
      otherCents: i('otherCents'),
      batchYield: i('batchYield'),
      marginPercent: i('marginPercent'),
    );
  }
}

/// Etapas da entrevista de custo.
enum CostStep {
  parts,
  partMaterials,
  materialsList,
  itemAmount,
  itemPrice,
  itemPack,
  itemWeight,
  moreItems,
  batchYield,
  packaging,
  freight,
  wear,
  labor,
  other,
  done,
}

/// "a massa", "o recheio": artigo pelo genero provavel da palavra.
String _withArticle(String part) {
  final p = normalizePt(part);
  final fem = p.endsWith('a') || p.endsWith('cao') || p.endsWith('agem') || p.endsWith('ade');
  return '${fem ? 'a' : 'o'} ${part.toLowerCase()}';
}

/// Entrevista por voz que preenche a [CostBreakdown], uma pergunta por vez.
/// "pular" pula a pergunta; "voltar" (tratado por [back]) refaz a anterior.
class CostInterview {
  CostInterview({
    required List<String> materials,
    required int? batchYield,
    required this.productionMinutes,
    required int marginPercent,
    this.sector,
    CostBreakdown? draft,
    bool skipParts = false,
  }) : table = draft ?? CostBreakdown(batchYield: batchYield) {
    // Materiais da triagem so entram se a pessoa disser que o produto nao tem partes
    // (com partes, os ingredientes sao perguntados por parte e nao duplicam).
    _triage = materials;
    table.marginPercent = marginPercent;
    table.batchYield ??= batchYield;
    // Lista que ja tem quantidades, partes ou precos (fala corrida, foto): pula a pergunta
    // das partes. So nomes ("arroz, feijao e frango"): ainda pergunta se ha partes.
    final rich = draft != null &&
        draft.materials.any((m) => m.used != null || m.part != null || m.priceCents != null);
    // Lista reaproveitada ("use esses ingredientes"): nao pergunta as partes de novo.
    _step = rich || (skipParts && table.materials.isNotEmpty) ? _afterMaterialsStep() : CostStep.parts;
    // O item da pergunta e o primeiro incompleto (pode ja ter quantidade e so faltar preco).
    _item = _firstIncomplete() ?? 0;
  }

  CostInterview._restore(
      this.table, this.productionMinutes, this.sector, this._step, this._item, this._parts,
      this._partIndex, this._triage);

  final CostBreakdown table;
  final int? productionMinutes;
  final String? sector;
  late CostStep _step;
  int _item = 0;
  final _history = <(CostStep, int)>[];

  /// Partes ditas pela pessoa e qual delas esta sendo preenchida.
  List<String> _parts = [];
  int _partIndex = 0;

  /// Materiais da triagem, guardados caso a pessoa diga que o produto nao tem partes.
  List<String> _triage = [];

  CostStep get step => _step;
  bool get done => _step == CostStep.done;
  MaterialCost? get _current =>
      _item < table.materials.length ? table.materials[_item] : null;

  /// Primeiro passo depois de ter a lista de materiais.
  CostStep _afterMaterialsStep() =>
      _firstIncomplete() != null ? _stepFor(table.materials[_firstIncomplete()!]) : CostStep.moreItems;

  /// Proxima pergunta de um material ainda incompleto.
  CostStep _stepFor(MaterialCost m) {
    if (m.used == null) return CostStep.itemAmount;
    if (m.priceCents == null) return CostStep.itemPrice;
    if (m.pack == null) return CostStep.itemPack;
    return CostStep.itemWeight; // medidas diferentes sem conversao conhecida
  }

  /// Pergunta da etapa atual.
  String question() {
    final m = _current;
    final name = m == null
        ? 'o material'
        : m.part == null
            ? m.name
            : '${m.name} (${m.part!.toLowerCase()})';
    switch (_step) {
      case CostStep.parts:
        return 'Esse produto é dividido em partes, como ${partsExample(sector)}? Diga '
            'as partes, ou diga: não.';
      case CostStep.partMaterials:
        if (_return != null) {
          return 'Quais ingredientes faltaram n${_withArticle(_parts[_partIndex])}? Diga o '
              'nome e a quantidade.';
        }
        return 'Para ${_withArticle(_parts[_partIndex])}, quais ingredientes ou materiais '
            'você usa? Pode dizer com as quantidades, por exemplo: 2 xícaras de farinha.';
      case CostStep.materialsList:
        return 'Quais materiais ou ingredientes você usa em um lote? Fale os nomes, '
            'por exemplo: ${materialsExample(sector)}.';
      case CostStep.itemAmount:
        return 'Quanto de $name você usa em um lote? Por exemplo: 2 xícaras, 500 gramas '
            'ou 6 unidades. Se não usar, diga: pular.';
      case CostStep.itemPrice:
        return 'Quanto você paga em ${m?.name ?? 'esse material'}? Diga o preço e o '
            'tamanho, por exemplo: 25 reais o pacote de 5 quilos, ou 8 reais o quilo.';
      case CostStep.itemPack:
        final u = m?.used?.kind;
        final ex = switch (u) {
          MeasureKind.volume => '1 litro ou 1 quilo',
          MeasureKind.unit => '12 unidades',
          _ => '5 quilos',
        };
        return 'Esse preço é de que tamanho? Por exemplo: $ex.';
      case CostStep.itemWeight:
        final nonMass =
            m!.used!.kind != MeasureKind.mass ? m.used! : m.pack!;
        return 'Você usa ${m.name} em ${_kindName(m.used!.kind)} e compra em '
            '${_kindName(m.pack!.kind)}. Quanto pesa ${speakMeasure(nonMass)} de ${m.name}? '
            'Por exemplo: 120 gramas.';
      case CostStep.moreItems:
        return 'Tem mais algum material, ingrediente ou insumo? Diga o nome, ou diga: não.';
      case CostStep.batchYield:
        return 'Para dividir o custo, quantas unidades rende cada lote?';
      case CostStep.packaging:
        return 'Quanto custa a embalagem de CADA unidade? Some pote, tampa, sacola e '
            'etiqueta. Se não tiver, diga: pular.';
      case CostStep.freight:
        return 'Quanto você gasta de frete, entrega ou transporte por lote? Inclua a ida '
            'para comprar os materiais. Se não tiver, diga: pular.';
      case CostStep.wear:
        return 'Quanto vai de gás, energia, água e desgaste de equipamentos por lote? Se '
            'não souber, diga: pular.';
      case CostStep.labor:
        return productionMinutes != null
            ? 'E o seu pró-labore: quanto você quer ganhar por hora de trabalho? Por '
                'exemplo: 20 reais por hora.'
            : 'E o seu pró-labore: quanto você quer ganhar pelo seu trabalho em cada lote?';
      case CostStep.other:
        return 'Tem mais algum custo por lote, como taxa de cartão, aluguel ou '
            'divulgação? Diga o valor, ou diga: não.';
      case CostStep.done:
        return '';
    }
  }

  static String _kindName(MeasureKind k) => switch (k) {
        MeasureKind.mass => 'peso',
        MeasureKind.volume => 'volume',
        MeasureKind.unit => 'unidades',
      };


  /// Processa a resposta. [ok] false = nao entendeu (fica na mesma pergunta).
  ({bool ok, String text}) answer(String input) {
    // "alterar a embalagem para 1,50", "corrigir o preço da farinha", "tirar a manteiga":
    // corrige qualquer item da tabela sem refazer a entrevista.
    final edit = _tryEdit(input);
    if (edit != null) return edit;
    // "faltaram ingredientes da massa", "esqueci a farinha na massa": completa uma parte
    // (ou a lista) em qualquer pergunta da lista de materiais, sem virar resposta da atual.
    final extra = _tryComplement(input);
    if (extra != null) return extra;
    final no = isSkip(input) || parseYesNo(input) == YesNo.no;
    final m = _current;
    switch (_step) {
      case CostStep.parts:
        if (no) {
          // A lista (da triagem ou do rascunho) ja esta na tabela; senao, usa a triagem.
          if (table.materials.isEmpty && _triage.isNotEmpty) {
            table.materials.addAll(_triage.map(MaterialCost.new));
          }
          if (table.materials.isEmpty) return _go(CostStep.materialsList, 'Tudo bem.');
          _item = _firstIncomplete() ?? 0;
          return _go(_afterMaterialsStep(), 'Tudo bem.');
        }
        final parts = splitMaterials(input
            .replaceFirst(RegExp(r'^\s*(sim|tem|e|é)[,.\s]+', caseSensitive: false), '')
            .replaceFirst(RegExp(r'^\s*(dividido\s+em|as\s+partes\s+sao|tem)\s+',
                caseSensitive: false), ''));
        if (parts.isEmpty || parseYesNo(input) == YesNo.yes && parts.length == 1 &&
            normalizePt(parts.first) == 'sim') {
          return _fail('Diga os nomes das partes, por exemplo: ${partsExample(sector)}. '
              'Ou diga: não.');
        }
        _parts = [for (final p in parts) p[0].toUpperCase() + p.substring(1).toLowerCase()];
        // Nomes soltos da triagem seriam repetidos nas partes: saem da tabela.
        table.materials.removeWhere((m) => m.used == null && m.priceCents == null);
        _partIndex = 0;
        return _go(CostStep.partMaterials, 'Anotei as partes: ${_parts.join(', ')}.');

      case CostStep.partMaterials:
        if (isConversation(input)) return _fail('Não entendi os ingredientes. ${question()}');
        final part = _parts[_partIndex];
        final items = _readItems(input, part);
        if (items.isEmpty) return _fail('Não entendi os ingredientes. ${question()}');
        table.materials.addAll(items);
        // Partes novas ditas na mesma fala ("... e para o recheio ...") entram na lista.
        for (final p in items.map((m) => m.part).whereType<String>()) {
          if (!_parts.contains(p)) _parts.add(p);
        }
        final ack = 'Anotei ${_withArticle(part)}: ${items.map(_label).join(', ')}.';
        // Faltava completar uma parte ja respondida ("faltou ... da massa"): volta.
        final ret = _return;
        if (ret != null) {
          _return = null;
          _step = ret.step;
          _item = ret.item;
          _partIndex = ret.partIndex;
          return (ok: true, text: '$ack ${question()}');
        }
        final nextPart = _nextEmptyPart();
        if (nextPart != null) {
          _pushHistory();
          _partIndex = nextPart;
          return (ok: true, text: '$ack ${question()}');
        }
        _item = _firstIncomplete() ?? 0;
        return _go(_afterMaterialsStep(), ack);

      case CostStep.materialsList:
        if (isConversation(input)) return _fail('Não entendi os ingredientes. ${question()}');
        final items = _readItems(input, null);
        if (items.isEmpty) return _fail('Não entendi os nomes. ${question()}');
        table.materials.addAll(items);
        _item = _firstIncomplete() ?? 0;
        return _go(_afterMaterialsStep(), 'Anotei: ${items.map(_label).join(', ')}.');

      case CostStep.itemAmount:
        if (no) {
          table.materials.removeAt(_item);
          return _nextItem('Tudo bem, tirei ${m?.name ?? 'esse material'} da tabela.');
        }
        final used = parseMeasure(input);
        if (used == null) {
          return _fail('Não entendi a quantidade. Diga, por exemplo: 2 xícaras, 2 quilos ou '
              '500 gramas. Se não usar, diga: pular.');
        }
        m!.used = used;
        if (m.priceCents != null && m.pack != null) return _checkItem('Usa ${speakMeasure(used)}.');
        return _go(CostStep.itemPrice, 'Usa ${speakMeasure(used)}.');

      case CostStep.itemPrice:
        if (no) {
          table.materials.removeAt(_item);
          return _nextItem('Tudo bem, deixei ${m!.name} fora do cálculo.');
        }
        // Varios precos na mesma fala: "5,50 o quilo da farinha e 4,50 os 100 g de fermento".
        final multi = _tryMultiPrice(input);
        if (multi != null) return multi;
        final p = parsePriceWithPackage(input);
        if (p == null) {
          return _fail('Não entendi o preço. Diga, por exemplo: 25 reais o pacote de 5 '
              'quilos.');
        }
        m!.priceCents = p.cents;
        if (p.pack == null) return _go(CostStep.itemPack, 'Anotei ${speakBrl(p.cents)}.');
        m.pack = p.pack;
        return _checkItem('');

      case CostStep.itemPack:
        final pack = parseMeasure(input);
        if (pack == null) return _fail('Não entendi o tamanho. ${question()}');
        m!.pack = pack;
        return _checkItem('');

      case CostStep.itemWeight:
        final g = parseMeasure(input);
        if (g == null || g.kind != MeasureKind.mass || g.amount <= 0) {
          return _fail('Diga o peso em gramas ou quilos, por exemplo: 120 gramas.');
        }
        final nonMass = m!.used!.kind != MeasureKind.mass ? m.used! : m.pack!;
        m.gramsPer = g.amount / nonMass.amount;
        return _checkItem('');

      case CostStep.moreItems:
        if (no) return _afterItems();
        if (isConversation(input)) return _fail(question());
        final items = _readItems(input, table.parts.isNotEmpty ? 'Outros' : null);
        if (items.isEmpty) return _fail(question());
        table.materials.addAll(items);
        _item = _firstIncomplete() ?? table.materials.length - 1;
        return _go(_stepFor(table.materials[_item]), 'Anotei: ${items.map(_label).join(', ')}.');

      case CostStep.batchYield:
        final y = parseBatchYield(input);
        if (y == null || y < 1 || y > 100000) {
          return _fail('Diga quantas unidades saem de cada lote, por exemplo: vinte.');
        }
        table.batchYield = y;
        if (_return != null) return _finishEdit('Cada lote rende $y.');
        return _go(_nextMoneyStep(CostStep.packaging), 'Cada lote rende $y.');

      case CostStep.packaging:
        return _money(input, no, (c) => table.packagingPerUnitCents = c, CostStep.freight,
            (c) => 'Embalagem: ${speakBrl(c)} por unidade.');

      case CostStep.freight:
        return _money(input, no, (c) => table.freightCents = c, CostStep.wear,
            (c) => 'Frete: ${speakBrl(c)} por lote.');

      case CostStep.wear:
        return _money(input, no, (c) => table.wearCents = c, CostStep.labor,
            (c) => 'Gás, energia e desgaste: ${speakBrl(c)} por lote.');

      case CostStep.labor:
        final mins = productionMinutes;
        return _money(input, no, (c) {
          if (mins != null) {
            table.laborHourlyCents = c;
            table.laborCents = (c * mins / 60).round();
          } else {
            table.laborCents = c;
          }
        }, CostStep.other, (c) {
          return mins != null
              ? 'Pró-labore: ${speakBrl(c)} por hora, ${speakBrl(table.laborCents!)} por lote '
                  'de ${speakDuration(mins)}.'
              : 'Pró-labore: ${speakBrl(c)} por lote.';
        });

      case CostStep.other:
        return _money(input, no, (c) => table.otherCents = c, CostStep.done,
            (c) => 'Outros custos: ${speakBrl(c)} por lote.');

      case CostStep.done:
        return (ok: true, text: '');
    }
  }

  /// Pergunta para onde voltar depois de completar uma parte ("faltou ... da massa").
  ({CostStep step, int item, int partIndex})? _return;

  /// Ingredientes ditos (com quantidades, partes e varios por frase) viram linhas.
  List<MaterialCost> _readItems(String input, String? part) => [
        for (final it in parseSpokenRecipe(parseMaterials(input) ?? input))
          if (!isConversation(it.name))
            MaterialCost(it.name, used: it.used, part: it.part ?? part),
      ];

  static String _label(MaterialCost m) =>
      m.used == null ? m.name : '${m.name} (${speakMeasure(m.used!)})';

  /// Proxima parte (depois da atual) que ainda nao tem ingredientes.
  int? _nextEmptyPart() {
    for (var i = _partIndex + 1; i < _parts.length; i++) {
      if (!table.materials.any((m) => m.part == _parts[i])) return i;
    }
    return null;
  }

  static final _complement = RegExp(
      r'\b(faltou|faltaram|faltando|falta|esqueci|esqueceu|tambem vai|tambem tem|ainda tem|'
      r'ainda falta|ainda faltam)\b');

  /// "faltaram ingredientes da massa" (sem dizer quais): volta para a massa e depois
  /// continua de onde estava. "faltou 2 xicaras de farinha na massa": ja anota.
  ({bool ok, String text})? _tryComplement(String input) {
    const listSteps = {
      CostStep.partMaterials, CostStep.materialsList, CostStep.itemAmount, CostStep.itemPrice,
      CostStep.itemPack, CostStep.itemWeight, CostStep.moreItems,
    };
    if (!listSteps.contains(_step)) return null;
    final n = normalizePt(input);
    if (!_complement.hasMatch(n)) return null;
    final known = {..._parts, ...table.parts};
    String? part;
    for (final p in known) {
      if (RegExp('\\b${normalizePt(p)}s?\\b').hasMatch(n)) part = p;
    }
    // O que sobra sem "faltou", "ingredientes", "da massa" sao os ingredientes ditos
    // (no texto ORIGINAL, para os nomes manterem os acentos).
    var rest = input
        .replaceAll(
            RegExp(r'\b(faltou|faltaram|faltando|falta|esqueci|esqueceu|ainda faltam|'
                r'ainda falta|tamb[eé]m vai|tamb[eé]m tem|ainda tem)\b',
                caseSensitive: false),
            ' ')
        .replaceAll(
            RegExp(r'\b(ingredientes?|mat[eé]ria(l|is)|coisas?|itens?|produtos?)\b',
                caseSensitive: false),
            ' ')
        .replaceAll(RegExp(r'^\s*((os|as|o|a|eu|que|mais|ainda)\s+)+', caseSensitive: false), '');
    if (part != null) {
      rest = rest.replaceAll(
          RegExp('\\b((d|n)[aoe]s?|para|pra|em)?\\s*${RegExp.escape(part)}s?\\b',
              caseSensitive: false),
          ' ');
    }
    rest = rest.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (RegExp(r'\p{L}{3,}', unicode: true).hasMatch(rest)) {
      final items = _readItems(rest, part);
      if (items.isNotEmpty) {
        table.materials.addAll(items);
        final where = part == null ? '' : ' ${part == 'Outros' ? 'em outros' : 'n${_withArticle(part)}'}';
        return (ok: true, text: 'Anotei$where: ${items.map(_label).join(', ')}. ${question()}');
      }
    }
    if (part != null && _parts.contains(part)) {
      _return = (step: _step, item: _item, partIndex: _partIndex);
      _pushHistory();
      _partIndex = _parts.indexOf(part);
      _step = CostStep.partMaterials;
      return (ok: true, text: 'Tudo bem. Quais ingredientes faltaram n${_withArticle(part)}? '
          'Diga o nome e a quantidade.');
    }
    _pushHistory();
    _step = CostStep.moreItems;
    return (ok: true, text: 'Tudo bem. Quais ingredientes faltaram? Diga o nome e a quantidade.');
  }

  /// A fala parece resposta da pergunta atual? (para o envio automatico do texto ouvido
  /// nao mandar conversa, frase cortada ou ruido).
  bool looksLikeAnswer(String input) {
    if (_complement.hasMatch(normalizePt(input))) return true;
    if (isConversation(input)) return false;
    final skip = isSkip(input) || parseYesNo(input) != null;
    switch (_step) {
      case CostStep.parts:
      case CostStep.partMaterials:
      case CostStep.materialsList:
      case CostStep.moreItems:
        return true;
      case CostStep.itemAmount:
      case CostStep.itemPack:
      case CostStep.itemWeight:
        return skip || parseMeasure(input) != null;
      case CostStep.itemPrice:
        return skip || parsePriceWithPackage(input) != null;
      case CostStep.batchYield:
        return parseBatchYield(input) != null;
      case CostStep.packaging:
      case CostStep.freight:
      case CostStep.wear:
      case CostStep.labor:
      case CostStep.other:
        return skip || parseMoneyCents(input) != null;
      case CostStep.done:
        return true;
    }
  }

  /// Acrescenta o que foi lido nas fotos e continua do proximo dado que falta.
  String importDocuments(List<RecipeItem> recipe, List<PurchaseItem> purchases) {
    table.importRecipe(recipe);
    table.importPurchases(purchases);
    _pushHistory();
    // Ainda nas perguntas da lista de materiais: as fotos ja responderam.
    if (const {CostStep.parts, CostStep.partMaterials, CostStep.materialsList, CostStep.itemAmount,
            CostStep.itemPrice, CostStep.itemPack, CostStep.itemWeight, CostStep.moreItems}
        .contains(_step)) {
      final next = _firstIncomplete();
      if (next != null) {
        _item = next;
        _step = _stepFor(table.materials[next]);
      } else {
        _step = CostStep.moreItems;
      }
    }
    return question();
  }

  /// Volta uma pergunta dentro da entrevista. false = ja esta na primeira.
  bool back() {
    if (_history.isEmpty) return false;
    final (step, item) = _history.removeLast();
    _step = step;
    _item = item;
    if (step == CostStep.partMaterials && _partIndex > 0) _partIndex--;
    return true;
  }

  /// Depois de preco/tamanho/peso: calcula o custo do item ou pede o que falta.
  ({bool ok, String text}) _checkItem(String ack) {
    final m = _current!;
    if (m.pack == null) return _go(CostStep.itemPack, ack);
    if (m.costCents == null && m.mixedUnits) {
      final kinds = {m.used!.kind, m.pack!.kind};
      if (kinds.contains(MeasureKind.mass)) {
        // volume/unidade x peso sem conversao conhecida: pergunta quanto pesa
        return _go(CostStep.itemWeight, ack);
      }
      // volume x unidade: pede o tamanho na mesma medida do uso
      m.pack = null;
      final (how, ex) = switch (m.used!.kind) {
        MeasureKind.mass => ('em peso', '5 quilos'),
        MeasureKind.volume => ('em volume', '1 litro'),
        MeasureKind.unit => ('em unidades', '12 unidades'),
      };
      _step = CostStep.itemPack;
      return _fail('Você usa ${m.name} $how. Quanto vem na embalagem desse preço? '
          'Diga, por exemplo: $ex.');
    }
    final conv = m.usedGrams != null
        ? ' (${speakMeasure(m.used!)} dá cerca de ${speakMeasure(Measure(m.usedGrams!.roundToDouble(), MeasureKind.mass))})'
        : '';
    return _nextItem('${ack.isEmpty ? '' : '$ack '}${m.name}$conv: '
        '${speakBrl(m.costCents!)} por lote.');
  }

  ({bool ok, String text}) _nextItem(String ack) {
    // Era uma correcao ("corrigir o preco da farinha"): volta para onde estava.
    if (_return != null) return _finishEdit(ack);
    _pushHistory();
    final next = _firstIncomplete();
    if (next != null) {
      _item = next;
      _step = _stepFor(table.materials[next]);
    } else {
      _step = CostStep.moreItems;
    }
    return (ok: true, text: '$ack ${question()}');
  }

  int? _firstIncomplete() {
    for (var i = 0; i < table.materials.length; i++) {
      if (table.materials[i].costCents == null) return i;
    }
    return null;
  }

  ({bool ok, String text}) _afterItems() {
    _pushHistory();
    _step = table.batchYield == null
        ? CostStep.batchYield
        : _nextMoneyStep(CostStep.packaging);
    return (ok: true, text: 'Certo. ${question()}');
  }

  /// Primeira pergunta de custo extra (a partir de [from]) ainda sem resposta. Valores
  /// ja respondidos (inclusive "pular" = 0) nao sao perguntados de novo.
  CostStep _nextMoneyStep(CostStep from) {
    const order = [
      CostStep.packaging, CostStep.freight, CostStep.wear, CostStep.labor, CostStep.other,
    ];
    for (final s in order.skip(order.indexOf(from).clamp(0, order.length))) {
      final answered = switch (s) {
        CostStep.packaging => table.packagingPerUnitCents != null,
        CostStep.freight => table.freightCents != null,
        CostStep.wear => table.wearCents != null,
        CostStep.labor => table.laborCents != null,
        _ => table.otherCents != null,
      };
      if (!answered) return s;
    }
    return CostStep.done;
  }

  ({bool ok, String text}) _money(String input, bool skip, void Function(int) set,
      CostStep next, String Function(int) ack) {
    // Fala sobre OUTRO custo ("a embalagem ta cara..." na pergunta do frete) nao e resposta
    // desta pergunta: nao entendeu (a IA local ou a pessoa esclarece).
    final other = _otherFieldMentioned(input);
    if (other != null) {
      return _fail('Você falou d${other == CostStep.packaging || other == CostStep.wear ? 'a' : 'o'} '
          '${_fieldName(other)}. Para mudar, diga, por exemplo: alterar ${_fieldName(other)} '
          'para 2 reais. ${question()}');
    }
    if (skip) {
      set(0);
      if (_return != null) return _finishEdit('Tudo bem.');
      return _go(next == CostStep.done ? next : _nextMoneyStep(next), 'Tudo bem.');
    }
    final c = parseMoneyCents(input);
    if (c == null || c < 0) {
      return _fail('Não entendi o valor. Diga em reais, por exemplo: 15 reais. Ou diga: '
          'pular.');
    }
    set(c);
    if (_return != null) return _finishEdit(ack(c));
    return _go(next == CostStep.done ? next : _nextMoneyStep(next), ack(c));
  }

  /// Outro custo extra citado na fala (diferente da pergunta atual), ou null.
  CostStep? _otherFieldMentioned(String input) {
    final n = normalizePt(input);
    for (final e in _fieldWords.entries) {
      if (e.key != _step && RegExp('\\b(${e.value})\\b').hasMatch(n)) return e.key;
    }
    return null;
  }

  static String _fieldName(CostStep s) => switch (s) {
        CostStep.packaging => 'embalagem',
        CostStep.freight => 'frete',
        CostStep.wear => 'gás e energia',
        CostStep.labor => 'pró-labore',
        CostStep.other => 'outros custos',
        CostStep.batchYield => 'rendimento',
        _ => 'item',
      };

  /// Fim de uma correcao: volta para a pergunta em que a pessoa estava.
  ({bool ok, String text}) _finishEdit(String ack) {
    final ret = _return!;
    _return = null;
    _step = ret.step;
    _item = ret.item.clamp(0, table.materials.isEmpty ? 0 : table.materials.length - 1);
    _partIndex = ret.partIndex;
    // A pergunta de onde veio pode ja ter sido respondida pela correcao.
    if (const {CostStep.itemAmount, CostStep.itemPrice, CostStep.itemPack, CostStep.itemWeight}
        .contains(_step)) {
      final next = _firstIncomplete();
      if (next == null) {
        _step = CostStep.moreItems;
      } else if (_current?.costCents != null) {
        _item = next;
        _step = _stepFor(table.materials[next]);
      }
    }
    final q = question();
    return (ok: true, text: q.isEmpty ? ack : '$ack Voltando: $q');
  }

  static final _editTrigger = RegExp(r'\b(alterar|altera|altere|mudar|muda|mude|corrigir|'
      r'corrige|corrija|trocar|troca|troque|ajustar|ajusta|ajuste|na verdade|errei|errado|'
      r'errada)\b');

  /// Palavras de cada custo extra (texto sem acento).
  static const _fieldWords = <CostStep, String>{
    CostStep.packaging: r'embalage(m|ns)',
    CostStep.freight: r'frete|entrega|transporte',
    CostStep.wear: r'gas|energia|desgaste',
    CostStep.labor: r'pro\s*-?\s*labore|prolabore|mao de obra|meu trabalho',
    CostStep.other: r'outros? custos?|taxa|aluguel|divulgacao',
    CostStep.batchYield: r'rendimento|rende',
  };

  /// Correcoes em qualquer ponto da entrevista: custos extras ("alterar a embalagem para
  /// 1,50", "o frete e 10 reais"), ingredientes ("corrigir o preco da farinha", "a
  /// manteiga e 1 colher de sopa") e "tirar a manteiga". Com o valor dito, aplica e
  /// continua na mesma pergunta; sem valor, pergunta aquele item e depois volta.
  ({bool ok, String text})? _tryEdit(String input) {
    if (_step == CostStep.done) return null;
    final n = normalizePt(input);
    final trigger = _editTrigger.hasMatch(n);
    // Nas perguntas de LISTA, nomes ja na tabela sao ingredientes novos sendo ditos; so
    // vira correcao com verbo explicito ("corrigir", "alterar", "na verdade").
    final listStep = const {
      CostStep.parts, CostStep.partMaterials, CostStep.materialsList, CostStep.moreItems,
    }.contains(_step);

    // Tirar um ingrediente pelo nome.
    if (RegExp(r'\b(tirar|tira|tire|remover|remove|remova|excluir|exclui|apagar|apaga)\b')
        .hasMatch(n)) {
      final m = _mentioned(input);
      if (m != null) {
        final wasCurrent = identical(m, _current);
        table.materials.remove(m);
        if (_item >= table.materials.length) _item = 0;
        final ack = 'Tirei ${m.name} da tabela.';
        if (wasCurrent || _step == CostStep.itemAmount || _step == CostStep.itemPrice) {
          return _nextItem(ack);
        }
        return (ok: true, text: '$ack ${question()}');
      }
    }

    // Custos extras pelo nome.
    for (final e in _fieldWords.entries) {
      final fm = RegExp('\\b(${e.value})\\b').firstMatch(n);
      if (fm == null) continue;
      if (e.key == _step) return null; // e a resposta da pergunta atual
      final after = input.substring(fm.end);
      final statement = RegExp(r'^\s*(e|eh|é|fica|foi|custa|sao|são|vai ser|para|pra)\b',
              caseSensitive: false)
          .hasMatch(after);
      if (!trigger && (listStep || !statement)) continue;
      if (e.key == CostStep.batchYield) {
        final y = parseBatchYield(after);
        if (y != null && y > 0) {
          table.batchYield = y;
          return (ok: true, text: 'Corrigido: cada lote rende $y. ${question()}');
        }
      } else {
        final c = parseMoneyCents(after);
        if (c != null && c >= 0) {
          return (ok: true, text: '${_setExtra(e.key, c)} ${question()}');
        }
      }
      if (!trigger) continue;
      _return = (step: _step, item: _item, partIndex: _partIndex);
      _pushHistory();
      _step = e.key;
      return (ok: true, text: 'Tudo bem, vamos corrigir. ${question()}');
    }

    // Ingrediente pelo nome.
    final m = _mentioned(input);
    if (m == null ||
        (!trigger && (listStep || (!identical(m, _current) && !_statementAbout(n))))) {
      return null;
    }
    if (identical(m, _current) && !trigger) return null; // resposta normal do item atual
    final wantsPrice = RegExp(r'\b(preco|valor|custa|custou|paguei|pago|reais|real)\b').hasMatch(n);
    if (wantsPrice) {
      final p = parsePriceWithPackage(input);
      if (p != null && p.pack != null) {
        m
          ..priceCents = p.cents
          ..pack = p.pack;
        return (ok: true, text: '${_costAck('Corrigido:', m)} ${question()}');
      }
      return _jumpTo(m, CostStep.itemPrice);
    }
    final used = parseMeasure(_withoutName(input, m));
    if (used != null) {
      m.used = used;
      return (ok: true, text: '${_costAck('Corrigido:', m)} ${question()}');
    }
    return _jumpTo(m, CostStep.itemAmount);
  }

  /// "a manteiga e 1 colher de sopa": fala sobre um ingrediente (sem verbo de correcao).
  bool _statementAbout(String n) =>
      RegExp(r'\b(e|eh|sao|fica|foi|vai ser|uso|usa|custa|custou)\b').hasMatch(n) &&
      RegExp(r'\d').hasMatch(n);

  ({bool ok, String text}) _jumpTo(MaterialCost m, CostStep step) {
    _return = (step: _step, item: _item, partIndex: _partIndex);
    _pushHistory();
    _item = table.materials.indexOf(m);
    _step = step;
    return (ok: true, text: 'Tudo bem, vamos corrigir ${m.name}. ${question()}');
  }

  String _costAck(String prefix, MaterialCost m) {
    final c = m.costCents;
    final what = [
      if (m.used != null) 'usa ${speakMeasure(m.used!)}',
      if (m.priceCents != null && m.pack != null)
        'paga ${speakBrl(m.priceCents!)} por ${speakMeasure(m.pack!)}',
    ].join(', ');
    return '$prefix ${m.name}, $what${c != null ? ': ${speakBrl(c)} por lote' : ''}.';
  }

  String _withoutName(String input, MaterialCost m) {
    var t = input;
    for (final w in m.name.split(RegExp(r'\s+'))) {
      if (w.length > 2) t = t.replaceAll(RegExp(RegExp.escape(w), caseSensitive: false), ' ');
    }
    return t;
  }

  /// Grava um custo extra e devolve a frase de confirmacao.
  String _setExtra(CostStep field, int c) {
    switch (field) {
      case CostStep.packaging:
        table.packagingPerUnitCents = c;
        return 'Corrigido: embalagem ${speakBrl(c)} por unidade.';
      case CostStep.freight:
        table.freightCents = c;
        return 'Corrigido: frete ${speakBrl(c)} por lote.';
      case CostStep.wear:
        table.wearCents = c;
        return 'Corrigido: gás, energia e desgaste ${speakBrl(c)} por lote.';
      case CostStep.labor:
        final mins = productionMinutes;
        if (mins != null) {
          table.laborHourlyCents = c;
          table.laborCents = (c * mins / 60).round();
          return 'Corrigido: pró-labore ${speakBrl(c)} por hora, '
              '${speakBrl(table.laborCents!)} por lote.';
        }
        table.laborCents = c;
        return 'Corrigido: pró-labore ${speakBrl(c)} por lote.';
      default:
        table.otherCents = c;
        return 'Corrigido: outros custos ${speakBrl(c)} por lote.';
    }
  }

  /// Ingrediente citado na fala (pelo nome principal: "farinha" casa "farinha de trigo").
  MaterialCost? _mentioned(String text) {
    final words = _nameTokens(text).toSet();
    MaterialCost? best;
    var bestScore = 0;
    for (final m in table.materials) {
      final nt = _nameTokens(m.name);
      if (nt.isEmpty || !words.contains(nt.first)) continue;
      final score = nt.where(words.contains).length;
      if (score > bestScore) {
        best = m;
        bestScore = score;
      }
    }
    return best;
  }

  static List<String> _nameTokens(String s) => normalizePt(s)
      .split(RegExp(r'[^a-z]+'))
      .where((w) => w.length > 2 && !const {'com', 'sem', 'para', 'das', 'dos'}.contains(w))
      .map((w) => w.endsWith('s') && w.length > 3 ? w.substring(0, w.length - 1) : w)
      .toList();

  /// "5,50 o quilo da farinha e 4,50 reais 100 gramas de fermento": um preco para cada
  /// ingrediente citado; trecho sem nome vale para o ingrediente atual.
  ({bool ok, String text})? _tryMultiPrice(String input) {
    final segs = input
        .split(RegExp(r';|,(?!\d)|\s+e\s+(?=\S*\d)', caseSensitive: false))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (segs.length < 2) return null;
    final assigned = <MaterialCost>[];
    for (final s in segs) {
      final p = parsePriceWithPackage(s);
      if (p == null) return null; // algum trecho sem preco: nao e lista de precos
      final m = _mentioned(s) ?? _current;
      if (m == null || assigned.contains(m)) return null;
      m.priceCents = p.cents;
      if (p.pack != null) m.pack = p.pack;
      assigned.add(m);
    }
    final acks = [
      for (final m in assigned)
        m.costCents != null ? '${m.name}: ${speakBrl(m.costCents!)} por lote' : m.name,
    ];
    return _nextItem('Anotei os preços. ${acks.join('; ')}.');
  }

  ({bool ok, String text}) _go(CostStep next, String ack) {
    _pushHistory();
    _step = next;
    final q = question();
    if (ack.isEmpty) return (ok: true, text: q);
    return (ok: true, text: q.isEmpty ? ack : '$ack $q');
  }

  void _pushHistory() => _history.add((_step, _item));

  ({bool ok, String text}) _fail(String text) => (ok: false, text: text);

  Map<String, Object?> toJson() => {
        'table': table.toJson(),
        'productionMinutes': productionMinutes,
        'sector': sector,
        'step': _step.name,
        'item': _item,
        'parts': _parts,
        'partIndex': _partIndex,
        'triage': _triage,
      };

  static CostInterview? fromJson(Object? j) {
    if (j is! Map) return null;
    final table = CostBreakdown.fromJson(j['table']);
    final step = CostStep.values.asNameMap()[j['step']];
    if (table == null || step == null) return null;
    List<String> strs(Object? v) => [for (final s in (v as List? ?? const [])) '$s'];
    return CostInterview._restore(
      table,
      (j['productionMinutes'] as num?)?.toInt(),
      j['sector'] as String?,
      step,
      (j['item'] as num?)?.toInt() ?? 0,
      strs(j['parts']),
      (j['partIndex'] as num?)?.toInt() ?? 0,
      strs(j['triage']),
    );
  }
}

/// Resumo falado do custo detalhado: custo por parte, custo do lote, preco da unidade e
/// preco do lote, separados.
String speakBreakdown(CostBreakdown t, {UnitWords units = UnitWords.generic}) {
  final u = units;
  final parts = t.parts;
  final items = <String>[
    if (parts.isEmpty)
      'materiais ${speakBrl(t.materialsCents)}'
    else ...[
      for (final p in parts) '${p.toLowerCase()} ${speakBrl(t.partCents(p))}',
      if (t.partCents(null) > 0) 'outros materiais ${speakBrl(t.partCents(null))}',
    ],
    if (t.packagingCents > 0) 'embalagens ${speakBrl(t.packagingCents)}',
    if ((t.freightCents ?? 0) > 0) 'frete ${speakBrl(t.freightCents!)}',
    if ((t.wearCents ?? 0) > 0) 'gás, energia e desgaste ${speakBrl(t.wearCents!)}',
    if ((t.laborCents ?? 0) > 0) 'pró-labore ${speakBrl(t.laborCents!)}',
    if ((t.otherCents ?? 0) > 0) 'outros ${speakBrl(t.otherCents!)}',
  ];
  final b = StringBuffer('Pronto! Produzir um lote custa ${speakBrl(t.batchCents)}: '
      '${items.join(', ')}.');
  final unit = t.unitCostCents;
  if (unit != null) b.write(' Cada ${u.one} custa ${speakBrl(unit)} para produzir.');
  final price = t.unitPriceCents;
  if (price != null) {
    b.write(' Com margem de ${t.marginPercent} por cento, o preço ${u.ofTheOne} é '
        '${speakBrl(price)}, e o preço ${u.ofBatch(t.batchYield!)} é '
        '${speakBrl(t.batchPriceCents!)}.');
  }
  return b.toString();
}

/// Preco de um ingrediente ja registrado (de outro produto ou de uma compra).
class KnownPrice {
  const KnownPrice(this.name, this.cents, this.pack, {this.from});
  final String name;
  final int cents;
  final Measure pack;

  /// Produto de onde veio o preco.
  final String? from;

  /// "farinha de trigo, 5 reais e 50 centavos o 1 quilo (do bolo de cenoura)".
  String speak() => '$name, ${speakBrl(cents)} por ${speakMeasure(pack)}'
      '${from == null ? '' : ' (do $from)'}';
}

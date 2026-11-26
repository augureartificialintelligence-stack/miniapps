import 'conversions.dart';
import 'document_parser.dart';
import 'pricing_calculator.dart';
import 'pt_br_parser.dart';
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
    _step = rich ? _afterMaterialsStep() : CostStep.parts;
    if (_step == CostStep.itemAmount) _item = _firstIncomplete() ?? 0;
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
        return 'Para ${_withArticle(_parts[_partIndex])}, quais ingredientes ou materiais '
            'você usa?';
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
        final names = splitMaterials(parseMaterials(input));
        if (names.isEmpty) return _fail('Não entendi os ingredientes. ${question()}');
        final part = _parts[_partIndex];
        table.materials.addAll(names.map((n) => MaterialCost(n, part: part)));
        final ack = '$part: ${names.join(', ')}.';
        if (_partIndex < _parts.length - 1) {
          _pushHistory();
          _partIndex++;
          return (ok: true, text: '$ack ${question()}');
        }
        _item = _firstIncomplete() ?? 0;
        return _go(_afterMaterialsStep(), ack);

      case CostStep.materialsList:
        final names = splitMaterials(parseMaterials(input));
        if (names.isEmpty) return _fail('Não entendi os nomes. ${question()}');
        table.materials.addAll(names.map(MaterialCost.new));
        _item = _firstIncomplete() ?? 0;
        return _go(_afterMaterialsStep(), 'Anotei: ${names.join(', ')}.');

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
        final names = splitMaterials(parseMaterials(input));
        if (names.isEmpty) return _fail(question());
        _item = table.materials.length;
        table.materials.addAll(names.map((n) =>
            MaterialCost(n, part: table.parts.isNotEmpty ? 'Outros' : null)));
        return _go(CostStep.itemAmount, 'Anotei: ${names.join(', ')}.');

      case CostStep.batchYield:
        final y = parseBatchYield(input);
        if (y == null || y < 1 || y > 100000) {
          return _fail('Diga quantas unidades saem de cada lote, por exemplo: vinte.');
        }
        table.batchYield = y;
        return _go(CostStep.packaging, 'Cada lote rende $y.');

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
    _step = table.batchYield == null ? CostStep.batchYield : CostStep.packaging;
    return (ok: true, text: 'Certo. ${question()}');
  }

  ({bool ok, String text}) _money(String input, bool skip, void Function(int) set,
      CostStep next, String Function(int) ack) {
    if (skip) {
      set(0);
      return _go(next, 'Tudo bem.');
    }
    final c = parseMoneyCents(input);
    if (c == null || c < 0) {
      return _fail('Não entendi o valor. Diga em reais, por exemplo: 15 reais. Ou diga: '
          'pular.');
    }
    set(c);
    return _go(next, ack(c));
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
String speakBreakdown(CostBreakdown t) {
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
  if (unit != null) b.write(' Cada unidade custa ${speakBrl(unit)} para produzir.');
  final price = t.unitPriceCents;
  if (price != null) {
    b.write(' Com margem de ${t.marginPercent} por cento, o preço da unidade é '
        '${speakBrl(price)}, e o preço do lote de ${t.batchYield} unidades é '
        '${speakBrl(t.batchPriceCents!)}.');
  }
  return b.toString();
}

import 'pricing_calculator.dart';
import 'pt_br_parser.dart';

int _ceilDiv(int a, int b) => (a + b - 1) ~/ b;

/// Um material/ingrediente do lote: quanto se usa e quanto custa a embalagem comprada.
class MaterialCost {
  MaterialCost(this.name, {this.used, this.priceCents, this.pack});

  final String name;
  Measure? used;
  int? priceCents;
  Measure? pack;

  /// Custo deste material NO LOTE (proporcional ao que se usa da embalagem).
  int? get costCents {
    final u = used, p = pack, price = priceCents;
    if (u == null || p == null || price == null || u.kind != p.kind || p.amount <= 0) {
      return null;
    }
    return (u.amount / p.amount * price).round();
  }

  Map<String, Object?> toJson() => {
        'name': name,
        'used': used?.toJson(),
        'priceCents': priceCents,
        'pack': pack?.toJson(),
      };

  static MaterialCost fromJson(Map<String, Object?> j) => MaterialCost(
        j['name'] as String? ?? '',
        used: Measure.fromJson(j['used']),
        priceCents: (j['priceCents'] as num?)?.toInt(),
        pack: Measure.fromJson(j['pack']),
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

  int? get unitProfitCents {
    final p = unitPriceCents;
    return p == null ? null : p - (batchCents / batchYield!).round();
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
  materialsList,
  itemAmount,
  itemPrice,
  itemPack,
  moreItems,
  batchYield,
  packaging,
  freight,
  wear,
  labor,
  other,
  done,
}

/// Entrevista por voz que preenche a [CostBreakdown], uma pergunta por vez.
/// "pular" pula a pergunta; "voltar" (tratado por [back]) refaz a anterior.
class CostInterview {
  CostInterview({
    required List<String> materials,
    required int? batchYield,
    required this.productionMinutes,
    required int marginPercent,
  }) : table = CostBreakdown(
          materials: [for (final m in materials) MaterialCost(m)],
          batchYield: batchYield,
          marginPercent: marginPercent,
        ) {
    _step = table.materials.isEmpty ? CostStep.materialsList : CostStep.itemAmount;
  }

  CostInterview._restore(this.table, this.productionMinutes, this._step, this._item);

  final CostBreakdown table;
  final int? productionMinutes;
  late CostStep _step;
  int _item = 0;
  final _history = <(CostStep, int)>[];

  CostStep get step => _step;
  bool get done => _step == CostStep.done;
  MaterialCost? get _current =>
      _item < table.materials.length ? table.materials[_item] : null;

  /// Pergunta da etapa atual.
  String question() {
    final name = _current?.name ?? 'o material';
    switch (_step) {
      case CostStep.materialsList:
        return 'Quais materiais ou ingredientes você usa em um lote? Fale os nomes, '
            'por exemplo: farinha, ovos e açúcar.';
      case CostStep.itemAmount:
        return 'Quanto de $name você usa em um lote? Por exemplo: 2 quilos, 500 gramas '
            'ou 6 unidades. Se não usar, diga: pular.';
      case CostStep.itemPrice:
        return 'Quanto você paga em $name? Diga o preço e o tamanho, por exemplo: 25 reais '
            'o pacote de 5 quilos, ou 8 reais o quilo.';
      case CostStep.itemPack:
        final u = _current?.used?.kind;
        final ex = switch (u) {
          MeasureKind.volume => '1 litro',
          MeasureKind.unit => '12 unidades',
          _ => '5 quilos',
        };
        return 'Esse preço é de que tamanho? Por exemplo: $ex.';
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

  /// Processa a resposta. [ok] false = nao entendeu (fica na mesma pergunta).
  ({bool ok, String text}) answer(String input) {
    final skip = isSkip(input) || parseYesNo(input) == YesNo.no;
    final m = _current;
    switch (_step) {
      case CostStep.materialsList:
        final names = splitMaterials(parseMaterials(input));
        if (names.isEmpty) return _fail('Não entendi os nomes. ${question()}');
        table.materials.addAll(names.map(MaterialCost.new));
        return _go(CostStep.itemAmount, 'Anotei: ${names.join(', ')}.');

      case CostStep.itemAmount:
        if (skip) {
          table.materials.removeAt(_item);
          return _nextItem('Tudo bem, tirei ${_nameOrIt(m)} da tabela.');
        }
        final used = parseMeasure(input);
        if (used == null) {
          return _fail('Não entendi a quantidade. Diga, por exemplo: 2 quilos ou 500 '
              'gramas. Se não usar, diga: pular.');
        }
        m!.used = used;
        return _go(CostStep.itemPrice, 'Usa ${speakMeasure(used)}.');

      case CostStep.itemPrice:
        if (skip) {
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
        return _setPack(p.pack!);

      case CostStep.itemPack:
        final pack = parseMeasure(input);
        if (pack == null) return _fail('Não entendi o tamanho. ${question()}');
        return _setPack(pack);

      case CostStep.moreItems:
        if (skip || parseYesNo(input) == YesNo.no) return _afterItems();
        final names = splitMaterials(parseMaterials(input));
        if (names.isEmpty) return _fail(question());
        _item = table.materials.length;
        table.materials.addAll(names.map(MaterialCost.new));
        return _go(CostStep.itemAmount, 'Anotei: ${names.join(', ')}.');

      case CostStep.batchYield:
        final y = parseBatchYield(input);
        if (y == null || y < 1 || y > 100000) {
          return _fail('Diga quantas unidades saem de cada lote, por exemplo: vinte.');
        }
        table.batchYield = y;
        return _go(CostStep.packaging, 'Cada lote rende $y.');

      case CostStep.packaging:
        return _money(input, skip, (c) => table.packagingPerUnitCents = c, CostStep.freight,
            (c) => 'Embalagem: ${speakBrl(c)} por unidade.');

      case CostStep.freight:
        return _money(input, skip, (c) => table.freightCents = c, CostStep.wear,
            (c) => 'Frete: ${speakBrl(c)} por lote.');

      case CostStep.wear:
        return _money(input, skip, (c) => table.wearCents = c, CostStep.labor,
            (c) => 'Gás, energia e desgaste: ${speakBrl(c)} por lote.');

      case CostStep.labor:
        final mins = productionMinutes;
        return _money(input, skip, (c) {
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
        return _money(input, skip, (c) => table.otherCents = c, CostStep.done,
            (c) => 'Outros custos: ${speakBrl(c)} por lote.');

      case CostStep.done:
        return (ok: true, text: '');
    }
  }

  /// Volta uma pergunta dentro da entrevista. false = ja esta na primeira.
  bool back() {
    if (_history.isEmpty) return false;
    final (step, item) = _history.removeLast();
    _step = step;
    _item = item;
    return true;
  }

  String _nameOrIt(MaterialCost? m) => m?.name ?? 'esse material';

  ({bool ok, String text}) _setPack(Measure pack) {
    final m = _current!;
    if (m.used != null && m.used!.kind != pack.kind) {
      // Ex.: usa 500 gramas, mas disse o preco "por unidade": pergunta o tamanho em peso.
      _step = CostStep.itemPack;
      final (how, ex) = switch (m.used!.kind) {
        MeasureKind.mass => ('em peso', '5 quilos'),
        MeasureKind.volume => ('em volume', '1 litro'),
        MeasureKind.unit => ('em unidades', '12 unidades'),
      };
      return _fail('Você usa ${m.name} $how. Quanto vem na embalagem desse preço? '
          'Diga, por exemplo: $ex.');
    }
    m.pack = pack;
    return _nextItem('${m.name}: ${speakBrl(m.costCents!)} por lote.');
  }

  ({bool ok, String text}) _nextItem(String ack) {
    _pushHistory();
    final next = _firstIncomplete();
    if (next != null) {
      _item = next;
      _step = CostStep.itemAmount;
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
    return (ok: true, text: q.isEmpty ? ack : '$ack $q');
  }

  void _pushHistory() => _history.add((_step, _item));

  ({bool ok, String text}) _fail(String text) => (ok: false, text: text);

  Map<String, Object?> toJson() => {
        'table': table.toJson(),
        'productionMinutes': productionMinutes,
        'step': _step.name,
        'item': _item,
      };

  static CostInterview? fromJson(Object? j) {
    if (j is! Map) return null;
    final table = CostBreakdown.fromJson(j['table']);
    final step = CostStep.values.asNameMap()[j['step']];
    if (table == null || step == null) return null;
    return CostInterview._restore(
        table, (j['productionMinutes'] as num?)?.toInt(), step, (j['item'] as num?)?.toInt() ?? 0);
  }
}

/// Resumo falado do custo detalhado.
String speakBreakdown(CostBreakdown t) {
  final parts = <String>[
    'materiais ${speakBrl(t.materialsCents)}',
    if (t.packagingCents > 0) 'embalagens ${speakBrl(t.packagingCents)}',
    if ((t.freightCents ?? 0) > 0) 'frete ${speakBrl(t.freightCents!)}',
    if ((t.wearCents ?? 0) > 0) 'gás, energia e desgaste ${speakBrl(t.wearCents!)}',
    if ((t.laborCents ?? 0) > 0) 'pró-labore ${speakBrl(t.laborCents!)}',
    if ((t.otherCents ?? 0) > 0) 'outros ${speakBrl(t.otherCents!)}',
  ];
  final b = StringBuffer('Pronto! Produzir um lote custa ${speakBrl(t.batchCents)}: '
      '${parts.join(', ')}.');
  final unit = t.unitCostCents;
  final price = t.unitPriceCents;
  if (unit != null) b.write(' Cada unidade custa ${speakBrl(unit)} para produzir.');
  if (price != null) {
    b.write(' Com margem de ${t.marginPercent} por cento, cobre ${speakBrl(price)} por '
        'unidade.');
  }
  return b.toString();
}

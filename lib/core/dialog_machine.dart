import 'cost_breakdown.dart';
import 'document_parser.dart';
import 'pricing_calculator.dart';
import 'pt_br_parser.dart';
import 'sale_unit.dart';
import 'sectors.dart';

/// Estados do fluxo "assistente de vendas / precificacao".
/// Uma pergunta por vez, linguagem simples (requisito do documento AUGURE).
///
/// Ordem: triagem (empresa, produto, especificacoes de producao) e depois o preco.
enum DialogState {
  askCompany,

  /// Ramo do negocio (confeitaria, salgados, marmitas...).
  askSector,
  askProduct,

  /// Produto com o mesmo nome de um salvo: "quer usar os mesmos dados?". Fora da ordem.
  askReuse,
  askMaterials,
  askBatchYield,
  askProductionTime,
  askCharacteristics,
  askQuantity,
  askCost,
  askMargin,
  confirm,
  result,

  /// Depois do resultado: "quer detalhar o custo de producao do lote?".
  offerDetail,

  /// Entrevista do custo detalhado (materiais, embalagem, frete, pro-labore...).
  costDetail,
}

/// Ordem linear das perguntas (usada por "voltar" e pelas correcoes).
const dialogOrder = [
  DialogState.askCompany,
  DialogState.askSector,
  DialogState.askProduct,
  DialogState.askMaterials,
  DialogState.askBatchYield,
  DialogState.askProductionTime,
  DialogState.askCharacteristics,
  DialogState.askQuantity,
  DialogState.askCost,
  DialogState.askMargin,
  DialogState.confirm,
  DialogState.result,
];

/// Perguntas cujas respostas podem ser corrigidas depois.
const correctableStates = {
  DialogState.askCompany,
  DialogState.askSector,
  DialogState.askProduct,
  DialogState.askMaterials,
  DialogState.askBatchYield,
  DialogState.askProductionTime,
  DialogState.askCharacteristics,
  DialogState.askQuantity,
  DialogState.askCost,
  DialogState.askMargin,
};

class SalesSession {
  const SalesSession({
    this.company,
    this.sector,
    this.product,
    this.materials,
    this.batchYield,
    this.productionMinutes,
    this.characteristics,
    this.saleUnit,
    this.batchName,
    this.quantity,
    this.totalCostCents,
    this.marginPercent,
    this.costs,
  });

  // Triagem (opcionais, exceto o produto).
  final String? company;

  /// Ramo do negocio.
  final String? sector;
  final String? product;
  final String? materials;
  final int? batchYield;
  final int? productionMinutes;
  final String? characteristics;

  /// Unidade de venda ("pedaço", "fatia", "pote"); null = unidade.
  final String? saleUnit;

  /// O que e o lote ("bolo", "torta", "forma"); null = lote.
  final String? batchName;

  /// Palavras da unidade de venda para as frases ("12 pedaços", "o bolo inteiro").
  UnitWords get units => unitWordsFor(saleUnit, batchName);

  // Preco.
  final int? quantity;
  final int? totalCostCents;
  final int? marginPercent;

  /// Tabela de custo de producao do lote (custo detalhado). Faz parte do cadastro.
  final CostBreakdown? costs;

  bool get hasSpecs =>
      materials != null ||
      batchYield != null ||
      productionMinutes != null ||
      characteristics != null;

  SalesSession copyWith({
    String? company,
    String? sector,
    String? product,
    String? materials,
    int? batchYield,
    int? productionMinutes,
    String? characteristics,
    String? saleUnit,
    String? batchName,
    int? quantity,
    int? totalCostCents,
    int? marginPercent,
  }) =>
      SalesSession(
        company: company ?? this.company,
        sector: sector ?? this.sector,
        product: product ?? this.product,
        materials: materials ?? this.materials,
        batchYield: batchYield ?? this.batchYield,
        productionMinutes: productionMinutes ?? this.productionMinutes,
        characteristics: characteristics ?? this.characteristics,
        saleUnit: saleUnit ?? this.saleUnit,
        batchName: batchName ?? this.batchName,
        quantity: quantity ?? this.quantity,
        totalCostCents: totalCostCents ?? this.totalCostCents,
        marginPercent: marginPercent ?? this.marginPercent,
        costs: costs,
      );

  /// Copia com UM campo trocado, aceitando null (para "pular" numa correcao).
  SalesSession withField(DialogState field, Object? value) => SalesSession(
        company: field == DialogState.askCompany ? value as String? : company,
        sector: field == DialogState.askSector ? value as String? : sector,
        product: field == DialogState.askProduct ? value as String? : product,
        materials: field == DialogState.askMaterials ? value as String? : materials,
        batchYield: field == DialogState.askBatchYield ? value as int? : batchYield,
        productionMinutes:
            field == DialogState.askProductionTime ? value as int? : productionMinutes,
        characteristics:
            field == DialogState.askCharacteristics ? value as String? : characteristics,
        saleUnit: saleUnit,
        batchName: batchName,
        quantity: field == DialogState.askQuantity ? value as int? : quantity,
        totalCostCents: field == DialogState.askCost ? value as int? : totalCostCents,
        marginPercent: field == DialogState.askMargin ? value as int? : marginPercent,
        costs: costs,
      );

  SalesSession withCosts(CostBreakdown? table) => SalesSession(
        company: company,
        sector: sector,
        product: product,
        materials: materials,
        batchYield: table?.batchYield ?? batchYield,
        productionMinutes: productionMinutes,
        characteristics: characteristics,
        saleUnit: saleUnit,
        batchName: batchName,
        quantity: quantity,
        totalCostCents: totalCostCents,
        marginPercent: marginPercent,
        costs: table,
      );

  /// Cadastro completo: a triagem ja foi feita (o produto e obrigatorio).
  bool get hasProfile => product != null;

  /// Mantem a triagem (cadastro); zera so os numeros do preco.
  SalesSession keepTriage() => SalesSession(
        company: company,
        sector: sector,
        product: product,
        materials: materials,
        batchYield: batchYield,
        productionMinutes: productionMinutes,
        characteristics: characteristics,
        saleUnit: saleUnit,
        batchName: batchName,
        costs: costs,
      );

  Map<String, Object?> toJson() => {
        'company': company,
        'sector': sector,
        'product': product,
        'materials': materials,
        'batchYield': batchYield,
        'productionMinutes': productionMinutes,
        'characteristics': characteristics,
        'saleUnit': saleUnit,
        'batchName': batchName,
        'quantity': quantity,
        'totalCostCents': totalCostCents,
        'marginPercent': marginPercent,
        'costs': costs?.toJson(),
      };

  static SalesSession fromJson(Map<String, Object?> j) => SalesSession(
        company: j['company'] as String?,
        sector: j['sector'] as String?,
        product: j['product'] as String?,
        materials: j['materials'] as String?,
        batchYield: (j['batchYield'] as num?)?.toInt(),
        productionMinutes: (j['productionMinutes'] as num?)?.toInt(),
        characteristics: j['characteristics'] as String?,
        saleUnit: j['saleUnit'] as String?,
        batchName: j['batchName'] as String?,
        quantity: (j['quantity'] as num?)?.toInt(),
        totalCostCents: (j['totalCostCents'] as num?)?.toInt(),
        marginPercent: (j['marginPercent'] as num?)?.toInt(),
        costs: CostBreakdown.fromJson(j['costs']),
      );
}

class DialogResponse {
  const DialogResponse(this.text, this.state,
      {this.result, this.breakdown, this.understood = true, this.share = false});

  /// Texto exibido E falado.
  final String text;
  final DialogState state;

  /// Preenchido apenas no estado [DialogState.result].
  final PricingResult? result;

  /// Preenchido ao terminar o custo detalhado (tabela para a tela).
  final CostBreakdown? breakdown;

  /// A pessoa pediu para compartilhar/exportar o resultado (a tela abre as opcoes).
  final bool share;

  /// false quando a fala nao pode ser interpretada no estado atual (pedido de repeticao).
  /// A camada de LLM local usa isso para tentar uma segunda interpretacao.
  final bool understood;
}

/// Pedido de correcao de uma resposta anterior, detectado na fala.
class CorrectionRequest {
  const CorrectionRequest(this.field, this.value);

  /// Pergunta a corrigir (um de [correctableStates]).
  final DialogState field;

  /// Valor novo dito junto ("a empresa se chama X"); null = perguntar de novo.
  final String? value;
}

const _correctionTrigger =
    r'\b(corrigir|corrige|corrija|correcao|errei|errado|errada|errou|na verdade|'
    r'mudar|muda|trocar|troca|alterar|altera|editar)\b';

/// Palavras que identificam o campo (texto normalizado, sem acento).
const _fieldKeywords = <DialogState, String>{
  DialogState.askCompany: r'empresa|loja|negocio|marca',
  DialogState.askSector: r'ramo|setor|segmento|area',
  DialogState.askProduct: r'produto',
  DialogState.askMaterials: r'ingredientes?|materia(l|is)|materia prima',
  DialogState.askBatchYield: r'rendimento|rende|lotes?',
  DialogState.askProductionTime: r'tempo|demora|duracao',
  DialogState.askCharacteristics: r'caracteristicas?|tamanho|peso|sabor|cor',
  DialogState.askQuantity: r'quantidade|unidades',
  DialogState.askCost: r'custos?|gastos?',
  DialogState.askMargin: r'margem|porcentagem',
};

/// Conectivos entre o campo e o valor novo: "empresa [na verdade] [se chama] X".
final _connector = RegExp(
    r'^[\s,:=-]*(d[aoe]s?\s+|o\s+|a\s+|nome\s+|na\s+verdade\s+|agora\s+|e\s+|é\s+|eh\s+|'
    r'esta\s+|está\s+|sao\s+|são\s+|para\s+|pra\s+|seria\s+|vai\s+ser\s+|se\s+chama\s+|'
    r'chama\s+)',
    caseSensitive: false);

/// Detecta "corrigir <campo> [para <valor>]" em linguagem natural.
/// Exige um verbo de correcao E um campo conhecido; o resto vira o valor novo.
/// Fim do valor de uma informacao dita no meio da fala: pontuacao, outra informacao
/// ("... e a margem e 40") ou fim do texto.
const _valueEnd = r'(?=\s*(?:[,;.!?]|\s+e\s+(?:o|a|os|as|rende|rendem|leva|demora|custa|custo|'
    r'margem|tempo|rendimento|produto|empresa|ramo|quantidade)\b|$))';

/// Informacoes ditas pelo nome, em qualquer pergunta ("a margem e 40%", "rende 15",
/// "leva 2 horas", "o custo foi 20 reais", "a empresa se chama X"). Cada padrao captura o
/// valor; o valor so vale se o parser daquele campo entender (sem isso, e ignorado).
final _statements = <DialogState, RegExp>{
  DialogState.askCompany: RegExp(
      r'\b(?:empresa|loja|marca|negocio)\s+(?:se\s+chama|chama|e|eh)\s+(.+?)' + _valueEnd),
  DialogState.askSector: RegExp(r'\bramo\s+(?:e|eh|de)\s+(.+?)' + _valueEnd),
  DialogState.askProduct: RegExp(r'\bproduto\s+(?:e|eh|se\s+chama)\s+(.+?)' + _valueEnd),
  DialogState.askBatchYield: RegExp(
      r'\b(?:rende|rendem|rendimento\s+(?:e|eh|de)|cada\s+(?:lote|fornada|panela)\s+(?:rende|da|faz))\s+(.+?)' +
          _valueEnd),
  DialogState.askProductionTime: RegExp(
      r'\b(?:leva|levo|demora|demoro|tempo(?:\s+de\s+producao)?\s+(?:e|eh|de))\s+(.+?)' +
          _valueEnd),
  DialogState.askQuantity: RegExp(
      r'\b(?:quantidade\s+(?:e|eh|de)|vou\s+vender|quero\s+vender)\s+(\S+\s+unidades)\b'),
  DialogState.askCost: RegExp(
      r'\b(?:custo(?:\s+total)?|gasto(?:\s+total)?|gastei|gasto)\s+(?:e|eh|de|foi|fica|ficou)?\s*(.+?)' +
          _valueEnd),
  DialogState.askMargin: RegExp(r'\bmargem\s+(?:e|eh|de|fica|seja)?\s*(.+?)' + _valueEnd),
};

/// Informacoes que a fala traz pelo nome do campo: {campo: valor dito}. O texto e
/// analisado sem acento; o valor devolvido e o trecho ORIGINAL (com acentos).
Map<DialogState, String> parseFieldStatements(String input) =>
    {for (final s in _findStatements(input)) s.field: s.value};

/// O que sobra da fala sem as informacoes ditas pelo nome do campo ("cenoura e ovos,
/// e rende 12" -> "cenoura e ovos"): e a resposta da pergunta atual.
String remainderWithoutStatements(String input) {
  var t = input.trim();
  final spans = _findStatements(t).toList()..sort((a, b) => b.start.compareTo(a.start));
  for (final s in spans) {
    t = t.replaceRange(s.start, s.end, ' ');
  }
  return t
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'(^|\s)(e|ah|entao|então|tambem|também|o|a|os|as)(?=\s*([,;.]|$))',
          caseSensitive: false), ' ')
      .replaceAll(RegExp(r'^[\s,;.e]+|[\s,;.]+(e)?[\s,;.]*$', caseSensitive: false), '')
      .trim();
}

Iterable<({DialogState field, String value, int start, int end})> _findStatements(
    String input) sync* {
  final t = input.trim();
  final n = normalizePt(t);
  for (final e in _statements.entries) {
    final m = e.value.firstMatch(n);
    if (m == null) continue;
    // O valor e o fim do trecho casado (o lookahead do fim nao consome texto).
    final g = m.group(1)!;
    final v = t.substring(m.end - g.length, m.end).trim();
    // O trecho a remover inclui "o/a" e "e" logo antes ("..., e a margem e 40").
    var start = m.start;
    final before = n.substring(0, start);
    final lead = RegExp(r'(\s*(,|\be)\s*)?(\b(o|a|os|as)\s+)?$').firstMatch(before);
    if (lead != null) start = lead.start;
    if (v.isNotEmpty) yield (field: e.key, value: v, start: start, end: m.end);
  }
}

CorrectionRequest? parseCorrection(String input) {
  final norm = normalizePt(input);
  if (!RegExp(_correctionTrigger).hasMatch(norm)) return null;
  for (final e in _fieldKeywords.entries) {
    final m = RegExp('\\b(${e.value})\\b').firstMatch(norm);
    if (m == null) continue;
    // normalizePt preserva o tamanho do texto (1 caractere -> 1 caractere), entao o
    // indice vale para o texto original, que mantem maiusculas e acentos.
    final trimmed = input.trimLeft();
    var rest = m.end <= trimmed.length ? trimmed.substring(m.end) : '';
    var prev = '';
    while (prev != rest) {
      prev = rest;
      rest = rest.replaceFirst(_connector, '');
    }
    rest = rest.replaceAll(RegExp(r'[.!?]+$'), '').trim();
    final nr = normalizePt(rest);
    final noValue = rest.isEmpty ||
        RegExp(r'^(errad[oa]|incorret[oa]|trocad[oa])\b').hasMatch(nr) ||
        RegExp(_correctionTrigger).hasMatch(nr);
    return CorrectionRequest(e.key, noValue ? null : rest);
  }
  return null;
}

/// Motor de dialogo 100% local e deterministico.
/// O LLM local (fase 2) entra apenas como "interpretador" que transforma fala livre em
/// texto normalizado ANTES de [handle]; nunca calcula nem decide precos.
///
/// Fase de testes: UM produto por usuario. A triagem (empresa, produto, especificacoes)
/// e feita uma vez e vira o cadastro ([profile]); nas proximas conversas o app vai direto
/// ao preco desse produto, e o cadastro so muda por correcao ("corrigir o tempo").
class DialogMachine {
  DialogMachine({
    SalesSession? profile,
    this.recallProduct,
    this.savedProductNames,
    this.knownPrices,
  }) {
    _state = DialogState.askCompany;
    if (profile != null) this.profile = profile.keepTriage();
  }

  /// Cadastro do usuario (triagem salva). Atualizado sempre que a triagem muda.
  SalesSession profile = const SalesSession();

  /// Memoria local: produto salvo citado num pedido ("use a receita do bolo que voce ja
  /// tem") ou com o nome [current]. null = nao achou.
  /// [exact]: so o produto com o mesmo nome (oferta automatica apos o nome do produto).
  final SalesSession? Function(String request, {String? current, bool exact})? recallProduct;

  /// Nomes dos produtos salvos (para dizer quais existem quando nao acha).
  final List<String> Function()? savedProductNames;

  /// Precos de ingredientes ja registrados (memoria local).
  final List<KnownPrice> Function()? knownPrices;

  /// Precos salvos oferecidos ("quer que eu use esses precos?"), aguardando sim/nao.
  List<KnownPrice>? _pendingFill;

  /// Produto salvo aguardando "sim/nao" em [DialogState.askReuse].
  SalesSession? _recalled;

  /// Avisado a cada correcao (campo, valor antigo, valor novo): sinal de aprendizado.
  void Function(DialogState field, Object? oldValue, Object? newValue)? onCorrected;

  /// Valor que estava no campo quando a pessoa pediu para corrigi-lo.
  Object? _correctingOld;

  late DialogState _state;
  SalesSession _session = const SalesSession();
  String _lastPrompt = '';

  /// Depois de corrigir uma resposta antiga, volta para esta pergunta.
  DialogState? _resumeTo;

  /// Entrevista do custo detalhado em andamento ([DialogState.costDetail]).
  CostInterview? _interview;

  static const _offerText = 'Quer detalhar o custo de produção do lote? Eu monto uma '
      'tabela com cada material, embalagem, frete e o seu pró-labore, e calculo quanto '
      'custa produzir cada unidade.';

  DialogState get state => _state;
  SalesSession get session => _session;
  String get lastPrompt => _lastPrompt;

  /// Pergunta atual, sem o comentario da resposta anterior (para voltar a ela).
  String get currentQuestion => _resumeText();

  static const _greeting =
      'Oi! Eu sou seu assistente de vendas. Vou te ajudar a descobrir quanto cobrar. ';

  /// Nova conversa. Com cadastro: vai direto ao preco do produto. Sem: faz a triagem.
  /// Ultima simulacao de preco (para a tela). Some quando um novo calculo comeca.
  PriceSimulation? get simulation => _simulation;
  PriceSimulation? _simulation;

  /// "quero vender a unidade por 6 reais", "e se eu cobrar 7?", "vender o lote por 80":
  /// calcula lucro e margem real com o preco escolhido. null = a fala nao e isso.
  DialogResponse? _trySimulate(String input) {
    final n = normalizePt(input);
    if (!RegExp(r'\b(vender|vendo|venda|cobrar|cobro|cobrando|preco|custar|sair|e se)\b')
        .hasMatch(n)) {
      return null;
    }
    final cents = parsePriceWithPackage(input)?.cents ?? parseMoneyCents(input);
    if (cents == null || cents <= 0) return null;
    final unitCost = _unitCostExact();
    if (unitCost == null) return null;
    final y = _session.costs?.batchYield ?? _session.batchYield;
    // Preco do lote ("o lote por 80 reais") vira preco da unidade.
    final u = _session.units;
    final batchWord = u.batch == null ? '' : '|${normalizePt(u.batch!)}';
    final isLot = RegExp('\\b(lote|fornada|tudo|inteir[ao]$batchWord)\\b').hasMatch(n) &&
        !RegExp('\\b(unidade|cada|${normalizePt(u.one)})\\b').hasMatch(n);
    final unitPrice = isLot && y != null && y > 0 ? (cents / y).round() : cents;
    _simulation = PriceSimulation(
      priceCents: unitPrice,
      unitCostCents: unitCost,
      suggestedCents: _suggestedUnitPrice(),
      batchYield: y,
    );
    final lotNote =
        isLot && y != null
            ? 'O ${u.batchName} de ${u.count(y)} por ${speakBrl(cents)} dá ${u.theOne} a '
                '${speakBrl(unitPrice)}. '
            : '';
    final next = _state == DialogState.offerDetail
        ? ' Pode testar outro preço. $_offerText'
        : ' Pode testar outro preço, ou diga: recomeçar.';
    final text = '$lotNote${speakSimulation(_simulation!, units: _session.units)}$next';
    _lastPrompt = text;
    return DialogResponse(text, _state);
  }

  /// Unidade de venda e rendimento ditos em qualquer ponto ("sao 12 pedacos de 1 bolo",
  /// "cada bolo rende 12 fatias", "vendo por pote"). Atualiza as frases do app e o
  /// rendimento. Na pergunta da quantidade/rendimento a fala tambem e a resposta.
  /// null = a fala nao traz unidade de venda (segue o fluxo normal).
  DialogResponse? _trySaleUnit(String input) {
    // Na pergunta do produto, "marmitas" e o nome do produto; na entrevista de custo,
    // "o pote custa 2 reais" e embalagem.
    if (_state == DialogState.costDetail || _state == DialogState.askProduct) return null;
    final su = parseSaleUnit(input);
    if (su == null) return null;
    const answerStates = {DialogState.askQuantity, DialogState.askBatchYield};
    const reviewStates = {DialogState.confirm, DialogState.result, DialogState.offerDetail};
    if (!su.strong && !answerStates.contains(_state) && !reviewStates.contains(_state)) {
      return null;
    }
    final unitChanged = su.one != _session.saleUnit ||
        (su.batch != null && su.batch != _session.batchName);
    final oldYield = _session.batchYield;
    _session = _session.copyWith(saleUnit: su.one, batchName: su.batch);
    final u = _session.units;
    final notes = <String>[
      if (unitChanged) 'você vende por ${su.one}',
    ];
    if (su.perBatch != null && su.perBatch != oldYield) {
      if (oldYield != null) {
        onCorrected?.call(DialogState.askBatchYield, oldYield, su.perBatch);
      }
      _setField(DialogState.askBatchYield, su.perBatch);
      notes.add('${su.batchFeminine ? 'uma' : 'um'} ${u.batchName} rende ${u.count(su.perBatch!)}');
    }
    if (_session.hasProfile) profile = _session.keepTriage();
    final ack = notes.isEmpty ? '' : 'Anotei: ${notes.join(', e ')}.';

    // Nas perguntas de quantidade/rendimento, a mesma fala responde a pergunta.
    if (answerStates.contains(_state)) {
      final r = _answer(input);
      if (r.understood) {
        return DialogResponse(ack.isEmpty ? r.text : '$ack ${r.text}', r.state,
            result: r.result, breakdown: r.breakdown);
      }
      if (ack.isEmpty) return null;
      return _say('$ack ${_question(_state)}');
    }
    if (ack.isEmpty) return null;
    // Na revisao do calculo: confere de novo com as palavras certas.
    if (reviewStates.contains(_state) && _session.quantity != null &&
        _session.totalCostCents != null && _session.marginPercent != null) {
      _simulation = null;
      return _goto(DialogState.confirm, '$ack ${_confirmationText()}');
    }
    return _say('$ack ${_question(_state)}');
  }

  // ---- perguntas da pessoa ----

  /// Perguntas que o app responde sozinho. Pergunta desconhecida volta como "nao
  /// entendi" (a IA local responde em seguida, se estiver instalada).
  DialogResponse? _tryQuestion(String input) {
    if (!isQuestion(input) || parseYesNo(input) != null || RegExp(r'\d').hasMatch(input)) {
      return null;
    }
    final n = normalizePt(input);
    final back = _resumeText();
    final table = costTable;

    // Precos registrados ("voce tem registro dos precos dos produtos listados?").
    final asksPrice = RegExp(r'\b(precos?|valor|valores|custa|custou|paguei|pago)\b').hasMatch(n);
    final known = knownPrices?.call() ?? const <KnownPrice>[];
    if (asksPrice && RegExp(r'\b(registro|registrado|historico|salvos?|guardados?|anotados?|'
            r'lembra|tem|sabe|ja|listados?|desses|destes|deles)\b')
        .hasMatch(n)) {
      // Pergunta de UM ingrediente ("quanto paguei na farinha?").
      final one = _knownFor(n, known);
      if (one != null) return _retryOk('Tenho registrado: ${one.speak()}. $back');
      if (known.isEmpty) {
        return _retryOk('Ainda não tenho preços salvos. Eles ficam guardados quando você '
            'detalha o custo de um produto. $back');
      }
      final missing = table?.materials.where((m) => m.costCents == null).toList() ?? const [];
      final useful = {
        for (final m in missing)
          for (final k in known)
            if (sameIngredient(m.name, k.name)) k,
      }.toList();
      if (useful.isNotEmpty) {
        _pendingFill = useful;
        return _retryOk('Tenho preços salvos de: ${useful.map((k) => k.speak()).join('; ')}. '
            'Quer que eu use esses preços na tabela?');
      }
      return _retryOk('Tenho preços salvos de: ${known.take(6).map((k) => k.speak()).join('; ')}. '
          'Nenhum deles é dos ingredientes que faltam agora. $back');
    }
    // Preco de um ingrediente ("quanto custa a farinha?", "qual o preco do acucar?").
    if (asksPrice) {
      final inTable = table?.materials
          .where((m) => m.priceCents != null && m.pack != null)
          .where((m) => _nameIn(n, m.name))
          .firstOrNull;
      if (inTable != null) {
        return _retryOk('Na tabela: ${inTable.name}, ${speakBrl(inTable.priceCents!)} por '
            '${speakMeasure(inTable.pack!)}${inTable.costCents == null ? '' : ', ${speakBrl(inTable.costCents!)} por ${_session.units.batchName}'}. $back');
      }
      final one = _knownFor(n, known);
      if (one != null) return _retryOk('Tenho registrado: ${one.speak()}. $back');
    }
    // O que falta preencher.
    if (RegExp(r'\b(falta|faltam|faltando|pendente|pendentes)\b').hasMatch(n)) {
      final missing = table?.materials.where((m) => m.costCents == null).toList() ?? const [];
      if (missing.isEmpty) return _retryOk('Não falta nenhum ingrediente na tabela. $back');
      return _retryOk('Falta completar: ${missing.map((m) => '${m.name} (${m.used == null ? 'quantidade' : 'preço'})').join(', ')}. $back');
    }
    // Preco sugerido.
    if (RegExp(r'\b(cobrar|cobro|vender|preco sugerido|preco de venda)\b').hasMatch(n)) {
      final sug = _suggestedUnitPrice();
      if (sug != null) {
        return _retryOk('O preço sugerido ${_session.units.ofTheOne} é ${speakBrl(sug)}. $back');
      }
      return _retryOk('Ainda não calculei o preço: preciso da quantidade, do custo e da '
          'margem. $back');
    }
    // Produtos salvos.
    if (RegExp(r'\b(produtos|cadastrados?|salvos?)\b').hasMatch(n) && savedProductNames != null) {
      final names = savedProductNames!();
      return _retryOk(names.isEmpty
          ? 'Ainda não tenho produtos salvos. $back'
          : 'Produtos salvos: ${names.join(', ')}. Eles ficam em Meus produtos, no topo. $back');
    }
    // Como funciona.
    if (RegExp(r'\b(funciona|faz|fazer|posso dizer|posso falar|ajuda)\b').hasMatch(n)) {
      return _retryOk('Eu calculo o preço do seu produto: pergunto os ingredientes, o custo e '
          'a margem, e mostro o preço da unidade e do lote. Você pode corrigir qualquer dado '
          'dizendo, por exemplo: corrigir a margem. $back');
    }
    // Pergunta que o app nao sabe responder: nao vira resposta (a IA local tenta).
    return _retry('Não sei responder isso ainda. $back');
  }

  /// Resposta a uma pergunta da pessoa: NAO muda a pergunta atual do app.
  DialogResponse _retryOk(String text) => DialogResponse(text, _state);

  /// Texto para voltar a pergunta atual depois de responder outra coisa.
  String _resumeText() {
    if (_state == DialogState.result) return '';
    final q = _question(_state);
    return q.isEmpty ? '' : 'Voltando: $q';
  }

  static bool _nameIn(String n, String name) {
    final head = normalizePt(name).split(RegExp(r'[^a-z]+')).firstWhere((w) => w.length > 2,
        orElse: () => '');
    if (head.isEmpty) return false;
    final stem = head.endsWith('s') ? head.substring(0, head.length - 1) : head;
    return RegExp('\\b${stem}s?\\b').hasMatch(n);
  }

  KnownPrice? _knownFor(String n, List<KnownPrice> known) {
    for (final k in known) {
      if (_nameIn(n, k.name)) return k;
    }
    return null;
  }

  /// Usa os precos salvos nos ingredientes da tabela que ainda nao tem preco.
  DialogResponse _applyKnownPrices(List<KnownPrice> prices) {
    final items = [for (final k in prices) PurchaseItem(k.name, k.cents, k.pack)];
    if (_state == DialogState.costDetail && _interview != null) {
      final before = _interview!.table.materials.where((m) => m.costCents != null).length;
      // So preenche quem nao tem preco (nao cria itens novos).
      final missing = _interview!.table.materials.where((m) => m.priceCents == null).toList();
      final matched = [
        for (final it in items)
          if (missing.any((m) => sameIngredient(m.name, it.name))) it,
      ];
      final q = _interview!.importDocuments(const [], matched);
      final added = _interview!.table.materials.where((m) => m.costCents != null).length - before;
      return _say('Pronto, usei $added ${added == 1 ? 'preço salvo' : 'preços salvos'}. $q');
    }
    final t = _session.costs;
    if (t != null) {
      final copy = CostBreakdown.fromJson(t.toJson())!;
      for (final it in items) {
        for (final m in copy.materials) {
          if (m.priceCents == null && sameIngredient(m.name, it.name)) {
            m
              ..priceCents = it.cents
              ..pack = it.pack;
          }
        }
      }
      _session = _session.withCosts(copy);
      if (_session.hasProfile) profile = _session.keepTriage();
    }
    return _say('Pronto, anotei os preços salvos na tabela. ${_question(_state)}');
  }

  /// Contexto para a IA local responder perguntas livres (so dados, sem inventar).
  String contextForQuestions() {
    final s = _session;
    final t = costTable;
    final known = knownPrices?.call() ?? const <KnownPrice>[];
    return [
      if (s.product != null) 'Produto: ${s.product}.',
      if (s.batchYield != null) 'Rende ${s.units.count(s.batchYield!)} por ${s.units.batchName}.',
      if (t != null && t.materials.isNotEmpty)
        'Ingredientes: ${t.materials.map((m) => '${m.name}${m.used == null ? '' : ' ${speakMeasure(m.used!)}'}${m.costCents == null ? ' (sem preço)' : ' custa ${formatBrl(m.costCents!)}'}').join('; ')}.',
      if (known.isNotEmpty) 'Preços registrados: ${known.take(10).map((k) => k.speak()).join('; ')}.',
      if (_suggestedUnitPrice() != null) 'Preço sugerido: ${formatBrl(_suggestedUnitPrice()!)}.',
    ].join(' ');
  }

  /// Custo de producao de UMA unidade: da tabela de custo completa, se houver; senao,
  /// do custo total informado dividido pela quantidade.
  int? _unitCostExact() {
    final t = _session.costs;
    if (t != null &&
        t.batchYield != null &&
        t.batchYield! > 0 &&
        t.materials.isNotEmpty &&
        t.materials.every((m) => m.costCents != null)) {
      return (t.batchCents / t.batchYield!).round();
    }
    final q = _session.quantity, c = _session.totalCostCents;
    if (q == null || q < 1 || c == null) return null;
    return (c / q).round();
  }

  int? _suggestedUnitPrice() {
    final t = _session.costs;
    if (t?.unitPriceCents != null && t!.materials.every((m) => m.costCents != null)) {
      return t.unitPriceCents;
    }
    if (_session.quantity == null || _session.totalCostCents == null || _session.marginPercent == null) {
      return null;
    }
    return _currentResult().unitPriceCents;
  }

  DialogResponse start() {
    _simulation = null;
    _resumeTo = null;
    _correctingOld = null;
    _interview = null;
    final p = profile;
    if (p.hasProfile) {
      _session = p.keepTriage();
      _state = DialogState.askQuantity;
      final hi = p.company != null ? 'Oi de novo, ${p.company}!' : 'Oi de novo!';
      return _say('$hi Vamos calcular o preço de ${p.product}. '
          '${_question(DialogState.askQuantity)} Para mudar algum dado do produto, diga, '
          'por exemplo: corrigir o tempo.');
    }
    if (p.company != null) {
      // Novo produto da mesma empresa: a triagem comeca pelo produto.
      _session = SalesSession(company: p.company);
      _state = DialogState.askProduct;
      return _say('Vamos cadastrar um novo produto para ${p.company}. '
          '${_question(DialogState.askProduct)} Se a empresa mudou, diga: corrigir '
          'empresa.');
    }
    _state = DialogState.askCompany;
    _session = const SalesSession();
    return _say('$_greeting${_question(DialogState.askCompany)}');
  }

  DialogResponse handle(String input) {
    // Resposta para a oferta de usar precos salvos.
    final fill = _pendingFill;
    if (fill != null) {
      _pendingFill = null;
      final yn = parseYesNo(input);
      if (yn == YesNo.yes) return _applyKnownPrices(fill);
      if (yn == YesNo.no) return _say('Tudo bem. ${_question(_state)}');
    }

    final cmd = parseCommand(input);
    if (cmd != null) return _command(cmd);

    // Pergunta da pessoa ("voce tem registro dos precos?"): responde e volta para a
    // pergunta atual. Pergunta nunca vira resposta da pergunta do app.
    final q = _tryQuestion(input);
    if (q != null) return q;

    // Na entrevista de custo, frases como "o frete custa 20" nao sao correcoes.
    if (_state == DialogState.costDetail) {
      // Correcao de dado da FICHA no meio do custo ("corrigir os ingredientes", "o produto
      // e X"). Rendimento, precos e custos extras sao corrigidos pela propria entrevista.
      final fix = parseCorrection(input);
      const triage = {
        DialogState.askCompany, DialogState.askSector, DialogState.askProduct,
        DialogState.askMaterials, DialogState.askProductionTime,
      };
      if (fix != null && triage.contains(fix.field)) return _correct(fix.field, fix.value);
      return _answer(input);
    }

    // "sao 12 pedacos de 1 bolo", "vendo por fatia": unidade de venda (e rendimento).
    final unit = _trySaleUnit(input);
    if (unit != null) return unit;

    // "use a receita do bolo de cenoura que voce ja tem": reaproveita um produto salvo.
    final reuse = _tryReuseRequest(input);
    if (reuse != null) return reuse;

    // Depois do resultado: "quero vender por 6 reais" simula o lucro com esse preco.
    if (_state == DialogState.result || _state == DialogState.offerDetail) {
      final sim = _trySimulate(input);
      if (sim != null) return sim;
    }

    final fix = parseCorrection(input);
    if (fix != null) {
      if (!_canCorrect(fix.field)) {
        // Ainda nao perguntado: com valor, ja anota; sem valor, nao vira resposta da
        // pergunta atual (era o bug do "corrigir" virar produto).
        if (fix.value != null) {
          final early = _applyStatements({fix.field: fix.value!});
          if (early != null) return early;
        }
        return _retry('Essa informação ainda não foi respondida. ${_question(_state)}');
      }
      return fix.field == _state && fix.value != null
          ? _answer(fix.value!) // "na verdade rende trinta" na propria pergunta
          : _correct(fix.field, fix.value);
    }

    // Informacoes de OUTRAS perguntas ditas no meio da resposta ("... e a margem e 40%"):
    // corrige o que ja foi respondido e adianta o que ainda nao foi perguntado.
    final stmts = parseFieldStatements(input);
    if (stmts.keys.any((f) => f != _state && correctableStates.contains(f))) {
      final r = _applyStatements(stmts, original: input);
      if (r != null) return r;
    }
    return _answer(input);
  }

  /// Aplica informacoes ditas pelo nome do campo. A do campo da pergunta atual vira a
  /// resposta; as outras corrigem (ja respondidas) ou adiantam (ainda nao perguntadas).
  /// null = nenhuma informacao valida (a fala segue como resposta normal).
  DialogResponse? _applyStatements(Map<DialogState, String> stmts, {String? original}) {
    final acks = <String>[];
    var changedAnswered = false;
    for (final e in stmts.entries) {
      final f = e.key;
      if (f == _state || !correctableStates.contains(f)) continue;
      final parsed = _parseField(f, e.value, false);
      if (parsed.error != null || parsed.value == null) continue;
      final old = _valueOf(f);
      if (old == parsed.value) continue;
      final answered = _canCorrect(f);
      if (answered) {
        onCorrected?.call(f, old, parsed.value);
        changedAnswered = true;
        acks.add(_fixAck(f, parsed.value));
      } else {
        acks.add(_fixAck(f, parsed.value).replaceFirst('Corrigido:', 'Anotei:'));
      }
      _setField(f, parsed.value);
    }
    if (acks.isEmpty) return null;
    final ack = acks.join(' ');

    // Resposta da pergunta atual dita junto (pelo nome do campo ou no resto da fala).
    var current = stmts[_state];
    if (current == null && original != null) {
      final rest = remainderWithoutStatements(original);
      if (rest.length >= 2 && RegExp(r'[\p{L}\d]', unicode: true).hasMatch(rest)) {
        final r = _answer(rest);
        if (r.understood) {
          return DialogResponse('$ack ${r.text}', r.state,
              result: r.result, breakdown: r.breakdown, understood: true);
        }
      }
    }
    if (current != null) {
      final r = _answer(current);
      return DialogResponse('$ack ${r.text}', r.state,
          result: r.result, breakdown: r.breakdown, understood: r.understood);
    }
    // Mudou um dado do calculo depois do resultado: volta para a confirmacao.
    if (changedAnswered &&
        const {DialogState.confirm, DialogState.result, DialogState.offerDetail}
            .contains(_state)) {
      _simulation = null;
      return _goto(DialogState.confirm, '$ack ${_confirmationText()}');
    }
    // Senao, continua na mesma pergunta.
    return _say('$ack ${_question(_state)}');
  }

  /// A fala parece resposta da pergunta atual? Usada pelo envio automatico do texto
  /// ouvido: ruido ("reproduzir"), frase cortada ("entao olha so, primeira") ou conversa
  /// ("eu acho que poderia...") ficam esperando a pessoa confirmar ou continuar falando.
  bool looksLikeAnswer(String input) {
    final t = input.trim();
    if (t.isEmpty) return false;
    // Pergunta da pessoa e intencional: envia (o app responde e volta a pergunta atual).
    if (isQuestion(t)) return true;
    if (parseCommand(t) != null ||
        parseCorrection(t) != null ||
        parseFieldStatements(t).isNotEmpty ||
        parseSaleUnit(t)?.strong == true) {
      return true;
    }
    if (_state == DialogState.costDetail) return _interview?.looksLikeAnswer(t) ?? true;
    if (isConversation(t)) return false;
    final yesNo = parseYesNo(t) != null || isSkip(t);
    switch (_state) {
      case DialogState.askQuantity:
        return _parseQuantity(t) != null;
      case DialogState.askBatchYield:
        return isSkip(t) || parseBatchYield(t) != null;
      case DialogState.askProductionTime:
        return isSkip(t) || parseDurationMinutes(t) != null;
      case DialogState.askCost:
        return parseMoneyCents(t) != null;
      case DialogState.askMargin:
        return parsePercent(t) != null;
      case DialogState.confirm:
      case DialogState.askReuse:
        return yesNo;
      case DialogState.offerDetail:
      case DialogState.result:
        // sim/nao, "detalhar custo" ou um preco para simular
        return yesNo ||
            RegExp(r'\b(detalhar|detalhe|tabela)\b').hasMatch(normalizePt(t)) ||
            _shareWords.hasMatch(normalizePt(t)) ||
            parseMoneyCents(t) != null;
      default:
        return true; // texto livre (empresa, ramo, produto, ingredientes...)
    }
  }

  /// Volta para uma resposta anterior (lapis na tela ou "corrigir <campo>").
  /// Depois de responder, a conversa continua de onde estava.
  DialogResponse correct(DialogState field) => _correct(field, null);

  // ---- respostas ----

  DialogResponse _answer(String input) {
    final skip = isSkip(input);
    if (_state == DialogState.result &&
        RegExp(r'\b(detalhar|detalhe|tabela)\b').hasMatch(normalizePt(input))) {
      return _startInterview();
    }
    // "compartilhar", "exportar", "manda o resultado no zap": abre as opcoes de envio.
    if ((_state == DialogState.result || _state == DialogState.offerDetail) &&
        _shareWords.hasMatch(normalizePt(input))) {
      const text = 'Certo. Escolha como enviar: o resumo por mensagem ou a planilha.';
      return DialogResponse(text, _state, share: true);
    }
    switch (_state) {
      case DialogState.askReuse:
        final yn = parseYesNo(input);
        final saved = _recalled;
        if (yn == YesNo.yes && saved != null) return _applySaved(saved);
        if (yn == YesNo.no || saved == null) {
          _recalled = null;
          return _goto(DialogState.askMaterials,
              'Tudo bem, vamos cadastrar de novo. ${_question(DialogState.askMaterials)}');
        }
        return _retry('Responda sim para usar os dados salvos, ou não para cadastrar de novo.');

      case DialogState.confirm:
        final yn = parseYesNo(input);
        if (yn == YesNo.yes) return _finish();
        if (yn == YesNo.no) {
          // Mantem a triagem; corrige so os numeros.
          _session = _session.keepTriage();
          _resumeTo = null;
          return _goto(DialogState.askQuantity,
              'Tudo bem, vamos corrigir os números. ${_question(DialogState.askQuantity)}');
        }
        return _retry('Diga sim para calcular, ou não para refazer os números. Também pode '
            'dizer o que mudar, por exemplo: a margem é 40 por cento.');

      case DialogState.result:
        if (RegExp(r'\b(salvar|salva|salve|guardar|guarda|gravar|grava)\b')
            .hasMatch(normalizePt(input))) {
          return _say('Pode deixar: tudo já fica salvo automaticamente, a ficha, a tabela de '
              'custo e o último preço. Você encontra o produto em Meus produtos, no topo.');
        }
        return _say('Para enviar o resultado, diga: compartilhar. Para calcular de novo com '
            'outros números, diga: recomeçar. Para detalhar o custo de produção, diga: '
            'detalhar custo. Para mudar uma resposta, diga, por exemplo: corrigir o custo.');

      case DialogState.offerDetail:
        final yn = parseYesNo(input);
        if (yn == YesNo.yes) return _startInterview();
        if (yn == YesNo.no || isSkip(input)) {
          return _goto(DialogState.result, 'Tudo bem. Se quiser detalhar depois, diga: '
              'detalhar custo. Para calcular de novo, diga: recomeçar.');
        }
        return _retry('Responda sim para detalhar o custo, ou não para terminar.');

      case DialogState.costDetail:
        final it = _interview!;
        final r = it.answer(input);
        if (!r.ok) return _retry(r.text);
        if (!it.done) return _say(r.text);
        return _finishInterview(r.text);

      default:
        final field = _state;
        final parsed = _parseField(field, input, skip);
        if (parsed.error != null) return _retry(parsed.error!);
        _setField(field, parsed.value);
        return _advance(field, _ack(field, parsed.value));
    }
  }

  /// Interpreta a resposta de UMA pergunta. Mesmo codigo para resposta normal e correcao.
  _Parsed _parseField(DialogState field, String input, bool skip) {
    switch (field) {
      case DialogState.askCompany:
        final v = skip ? null : parseCompanyName(input);
        return v == null && !skip
            ? const _Parsed.error(
                'Não entendi. Qual é o nome da sua empresa? Se não tiver, diga: pular.')
            : _Parsed(v);
      case DialogState.askSector:
        final v = skip ? null : parseSector(input);
        return v == null && !skip
            ? const _Parsed.error('Não entendi o ramo. Diga, por exemplo: confeitaria, '
                'salgados ou marmitas. Se preferir, diga: pular.')
            : _Parsed(v);
      case DialogState.askProduct:
        final v = skip ? null : parseProductName(input);
        return v == null
            ? const _Parsed.error('Não entendi o nome. Qual produto você quer vender?')
            : _Parsed(v);
      case DialogState.askMaterials:
        // Conversa ("eu acho que...", "faltaram ingredientes") nao e lista de ingredientes.
        final v = skip || isConversation(input) ? null : parseMaterials(input);
        return v == null && !skip
            ? const _Parsed.error(
                'Não entendi. Fale os ingredientes ou materiais, ou diga: pular.')
            : _Parsed(v);
      case DialogState.askBatchYield:
        final v = skip ? null : parseBatchYield(input);
        return !skip && (v == null || v < 1 || v > 100000)
            ? const _Parsed.error('Não entendi. Diga quantas unidades saem de cada '
                'produção, por exemplo: vinte. Ou diga: pular.')
            : _Parsed(v);
      case DialogState.askProductionTime:
        final v = skip ? null : parseDurationMinutes(input);
        return !skip && (v == null || v > 60 * 24 * 60)
            ? const _Parsed.error('Não entendi o tempo. Diga, por exemplo: duas horas, '
                'ou quarenta minutos. Ou diga: pular.')
            : _Parsed(v);
      case DialogState.askCharacteristics:
        final v = skip ? null : parseCharacteristics(input);
        return v == null && !skip
            ? const _Parsed.error(
                'Não entendi. Fale o tamanho, peso, sabor ou cor, ou diga: pular.')
            : _Parsed(v);
      case DialogState.askQuantity:
        final v = _parseQuantity(input);
        return v == null || v < 1 || v > 100000
            ? const _Parsed.error(
                'Não entendi a quantidade. Diga um número, por exemplo: vinte.')
            : _Parsed(v);
      case DialogState.askCost:
        final v = parseMoneyCents(input);
        return v == null || v <= 0
            ? const _Parsed.error(
                'Não entendi o valor. Diga em reais, por exemplo: cento e vinte reais.')
            : _Parsed(v);
      case DialogState.askMargin:
        final v = parsePercent(input);
        return v == null || v < 0 || v > 90
            ? const _Parsed.error(
                'Diga uma margem entre zero e noventa por cento. Por exemplo: trinta.')
            : _Parsed(v);
      case DialogState.askReuse:
      case DialogState.confirm:
      case DialogState.result:
      case DialogState.offerDetail:
      case DialogState.costDetail:
        return const _Parsed.error('');
    }
  }

  /// Frase curta confirmando o que foi anotado (o usuario ouve e percebe erro de fala).
  String _ack(DialogState field, Object? v) {
    switch (field) {
      case DialogState.askCompany:
        return v == null ? 'Sem problema.' : 'Prazer, $v!';
      case DialogState.askSector:
        return v == null ? 'Tudo bem.' : 'Ramo: $v.';
      case DialogState.askProduct:
        return 'Certo, $v.';
      case DialogState.askMaterials:
        return v == null ? 'Tudo bem.' : 'Anotei: $v.';
      case DialogState.askBatchYield:
        return v == null
            ? 'Tudo bem.'
            : 'Cada ${_session.units.batchName} rende ${_session.units.count(v as int)}.';
      case DialogState.askProductionTime:
        return v == null ? 'Tudo bem.' : 'Leva ${speakDuration(v as int)}.';
      case DialogState.askCharacteristics:
        return v == null ? 'Tudo bem. Agora vamos ao preço.' : 'Anotei. Agora vamos ao preço.';
      case DialogState.askQuantity:
        return '';
      case DialogState.askCost:
        return 'Anotei ${speakBrl(v as int)} de custo.';
      case DialogState.askMargin:
      case DialogState.askReuse:
      case DialogState.confirm:
      case DialogState.result:
      case DialogState.offerDetail:
      case DialogState.costDetail:
        return '';
    }
  }

  /// Confirmacao de uma CORRECAO: diz o campo e o valor novo.
  String _fixAck(DialogState field, Object? v) {
    if (v == null) return 'Corrigido.';
    switch (field) {
      case DialogState.askCompany:
        return 'Corrigido: empresa $v.';
      case DialogState.askSector:
        return 'Corrigido: ramo $v.';
      case DialogState.askProduct:
        return 'Corrigido: produto $v.';
      case DialogState.askMaterials:
        return 'Corrigido: materiais, $v.';
      case DialogState.askBatchYield:
        return 'Corrigido: rende ${_session.units.count(v as int)} por ${_session.units.batchName}.';
      case DialogState.askProductionTime:
        return 'Corrigido: leva ${speakDuration(v as int)}.';
      case DialogState.askCharacteristics:
        return 'Corrigido: características, $v.';
      case DialogState.askQuantity:
        return 'Corrigido: $v unidades.';
      case DialogState.askCost:
        return 'Corrigido: custo de ${speakBrl(v as int)}.';
      case DialogState.askMargin:
        return 'Corrigido: margem de $v por cento.';
      case DialogState.askReuse:
      case DialogState.confirm:
      case DialogState.result:
      case DialogState.offerDetail:
      case DialogState.costDetail:
        return 'Corrigido.';
    }
  }

  /// Avanca depois de uma resposta valida: volta para onde estava (correcao) ou
  /// segue para a proxima pergunta.
  DialogResponse _advance(DialogState answered, String ack) {
    final resume = _resumeTo;
    if (resume != null) {
      _resumeTo = null;
      onCorrected?.call(answered, _correctingOld, _valueOf(answered));
      _correctingOld = null;
      final fix = _fixAck(answered, _valueOf(answered));
      return _goto(resume, 'Pronto. $fix ${_resumeQuestion(resume)}');
    }

    // Produto com o mesmo nome de um salvo: oferece reaproveitar a receita e os dados.
    if (answered == DialogState.askProduct) {
      final saved =
          recallProduct?.call(_session.product!, current: _session.product, exact: true);
      if (saved != null) {
        _recalled = saved;
        return _goto(DialogState.askReuse, '$ack ${_reuseQuestion(saved)}');
      }
    }

    // Pula perguntas que a pessoa ja respondeu antes, fora de ordem ("... e rende 15").
    var i = dialogOrder.indexOf(answered) + 1;
    while (dialogOrder[i] != DialogState.confirm && _valueOf(dialogOrder[i]) != null) {
      i++;
    }
    final next = dialogOrder[i];
    final text = next == DialogState.confirm ? _confirmationText() : _question(next);
    return _goto(next, ack.isEmpty ? text : '$ack $text');
  }

  /// Corrige um campo: aplica o valor dito junto, ou pergunta de novo e depois volta.
  DialogResponse _correct(DialogState field, String? value) {
    if (!_canCorrect(field)) {
      return _retry('Essa informação ainda não foi respondida. ${_question(_state)}');
    }
    // No meio do custo detalhado: guarda os precos ja dados antes de corrigir a ficha. A
    // entrevista recomeca dessa tabela depois (os precos dos mesmos ingredientes ficam).
    if (_state == DialogState.costDetail && _interview != null) {
      _session = _session.withCosts(CostBreakdown.fromJson(_interview!.table.toJson()));
    }
    // Do resultado ou da confirmacao, volta para a confirmacao com os valores novos.
    final resume = (_state == DialogState.result ||
            _state == DialogState.confirm ||
            _state == DialogState.offerDetail)
        ? DialogState.confirm
        : (_resumeTo ?? _state);
    if (value != null) {
      final parsed = _parseField(field, value, isSkip(value));
      if (parsed.error == null) {
        onCorrected?.call(field, _valueOf(field), parsed.value);
        _setField(field, parsed.value);
        _resumeTo = null;
        return _goto(resume, '${_fixAck(field, parsed.value)} ${_resumeQuestion(resume)}');
      }
      // Valor nao entendido: pergunta o campo de novo.
    }
    _resumeTo = resume == field ? null : resume;
    _correctingOld = _valueOf(field);
    return _goto(field, 'Tudo bem, vamos corrigir. ${_question(field)}');
  }

  /// Da para corrigir campos ja respondidos (ou o atual).
  bool _canCorrect(DialogState field) {
    if (!correctableStates.contains(field)) return false;
    var cur = _resumeTo ?? _state;
    if (cur == DialogState.offerDetail || cur == DialogState.costDetail) {
      cur = DialogState.result;
    }
    // Com cadastro pronto, toda a triagem ja foi respondida.
    if (profile.hasProfile && dialogOrder.indexOf(field) < dialogOrder.indexOf(DialogState.askQuantity)) {
      return true;
    }
    return dialogOrder.indexOf(field) <= dialogOrder.indexOf(cur);
  }

  /// Grava a resposta; campos da triagem atualizam tambem o cadastro.
  void _setField(DialogState field, Object? value, {bool rebuildDraft = true}) {
    _session = _session.withField(field, value);
    if (field == DialogState.askMaterials && rebuildDraft) {
      _session = _session.withCosts(_draftFromMaterials(value as String?));
    }
    if (dialogOrder.indexOf(field) < dialogOrder.indexOf(DialogState.askQuantity)) {
      profile = _session.keepTriage();
    }
  }

  /// Ingredientes ditos/digitados viram a lista da tabela de custo na hora (com as
  /// quantidades e partes faladas). Precos que ja existiam para o mesmo ingrediente
  /// (foto da nota, custo detalhado anterior) sao mantidos.
  CostBreakdown? _draftFromMaterials(String? text) {
    final old = _session.costs;
    final items = parseSpokenRecipe(text);
    if (items.isEmpty && old == null) return null;
    final t = old != null
        ? CostBreakdown.fromJson(old.toJson())!
        : CostBreakdown(batchYield: _session.batchYield);
    final previous = [...t.materials];
    t.materials.clear();
    for (final it in items) {
      final m = MaterialCost(it.name, used: it.used, part: it.part);
      for (final p in previous) {
        if (sameIngredient(p.name, it.name)) {
          m
            ..used ??= p.used
            ..priceCents = p.priceCents
            ..pack = p.pack
            ..gramsPer = p.gramsPer;
          break;
        }
      }
      t.materials.add(m);
    }
    return t;
  }

  String _reuseQuestion(SalesSession saved) {
    final parts = [
      if (saved.costs?.materials.isNotEmpty ?? false)
        '${saved.costs!.materials.length} ingredientes'
      else if (saved.materials != null)
        'ingredientes: ${saved.materials}',
      if (saved.batchYield != null) 'rende ${saved.batchYield} por lote',
      if (saved.productionMinutes != null) 'leva ${speakDuration(saved.productionMinutes!)}',
      if (saved.costs?.materials.any((m) => m.priceCents != null) ?? false) 'com preços',
    ];
    return 'Já tenho a ficha de ${saved.product} salva: ${parts.join('; ')}. Quer usar os '
        'mesmos dados?';
  }

  /// "use a receita do bolo de cenoura que voce ja tem", "aproveita os dados que voce
  /// tem": copia ingredientes, rendimento, tempo e tabela de custo de um produto salvo.
  /// So nas perguntas da triagem (nao mexe no preco nem na entrevista de custo).
  DialogResponse? _tryReuseRequest(String input) {
    final idx = dialogOrder.indexOf(_state);
    final inTriage = _state == DialogState.askReuse ||
        (idx > dialogOrder.indexOf(DialogState.askProduct) &&
            idx < dialogOrder.indexOf(DialogState.askQuantity));
    if (!inTriage || recallProduct == null) return null;
    final n = normalizePt(input);
    if (!RegExp(r'\b(usa|use|usar|utilize|utiliza|utilizar|aproveita|aproveite|copia|copie|'
            r'pega|pegue|mesm[ao]s?)\b')
            .hasMatch(n) ||
        !RegExp(r'\b(receita|dados|ficha|ingredientes|mesm[ao]s?|ja tem|tinha|salv[ao])\b')
            .hasMatch(n)) {
      return null;
    }
    final saved = recallProduct!(input, current: _session.product);
    if (saved == null) {
      final names = savedProductNames?.call() ?? const [];
      return _retry('Não encontrei receita salva para esse produto. '
          '${names.isEmpty ? '' : 'Tenho salvos: ${names.join(', ')}. '}'
          '${_question(_state)}');
    }
    return _applySaved(saved);
  }

  /// Copia a receita e os dados de um produto salvo e segue para o preco.
  DialogResponse _applySaved(SalesSession saved) {
    _recalled = null;
    _session = SalesSession(
      company: _session.company ?? saved.company,
      sector: _session.sector ?? saved.sector,
      product: _session.product ?? saved.product,
      materials: saved.materials,
      batchYield: saved.batchYield,
      productionMinutes: saved.productionMinutes,
      characteristics: saved.characteristics,
      saleUnit: _session.saleUnit ?? saved.saleUnit,
      batchName: _session.batchName ?? saved.batchName,
      costs: saved.costs == null ? null : CostBreakdown.fromJson(saved.costs!.toJson()),
    );
    if (_session.costs == null && saved.materials != null) {
      _session = _session.withCosts(_draftFromMaterials(saved.materials));
    }
    profile = _session.keepTriage();
    final got = [
      if (_session.costs?.materials.isNotEmpty ?? false)
        '${_session.costs!.materials.length} ingredientes',
      if (_session.batchYield != null) 'rende ${_session.batchYield}',
      if (_session.productionMinutes != null) 'leva ${speakDuration(_session.productionMinutes!)}',
    ];
    return _goto(
        DialogState.askQuantity,
        'Pronto, usei os dados salvos de ${saved.product}'
        '${got.isEmpty ? '' : ': ${got.join(', ')}'}. Agora vamos ao preço. '
        '${_question(DialogState.askQuantity)}');
  }

  /// Valor atual de um campo (para log, correcoes e exemplos de aprendizado).
  Object? valueOf(DialogState field) => _valueOf(field);

  Object? _valueOf(DialogState field) => switch (field) {
        DialogState.askCompany => _session.company,
        DialogState.askSector => _session.sector,
        DialogState.askProduct => _session.product,
        DialogState.askMaterials => _session.materials,
        DialogState.askBatchYield => _session.batchYield,
        DialogState.askProductionTime => _session.productionMinutes,
        DialogState.askCharacteristics => _session.characteristics,
        DialogState.askQuantity => _session.quantity,
        DialogState.askCost => _session.totalCostCents,
        DialogState.askMargin => _session.marginPercent,
        _ => null,
      };

  String _resumeQuestion(DialogState s) {
    if (s == DialogState.confirm) return _confirmationText();
    if (s == DialogState.costDetail) {
      // Volta ao custo com a tabela atualizada (ingredientes novos, precos mantidos).
      _interview = null;
      final r = _startInterview();
      return r.text.replaceFirst('Vamos montar a tabela de custo de um lote.',
          'Voltando ao custo:');
    }
    return 'Voltando: ${_question(s)}';
  }

  // ---- internos ----

  /// Pergunta "limpa" de cada estado (usada ao avancar, voltar e repetir).
  String _question(DialogState s) {
    final product = _session.product ?? 'o produto';
    switch (s) {
      case DialogState.askCompany:
        return 'Para começar, qual é o nome da sua empresa ou do seu negócio?';
      case DialogState.askSector:
        return 'Qual é o ramo do seu negócio? Por exemplo: confeitaria, salgados, marmitas, '
            'panificação, açaí, bebidas, artesanato ou cosméticos.';
      case DialogState.askProduct:
        return 'Qual produto você quer vender?';
      case DialogState.askReuse:
        final saved = _recalled;
        return saved != null ? _reuseQuestion(saved) : _question(DialogState.askMaterials);

      case DialogState.askMaterials:
        return 'Do que $product é feito? Fale os principais ingredientes ou materiais, '
            'por exemplo: ${materialsExample(_session.sector)}. Ou mande uma foto da receita.';
      case DialogState.askBatchYield:
        final u = _session.units;
        return u.isGeneric && u.batch == null
            ? 'Quantas unidades rende cada produção? Por exemplo: uma fornada rende vinte.'
            : '${u.howMany} rende ${u.eachBatch}? Por exemplo: ${u.count(12)}.';
      case DialogState.askProductionTime:
        return 'Quanto tempo leva para produzir um lote? Por exemplo: duas horas.';
      case DialogState.askCharacteristics:
        return 'Quais são as características? Tamanho, peso, sabor ou cor. '
            'Se não tiver, diga: pular.';
      case DialogState.askQuantity:
        return _session.batchYield != null
            ? '${_session.units.howMany} você quer vender? Pode dizer um número, ou: um ${_session.units.batchName}.'
            : '${_session.units.howMany} você quer vender?';
      case DialogState.askCost:
        final q = _session.quantity;
        return q != null
            ? 'Quanto você gasta no total para fazer ${_session.units.isGeneric ? q : _session.units.count(q)}? Some ingredientes, embalagem e '
                'outros custos. Pode falar, por exemplo: cento e vinte reais.'
            : 'Quanto você gasta no total, em reais?';
      case DialogState.askMargin:
        return 'Quanto por cento você quer ganhar em cima do preço? Por exemplo: trinta '
            'por cento.';
      case DialogState.confirm:
        return _confirmationText();
      case DialogState.result:
        return _lastPrompt;
      case DialogState.offerDetail:
        return _offerText;
      case DialogState.costDetail:
        return _interview?.question() ?? _offerText;
    }
  }

  /// Quantidade: numero, ou "um lote" / "dois lotes" quando o rendimento e conhecido.
  int? _parseQuantity(String input) {
    final t = normalizePt(input);
    final y = _session.batchYield;
    final u = _session.units;
    // "12 pedaços": o numero e de unidades de venda (mesmo que fale "de 1 bolo" depois).
    if (!u.isGeneric) {
      final m = RegExp('(\\S+(?:\\s+e\\s+\\S+)?)\\s+(?:${normalizePt(u.many)}|${normalizePt(u.one)})\\b')
          .firstMatch(t);
      if (m != null) {
        final n = parseInteger(m[1]!);
        if (n != null) return n;
      }
    }
    // "duas panelas", "um bolo" = lotes, nao unidades (o rendimento e por lote).
    final batch = u.batch == null ? '' : '|${normalizePt(u.batch!)}s?';
    final lote = RegExp('\\b(lotes?|fornadas?|producao|producoes|panelas?|formas?|'
            'assadeiras?|tabuleiros?|bandejas?|receitas?$batch)\\b')
        .firstMatch(t);
    if (y != null && lote != null) {
      final lots = parseInteger(t.substring(0, lote.start)) ?? 1;
      return lots * y;
    }
    return parseInteger(input);
  }

  DialogResponse _command(Command cmd) {
    switch (cmd) {
      case Command.repeat:
        final showResult =
            _state == DialogState.result || _state == DialogState.offerDetail;
        return DialogResponse(_lastPrompt, _state,
            result: showResult && _session.quantity != null ? _currentResult() : null,
            breakdown: _state == DialogState.result ? _session.costs : null);
      case Command.restart:
        return start();
      case Command.back:
        return _back();
      case Command.help:
        return _say('Eu pergunto uma coisa de cada vez. Você pode dizer: repetir, voltar, '
            'pular, recomeçar, ou corrigir e o nome da informação, por exemplo: corrigir '
            'a empresa. ${_question(_state)}');
    }
  }

  DialogResponse _back() {
    _resumeTo = null;
    if (_state == DialogState.askReuse) {
      _recalled = null;
      return _goto(DialogState.askProduct, _question(DialogState.askProduct));
    }
    if (_state == DialogState.costDetail) {
      if (_interview!.back()) return _say(_interview!.question());
      return _goto(DialogState.offerDetail, _offerText);
    }
    if (_state == DialogState.offerDetail) {
      return _goto(DialogState.confirm, _confirmationText());
    }
    final i = dialogOrder.indexOf(_state);
    if (i <= 0) return _say('Já estamos no começo. ${_question(_state)}');
    final prev = dialogOrder[i - 1];
    return _goto(prev, _question(prev));
  }

  /// "12 marmitas" (sem unidade de venda) ou "12 pedaços de bolo de cenoura".
  String _itemsLabel(int q) {
    final u = _session.units;
    return u.isGeneric ? '$q ${_session.product}' : '${u.count(q)} de ${_session.product}';
  }

  String _confirmationText() {
    final s = _session;
    return 'Vou conferir: ${_itemsLabel(s.quantity!)}, custo total de '
        '${speakBrl(s.totalCostCents!)}, margem de ${s.marginPercent} por cento. '
        'Está certo?';
  }

  PricingResult _currentResult() => calculatePricing(PricingInput(
        quantity: _session.quantity!,
        totalCostCents: _session.totalCostCents!,
        marginPercent: _session.marginPercent!,
      ));

  DialogResponse _finish() {
    _simulation = null;
    final r = _currentResult();
    _state = DialogState.offerDetail;
    final y = _session.batchYield;
    final u = _session.units;
    final q = r.input.quantity;
    final lot = y != null && y > 0
        ? 'O preço ${u.ofBatch(y)} é ${speakBrl(r.unitPriceCents * y)}. '
        : '';
    final text = 'Para ${_itemsLabel(q)}, ${u.eachOne} custa '
        '${speakBrl(r.unitCostCents)} para produzir. O preço ${u.ofTheOne} é '
        '${speakBrl(r.unitPriceCents)}. $lot'
        'Vendendo ${u.feminine ? 'as' : 'os'} ${u.count(q)}, você recebe '
        '${speakBrl(r.totalRevenueCents)} e fica com ${speakBrl(r.profitCents)} de lucro. '
        'Esse cálculo considera só os custos que você informou. $_offerText';
    _lastPrompt = text;
    return DialogResponse(text, _state, result: r);
  }

  /// Comeca a entrevista do custo detalhado (materiais do cadastro ja viram linhas).
  DialogResponse _startInterview() {
    final s = _session;
    if (s.marginPercent == null) {
      return _retry('Primeiro preciso da margem de lucro. ${_question(_state)}');
    }
    // Tabela ja salva ou rascunho das fotos: continua dela (copia, para nao mexer no
    // cadastro antes de terminar).
    final draft = s.costs != null && s.costs!.materials.isNotEmpty
        ? CostBreakdown.fromJson(s.costs!.toJson())
        : null;
    _interview = CostInterview(
      materials: splitMaterials(s.materials),
      batchYield: s.batchYield,
      productionMinutes: s.productionMinutes,
      marginPercent: s.marginPercent!,
      sector: s.sector,
      draft: draft,
    );
    return _goto(DialogState.costDetail,
        'Vamos montar a tabela de custo de um lote. ${_interview!.question()}');
  }

  /// Fim da entrevista: guarda a tabela no cadastro e mostra o custo por unidade.
  DialogResponse _finishInterview(String ack) {
    final table = _interview!.table;
    _interview = null;
    _session = _session.withCosts(table);
    profile = _session.keepTriage();
    _state = DialogState.result;
    final text = '${ack.isEmpty ? '' : '$ack '}${speakBreakdown(table, units: _session.units)} '
        'Para enviar este resultado, diga: compartilhar.';
    _lastPrompt = text;
    return DialogResponse(text, _state, breakdown: table);
  }

  static final _shareWords = RegExp(r'\b(compartilhar|compartilha|compartilhe|exportar|exporta|'
      r'exporte|enviar|envia|envie|mandar|manda|mande|planilha|whatsapp|zap)\b');

  /// Tabela de custo para a tela: a da entrevista em andamento ou a salva/rascunho.
  CostBreakdown? get costTable => _interview?.table ?? _session.costs;

  /// Acrescenta o que foi lido nas fotos (receita e/ou compra) e segue a conversa.
  /// Na entrevista de custo, as fotos preenchem a tabela e ela continua do que falta.
  /// Na pergunta dos materiais, a receita responde a pergunta. Em qualquer outro ponto,
  /// fica guardado como rascunho da tabela de custo.
  DialogResponse importDocuments(List<RecipeItem> recipe, List<PurchaseItem> purchases) {
    final read = [
      if (recipe.isNotEmpty)
        '${recipe.length} ${recipe.length == 1 ? 'ingrediente' : 'ingredientes'} da receita',
      if (purchases.isNotEmpty)
        '${purchases.length} ${purchases.length == 1 ? 'preço' : 'preços'} da compra',
    ];
    if (read.isEmpty) {
      return _retry('Não consegui ler ingredientes nem preços nas fotos. Tente uma foto mais '
          'de perto e com boa luz. ${_question(_state)}');
    }
    final ack = 'Li ${read.join(' e ')}.';
    if (_state == DialogState.costDetail) {
      return _say('$ack ${_interview!.importDocuments(recipe, purchases)}');
    }
    final table = _session.costs != null
        ? CostBreakdown.fromJson(_session.costs!.toJson())!
        : CostBreakdown(batchYield: _session.batchYield);
    table
      ..importRecipe(recipe)
      ..importPurchases(purchases);
    _session = _session.withCosts(table);
    if (_session.hasProfile) profile = _session.keepTriage();
    if (_state == DialogState.askMaterials && recipe.isNotEmpty) {
      final names = recipe.map((r) => r.name).toSet().join(', ');
      // A tabela ja recebeu a receita com quantidades: so guarda os nomes na ficha.
      _setField(DialogState.askMaterials, names, rebuildDraft: false);
      return _advance(DialogState.askMaterials, '$ack Anotei: $names.');
    }
    return _say('$ack Eles entram na tabela de custo quando você detalhar o custo. '
        '${_question(_state)}');
  }

  DialogResponse _goto(DialogState s, String text) {
    _state = s;
    return _say(text);
  }

  DialogResponse _say(String text) {
    _lastPrompt = text;
    return DialogResponse(text, _state);
  }

  /// Mensagem de erro/reprompt: nao muda de estado nem sobrescreve o ultimo prompt valido.
  DialogResponse _retry(String text) =>
      DialogResponse(text, _state, understood: false);

  // ---- persistencia (retomar a conversa depois que o app fecha) ----

  Map<String, Object?> toJson() => {
        'state': _state.name,
        'session': _session.toJson(),
        'lastPrompt': _lastPrompt,
        'resumeTo': _resumeTo?.name,
        'correctingOld': _correctingOld,
        'interview': _interview?.toJson(),
        'recalled': _recalled?.toJson(),
      };

  /// Restaura um snapshot salvo. Retorna false se o snapshot for invalido.
  bool restore(Map<String, Object?> j) {
    try {
      final state = DialogState.values.byName(j['state'] as String);
      final session = SalesSession.fromJson((j['session'] as Map).cast<String, Object?>());
      final resume = j['resumeTo'] as String?;
      // Estados que dependem de dados ausentes nao podem ser retomados.
      if (state == DialogState.confirm &&
          (session.quantity == null ||
              session.totalCostCents == null ||
              session.marginPercent == null)) {
        return false;
      }
      if (state == DialogState.result || state == DialogState.offerDetail) return false;
      final interview = CostInterview.fromJson(j['interview']);
      if (state == DialogState.costDetail && interview == null) return false;
      _interview = interview;
      final recalled = j['recalled'];
      _recalled = recalled is Map ? SalesSession.fromJson(recalled.cast<String, Object?>()) : null;
      if (state == DialogState.askReuse && _recalled == null) return false;
      _state = state;
      _session = session;
      _lastPrompt = j['lastPrompt'] as String? ?? '';
      _resumeTo = resume == null ? null : DialogState.values.byName(resume);
      _correctingOld = j['correctingOld'];
      if (session.hasProfile) profile = session.keepTriage();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Pergunta atual, para retomar a conversa ("continuando de onde paramos").
  DialogResponse resumePrompt() =>
      _say('Continuando de onde paramos. ${_question(_state)}');
}

class _Parsed {
  const _Parsed(this.value) : error = null;
  const _Parsed.error(this.error) : value = null;
  final Object? value;
  final String? error;
}

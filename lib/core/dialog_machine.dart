import 'cost_breakdown.dart';
import 'document_parser.dart';
import 'pricing_calculator.dart';
import 'pt_br_parser.dart';
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
        quantity: (j['quantity'] as num?)?.toInt(),
        totalCostCents: (j['totalCostCents'] as num?)?.toInt(),
        marginPercent: (j['marginPercent'] as num?)?.toInt(),
        costs: CostBreakdown.fromJson(j['costs']),
      );
}

class DialogResponse {
  const DialogResponse(this.text, this.state,
      {this.result, this.breakdown, this.understood = true});

  /// Texto exibido E falado.
  final String text;
  final DialogState state;

  /// Preenchido apenas no estado [DialogState.result].
  final PricingResult? result;

  /// Preenchido ao terminar o custo detalhado (tabela para a tela).
  final CostBreakdown? breakdown;

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
  DialogMachine({SalesSession? profile}) {
    _state = DialogState.askCompany;
    if (profile != null) this.profile = profile.keepTriage();
  }

  /// Cadastro do usuario (triagem salva). Atualizado sempre que a triagem muda.
  SalesSession profile = const SalesSession();

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
    final isLot = RegExp(r'\b(lote|fornada|tudo)\b').hasMatch(n) &&
        !RegExp(r'\b(unidade|cada)\b').hasMatch(n);
    final unitPrice = isLot && y != null && y > 0 ? (cents / y).round() : cents;
    _simulation = PriceSimulation(
      priceCents: unitPrice,
      unitCostCents: unitCost,
      suggestedCents: _suggestedUnitPrice(),
      batchYield: y,
    );
    final lotNote =
        isLot && y != null ? 'O lote de $y por ${speakBrl(cents)} dá a unidade a ${speakBrl(unitPrice)}. ' : '';
    final next = _state == DialogState.offerDetail
        ? ' Pode testar outro preço. $_offerText'
        : ' Pode testar outro preço, ou diga: recomeçar.';
    final text = '$lotNote${speakSimulation(_simulation!)}$next';
    _lastPrompt = text;
    return DialogResponse(text, _state);
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
    final cmd = parseCommand(input);
    if (cmd != null) return _command(cmd);

    // Na entrevista de custo, frases como "o frete custa 20" nao sao correcoes.
    if (_state == DialogState.costDetail) return _answer(input);

    // Depois do resultado: "quero vender por 6 reais" simula o lucro com esse preco.
    if (_state == DialogState.result || _state == DialogState.offerDetail) {
      final sim = _trySimulate(input);
      if (sim != null) return sim;
    }

    final fix = parseCorrection(input);
    if (fix != null) {
      if (!_canCorrect(fix.field)) {
        // Nao vira resposta da pergunta atual (era o bug do "corrigir" virar produto).
        return _retry('Essa informação ainda não foi respondida. ${_question(_state)}');
      }
      return fix.field == _state && fix.value != null
          ? _answer(fix.value!) // "na verdade rende trinta" na propria pergunta
          : _correct(fix.field, fix.value);
    }
    return _answer(input);
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
    switch (_state) {
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
        return _retry('Responda sim para continuar ou não para corrigir.');

      case DialogState.result:
        return _say('Para calcular de novo com outros números, diga: recomeçar. Para '
            'detalhar o custo de produção, diga: detalhar custo. Para mudar uma resposta, '
            'diga, por exemplo: corrigir o custo.');

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
        final v = skip ? null : parseMaterials(input);
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
        return v == null ? 'Tudo bem.' : 'Cada lote rende $v.';
      case DialogState.askProductionTime:
        return v == null ? 'Tudo bem.' : 'Leva ${speakDuration(v as int)}.';
      case DialogState.askCharacteristics:
        return v == null ? 'Tudo bem. Agora vamos ao preço.' : 'Anotei. Agora vamos ao preço.';
      case DialogState.askQuantity:
        return '';
      case DialogState.askCost:
        return 'Anotei ${speakBrl(v as int)} de custo.';
      case DialogState.askMargin:
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
        return 'Corrigido: rende $v por lote.';
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


    final next = dialogOrder[dialogOrder.indexOf(answered) + 1];
    final text = next == DialogState.confirm ? _confirmationText() : _question(next);
    return _goto(next, ack.isEmpty ? text : '$ack $text');
  }

  /// Corrige um campo: aplica o valor dito junto, ou pergunta de novo e depois volta.
  DialogResponse _correct(DialogState field, String? value) {
    if (!_canCorrect(field)) {
      return _retry('Essa informação ainda não foi respondida. ${_question(_state)}');
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

  String _resumeQuestion(DialogState s) =>
      s == DialogState.confirm ? _confirmationText() : 'Voltando: ${_question(s)}';

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

      case DialogState.askMaterials:
        return 'Do que $product é feito? Fale os principais ingredientes ou materiais, '
            'por exemplo: ${materialsExample(_session.sector)}. Ou mande uma foto da receita.';
      case DialogState.askBatchYield:
        return 'Quantas unidades rende cada produção? Por exemplo: uma fornada rende vinte.';
      case DialogState.askProductionTime:
        return 'Quanto tempo leva para produzir um lote? Por exemplo: duas horas.';
      case DialogState.askCharacteristics:
        return 'Quais são as características? Tamanho, peso, sabor ou cor. '
            'Se não tiver, diga: pular.';
      case DialogState.askQuantity:
        return _session.batchYield != null
            ? 'Quantas unidades você quer vender? Pode dizer um número, ou: um lote.'
            : 'Quantas unidades você quer vender?';
      case DialogState.askCost:
        final q = _session.quantity;
        return q != null
            ? 'Quanto você gasta no total para fazer $q? Some ingredientes, embalagem e '
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
    // "duas panelas" = 2 lotes, nao 2 unidades (o rendimento e por panela/forma/fornada).
    final lote = RegExp(r'\b(lotes?|fornadas?|producao|producoes|panelas?|formas?|'
            r'assadeiras?|tabuleiros?|bandejas?|receitas?)\b')
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

  String _confirmationText() {
    final s = _session;
    return 'Vou conferir: ${s.quantity} ${s.product}, custo total de '
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
    final lot = y != null && y > 0
        ? 'O preço do lote de $y unidades é ${speakBrl(r.unitPriceCents * y)}. '
        : '';
    final text = 'Para ${r.input.quantity} ${_session.product}, cada unidade custa '
        '${speakBrl(r.unitCostCents)} para produzir. O preço da unidade é '
        '${speakBrl(r.unitPriceCents)}. $lot'
        'Vendendo as ${r.input.quantity} unidades, você recebe '
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
    final text = '${ack.isEmpty ? '' : '$ack '}${speakBreakdown(table)}';
    _lastPrompt = text;
    return DialogResponse(text, _state, breakdown: table);
  }

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

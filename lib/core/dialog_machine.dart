import 'pricing_calculator.dart';
import 'pt_br_parser.dart';

/// Estados do fluxo "assistente de vendas / precificacao".
/// Uma pergunta por vez, linguagem simples (requisito do documento AUGURE).
///
/// Ordem: triagem (empresa, produto, especificacoes de producao) e depois o preco.
enum DialogState {
  askCompany,
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
}

/// Ordem linear das perguntas (usada por "voltar").
const _order = DialogState.values;

class SalesSession {
  const SalesSession({
    this.company,
    this.product,
    this.materials,
    this.batchYield,
    this.productionMinutes,
    this.characteristics,
    this.quantity,
    this.totalCostCents,
    this.marginPercent,
  });

  // Triagem (opcionais, exceto o produto).
  final String? company;
  final String? product;
  final String? materials;
  final int? batchYield;
  final int? productionMinutes;
  final String? characteristics;

  // Preco.
  final int? quantity;
  final int? totalCostCents;
  final int? marginPercent;

  SalesSession copyWith({
    String? company,
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
        product: product ?? this.product,
        materials: materials ?? this.materials,
        batchYield: batchYield ?? this.batchYield,
        productionMinutes: productionMinutes ?? this.productionMinutes,
        characteristics: characteristics ?? this.characteristics,
        quantity: quantity ?? this.quantity,
        totalCostCents: totalCostCents ?? this.totalCostCents,
        marginPercent: marginPercent ?? this.marginPercent,
      );

  /// Mantem empresa; zera produto, especificacoes e preco ("outro produto").
  SalesSession keepCompany() => SalesSession(company: company);

  /// Mantem a triagem; zera so os numeros do preco (correcao na confirmacao).
  SalesSession keepTriage() => SalesSession(
        company: company,
        product: product,
        materials: materials,
        batchYield: batchYield,
        productionMinutes: productionMinutes,
        characteristics: characteristics,
      );
}

class DialogResponse {
  const DialogResponse(this.text, this.state,
      {this.result, this.understood = true});

  /// Texto exibido E falado.
  final String text;
  final DialogState state;

  /// Preenchido apenas no estado [DialogState.result].
  final PricingResult? result;

  /// false quando a fala nao pode ser interpretada no estado atual (pedido de repeticao).
  /// A camada de LLM local usa isso para tentar uma segunda interpretacao.
  final bool understood;
}

/// Motor de dialogo 100% local e deterministico.
/// O LLM local (fase 2) entra apenas como "interpretador" que transforma fala livre em
/// texto normalizado ANTES de [handle]; nunca calcula nem decide precos.
class DialogMachine {
  DialogMachine() {
    _state = DialogState.askCompany;
  }

  late DialogState _state;
  SalesSession _session = const SalesSession();
  String _lastPrompt = '';

  DialogState get state => _state;
  SalesSession get session => _session;

  static const _greeting =
      'Oi! Eu sou seu assistente de vendas. Vou te ajudar a descobrir quanto cobrar. ';

  DialogResponse start() {
    _state = DialogState.askCompany;
    _session = const SalesSession();
    return _say('$_greeting${_question(DialogState.askCompany)}');
  }

  DialogResponse handle(String input) {
    final cmd = parseCommand(input);
    if (cmd != null) return _command(cmd);

    final skip = isSkip(input);
    switch (_state) {
      case DialogState.askCompany:
        final name = skip ? null : parseCompanyName(input);
        if (name == null && !skip) {
          return _retry('Não entendi. Qual é o nome da sua empresa? Se não tiver, diga: pular.');
        }
        _session = _session.copyWith(company: name);
        return _goto(
            DialogState.askProduct,
            name == null
                ? 'Sem problema. ${_question(DialogState.askProduct)}'
                : 'Prazer, $name! ${_question(DialogState.askProduct)}');

      case DialogState.askProduct:
        final name = skip ? null : parseProductName(input);
        if (name == null) return _retry('Não entendi o nome. Qual produto você quer vender?');
        _session = _session.copyWith(product: name);
        return _goto(DialogState.askMaterials,
            'Certo, $name. ${_question(DialogState.askMaterials)}');

      case DialogState.askMaterials:
        final m = skip ? null : parseMaterials(input);
        if (m == null && !skip) {
          return _retry('Não entendi. Fale os ingredientes ou materiais, ou diga: pular.');
        }
        _session = _session.copyWith(materials: m);
        return _goto(DialogState.askBatchYield,
            '${m == null ? 'Tudo bem.' : 'Anotei: $m.'} ${_question(DialogState.askBatchYield)}');

      case DialogState.askBatchYield:
        final y = skip ? null : parseBatchYield(input);
        if (!skip && (y == null || y < 1 || y > 100000)) {
          return _retry('Não entendi. Diga quantas unidades saem de cada produção, '
              'por exemplo: vinte. Ou diga: pular.');
        }
        _session = _session.copyWith(batchYield: y);
        return _goto(
            DialogState.askProductionTime,
            '${y == null ? 'Tudo bem.' : 'Cada lote rende $y.'} '
            '${_question(DialogState.askProductionTime)}');

      case DialogState.askProductionTime:
        final mins = skip ? null : parseDurationMinutes(input);
        if (!skip && (mins == null || mins > 60 * 24 * 60)) {
          return _retry('Não entendi o tempo. Diga, por exemplo: duas horas, ou quarenta '
              'minutos. Ou diga: pular.');
        }
        _session = _session.copyWith(productionMinutes: mins);
        return _goto(
            DialogState.askCharacteristics,
            '${mins == null ? 'Tudo bem.' : 'Leva ${speakDuration(mins)}.'} '
            '${_question(DialogState.askCharacteristics)}');

      case DialogState.askCharacteristics:
        final c = skip ? null : parseCharacteristics(input);
        if (c == null && !skip) {
          return _retry('Não entendi. Fale o tamanho, peso, sabor ou cor, ou diga: pular.');
        }
        _session = _session.copyWith(characteristics: c);
        return _goto(DialogState.askQuantity,
            '${c == null ? 'Tudo bem.' : 'Anotei.'} Agora vamos ao preço. '
            '${_question(DialogState.askQuantity)}');

      case DialogState.askQuantity:
        final q = _parseQuantity(input);
        if (q == null || q < 1 || q > 100000) {
          return _retry('Não entendi a quantidade. Diga um número, por exemplo: vinte.');
        }
        _session = _session.copyWith(quantity: q);
        return _goto(DialogState.askCost,
            'Quanto você gasta no total para fazer $q? Some ingredientes, embalagem e '
            'outros custos. Pode falar, por exemplo: cento e vinte reais.');

      case DialogState.askCost:
        final c = parseMoneyCents(input);
        if (c == null || c <= 0) {
          return _retry('Não entendi o valor. Diga em reais, por exemplo: cento e vinte reais.');
        }
        _session = _session.copyWith(totalCostCents: c);
        return _goto(DialogState.askMargin,
            'Anotei ${speakBrl(c)} de custo. ${_question(DialogState.askMargin)}');

      case DialogState.askMargin:
        final m = parsePercent(input);
        if (m == null || m < 0 || m > 90) {
          return _retry('Diga uma margem entre zero e noventa por cento. Por exemplo: trinta.');
        }
        _session = _session.copyWith(marginPercent: m);
        return _goto(DialogState.confirm, _confirmationText());

      case DialogState.confirm:
        final yn = parseYesNo(input);
        if (yn == YesNo.yes) return _finish();
        if (yn == YesNo.no) {
          // Mantem a triagem; corrige so os numeros.
          _session = _session.keepTriage();
          return _goto(DialogState.askQuantity,
              'Tudo bem, vamos corrigir os números. ${_question(DialogState.askQuantity)}');
        }
        return _retry('Responda sim para continuar ou não para corrigir.');

      case DialogState.result:
        if (RegExp(r'\boutro\b').hasMatch(normalizePt(input))) {
          _session = _session.keepCompany();
          return _goto(DialogState.askProduct, 'Vamos lá. ${_question(DialogState.askProduct)}');
        }
        return _say('Para calcular outro produto, diga: outro produto. Para começar tudo '
            'de novo, diga: recomeçar. Ou diga: repetir, para ouvir de novo.');
    }
  }

  // ---- internos ----

  /// Pergunta "limpa" de cada estado (usada ao avancar, voltar e repetir).
  String _question(DialogState s) {
    final product = _session.product ?? 'o produto';
    switch (s) {
      case DialogState.askCompany:
        return 'Para começar, qual é o nome da sua empresa ou do seu negócio?';
      case DialogState.askProduct:
        return 'Qual produto você quer vender?';
      case DialogState.askMaterials:
        return 'Do que $product é feito? Fale os principais ingredientes ou materiais.';
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
        return 'Quanto você gasta no total, em reais?';
      case DialogState.askMargin:
        return 'Quanto por cento você quer ganhar em cima do preço? Por exemplo: trinta '
            'por cento.';
      case DialogState.confirm:
        return _confirmationText();
      case DialogState.result:
        return _lastPrompt;
    }
  }

  /// Quantidade: numero, ou "um lote" / "dois lotes" quando o rendimento e conhecido.
  int? _parseQuantity(String input) {
    final t = normalizePt(input);
    final y = _session.batchYield;
    final lote = RegExp(r'\b(lotes?|fornadas?|producao|producoes)\b').firstMatch(t);
    if (y != null && lote != null) {
      final lots = parseInteger(t.substring(0, lote.start)) ?? 1;
      return lots * y;
    }
    return parseInteger(input);
  }

  DialogResponse _command(Command cmd) {
    switch (cmd) {
      case Command.repeat:
        return DialogResponse(_lastPrompt, _state,
            result: _state == DialogState.result ? _currentResult() : null);
      case Command.restart:
        return start();
      case Command.back:
        return _back();
      case Command.help:
        return _say(
            'Eu pergunto uma coisa de cada vez. Você pode dizer: repetir, voltar, pular ou '
            'recomeçar. $_lastPrompt');
    }
  }

  DialogResponse _back() {
    final i = _order.indexOf(_state);
    if (i == 0) return _say('Já estamos no começo. ${_question(_state)}');
    final prev = _order[i - 1];
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
    final r = _currentResult();
    _state = DialogState.result;
    final text = 'Para ${r.input.quantity} ${_session.product}, cada unidade custa '
        '${speakBrl(r.unitCostCents)}. Cobre ${speakBrl(r.unitPriceCents)} por unidade. '
        'Vendendo tudo, você recebe ${speakBrl(r.totalRevenueCents)} e fica com '
        '${speakBrl(r.profitCents)} de lucro. '
        'Esse cálculo considera só os custos que você informou.';
    _lastPrompt = text;
    return DialogResponse(text, _state, result: r);
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
}

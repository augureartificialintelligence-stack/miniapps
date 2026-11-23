import 'pricing_calculator.dart';
import 'pt_br_parser.dart';

/// Estados do fluxo "assistente de vendas / precificacao".
/// Uma pergunta por vez, linguagem simples (requisito do documento AUGURE).
enum DialogState {
  askProduct,
  askQuantity,
  askCost,
  askMargin,
  confirm,
  result,
}

class SalesSession {
  const SalesSession({
    this.product,
    this.quantity,
    this.totalCostCents,
    this.marginPercent,
  });

  final String? product;
  final int? quantity;
  final int? totalCostCents;
  final int? marginPercent;

  SalesSession copyWith({
    String? product,
    int? quantity,
    int? totalCostCents,
    int? marginPercent,
  }) =>
      SalesSession(
        product: product ?? this.product,
        quantity: quantity ?? this.quantity,
        totalCostCents: totalCostCents ?? this.totalCostCents,
        marginPercent: marginPercent ?? this.marginPercent,
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
    _state = DialogState.askProduct;
  }

  late DialogState _state;
  SalesSession _session = const SalesSession();
  String _lastPrompt = '';

  DialogState get state => _state;
  SalesSession get session => _session;

  static const _greeting =
      'Oi! Eu sou seu assistente de vendas. Vou te ajudar a descobrir quanto cobrar. ';

  DialogResponse start() {
    _state = DialogState.askProduct;
    _session = const SalesSession();
    return _say('${_greeting}O que você quer vender?');
  }

  DialogResponse handle(String input) {
    final cmd = parseCommand(input);
    if (cmd != null) return _command(cmd);

    switch (_state) {
      case DialogState.askProduct:
        final name = parseProductName(input);
        if (name == null) return _retry('Não entendi o nome. O que você quer vender?');
        _session = _session.copyWith(product: name);
        return _goto(DialogState.askQuantity,
            'Certo, $name. Quantas unidades você quer vender?');

      case DialogState.askQuantity:
        final q = parseInteger(input);
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
            'Anotei ${speakBrl(c)} de custo. Quanto por cento você quer ganhar em cima '
            'do preço? Por exemplo: trinta por cento.');

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
          _session = const SalesSession();
          return _goto(DialogState.askProduct,
              'Tudo bem, vamos corrigir do começo. O que você quer vender?');
        }
        return _retry('Responda sim para continuar ou não para corrigir.');

      case DialogState.result:
        return _say(
            'Se quiser calcular outro produto, diga: recomeçar. Ou diga: repetir, '
            'para ouvir de novo.');
    }
  }

  // ---- internos ----

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
            'Eu pergunto uma coisa de cada vez. Você pode dizer: repetir, voltar ou '
            'recomeçar. $_lastPrompt');
    }
  }

  DialogResponse _back() {
    switch (_state) {
      case DialogState.askProduct:
        return _say('Já estamos no começo. $_lastPrompt');
      case DialogState.askQuantity:
        return _goto(DialogState.askProduct, 'O que você quer vender?');
      case DialogState.askCost:
        return _goto(DialogState.askQuantity, 'Quantas unidades você quer vender?');
      case DialogState.askMargin:
        return _goto(DialogState.askCost, 'Quanto você gasta no total, em reais?');
      case DialogState.confirm:
        return _goto(DialogState.askMargin, 'Quanto por cento você quer ganhar?');
      case DialogState.result:
        return _goto(DialogState.confirm, _confirmationText());
    }
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
        'Vendendo tudo você recebe ${speakBrl(r.totalRevenueCents)} e fica com '
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

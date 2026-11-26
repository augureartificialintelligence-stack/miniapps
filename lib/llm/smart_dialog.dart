import '../core/dialog_machine.dart';
import '../core/pt_br_parser.dart' show isQuestion, parseCommand;
import 'utterance_interpreter.dart';

/// Um turno da conversa, para log e para a base de exemplos de aprendizado.
class TurnRecord {
  const TurnRecord({
    required this.stateBefore,
    required this.input,
    required this.stateAfter,
    required this.understood,
    this.llmCanonical,
    this.value,
  });

  final DialogState stateBefore;
  final String input;
  final DialogState stateAfter;
  final bool understood;

  /// Forma canonica devolvida pelo LLM local (null = LLM nao foi usado / nao ajudou).
  final String? llmCanonical;

  /// Valor que a fala gravou na pergunta respondida (rotulo do exemplo de aprendizado).
  /// null em comandos, correcoes e falas nao entendidas.
  final Object? value;

  Map<String, Object?> toJson() => {
        'type': 'turn',
        'state': stateBefore.name,
        'input': input,
        'llm': llmCanonical,
        'understood': understood,
        'next': stateAfter.name,
        'value': value,
      };
}

/// Fluxo hibrido: tenta SEMPRE o parser deterministico primeiro (rapido, gratis, sem
/// bateria). So quando ele nao entende, pede ao LLM local para reescrever a fala em
/// forma canonica e reenvia para a mesma maquina de estados.
class SmartDialog {
  SmartDialog(this.machine, [this.interpreter]);

  final DialogMachine machine;
  final UtteranceInterpreter? interpreter;

  /// Chamado a cada turno (log de diagnostico e exemplos para aprendizado).
  void Function(TurnRecord turn)? onTurn;

  DialogResponse start() => machine.start();

  Future<DialogResponse> handle(String input) async {
    final before = machine.state;
    final first = machine.handle(input);
    if (first.understood || interpreter == null) {
      _report(before, input, first, null);
      return first;
    }

    // Pergunta que o app nao sabe responder sozinho: a IA local responde com os dados do
    // app e a conversa continua na mesma pergunta.
    if (isQuestion(input)) {
      final answer = await interpreter!.answerQuestion(input, machine.contextForQuestions());
      if (answer != null) {
        final back = machine.currentQuestion.isEmpty ? '' : ' ${machine.currentQuestion}';
        final r = DialogResponse('$answer$back', machine.state);
        _report(before, input, r, '[resposta da IA]');
        return r;
      }
    }

    // O app nao entendeu. A IA local tenta duas leituras, nesta ordem:
    // - fala que NAO parece resposta da pergunta (ex.: na pergunta do frete, "a embalagem
    //   ta cara, poe 1,50"): primeiro ve se e um pedido de MUDANCA/COMANDO;
    // - fala que parece resposta: primeiro tenta extrair o valor da pergunta atual.
    final intentFirst = !machine.looksLikeAnswer(input);
    final attempts = intentFirst ? [_intent, _value] : [_value, _intent];
    for (final attempt in attempts) {
      final canonical = await attempt(input);
      if (canonical == null) continue;
      final second = machine.handle(canonical);
      if (second.understood) {
        _report(before, input, second, canonical);
        return second;
      }
    }
    // Nada passou na validacao: mantem a mensagem original de erro.
    _report(before, input, first, null);
    return first;
  }

  /// Valor da pergunta atual em forma canonica ("umas duas duzias" -> "24").
  Future<String?> _value(String input) => interpreter!.interpret(input, machine.state);

  /// Pedido de mudanca ou comando dito fora de hora ("muda a margem pra 40").
  Future<String?> _intent(String input) => interpreter!.interpretIntent(
        input,
        machine.lastPrompt,
        ingredients: [for (final m in machine.costTable?.materials ?? const []) m.name],
      );

  void _report(DialogState before, String input, DialogResponse r, String? llm) {
    // So vira exemplo quando a fala RESPONDEU a pergunta (nao comando nem correcao).
    final answered = r.understood &&
        r.state != before &&
        correctableStates.contains(before) &&
        parseCommand(input) == null &&
        parseCorrection(input) == null;
    onTurn?.call(TurnRecord(
      stateBefore: before,
      input: input,
      stateAfter: r.state,
      understood: r.understood,
      llmCanonical: llm,
      value: answered ? machine.valueOf(before) : null,
    ));
  }
}

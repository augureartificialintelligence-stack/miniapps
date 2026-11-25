import '../core/dialog_machine.dart';
import '../core/pt_br_parser.dart' show parseCommand;
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

    final canonical = await interpreter!.interpret(input, machine.state);
    if (canonical == null) {
      _report(before, input, first, null);
      return first;
    }

    final second = machine.handle(canonical);
    // Se nem a forma canonica passou na validacao, mantem a mensagem original de erro.
    final r = second.understood ? second : first;
    _report(before, input, r, canonical);
    return r;
  }

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

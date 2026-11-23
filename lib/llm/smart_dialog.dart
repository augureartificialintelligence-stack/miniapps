import '../core/dialog_machine.dart';
import 'utterance_interpreter.dart';

/// Fluxo hibrido: tenta SEMPRE o parser deterministico primeiro (rapido, gratis, sem
/// bateria). So quando ele nao entende, pede ao LLM local para reescrever a fala em
/// forma canonica e reenvia para a mesma maquina de estados.
class SmartDialog {
  SmartDialog(this.machine, [this.interpreter]);

  final DialogMachine machine;
  final UtteranceInterpreter? interpreter;

  DialogResponse start() => machine.start();

  Future<DialogResponse> handle(String input) async {
    final first = machine.handle(input);
    if (first.understood || interpreter == null) return first;

    final canonical = await interpreter!.interpret(input, machine.state);
    if (canonical == null) return first;

    final second = machine.handle(canonical);
    // Se nem a forma canonica passou na validacao, mantem a mensagem original de erro.
    return second.understood ? second : first;
  }
}

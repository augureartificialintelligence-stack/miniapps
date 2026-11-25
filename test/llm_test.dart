import 'package:augure_miniapps/core/dialog_machine.dart';
import 'package:augure_miniapps/llm/llm_engine.dart';
import 'package:augure_miniapps/llm/smart_dialog.dart';
import 'package:augure_miniapps/llm/utterance_interpreter.dart';
import 'package:flutter_test/flutter_test.dart';

/// LLM falso: devolve respostas programadas e registra os prompts recebidos.
class FakeLlm implements LlmEngine {
  FakeLlm(this.replies, {this.ready = true, this.throws = false});

  final List<String> replies;
  final bool ready;
  final bool throws;
  final prompts = <String>[];

  @override
  bool get isReady => ready;

  @override
  Future<bool> load() async => ready;

  @override
  Future<String> complete(String prompt,
      {Map<String, Object?>? jsonSchema, int maxTokens = 48}) async {
    prompts.add(prompt);
    if (throws) throw StateError('falha simulada');
    return replies.removeAt(0);
  }

  @override
  Future<void> dispose() async {}
}

/// Triagem deterministica (o LLM nao deve ser chamado aqui) ate a pergunta de quantidade.
Future<void> triage(SmartDialog d) async {
  for (final t in ['Doces da Ana', 'marmitas', 'arroz e frango', 'rende vinte', 'duas horas', 'pular']) {
    await d.handle(t);
  }
  expect(d.machine.state, DialogState.askQuantity);
}

SmartDialog build(FakeLlm llm) =>
    SmartDialog(DialogMachine(), UtteranceInterpreter(llm))..start();

void main() {
  group('interpretador', () {
    test('quantidade em fala livre que o parser nao entende', () async {
      final llm = FakeLlm(['{"quantity": 20}']);
      final d = build(llm);
      await triage(d);
      final r = await d.handle('umas duas dezenas, mais ou menos');
      expect(r.state, DialogState.askCost);
      expect(d.machine.session.quantity, 20);
      expect(llm.prompts, hasLength(1));
    });

    test('custo decimal vira forma canonica e e re-validado', () async {
      final llm = FakeLlm(['{"reais": 87.5}']);
      final d = build(llm);
      await triage(d);
      await d.handle('dez bolinhos');
      final r = await d.handle('gastei uns oitenta e sete e meio');
      expect(r.state, DialogState.askMargin);
      expect(d.machine.session.totalCostCents, 8750);
    });

    test('parser deterministico resolve primeiro: LLM nao e chamado', () async {
      final llm = FakeLlm([]);
      final d = build(llm);
      await triage(d);
      await d.handle('vinte');
      expect(llm.prompts, isEmpty);
    });

    test('null do LLM mantem a mensagem de erro original', () async {
      final llm = FakeLlm(['{"quantity": null}']);
      final d = build(llm);
      await triage(d);
      final r = await d.handle('sei la');
      expect(r.state, DialogState.askQuantity);
      expect(r.understood, isFalse);
    });

    test('valor absurdo do LLM e barrado pela maquina', () async {
      final llm = FakeLlm(['{"percent": 250}']);
      final d = build(llm);
      await triage(d);
      await d.handle('10');
      await d.handle('50 reais');
      final r = await d.handle('quero ganhar bastante');
      expect(r.state, DialogState.askMargin);
      expect(d.machine.session.marginPercent, isNull);
    });

    test('lixo e texto ao redor do JSON sao tolerados / rejeitados', () async {
      final ok = build(FakeLlm(['Claro! {"quantity": 5} espero ter ajudado']));
      await triage(ok);
      await ok.handle('cinco unidades pra mim');
      expect(ok.machine.session.quantity, 5);

      final bad = build(FakeLlm(['nao sei responder']));
      await triage(bad);
      final r = await bad.handle('blablabla');
      expect(r.state, DialogState.askQuantity);
    });

    test('falha ou LLM indisponivel cai no fluxo deterministico', () async {
      final boom = build(FakeLlm([], throws: true));
      await triage(boom);
      expect((await boom.handle('hmm')).state, DialogState.askQuantity);

      final off = build(FakeLlm([], ready: false));
      await triage(off);
      expect((await off.handle('hmm')).state, DialogState.askQuantity);

      final none = SmartDialog(DialogMachine())..start();
      await triage(none);
      expect((await none.handle('hmm')).state, DialogState.askQuantity);
    });

    test('confirmacao em fala livre', () async {
      final llm = FakeLlm(['{"answer": "sim"}']);
      final d = build(llm);
      await triage(d);
      await d.handle('10');
      await d.handle('50 reais');
      await d.handle('20');
      final r = await d.handle('pode seguir, ta tudo certinho'); // "pode" ja e sim
      expect(r.state, DialogState.offerDetail); // resultado + "quer detalhar o custo?"
      expect(llm.prompts, isEmpty);

      final d2 = build(FakeLlm(['{"answer": "nao"}']));
      await triage(d2);
      await d2.handle('10');
      await d2.handle('50 reais');
      await d2.handle('20');
      final r2 = await d2.handle('hmm, deixa eu pensar melhor');
      expect(r2.state, DialogState.askQuantity); // LLM disse "nao": corrige os numeros

      // Falar QUAL dado esta errado vai direto nele (sem LLM) e volta para a confirmacao.
      final llm3 = FakeLlm([]);
      final d3 = build(llm3);
      await triage(d3);
      await d3.handle('10');
      await d3.handle('50 reais');
      await d3.handle('20');
      final r3 = await d3.handle('hmm, acho que o custo tava errado');
      expect(r3.state, DialogState.askCost);
      expect((await d3.handle('60 reais')).state, DialogState.confirm);
      expect(llm3.prompts, isEmpty);
    });
  });
}

import 'dart:io';

import 'package:augure_miniapps/core/dialog_machine.dart';
import 'package:augure_miniapps/core/pricing_calculator.dart';
import 'package:augure_miniapps/llm/llm_engine.dart';
import 'package:augure_miniapps/llm/smart_dialog.dart';
import 'package:augure_miniapps/llm/utterance_interpreter.dart';
import 'package:augure_miniapps/memory/conversation_store.dart';
import 'package:augure_miniapps/memory/local_rag.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeLlm implements LlmEngine {
  FakeLlm(this.replies);
  final List<String> replies;
  final prompts = <String>[];
  @override
  bool get isReady => true;
  @override
  Future<bool> load() async => true;
  @override
  Future<String> complete(String prompt,
      {Map<String, Object?>? jsonSchema, int maxTokens = 48}) async {
    prompts.add(prompt);
    return replies.removeAt(0);
  }

  @override
  Future<void> dispose() async {}
}

const _profile = SalesSession(
  company: 'Doces da Ana',
  product: 'marmitas',
  materials: 'arroz e frango',
  batchYield: 20,
  productionMinutes: 120,
);

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('augure_mem_'));
  tearDown(() async {
    // Windows pode segurar o arquivo por um instante; nao falhar o teste por isso.
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  group('busca local (BM25)', () {
    test('acha o mais parecido e ignora plural', () {
      final rag = LocalRag<String>()
        ..add('a', 'uma panela rende vinte marmitas')
        ..add('b', 'a fornada de bolo sai com doze')
        ..add('c', 'trinta reais de custo');
      final hits = rag.search('quantas marmita rende a panela');
      expect(hits.first.item, 'a');
      expect(rag.search('nada a ver aqui'), isEmpty);
    });

    test('tokenizacao pt-BR', () {
      expect(tokenizePt('Marmitas de Frango'), ['marmita', 'frango']);
      expect(tokenizePt('Pães e limões'), ['pao', 'limao']);
    });
  });

  group('memoria local', () {
    test('cadastro e ultimo preco sobrevivem a reabertura', () async {
      final s = await ConversationStore.open(dir);
      await s.saveProfile(_profile.copyWith(quantity: 99)); // numeros nao entram
      await s.rememberResult(_profile,
          calculatePricing(const PricingInput(quantity: 20, totalCostCents: 12000, marginPercent: 30)));

      final again = await ConversationStore.open(dir);
      expect(again.profile.product, 'marmitas');
      expect(again.profile.quantity, isNull);
      expect(again.lastUnitPriceCents, 858);
      expect(again.profileSummary(), contains('Cada lote rende 20 unidades'));
      expect(again.profileSummary(), contains('R\$ 8,58'));
    });

    test('conversa em andamento e retomada; velha demais nao', () async {
      final s = await ConversationStore.open(dir);
      final m = DialogMachine(profile: _profile)..start();
      m.handle('10');
      await s.saveConversation(m.toJson(), [
        {'text': 'oi', 'fromAssistant': true},
      ]);

      final again = await ConversationStore.open(dir);
      final saved = again.resumable()!;
      final m2 = DialogMachine();
      expect(m2.restore(saved.dialog), isTrue);
      expect(m2.state, DialogState.askCost);
      expect(m2.session.quantity, 10);
      expect(m2.profile.product, 'marmitas');
      expect(m2.resumePrompt().text, startsWith('Continuando de onde paramos'));

      expect(again.resumable(DateTime.now().add(const Duration(days: 1))), isNull);
    });

    test('resultado nao e retomado (comeca de novo)', () {
      final m = DialogMachine(profile: _profile)..start();
      m.handle('20');
      m.handle('120 reais');
      m.handle('30');
      m.handle('sim');
      expect(DialogMachine().restore(m.toJson()), isFalse);
    });

    test('arquivo corrompido nao trava: memoria vazia', () async {
      await File('${dir.path}/${ConversationStore.memoryFileName}').writeAsString('{lixo');
      final s = await ConversationStore.open(dir);
      expect(s.profile.hasProfile, isFalse);
      expect(s.resumable(), isNull);
    });
  });

  group('aprendizado local (exemplos)', () {
    test('turnos entendidos viram exemplos e sobrevivem a reabertura', () async {
      final s = await ConversationStore.open(dir);
      final d = SmartDialog(DialogMachine(profile: _profile))
        ..onTurn = (t) => s.logExample(t.toJson());
      d.start();
      await d.handle('vinte unidades');
      await d.handle('voltar'); // comando: nao vira exemplo
      await d.handle('trinta');
      await s.flush();

      final again = await ConversationStore.open(dir);
      final shots = again.examplesFor(DialogState.askQuantity, 'umas vinte unidades');
      expect(shots.map((e) => (e.input, e.value)), contains(('vinte unidades', 20)));
      expect(shots.map((e) => e.input), isNot(contains('voltar')));
    });

    test('correcao invalida o exemplo errado e ensina o certo', () async {
      final s = await ConversationStore.open(dir);
      final m = DialogMachine()
        ..onCorrected = (f, o, n) =>
            s.logExample({'type': 'correction', 'field': f.name, 'old': o, 'new': n});
      final d = SmartDialog(m)..onTurn = (t) => s.logExample(t.toJson());
      d.start();
      await d.handle('doce da ana'); // STT ouviu errado
      await d.handle('na verdade a empresa se chama Doces da Ana');
      await s.flush();

      final shots = s.examplesFor(DialogState.askCompany, 'doce da ana');
      expect(shots, hasLength(1));
      expect(shots.single.input, 'doce da ana');
      expect(shots.single.value, 'Doces da Ana'); // aprendeu a forma certa

      final events = await s.readExamples();
      expect(events.where((e) => e['type'] == 'correction'), hasLength(1));
    });

    test('LLM recebe cadastro e exemplos parecidos no prompt (RAG)', () async {
      final s = await ConversationStore.open(dir);
      await s.saveProfile(_profile);
      await s.logExample({
        'type': 'turn',
        'state': 'askQuantity',
        'input': 'o tanto de sempre',
        'understood': true,
        'value': 20,
      });
      final llm = FakeLlm(['{"quantity": 20}']);
      final d = SmartDialog(DialogMachine(profile: s.profile),
          UtteranceInterpreter(llm, context: s))
        ..start();
      final r = await d.handle('o mesmo tanto de sempre'); // sem numero: parser nao entende
      expect(r.state, DialogState.askCost);
      expect(d.machine.session.quantity, 20);

      final prompt = llm.prompts.single;
      expect(prompt, contains('Cadastro do usuario'));
      expect(prompt, contains('Produto: marmitas'));
      expect(prompt, contains('Fala: "o tanto de sempre" -> {"quantity":20}'));
    });
  });
}

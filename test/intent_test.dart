import 'dart:io';

import 'package:augure_miniapps/core/dialog_machine.dart';
import 'package:augure_miniapps/llm/llm_engine.dart';
import 'package:augure_miniapps/llm/smart_dialog.dart';
import 'package:augure_miniapps/llm/utterance_interpreter.dart';
import 'package:augure_miniapps/memory/conversation_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// LLM falso que responde conforme o tipo de pergunta (intencao x valor).
class RoutedLlm implements LlmEngine {
  RoutedLlm({this.intent = '{"intencao":"nada"}', this.value = '{}'});
  String intent;
  String value;
  final intentPrompts = <String>[];
  @override
  bool get isReady => true;
  @override
  Future<bool> load() async => true;
  @override
  Future<String> complete(String prompt,
      {Map<String, Object?>? jsonSchema, int maxTokens = 48}) async {
    if (prompt.contains('intencao')) {
      intentPrompts.add(prompt);
      return intent;
    }
    return value;
  }

  @override
  Future<void> dispose() async {}
}

SmartDialog atFreight(RoutedLlm llm) {
  final d = SmartDialog(
      DialogMachine(profile: const SalesSession(product: 'bolo', batchYield: 12)),
      UtteranceInterpreter(llm))
    ..start();
  for (final a in ['12', '20 reais', '70', 'sim', 'sim', 'não', 'farinha']) {
    d.machine.handle(a);
  }
  d.machine.handle('2 xícaras');
  d.machine.handle('6 reais o quilo');
  d.machine.handle('não'); // mais materiais
  d.machine.handle('1,70'); // embalagem
  expect(d.machine.lastPrompt, contains('frete'));
  return d;
}

void main() {
  group('forma canonica do pedido', () {
    test('mudar dado, ingrediente e comando', () {
      expect(UtteranceInterpreter.canonicalIntent(
          {'intencao': 'mudar', 'campo': 'margem', 'valor': '40%'}), 'corrigir a margem para 40%');
      expect(UtteranceInterpreter.canonicalIntent(
          {'intencao': 'mudar', 'campo': 'embalagem', 'valor': null}), 'corrigir a embalagem');
      expect(
          UtteranceInterpreter.canonicalIntent(
              {'intencao': 'mudar', 'campo': 'preço da farinha', 'valor': '6 reais o quilo'},
              ingredients: ['farinha de trigo']),
          'corrigir o preço de farinha para 6 reais o quilo');
      expect(UtteranceInterpreter.canonicalIntent({'intencao': 'comando', 'comando': 'voltar'}),
          'voltar');
      expect(UtteranceInterpreter.canonicalIntent({'intencao': 'resposta'}), isNull);
      // campo inventado pela IA e descartado
      expect(UtteranceInterpreter.canonicalIntent(
          {'intencao': 'mudar', 'campo': 'cor do carro', 'valor': 'azul'}), isNull);
    });
  });

  group('fala inesperada no meio da entrevista', () {
    test('"a embalagem ta cara, poe um e cinquenta" na pergunta do frete', () async {
      final llm = RoutedLlm(
          intent: '{"intencao":"mudar","campo":"embalagem","valor":"1,50"}');
      final d = atFreight(llm);
      final r = await d.handle('a embalagem ta cara, poe um e cinquenta');
      expect(llm.intentPrompts, hasLength(1));
      expect(llm.intentPrompts.single, contains('Pergunta atual do app'));
      expect(d.machine.costTable!.packagingPerUnitCents, 150);
      expect(r.text, contains('Corrigido: embalagem'));
      expect(r.text, contains('frete')); // continua na mesma pergunta
    });

    test('pedido sem valor: a IA identifica o campo e o app pergunta', () async {
      final llm = RoutedLlm(intent: '{"intencao":"mudar","campo":"preço da farinha"}');
      final d = atFreight(llm);
      final r = await d.handle('pera, aquela farinha eu paguei diferente');
      expect(r.text, contains('vamos corrigir farinha'));
      await d.handle('7 reais o quilo');
      expect(d.machine.costTable!.materials.single.priceCents, 700);
    });

    test('comando fora de hora', () async {
      final llm = RoutedLlm(intent: '{"intencao":"comando","comando":"voltar"}');
      final d = atFreight(llm);
      final r = await d.handle('ah, deixa eu ver a anterior');
      expect(r.text, contains('embalagem'));
    });

    test('na triagem: "muda o nome do produto pra bolo de pote"', () async {
      final llm = RoutedLlm(
          intent: '{"intencao":"mudar","campo":"produto","valor":"bolo de pote"}');
      final d = SmartDialog(DialogMachine(), UtteranceInterpreter(llm))..start();
      for (final a in ['Alfaprotein', 'confeitaria', 'bolo', 'farinha e ovos']) {
        await d.handle(a);
      }
      expect(d.machine.state, DialogState.askBatchYield);
      final r = await d.handle('ah, deixa o nome do produto como bolo de pote');
      expect(d.machine.session.product, 'bolo de pote');
      expect(r.state, DialogState.askBatchYield); // voltou para onde estava
    });

    test('resposta normal nao chama a IA', () async {
      final llm = RoutedLlm();
      final d = atFreight(llm);
      await d.handle('10 reais');
      expect(llm.intentPrompts, isEmpty);
    });
  });

  group('reinstalar comeca do zero', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('augure_reset_'));
    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    test('build novo limpa a tela; produtos ficam em Meus produtos', () async {
      final s = await ConversationStore.open(dir);
      expect(await s.resetIfNewBuild('20261126-1500'), isFalse); // primeira instalacao
      await s.saveProfile(const SalesSession(company: 'Alfaprotein', product: 'bolo'));
      await s.saveConversation({'state': 'askCost'}, [
        {'text': 'oi', 'fromAssistant': true},
      ]);

      final again = await ConversationStore.open(dir);
      expect(await again.resetIfNewBuild('20261126-1500'), isFalse); // mesmo build: segue
      expect(again.resumable(), isNotNull);

      final updated = await ConversationStore.open(dir);
      expect(await updated.resetIfNewBuild('20261126-1600'), isTrue); // reinstalado
      expect(updated.resumable(), isNull);
      expect(updated.profile.hasProfile, isFalse);
      expect(updated.company, isNull);
      expect(updated.products.map((p) => p.name), ['bolo']); // historico mantido
      final m = DialogMachine(profile: updated.profile);
      expect(m.start().state, DialogState.askCompany); // do zero
    });

    test('sem carimbo nao zera', () async {
      final s = await ConversationStore.open(dir);
      await s.saveProfile(const SalesSession(product: 'bolo'));
      expect(await s.resetIfNewBuild(''), isFalse);
      expect(s.profile.hasProfile, isTrue);
    });
  });
}

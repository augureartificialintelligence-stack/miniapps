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

    test('novo produto guarda o anterior; da para voltar a ele', () async {
      final s = await ConversationStore.open(dir);
      await s.saveProfile(_profile); // marmitas
      expect(s.products, hasLength(1));

      await s.startNewProduct();
      expect(s.profile.product, isNull);
      expect(s.profile.company, 'Doces da Ana'); // empresa continua
      expect(s.resumable(), isNull); // conversa do produto anterior nao e retomada

      await s.saveProfile(const SalesSession(
          company: 'Doces da Ana', product: 'bolo de pote', batchYield: 12));
      expect(s.products.map((p) => p.name), ['bolo de pote', 'marmitas']);
      expect(s.profile.product, 'bolo de pote');

      final again = await ConversationStore.open(dir); // sobrevive a reabertura
      expect(again.products, hasLength(2));
      final marmitas = again.products.firstWhere((p) => p.name == 'marmitas');
      await again.activate(marmitas.id);
      expect(again.profile.product, 'marmitas');
      expect(again.profile.batchYield, 20);
    });

    test('mesmo nome de produto atualiza o salvo, sem duplicar', () async {
      final s = await ConversationStore.open(dir);
      await s.saveProfile(_profile);
      await s.startNewProduct();
      await s.saveProfile(const SalesSession(company: 'Doces da Ana', product: 'Marmita'));
      expect(s.products, hasLength(1));
    });

    test('memoria antiga (um produto, versao 2) e migrada', () async {
      await File('${dir.path}/${ConversationStore.memoryFileName}').writeAsString(
          '{"version":2,"profile":{"company":"Doces da Ana","product":"marmitas"},'
          '"lastUnitPriceCents":858}');
      final s = await ConversationStore.open(dir);
      expect(s.products, hasLength(1));
      expect(s.profile.product, 'marmitas');
      expect(s.lastUnitPriceCents, 858);
      expect(s.company, 'Doces da Ana');
    });

    group('reaproveitar receita de produto salvo', () {
      const receita = 'três cenouras três ovos uma xícara de óleo duas xícaras de farinha';

      /// Maquina como o app monta: com a memoria e salvando o cadastro a cada passo.
      Future<(ConversationStore, DialogMachine)> newProductMachine() async {
        final s = await ConversationStore.open(dir);
        await s.saveProfile(const SalesSession(
            company: 'Alfaprotein',
            product: 'bolo de cenoura',
            materials: receita,
            batchYield: 12,
            productionMinutes: 70));
        await s.startNewProduct(); // "Nova conversa"
        final m = DialogMachine(
          profile: s.profile,
          recallProduct: (r, {current, exact = false}) =>
              s.findSavedProduct(r, current: current, exact: exact),
          savedProductNames: () => s.savedProductNames,
        );
        expect(m.start().state, DialogState.askProduct);
        return (s, m);
      }

      test('mesmo nome: oferece usar os dados salvos, sem apagar o salvo', () async {
        final (s, m) = await newProductMachine();
        final r = m.handle('bolo de cenoura');
        expect(r.state, DialogState.askReuse);
        expect(r.text, contains('Já tenho a ficha de bolo de cenoura salva'));
        expect(r.text, contains('rende 12 por lote'));
        // O app salva o cadastro a cada passo: o produto salvo NAO pode perder a receita.
        await s.saveProfile(m.profile);
        expect(s.profile.materials, receita);
        expect(s.products, hasLength(1)); // nao duplicou

        final r2 = m.handle('sim');
        expect(r2.state, DialogState.askQuantity);
        expect(r2.text, contains('usei os dados salvos de bolo de cenoura'));
        expect(m.session.materials, receita);
        expect(m.session.productionMinutes, 70);
        expect(m.costTable!.materials, hasLength(4)); // lista com quantidades na tela
      });

      test('"nao" cadastra de novo', () async {
        final (_, m) = await newProductMachine();
        m.handle('bolo de cenoura');
        expect(m.handle('não').state, DialogState.askMaterials);
        expect(m.session.materials, isNull);
      });

      test('frase real: "utilize dados de receita de bolo de cenoura que você já tem"',
          () async {
        final (_, m) = await newProductMachine();
        m.handle('bolo de cenoura de pote'); // nome diferente: nao oferece sozinho
        expect(m.state, DialogState.askMaterials);
        final r = m.handle('utilize dados de receita de bolo de cenoura que você já tem');
        expect(r.state, DialogState.askQuantity);
        expect(m.session.materials, receita); // nao guardou a frase como ingredientes
        expect(m.session.product, 'bolo de cenoura de pote');
      });

      test('pedido sem produto salvo avisa quais existem', () async {
        final (_, m) = await newProductMachine();
        m.handle('torta de limão');
        final r = m.handle('use a receita de brigadeiro que você já tem');
        expect(r.understood, isFalse);
        expect(r.state, DialogState.askMaterials);
        expect(r.text, contains('Tenho salvos: bolo de cenoura'));
      });
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

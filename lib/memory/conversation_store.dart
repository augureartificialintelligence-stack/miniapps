import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/cost_breakdown.dart';
import '../core/dialog_machine.dart';
import '../core/document_parser.dart' show sameIngredient;
import '../core/pricing_calculator.dart';
import '../core/pt_br_parser.dart' show speakDuration;
import '../llm/utterance_interpreter.dart';
import 'local_rag.dart';

/// Memoria local do app, em arquivos no armazenamento privado do aparelho.
///
/// - `augure_memoria.json`: empresa do usuario, os produtos cadastrados (cada um com
///   especificacoes, tabela de custo e ultimo preco), qual produto esta ATIVO e a
///   conversa em andamento (para retomar se o app fechar). Um produto por vez esta em
///   uso; os outros ficam guardados em "Meus produtos" para voltar a eles.
/// - `augure_exemplos.jsonl`: um evento por linha: como cada fala foi interpretada e as
///   correcoes feitas pela pessoa. E a base do aprendizado local: exemplos parecidos sao
///   recuperados (RAG) e entregues ao LLM como contexto, e o arquivo pode ser exportado
///   para fine-tuning fora do aparelho.
///
/// Nada sai do aparelho sem a pessoa exportar.
class ConversationStore implements InterpreterContext {
  ConversationStore._(this.dir);

  final Directory dir;

  static const memoryFileName = 'augure_memoria.json';
  static const examplesFileName = 'augure_exemplos.jsonl';

  /// Conversas paradas ha mais tempo que isso comecam do zero (o cadastro fica).
  static const resumeWindow = Duration(hours: 12);

  /// Empresa do usuario (vale para todos os produtos).
  String? company;

  /// Produtos cadastrados (historico). O ativo e o da conversa atual.
  final _products = <ProductRecord>[];
  String? _activeId;

  /// Produtos salvos, o mais recente primeiro.
  List<ProductRecord> get products =>
      [..._products]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  ProductRecord? get activeProduct {
    for (final p in _products) {
      if (p.id == _activeId) return p;
    }
    return null;
  }

  /// Cadastro do produto ativo (ou so a empresa, se ainda nao ha produto ativo).
  SalesSession get profile =>
      activeProduct?.session ?? SalesSession(company: company);

  /// Ultimo preco calculado para o produto ativo.
  int? get lastUnitPriceCents => activeProduct?.lastUnitPriceCents;

  Map<String, Object?>? _dialog;
  List<Map<String, Object?>> _messages = [];
  DateTime? _conversationUpdatedAt;

  /// Exemplos aprendidos (fala -> valor aceito), por pergunta.
  final _examples = <_Example>[];

  Future<void> _writing = Future.value();

  File get memoryFile => File('${dir.path}${Platform.pathSeparator}$memoryFileName');
  File get examplesFile => File('${dir.path}${Platform.pathSeparator}$examplesFileName');

  int get exampleCount => _examples.where((e) => !e.corrected).length;

  /// Abre (ou cria) a memoria em [dir]. Arquivo corrompido = memoria vazia, sem travar.
  static Future<ConversationStore> open(Directory dir) async {
    final s = ConversationStore._(dir);
    await s._load();
    return s;
  }

  Future<void> _load() async {
    try {
      if (await memoryFile.exists()) {
        final j = jsonDecode(await memoryFile.readAsString());
        if (j is Map) {
          company = j['company'] as String?;
          for (final p in (j['products'] as List? ?? const [])) {
            if (p is Map) {
              final r = ProductRecord.fromJson(p.cast<String, Object?>());
              if (r != null) _products.add(r);
            }
          }
          _activeId = j['activeId'] as String?;
          _buildStamp = j['buildStamp'] as String?;
          // Versao 2 (um produto so): migra para a lista de produtos.
          final old = j['profile'];
          if (old is Map && _products.isEmpty) {
            final s = SalesSession.fromJson(old.cast<String, Object?>());
            company ??= s.company;
            if (s.hasProfile) {
              final r = ProductRecord(_newId(), s,
                  lastUnitPriceCents: (j['lastUnitPriceCents'] as num?)?.toInt());
              _products.add(r);
              _activeId = r.id;
            }
          }
          final conv = j['conversation'];
          if (conv is Map) {
            _dialog = (conv['dialog'] as Map?)?.cast<String, Object?>();
            _messages = [
              for (final m in (conv['messages'] as List? ?? const []))
                if (m is Map) m.cast<String, Object?>(),
            ];
            _conversationUpdatedAt = DateTime.tryParse(conv['updatedAt'] as String? ?? '');
          }
        }
      }
    } catch (_) {
      // Memoria ilegivel: segue vazia (o app nunca deve travar por isso).
    }
    for (final e in await readExamples()) {
      _learn(e);
    }
  }

  // ---- conversa em andamento ----

  /// Conversa salva que ainda pode ser retomada, ou null.
  ({Map<String, Object?> dialog, List<Map<String, Object?>> messages})? resumable(
      [DateTime? now]) {
    final d = _dialog;
    final at = _conversationUpdatedAt;
    if (d == null || at == null || _messages.isEmpty) return null;
    if ((now ?? DateTime.now()).difference(at) > resumeWindow) return null;
    return (dialog: d, messages: _messages);
  }

  Future<void> saveConversation(
      Map<String, Object?> dialog, List<Map<String, Object?>> messages) {
    _dialog = dialog;
    _messages = messages;
    _conversationUpdatedAt = DateTime.now();
    return _persist();
  }

  Future<void> clearConversation() {
    _clearConversationFields();
    return _persist();
  }

  void _clearConversationFields() {
    _dialog = null;
    _messages = [];
    _conversationUpdatedAt = null;
  }

  // ---- cadastro ----

  /// Salva o cadastro do produto ativo (so a triagem; numeros de preco nao entram).
  /// O primeiro salvamento com nome de produto cria o registro dele no historico; um
  /// produto com o MESMO nome de um ja salvo atualiza aquele, sem duplicar.
  Future<void> saveProfile(SalesSession s) {
    final p = s.keepTriage();
    var changed = false;
    if (p.company != company) {
      company = p.company;
      changed = true;
    }
    if (p.hasProfile) {
      var active = activeProduct;
      if (active == null) {
        final same = _byName(p.product!);
        if (same != null) {
          // Produto com o MESMO nome de um salvo (ex.: "Nova conversa" e "bolo de
          // cenoura" de novo): reativa o salvo SEM apagar o que ele tinha. So os
          // campos ja respondidos agora substituem os antigos; a conversa oferece
          // reaproveitar o resto.
          _activeId = same.id;
          same
            ..session = _keepOld(p, same.session)
            ..updatedAt = DateTime.now();
          return _persist();
        }
      }
      if (active == null) {
        final r = ProductRecord(_newId(), p);
        _products.add(r);
        _activeId = r.id;
        changed = true;
      } else {
        _activeId = active.id;
        if (jsonEncode(active.session.toJson()) != jsonEncode(p.toJson())) {
          active
            ..session = p
            ..updatedAt = DateTime.now();
          changed = true;
        }
      }
    }
    return changed ? _persist() : Future.value();
  }

  Future<void> rememberResult(SalesSession s, PricingResult r) async {
    await saveProfile(s);
    final active = activeProduct;
    if (active == null) return;
    active
      ..lastUnitPriceCents = r.unitPriceCents
      ..updatedAt = DateTime.now();
    await _persist();
  }

  /// Carimbo da instalacao que gravou esta memoria (data/hora do build).
  String? _buildStamp;

  /// App reinstalado (build novo): comeca do zero. Limpa a tela (conversa em andamento,
  /// produto ativo e empresa da conversa); os produtos salvos continuam em "Meus
  /// produtos". Sem carimbo (build sem BUILD_STAMP) nao faz nada. true = zerou.
  Future<bool> resetIfNewBuild(String stamp) async {
    if (stamp.isEmpty || stamp == _buildStamp) return false;
    final first = _buildStamp == null && _products.isEmpty && _dialog == null;
    _buildStamp = stamp;
    if (!first) {
      _activeId = null;
      company = null;
      _clearConversationFields();
    }
    await _persist();
    return !first;
  }

  /// "Nova conversa": o produto atual fica salvo no historico e o proximo cadastro
  /// comeca do zero (mantendo a empresa).
  Future<void> startNewProduct() {
    _activeId = null;
    _clearConversationFields();
    return _persist();
  }

  /// Volta a um produto salvo ("Meus produtos").
  Future<void> activate(String id) {
    if (!_products.any((p) => p.id == id)) return Future.value();
    _activeId = id;
    _clearConversationFields();
    return _persist();
  }

  static SalesSession _keepOld(SalesSession newer, SalesSession older) => SalesSession(
        company: newer.company ?? older.company,
        sector: newer.sector ?? older.sector,
        product: newer.product ?? older.product,
        materials: newer.materials ?? older.materials,
        batchYield: newer.batchYield ?? older.batchYield,
        productionMinutes: newer.productionMinutes ?? older.productionMinutes,
        characteristics: newer.characteristics ?? older.characteristics,
        saleUnit: newer.saleUnit ?? older.saleUnit,
        batchName: newer.batchName ?? older.batchName,
        costs: newer.costs ?? older.costs,
      );

  /// Palavras do pedido que nao sao nome de produto ("use a receita que voce ja tem").
  static const _requestWords = {
    'usa', 'use', 'usar', 'utilize', 'utiliza', 'utilizar', 'aproveita', 'aproveite',
    'copia', 'copie', 'pega', 'pegue', 'mesmo', 'mesma', 'receita', 'dado', 'ficha',
    'ingrediente', 'produto', 'voce', 'vc', 'ja', 'tem', 'tinha', 'salvo', 'salva',
    'guardado', 'guardada', 'cadastrado', 'cadastrada', 'anterior', 'aquele', 'aquela',
    'esse', 'essa', 'este', 'esta', 'por', 'favor',
  };

  /// Produto salvo citado no pedido ("use a receita do bolo de cenoura que voce ja
  /// tem"), ou, sem nome no pedido, o produto com o nome [current]. So devolve produto
  /// que tenha ingredientes ou tabela de custo.
  /// Com [exact], so vale produto com o MESMO nome (oferta automatica da conversa).
  SalesSession? findSavedProduct(String request, {String? current, bool exact = false}) {
    final q = tokenizePt(request).where((w) => !_requestWords.contains(w)).toSet();
    final query = q.isNotEmpty ? q : tokenizePt(current ?? '').toSet();
    if (query.isEmpty) return null;
    ProductRecord? best;
    var bestScore = 0.0;
    for (final p in products) {
      final s = p.session;
      if (s.materials == null && (s.costs?.materials.isEmpty ?? true)) continue;
      final name = tokenizePt(p.name).toSet();
      if (name.isEmpty) continue;
      final inter = name.intersection(query).length;
      if (exact && (inter != name.length || inter != query.length)) continue;
      // Quanto do nome salvo foi citado, e quanto do pedido bate com o nome.
      final score = inter / name.length + inter / query.length;
      if (inter > 0 && inter / name.length >= 0.5 && score > bestScore) {
        best = p;
        bestScore = score;
      }
    }
    return best?.session;
  }

  /// Precos de ingredientes ja registrados (tabelas de custo de todos os produtos, o
  /// mais recente primeiro; um por ingrediente).
  List<KnownPrice> knownPrices() {
    final out = <KnownPrice>[];
    for (final p in products) {
      for (final m in p.session.costs?.materials ?? const <MaterialCost>[]) {
        if (m.priceCents == null || m.pack == null) continue;
        if (out.any((k) => sameIngredient(k.name, m.name))) continue;
        out.add(KnownPrice(m.name, m.priceCents!, m.pack!, from: p.name));
      }
    }
    return out;
  }

  /// Nomes dos produtos salvos (para dizer quais existem).
  List<String> get savedProductNames => [for (final p in products) p.name];

  ProductRecord? _byName(String name) {
    final key = tokenizePt(name).join(' ');
    for (final p in _products) {
      if (tokenizePt(p.session.product ?? '').join(' ') == key) return p;
    }
    return null;
  }

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_products.length}';

  // ---- contexto para o LLM (RAG local) ----

  @override
  String? profileSummary() {
    final p = profile;
    if (!p.hasProfile && p.company == null) return null;
    return [
      if (p.company != null) 'Empresa: ${p.company}.',
      if (p.product != null) 'Produto: ${p.product}.',
      if (p.materials != null) 'Feito de: ${p.materials}.',
      if (p.batchYield != null) 'Cada lote rende ${p.batchYield} unidades.',
      if (p.productionMinutes != null)
        'Um lote leva ${speakDuration(p.productionMinutes!)}.',
      if (p.characteristics != null) 'Caracteristicas: ${p.characteristics}.',
      if (lastUnitPriceCents != null)
        'Ultimo preco calculado: ${formatBrl(lastUnitPriceCents!)} por unidade.',
    ].join(' ');
  }

  /// Falas parecidas ja entendidas NESTA pergunta (busca BM25), sem as que foram
  /// corrigidas depois. Mais recente primeiro em caso de empate.
  @override
  List<FewShot> examplesFor(DialogState state, String utterance, {int k = 3}) {
    final rag = LocalRag<_Example>();
    for (final e in _examples.reversed) {
      if (e.state == state && !e.corrected) rag.add(e, e.input);
    }
    return [
      for (final h in rag.search(utterance, k: k)) FewShot(h.item.input, h.item.value),
    ];
  }

  // ---- exemplos (aprendizado) ----

  /// Acrescenta um evento ao arquivo JSONL e aprende com ele na hora.
  Future<void> logExample(Map<String, Object?> event) {
    final e = {'ts': DateTime.now().toIso8601String(), ...event};
    _learn(e);
    final line = jsonEncode(e);
    return _serial(() async {
      await dir.create(recursive: true);
      await examplesFile.writeAsString('$line\n', mode: FileMode.append, flush: true);
    });
  }

  /// Turnos entendidos viram exemplos; correcoes invalidam o exemplo errado e criam
  /// um exemplo certo com a mesma fala (o app aprende com o erro).
  void _learn(Map<String, Object?> e) {
    final state = DialogState.values.asNameMap()[e['state'] ?? e['field']];
    if (state == null || !correctableStates.contains(state)) return;
    if (e['type'] == 'turn') {
      final input = e['input'];
      final value = e['value'];
      if (input is! String || value == null || e['understood'] != true) return;
      _examples.removeWhere((x) => x.state == state && x.input == input);
      _examples.add(_Example(state, input, value));
    } else if (e['type'] == 'correction') {
      final old = e['old'];
      final neu = e['newValue'] ?? e['new'];
      _Example? wrong;
      for (final x in _examples.reversed) {
        if (x.state == state && !x.corrected && '${x.value}' == '$old') {
          wrong = x;
          break;
        }
      }
      if (wrong == null) return;
      wrong.corrected = true;
      if (neu != null) _examples.add(_Example(state, wrong.input, neu));
    }
  }

  /// Le todos os eventos gravados (linhas invalidas sao ignoradas).
  Future<List<Map<String, Object?>>> readExamples() async {
    if (!await examplesFile.exists()) return const [];
    final out = <Map<String, Object?>>[];
    for (final line in await examplesFile.readAsLines()) {
      if (line.trim().isEmpty) continue;
      try {
        final j = jsonDecode(line);
        if (j is Map) out.add(j.cast<String, Object?>());
      } catch (_) {}
    }
    return out;
  }

  // ---- gravacao ----

  Future<void> _persist() => _serial(() async {
        await dir.create(recursive: true);
        final data = jsonEncode({
          'version': 3,
          'company': company,
          'activeId': _activeId,
          'buildStamp': _buildStamp,
          'products': [for (final p in _products) p.toJson()],
          'conversation': _dialog == null
              ? null
              : {
                  'dialog': _dialog,
                  'messages': _messages,
                  'updatedAt': _conversationUpdatedAt?.toIso8601String(),
                },
        });
        // Grava em arquivo temporario e troca: nunca deixa a memoria pela metade.
        final tmp = File('${memoryFile.path}.tmp');
        await tmp.writeAsString(data, flush: true);
        await tmp.rename(memoryFile.path);
      });

  /// Espera todas as gravacoes pendentes (antes de exportar ou fechar).
  Future<void> flush() => _writing;

  /// Uma gravacao por vez, na ordem em que foram pedidas.
  Future<void> _serial(Future<void> Function() op) {
    final next = _writing.then((_) => op()).catchError((_) {});
    _writing = next;
    return next;
  }
}

/// Um produto do historico ("Meus produtos").
class ProductRecord {
  ProductRecord(this.id, this.session, {this.lastUnitPriceCents, DateTime? updatedAt})
      : updatedAt = updatedAt ?? DateTime.now();

  final String id;

  /// Cadastro do produto: triagem + tabela de custo (sem os numeros de um calculo).
  SalesSession session;
  int? lastUnitPriceCents;
  DateTime updatedAt;

  String get name => session.product ?? 'Produto sem nome';

  Map<String, Object?> toJson() => {
        'id': id,
        'session': session.toJson(),
        'lastUnitPriceCents': lastUnitPriceCents,
        'updatedAt': updatedAt.toIso8601String(),
      };

  static ProductRecord? fromJson(Map<String, Object?> j) {
    final id = j['id'];
    final s = j['session'];
    if (id is! String || s is! Map) return null;
    return ProductRecord(id, SalesSession.fromJson(s.cast<String, Object?>()),
        lastUnitPriceCents: (j['lastUnitPriceCents'] as num?)?.toInt(),
        updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''));
  }
}

class _Example {
  _Example(this.state, this.input, this.value);
  final DialogState state;
  final String input;
  final Object value;
  bool corrected = false;
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/dialog_machine.dart';
import '../core/pricing_calculator.dart';
import '../core/pt_br_parser.dart' show speakDuration;
import '../llm/utterance_interpreter.dart';
import 'local_rag.dart';

/// Memoria local do app, em arquivos no armazenamento privado do aparelho.
///
/// - `augure_memoria.json`: cadastro do usuario (empresa + UM produto + especificacoes),
///   ultimo preco calculado e a conversa em andamento (para retomar se o app fechar).
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

  /// Cadastro (triagem). Vazio ate a primeira triagem.
  SalesSession profile = const SalesSession();

  /// Ultimo preco calculado para o produto do cadastro.
  int? lastUnitPriceCents;

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
          final p = j['profile'];
          if (p is Map) profile = SalesSession.fromJson(p.cast<String, Object?>());
          lastUnitPriceCents = (j['lastUnitPriceCents'] as num?)?.toInt();
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
    _dialog = null;
    _messages = [];
    _conversationUpdatedAt = null;
    return _persist();
  }

  // ---- cadastro ----

  /// Salva o cadastro (so a triagem; numeros de preco nao entram).
  Future<void> saveProfile(SalesSession s) {
    final p = s.keepTriage();
    if (jsonEncode(p.toJson()) == jsonEncode(profile.toJson())) return Future.value();
    profile = p;
    return _persist();
  }

  Future<void> rememberResult(SalesSession s, PricingResult r) {
    profile = s.keepTriage();
    lastUnitPriceCents = r.unitPriceCents;
    return _persist();
  }

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
          'version': 2,
          'profile': profile.toJson(),
          'lastUnitPriceCents': lastUnitPriceCents,
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

class _Example {
  _Example(this.state, this.input, this.value);
  final DialogState state;
  final String input;
  final Object value;
  bool corrected = false;
}

import 'dart:math' show log;

import '../core/pt_br_parser.dart' show normalizePt;

/// Busca local por relevancia (BM25) sobre documentos curtos em pt-BR.
///
/// "RAG" leve e 100% offline: sem embeddings nem modelo extra. Serve para recuperar
/// fichas de produtos ja calculados e exemplos de falas ja entendidas. A recuperacao
/// so SUGERE: a pessoa confirma antes de qualquer dado ser reaproveitado.
class LocalRag<T> {
  LocalRag({this.k1 = 1.2, this.b = 0.75});

  final double k1;
  final double b;

  final _docs = <_Doc<T>>[];
  final _df = <String, int>{};
  var _totalLen = 0;

  int get length => _docs.length;

  void clear() {
    _docs.clear();
    _df.clear();
    _totalLen = 0;
  }

  void add(T item, String text) {
    final tokens = tokenizePt(text);
    _docs.add(_Doc(item, tokens));
    _totalLen += tokens.length;
    for (final t in tokens.toSet()) {
      _df[t] = (_df[t] ?? 0) + 1;
    }
  }

  /// Os [k] documentos mais relevantes para [query], do mais para o menos relevante.
  /// [minScore] descarta resultados fracos.
  List<RagHit<T>> search(String query, {int k = 3, double minScore = 0}) {
    final q = tokenizePt(query).toSet();
    if (q.isEmpty || _docs.isEmpty) return const [];
    final avgLen = _totalLen / _docs.length;
    final n = _docs.length;
    final hits = <RagHit<T>>[];
    for (final d in _docs) {
      var score = 0.0;
      var matched = 0;
      for (final term in q) {
        final tf = d.tf[term];
        if (tf == null) continue;
        matched++;
        final df = _df[term] ?? 0;
        final idf = log(1 + (n - df + 0.5) / (df + 0.5));
        final norm = tf + k1 * (1 - b + b * d.length / (avgLen == 0 ? 1 : avgLen));
        score += idf * (tf * (k1 + 1)) / norm;
      }
      if (matched > 0 && score >= minScore) {
        hits.add(RagHit(d.item, score, matched / q.length));
      }
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.take(k).toList();
  }
}

class RagHit<T> {
  const RagHit(this.item, this.score, this.coverage);
  final T item;
  final double score;

  /// Fracao das palavras da consulta encontradas no documento (0..1).
  final double coverage;
}

class _Doc<T> {
  _Doc(this.item, List<String> tokens) : length = tokens.length {
    for (final t in tokens) {
      tf[t] = (tf[t] ?? 0) + 1;
    }
  }
  final T item;
  final int length;
  final tf = <String, int>{};
}

const _stopwords = {
  'a', 'o', 'as', 'os', 'um', 'uma', 'uns', 'umas', 'de', 'da', 'do', 'das', 'dos',
  'e', 'em', 'na', 'no', 'nas', 'nos', 'com', 'para', 'pra', 'por', 'que', 'se',
  'eu', 'meu', 'minha', 'quero', 'vender', 'fazer', 'produzir', 'vou',
};

/// Tokens normalizados: sem acento, minusculos, sem stopwords, com radical simples
/// (plural -> singular), para "marmitas" casar com "marmita".
List<String> tokenizePt(String text) => normalizePt(text)
    .split(RegExp(r'[^a-z0-9]+'))
    .where((w) => w.length > 1 && !_stopwords.contains(w))
    .map(_stem)
    .toList();

String _stem(String w) {
  if (w.length >= 4 && w.endsWith('oes')) return '${w.substring(0, w.length - 3)}ao';
  if (w.length >= 4 && w.endsWith('aes')) return '${w.substring(0, w.length - 3)}ao';
  if (w.length > 4 && w.endsWith('is')) return '${w.substring(0, w.length - 2)}l';
  if (w.length > 3 && w.endsWith('es') && RegExp(r'[rz]es$').hasMatch(w)) {
    return w.substring(0, w.length - 2);
  }
  if (w.length > 3 && w.endsWith('s')) return w.substring(0, w.length - 1);
  return w;
}

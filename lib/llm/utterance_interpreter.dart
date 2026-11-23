import 'dart:convert';

import '../core/dialog_machine.dart';
import 'llm_engine.dart';

/// Usa o LLM local como INTERPRETADOR de fala livre: devolve uma frase "canonica"
/// (ex.: "20", "120,50 reais", "sim") que a [DialogMachine] entende pelos parsers
/// deterministicos. Toda saida do LLM e re-validada pela maquina (faixas, tipos), e o
/// usuario ainda ouve a leitura dos valores na etapa de confirmacao.
class UtteranceInterpreter {
  UtteranceInterpreter(this._llm);

  final LlmEngine _llm;

  /// Retorna a frase canonica ou null se o LLM nao souber/falhar.
  Future<String?> interpret(String utterance, DialogState state) async {
    if (!_llm.isReady || utterance.trim().isEmpty) return null;
    final spec = _specFor(state);
    if (spec == null) return null;
    try {
      final raw = await _llm.complete(
        spec.prompt(utterance.trim()),
        jsonSchema: spec.schema,
      );
      final json = _extractJson(raw);
      if (json == null) return null;
      return spec.canonical(json);
    } catch (_) {
      return null; // qualquer falha do LLM cai de volta no fluxo deterministico
    }
  }

  static const _rules =
      'Responda SOMENTE com JSON. Se a fala nao trouxer a informacao, use null. '
      'Nao invente valores.';

  _Spec? _specFor(DialogState state) {
    switch (state) {
      case DialogState.askProduct:
        return _Spec(
          schema: _obj({'product': _t(['string', 'null'])}),
          prompt: (u) => 'Extraia o nome do produto que a pessoa quer vender. $_rules\n'
              'Fala: "$u"\nFormato: {"product": "nome curto"}',
          canonical: (j) {
            final v = j['product'];
            return v is String && v.trim().isNotEmpty ? v.trim() : null;
          },
        );
      case DialogState.askQuantity:
        return _Spec(
          schema: _obj({'quantity': _t(['integer', 'null'])}),
          prompt: (u) => 'Extraia a quantidade de unidades (numero inteiro). $_rules\n'
              'Fala: "$u"\nFormato: {"quantity": 20}',
          canonical: (j) {
            final v = j['quantity'];
            return v is num && v == v.roundToDouble() ? '${v.toInt()}' : null;
          },
        );
      case DialogState.askCost:
        return _Spec(
          schema: _obj({'reais': _t(['number', 'null'])}),
          prompt: (u) =>
              'Extraia o valor TOTAL em reais (pode ter centavos, ex.: 12.5). $_rules\n'
              'Fala: "$u"\nFormato: {"reais": 120.5}',
          canonical: (j) {
            final v = j['reais'];
            if (v is! num || v <= 0 || v > 10000000) return null;
            final cents = (v * 100).round();
            final cs = (cents % 100).toString().padLeft(2, '0');
            return '${cents ~/ 100},$cs reais';
          },
        );
      case DialogState.askMargin:
        return _Spec(
          schema: _obj({'percent': _t(['integer', 'null'])}),
          prompt: (u) =>
              'Extraia a porcentagem de lucro desejada (numero inteiro, sem o simbolo). '
              '$_rules\nFala: "$u"\nFormato: {"percent": 30}',
          canonical: (j) {
            final v = j['percent'];
            return v is num && v == v.roundToDouble() ? '${v.toInt()}' : null;
          },
        );
      case DialogState.confirm:
        return _Spec(
          schema: _obj({
            'answer': {
              'type': ['string', 'null'],
              'enum': ['sim', 'nao', null],
            }
          }),
          prompt: (u) => 'A pessoa concordou ("sim") ou discordou ("nao")? $_rules\n'
              'Fala: "$u"\nFormato: {"answer": "sim"}',
          canonical: (j) {
            final v = j['answer'];
            if (v == 'sim') return 'sim';
            if (v == 'nao') return 'não';
            return null;
          },
        );
      case DialogState.result:
        return null;
    }
  }

  static Map<String, Object?> _t(List<String> types) => {'type': types};

  static Map<String, Object?> _obj(Map<String, Object?> props) => {
        'type': 'object',
        'properties': props,
        'required': props.keys.toList(),
        'additionalProperties': false,
      };

  /// Tolera texto ao redor do JSON (modelos pequenos as vezes "conversam").
  static Map<String, Object?>? _extractJson(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final v = jsonDecode(raw.substring(start, end + 1));
      return v is Map<String, Object?> ? v : null;
    } catch (_) {
      return null;
    }
  }
}

class _Spec {
  _Spec({required this.schema, required this.prompt, required this.canonical});
  final Map<String, Object?> schema;
  final String Function(String utterance) prompt;
  final String? Function(Map<String, Object?> json) canonical;
}

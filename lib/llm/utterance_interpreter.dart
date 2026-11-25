import 'dart:convert';

import '../core/dialog_machine.dart';
import 'llm_engine.dart';

/// Usa o LLM local como INTERPRETADOR de fala livre: devolve uma frase "canonica"
/// (ex.: "20", "120,50 reais", "sim") que a [DialogMachine] entende pelos parsers
/// deterministicos. Toda saida do LLM e re-validada pela maquina (faixas, tipos), e o
/// usuario ainda ouve a leitura dos valores na etapa de confirmacao.
///
/// Com [context], o prompt leva o cadastro do usuario e as falas parecidas que ja foram
/// entendidas nesta pergunta (recuperadas da memoria local). E aprendizado em contexto:
/// o modelo nao e re-treinado, mas recebe os acertos e correcoes anteriores.
class UtteranceInterpreter {
  UtteranceInterpreter(this._llm, {this.context});

  final LlmEngine _llm;

  /// Memoria local (cadastro + exemplos). Opcional.
  final InterpreterContext? context;

  /// Retorna a frase canonica ou null se o LLM nao souber/falhar.
  Future<String?> interpret(String utterance, DialogState state) async {
    if (!_llm.isReady || utterance.trim().isEmpty) return null;
    final spec = _specFor(state);
    if (spec == null) return null;
    try {
      final raw = await _llm.complete(
        _buildPrompt(spec, utterance.trim(), state),
        jsonSchema: spec.schema,
      );
      final json = _extractJson(raw);
      if (json == null) return null;
      return spec.canonical(json);
    } catch (_) {
      return null; // qualquer falha do LLM cai de volta no fluxo deterministico
    }
  }

  /// Prompt = contexto do cadastro + exemplos recuperados + pergunta da etapa.
  String _buildPrompt(_Spec spec, String utterance, DialogState state) {
    final b = StringBuffer();
    final profile = context?.profileSummary();
    if (profile != null && profile.isNotEmpty) {
      b.writeln('Cadastro do usuario (use so para entender a fala; nao copie valores '
          'dele para a resposta): $profile');
    }
    final shots = spec.example == null
        ? const <FewShot>[]
        : context?.examplesFor(state, utterance) ?? const <FewShot>[];
    if (shots.isNotEmpty) {
      b.writeln('Exemplos ja confirmados por este usuario:');
      for (final s in shots) {
        b.writeln('Fala: "${s.input}" -> ${jsonEncode(spec.example!(s.value))}');
      }
    }
    b.write(spec.prompt(utterance));
    return b.toString();
  }

  static const _rules =
      'Responda SOMENTE com JSON. Se a fala nao trouxer a informacao, use null. '
      'Nao invente valores.';

  _Spec? _specFor(DialogState state) {
    switch (state) {
      // Texto livre: o parser deterministico ja aceita qualquer fala nao vazia.
      case DialogState.askCompany:
      case DialogState.askMaterials:
      case DialogState.askCharacteristics:
        return null;
      case DialogState.askBatchYield:
        return _Spec(
          schema: _obj({'units': _t(['integer', 'null'])}),
          example: (v) => {'units': _int(v)},
          prompt: (u) => 'Extraia quantas unidades rende UMA producao/lote (numero '
              'inteiro). $_rules\nFala: "$u"\nFormato: {"units": 20}',
          canonical: (j) {
            final v = j['units'];
            return v is num && v == v.roundToDouble() ? '${v.toInt()}' : null;
          },
        );
      case DialogState.askProductionTime:
        return _Spec(
          schema: _obj({'minutes': _t(['integer', 'null'])}),
          example: (v) => {'minutes': _int(v)},
          prompt: (u) => 'Extraia o tempo para produzir um lote, convertido em MINUTOS '
              '(numero inteiro). $_rules\nFala: "$u"\nFormato: {"minutes": 90}',
          canonical: (j) {
            final v = j['minutes'];
            return v is num && v > 0 && v == v.roundToDouble() ? '${v.toInt()} minutos' : null;
          },
        );
      case DialogState.askProduct:
        return _Spec(
          schema: _obj({'product': _t(['string', 'null'])}),
          example: (v) => {'product': '$v'},
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
          example: (v) => {'quantity': _int(v)},
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
          example: (v) => {'reais': (_int(v) ?? 0) / 100}, // valor salvo em centavos
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
          example: (v) => {'percent': _int(v)},
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

  static int? _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v');

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
  _Spec({
    required this.schema,
    required this.prompt,
    required this.canonical,
    this.example,
  });
  final Map<String, Object?> schema;
  final String Function(String utterance) prompt;
  final String? Function(Map<String, Object?> json) canonical;

  /// Valor salvo -> JSON de resposta, para montar exemplos (few-shot). null = sem exemplos.
  final Map<String, Object?> Function(Object value)? example;
}

/// Exemplo recuperado da memoria: fala real do usuario -> valor aceito.
class FewShot {
  const FewShot(this.input, this.value);
  final String input;
  final Object value;
}

/// Contexto local entregue ao LLM (implementado pela memoria do app).
abstract class InterpreterContext {
  /// Resumo do cadastro (empresa, produto, especificacoes), ou null.
  String? profileSummary();

  /// Falas parecidas ja entendidas nesta pergunta.
  List<FewShot> examplesFor(DialogState state, String utterance, {int k = 3});
}

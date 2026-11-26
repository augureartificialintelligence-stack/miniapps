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

  /// Campos que a pessoa pode pedir para mudar, como a IA deve nomea-los -> forma
  /// canonica que o app entende ("corrigir a margem para 40").
  static const _editFields = <String, String>{
    'empresa': 'a empresa',
    'ramo': 'o ramo',
    'produto': 'o produto',
    'ingredientes': 'os ingredientes',
    'rendimento': 'o rendimento',
    'tempo': 'o tempo',
    'caracteristicas': 'as características',
    'quantidade': 'a quantidade',
    'custo': 'o custo',
    'margem': 'a margem',
    'embalagem': 'a embalagem',
    'frete': 'o frete',
    'gas': 'o gás',
    'pro-labore': 'o pró-labore',
    'outros custos': 'os outros custos',
  };

  static const _commands = {
    'voltar': 'voltar',
    'repetir': 'repetir',
    'recomecar': 'recomeçar',
    'detalhar custo': 'detalhar custo',
    'ajuda': 'ajuda',
  };

  /// Fala inesperada no momento (o app nao entendeu): a IA diz se a pessoa quer MUDAR um
  /// dado, dar um COMANDO, ou se e resposta da pergunta atual. Devolve a frase canonica
  /// ("corrigir a margem para 40", "corrigir o preço da farinha", "voltar") ou null
  /// (resposta da pergunta atual / nao entendeu). O app valida tudo como sempre.
  Future<String?> interpretIntent(String utterance, String currentQuestion,
      {List<String> ingredients = const []}) async {
    if (!_llm.isReady || utterance.trim().isEmpty) return null;
    final schema = _obj({
      'intencao': {
        'type': 'string',
        'enum': ['mudar', 'comando', 'resposta', 'nada'],
      },
      'campo': _t(['string', 'null']),
      'valor': _t(['string', 'null']),
      'comando': _t(['string', 'null']),
    });
    final b = StringBuffer();
    final profile = context?.profileSummary();
    if (profile != null && profile.isNotEmpty) b.writeln('Cadastro: $profile');
    b
      ..writeln('Pergunta atual do app: "$currentQuestion"')
      ..writeln('Campos que a pessoa pode mudar: ${_editFields.keys.join(', ')}'
          '${ingredients.isEmpty ? '' : ', ou preço/quantidade de: ${ingredients.join(', ')}'}.')
      ..writeln('Comandos: ${_commands.keys.join(', ')}.')
      ..writeln('A pessoa disse algo que o app nao esperava. Se ela quer mudar ou corrigir um '
          'dado, responda {"intencao":"mudar","campo":"<campo>","valor":"<valor novo ou null>"}. '
          'Para preço ou quantidade de um ingrediente, use campo "preço de <ingrediente>" ou '
          '"quantidade de <ingrediente>". Se e um comando, {"intencao":"comando",'
          '"comando":"<comando>"}. Se e resposta da pergunta atual, {"intencao":"resposta"}. '
          'Se nao der para entender, {"intencao":"nada"}. $_rules')
      ..write('Fala: "${utterance.trim()}"');
    try {
      final j = _extractJson(await _llm.complete(b.toString(), jsonSchema: schema, maxTokens: 64));
      if (j == null) return null;
      return canonicalIntent(j, ingredients: ingredients);
    } catch (_) {
      return null;
    }
  }

  /// Pergunta livre da pessoa ("qual a diferenca entre fermento quimico e biologico?"):
  /// resposta curta da IA usando so os dados do app. null = sem IA ou nao soube.
  Future<String?> answerQuestion(String question, String appData) async {
    if (!_llm.isReady || question.trim().isEmpty) return null;
    final schema = _obj({'resposta': _t(['string', 'null'])});
    final prompt = 'Voce e o assistente de um app de precificacao para pequenos negocios. '
        'Responda a pergunta da pessoa em portugues do Brasil, em no maximo duas frases '
        'curtas e simples. Use os dados do app quando a pergunta for sobre eles. NUNCA '
        'invente precos, quantidades ou valores que nao estejam nos dados. Se nao souber, '
        'responda null.\n'
        'Dados do app: ${appData.isEmpty ? '(nenhum ainda)' : appData}\n'
        'Pergunta: "${question.trim()}"\n'
        'Formato: {"resposta": "texto"}';
    try {
      final j = _extractJson(await _llm.complete(prompt, jsonSchema: schema, maxTokens: 96));
      final v = j?['resposta'];
      return v is String && v.trim().isNotEmpty && v != 'null' ? v.trim() : null;
    } catch (_) {
      return null;
    }
  }

  /// JSON da IA -> frase que o app entende. Campo ou comando fora da lista = null.
  static String? canonicalIntent(Map<String, Object?> j, {List<String> ingredients = const []}) {
    final intent = j['intencao'];
    String? str(Object? v) => v is String && v.trim().isNotEmpty && v != 'null' ? v.trim() : null;
    String norm(String s) => s
        .toLowerCase()
        .replaceAll(RegExp('[áàâã]'), 'a')
        .replaceAll(RegExp('[éê]'), 'e')
        .replaceAll('í', 'i')
        .replaceAll(RegExp('[óôõ]'), 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ç', 'c');
    if (intent == 'comando') {
      final c = str(j['comando']);
      return c == null ? null : _commands[norm(c)];
    }
    if (intent != 'mudar') return null;
    final campo = str(j['campo']);
    final valor = str(j['valor']);
    if (campo == null) return null;
    final f = norm(campo);
    // Preco/quantidade de um ingrediente: "corrigir o preço da farinha para 6 reais o quilo".
    final ing = RegExp(r'^(preco|valor|quantidade)\s+(de|da|do|das|dos)\s+(.+)$').firstMatch(f);
    if (ing != null) {
      final name = ing[3]!;
      if (ingredients.isNotEmpty && !ingredients.any((i) => norm(i).contains(name) || name.contains(norm(i)))) {
        return null;
      }
      final what = ing[1] == 'quantidade' ? 'a quantidade' : 'o preço';
      return 'corrigir $what de $name${valor == null ? '' : ' para $valor'}';
    }
    final label = _editFields[f] ?? _editFields[f.replaceAll(' ', '-')];
    if (label == null) return null;
    return 'corrigir $label${valor == null ? '' : ' para $valor'}';
  }

  static const _rules =
      'Responda SOMENTE com JSON. Se a fala nao trouxer a informacao, use null. '
      'Nao invente valores.';

  _Spec? _specFor(DialogState state) {
    switch (state) {
      // Texto livre: o parser deterministico ja aceita qualquer fala nao vazia.
      case DialogState.askCompany:
      case DialogState.askSector:
      case DialogState.askMaterials:
      case DialogState.askCharacteristics:
      // Entrevista de custo: parsers proprios (quantidades e precos).
      case DialogState.costDetail:
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
      case DialogState.askReuse:
      case DialogState.offerDetail:
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

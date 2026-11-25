/// Interpretacao local de fala em pt-BR: numeros, dinheiro, sim/nao, comandos.
/// Deterministico; serve de base e de fallback quando nao ha LLM local.
String normalizePt(String s) {
  const from = 'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ';
  const to = 'aaaaaeeeeiiiiooooouuuucAAAAAEEEEIIIIOOOOOUUUUC';
  final b = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    final i = from.indexOf(ch);
    b.write(i >= 0 ? to[i] : ch);
  }
  return b.toString().toLowerCase().trim();
}

const _units = {
  'zero': 0, 'um': 1, 'uma': 1, 'dois': 2, 'duas': 2, 'tres': 3, 'quatro': 4,
  'cinco': 5, 'seis': 6, 'sete': 7, 'oito': 8, 'nove': 9, 'dez': 10,
  'onze': 11, 'doze': 12, 'treze': 13, 'catorze': 14, 'quatorze': 14,
  'quinze': 15, 'dezesseis': 16, 'dezessete': 17, 'dezoito': 18, 'dezenove': 19,
};
const _tens = {
  'vinte': 20, 'trinta': 30, 'quarenta': 40, 'cinquenta': 50, 'sessenta': 60,
  'setenta': 70, 'oitenta': 80, 'noventa': 90,
};
const _hundreds = {
  'cem': 100, 'cento': 100, 'duzentos': 200, 'duzentas': 200, 'trezentos': 300,
  'trezentas': 300, 'quatrocentos': 400, 'quatrocentas': 400,
  'quinhentos': 500, 'quinhentas': 500, 'seiscentos': 600, 'seiscentas': 600,
  'setecentos': 700, 'setecentas': 700, 'oitocentos': 800, 'oitocentas': 800,
  'novecentos': 900, 'novecentas': 900,
};

/// Converte numero por extenso (0..999.999) em int. Retorna null se nao houver numero.
int? _wordsToInt(List<String> words) {
  var total = 0;
  var current = 0;
  var found = false;
  for (final w in words) {
    if (w == 'e') continue;
    if (_units.containsKey(w)) {
      current += _units[w]!;
      found = true;
    } else if (_tens.containsKey(w)) {
      current += _tens[w]!;
      found = true;
    } else if (_hundreds.containsKey(w)) {
      current += _hundreds[w]!;
      found = true;
    } else if (w == 'mil') {
      total += (current == 0 ? 1 : current) * 1000;
      current = 0;
      found = true;
    } else if (found) {
      break; // numero terminou
    }
  }
  return found ? total + current : null;
}

/// Expressoes que o parser simples NAO sabe interpretar ("duas dezenas", "meio",
/// "meia duzia"). Em vez de ler so o primeiro numero e errar em silencio, recusamos:
/// o fluxo reprompta ou delega ao LLM local (fase 2).
final _ambiguous =
    RegExp(r'\b(dezenas?|duzias?|centenas?|meio|meia|metade|milhao|milhoes)\b');

/// Extrai um inteiro da fala: "20", "vinte", "vinte e cinco", "1.500".
int? parseInteger(String input) {
  final t = normalizePt(input);
  if (_ambiguous.hasMatch(t)) return null;
  final digits = RegExp(r'\d+(?:\.\d{3})*').firstMatch(t);
  if (digits != null) {
    return int.tryParse(digits.group(0)!.replaceAll('.', ''));
  }
  return _wordsToInt(t.split(RegExp(r'\s+')));
}

/// Extrai dinheiro em CENTAVOS: "12,50", "R$ 30", "doze reais e cinquenta",
/// "trinta e cinco reais", "50 centavos".
int? parseMoneyCents(String input) {
  final t = normalizePt(input).replaceAll('r\$', ' ');
  if (_ambiguous.hasMatch(t)) return null;
  // 12,50 | 12.50 (virgula/ponto decimal com 1-2 casas)
  final dec = RegExp(r'(\d+(?:\.\d{3})*)[,.](\d{1,2})(?!\d)').firstMatch(t);
  if (dec != null) {
    final reais = int.parse(dec.group(1)!.replaceAll('.', ''));
    final c = dec.group(2)!.padRight(2, '0');
    return reais * 100 + int.parse(c);
  }
  // "<n> reais [e <m> [centavos]]" por extenso ou digitos
  final parts = t.split(RegExp(r'\s*\breais?\b\s*'));
  if (t.contains(RegExp(r'\breais?\b'))) {
    final reais = parseInteger(parts.first) ?? 0;
    var cents = 0;
    if (parts.length > 1) {
      final rest = parts[1].replaceAll(RegExp(r'\bcentavos?\b'), ' ');
      cents = parseInteger(rest) ?? 0;
      if (cents > 99) return null;
    }
    return reais * 100 + cents;
  }
  if (t.contains(RegExp(r'\bcentavos?\b'))) {
    return parseInteger(t);
  }
  final n = parseInteger(t);
  return n == null ? null : n * 100;
}

/// Extrai percentual: "30", "trinta por cento", "30%".
int? parsePercent(String input) => parseInteger(input);

enum YesNo { yes, no }

YesNo? parseYesNo(String input) {
  final t = normalizePt(input);
  final words = t.split(RegExp(r'[^a-z]+')).where((w) => w.isNotEmpty).toSet();
  const yes = {'sim', 'isso', 'certo', 'correto', 'confirmo', 'ok', 'pode', 'claro', 'positivo'};
  const no = {'nao', 'errado', 'incorreto', 'negativo', 'corrigir'};
  if (words.any(no.contains)) return YesNo.no;
  if (words.any(yes.contains)) return YesNo.yes;
  return null;
}

enum Command { repeat, restart, back, help }

Command? parseCommand(String input) {
  final t = normalizePt(input);
  if (RegExp(r'\b(repete|repetir|de novo|outra vez)\b').hasMatch(t) &&
      !t.contains('comecar')) {
    return Command.repeat;
  }
  if (RegExp(r'\b(recomecar|reiniciar|comecar de novo|zerar)\b').hasMatch(t)) {
    return Command.restart;
  }
  if (RegExp(r'\b(voltar|volta|anterior)\b').hasMatch(t)) return Command.back;
  if (RegExp(r'\b(ajuda|socorro|nao entendi)\b').hasMatch(t)) return Command.help;
  return null;
}

/// Nome do produto: remove prefixos comuns ("vender", "quero vender", "e") e quantidade.
String? parseProductName(String input) {
  var t = input.trim();
  if (t.isEmpty) return null;
  t = t.replaceFirst(
      RegExp(r'^(eu\s+)?(quero|vou|preciso)?\s*(vender|fazer|produzir)\s+',
          caseSensitive: false),
      '');
  t = t.replaceFirst(RegExp(r'^(o|a|os|as|um|uma)\s+', caseSensitive: false), '');
  t = t.replaceAll(RegExp(r'[.!?]+$'), '').trim();
  return t.isEmpty ? null : t;
}

// ---------------------------------------------------------------------------
// Triagem: empresa, especificacoes de producao.
// ---------------------------------------------------------------------------

/// true quando a pessoa quer pular uma pergunta opcional ("pular", "nao sei", "nenhuma").
/// So vale para a fala INTEIRA: "sem acucar" e uma caracteristica, nao um pulo.
bool isSkip(String input) {
  final t = normalizePt(input).replaceAll(RegExp(r'[^a-z ]'), '').trim();
  return RegExp(r'^(pode\s+)?(pular|pula|passar|proxima)$|'
          r'^(nenhum|nenhuma|nada|nao tem|nao tenho|nao sei|sem nome|nao tem nome)$')
      .hasMatch(t);
}

/// Remove pontuacao final e espacos.
String _clean(String s) => s.replaceAll(RegExp(r'[.!?]+$'), '').trim();

/// Primeira letra de cada palavra em maiuscula (exceto conectivos). O STT costuma
/// devolver tudo minusculo; nome de empresa fica melhor capitalizado.
String titleCasePt(String s) {
  const small = {'de', 'da', 'do', 'das', 'dos', 'e', 'a', 'o'};
  final words = s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  return [
    for (var i = 0; i < words.length; i++)
      (i > 0 && small.contains(words[i].toLowerCase()))
          ? words[i].toLowerCase()
          : words[i][0].toUpperCase() + words[i].substring(1),
  ].join(' ');
}

/// Nome da empresa: "minha empresa se chama doces da ana" -> "Doces da Ana".
String? parseCompanyName(String input) {
  var t = _clean(input);
  t = t.replaceFirst(
      RegExp(
          r'^((o\s+)?nome\s+(da|do|e|é)\s+(minha\s+|meu\s+)?(empresa|loja|marca|negocio|negócio)\s+(e|é)\s+|'
          r'(a\s+|o\s+)?(minha|meu)\s+(empresa|loja|marca|negocio|negócio)\s+(se\s+chama|chama|e|é)\s+|'
          r'(o\s+nome\s+(e|é)|se\s+chama|chama|(e|é)\s+(a|o))\s+)',
          caseSensitive: false),
      '');
  t = t.trim();
  return t.isEmpty ? null : titleCasePt(t);
}

/// Materiais/ingredientes (texto livre): tira "e feito de", "eu uso", "leva".
String? parseMaterials(String input) {
  var t = _clean(input);
  t = t.replaceFirst(
      RegExp(
          r'^((ele|ela)\s+)?((e|é)\s+)?(feit[oa]s?\s+(de|com)|(eu\s+)?(uso|usamos|uso\s+de)|levam?|vai|vao|vão|tem)\s+',
          caseSensitive: false),
      '');
  t = t.trim();
  return t.isEmpty ? null : t;
}

/// Caracteristicas (texto livre): tamanho, peso, sabor, cor.
String? parseCharacteristics(String input) {
  var t = _clean(input);
  t = t.replaceFirst(RegExp(r'^((ele|ela)\s+)?(e|é|tem)\s+', caseSensitive: false), '');
  t = t.trim();
  return t.isEmpty ? null : t;
}

/// Rendimento do lote: "uma fornada rende vinte" -> 20 (le o numero DEPOIS do verbo,
/// para nao pegar o "uma" de "uma fornada").
int? parseBatchYield(String input) {
  final t = normalizePt(input);
  final verb = RegExp(r'\b(rende|rendem|faz|fazem|sai|saem|produz|produzem|da|dao)\b')
      .firstMatch(t);
  final tail = verb != null ? t.substring(verb.end) : t;
  return parseInteger(tail);
}

/// Minutos por unidade de tempo reconhecida.
int? _unitMinutes(String w) {
  if (RegExp(r'^(minutos?|min)$').hasMatch(w)) return 1;
  if (RegExp(r'^(horas?|h)$').hasMatch(w)) return 60;
  if (RegExp(r'^dias?$').hasMatch(w)) return 60 * 24;
  return null;
}

bool _isNumberWord(String w) =>
    _units.containsKey(w) ||
    _tens.containsKey(w) ||
    _hundreds.containsKey(w) ||
    w == 'mil' ||
    RegExp(r'^\d+([.,]\d+)?$').hasMatch(w);

/// Tempo de producao em MINUTOS: "duas horas", "1 hora e meia", "meia hora",
/// "40 minutos", "2h30", "um dia". Exige unidade; numero solto e ambiguo (null).
int? parseDurationMinutes(String input) {
  var t = normalizePt(input);
  // pontuacao que nao e separador decimal ("duas horas." / "ah, uns 40 minutos")
  t = t.replaceAll(RegExp(r'(?<!\d)[.,]|[.,](?!\d)'), ' ');
  t = t.replaceAll(RegExp(r'\bmeia\s+hora\b'), '30 minutos');
  t = t.replaceAllMapped(RegExp(r'(\d)\s*h\s*(\d{1,2})\b'), (m) => '${m[1]} horas ${m[2]} minutos');
  t = t.replaceAllMapped(RegExp(r'(\d)h\b'), (m) => '${m[1]} horas');
  final tokens =
      t.split(RegExp(r'[^a-z0-9,.]+')).where((w) => w.isNotEmpty).toList();

  var total = 0;
  var found = false;
  final number = <String>[];
  for (var i = 0; i < tokens.length; i++) {
    final w = tokens[i];
    final unit = _unitMinutes(w);
    if (unit != null) {
      double? n;
      if (number.isEmpty) {
        n = RegExp(r's$').hasMatch(w) ? null : 1; // "hora" sozinha = 1 hora
      } else if (number.length == 1 && RegExp(r'^\d').hasMatch(number.first)) {
        n = double.tryParse(number.first.replaceAll(',', '.'));
      } else {
        n = _wordsToInt(number)?.toDouble();
      }
      number.clear();
      if (n == null) continue;
      var minutes = n * unit;
      // "... e meia" / "... e meio" logo depois da unidade
      if (i + 2 < tokens.length &&
          tokens[i + 1] == 'e' &&
          (tokens[i + 2] == 'meia' || tokens[i + 2] == 'meio')) {
        minutes += unit / 2;
        i += 2;
      }
      total += minutes.round();
      found = true;
    } else if (_isNumberWord(w)) {
      number.add(w);
    } else if (w == 'e' && number.isNotEmpty) {
      number.add(w); // "vinte e cinco minutos"
    } else {
      number.clear();
    }
  }
  return found && total > 0 ? total : null;
}

// ---------------------------------------------------------------------------
// Custo detalhado: quantidades (g, kg, ml, l, unidades) e precos de embalagem.
// ---------------------------------------------------------------------------

enum MeasureKind { mass, volume, unit }

/// Quantidade em unidade-base: gramas, mililitros ou unidades.
class Measure {
  const Measure(this.amount, this.kind);
  final double amount;
  final MeasureKind kind;

  Map<String, Object?> toJson() => {'amount': amount, 'kind': kind.name};
  static Measure? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = MeasureKind.values.asNameMap()[j['kind']];
    final amount = (j['amount'] as num?)?.toDouble();
    return kind == null || amount == null ? null : Measure(amount, kind);
  }

  @override
  bool operator ==(Object other) =>
      other is Measure && other.amount == amount && other.kind == kind;
  @override
  int get hashCode => Object.hash(amount, kind);
  @override
  String toString() => 'Measure($amount ${kind.name})';
}

/// Fator da unidade para a unidade-base (null = nao e unidade de medida).
(double, MeasureKind)? _measureUnit(String w) {
  if (RegExp(r'^(kg|kgs|quilos?|kilos?|quilogramas?)$').hasMatch(w)) return (1000, MeasureKind.mass);
  if (RegExp(r'^(g|gr|grs|gramas?)$').hasMatch(w)) return (1, MeasureKind.mass);
  if (RegExp(r'^(l|lt|lts|litros?)$').hasMatch(w)) return (1000, MeasureKind.volume);
  if (RegExp(r'^(ml|mililitros?)$').hasMatch(w)) return (1, MeasureKind.volume);
  if (RegExp(r'^duzias?$').hasMatch(w)) return (12, MeasureKind.unit);
  if (RegExp(r'^(unidades?|un|und|unid|pecas?)$').hasMatch(w)) return (1, MeasureKind.unit);
  return null;
}

/// Pontuacao que nao e separador decimal, e "1kg" -> "1 kg".
String _prepNumbers(String input) => normalizePt(input)
    .replaceAll(RegExp(r'(?<!\d)[.,]|[.,](?!\d)'), ' ')
    .replaceAllMapped(RegExp(r'(\d)([a-z])'), (m) => '${m[1]} ${m[2]}');

double? _numberOf(List<String> tokens) {
  final words = tokens.where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return null;
  if (words.length == 1 && RegExp(r'^\d').hasMatch(words.first)) {
    final w = words.first;
    // "1.500" = mil e quinhentos; "1.5" / "1,5" = um e meio.
    if (RegExp(r'^\d{1,3}(\.\d{3})+$').hasMatch(w)) return double.tryParse(w.replaceAll('.', ''));
    return double.tryParse(w.replaceAll(',', '.'));
  }
  return _wordsToInt(words)?.toDouble();
}

/// Quantidade usada/comprada: "2 quilos", "500 g", "meio quilo", "quilo e meio",
/// "1,5 kg", "meio litro", "6 ovos" (numero sem unidade = unidades), "uma duzia".
Measure? parseMeasure(String input) {
  var t = _prepNumbers(input)
      .replaceAll(RegExp(r'\bmeio\s+(quilo|kg|kilo)\b'), '500 gramas')
      .replaceAll(RegExp(r'\bmeio\s+litro\b'), '500 ml')
      .replaceAll(RegExp(r'\bmeia\s+duzia\b'), '6 unidades');
  final tokens = t.split(RegExp(r'[^a-z0-9,.]+')).where((w) => w.isNotEmpty).toList();
  final number = <String>[];
  double? loose; // numero sem unidade
  for (var i = 0; i < tokens.length; i++) {
    final w = tokens[i];
    final unit = _measureUnit(w);
    if (unit != null) {
      double? n;
      if (number.isEmpty) {
        // "o quilo", "a duzia": unidade sozinha no singular = 1
        n = RegExp(r's$').hasMatch(w) && w != 'kgs' ? null : 1;
      } else {
        n = _numberOf(number);
      }
      number.clear();
      if (n == null) continue;
      var amount = n * unit.$1;
      if (i + 2 < tokens.length &&
          tokens[i + 1] == 'e' &&
          (tokens[i + 2] == 'meio' || tokens[i + 2] == 'meia')) {
        amount += unit.$1 / 2;
      }
      return Measure(amount, unit.$2);
    } else if (_isNumberWord(w) || (w == 'e' && number.isNotEmpty)) {
      number.add(w);
    } else {
      if (number.isNotEmpty) loose ??= _numberOf(number);
      number.clear();
    }
  }
  if (number.isNotEmpty) loose ??= _numberOf(number);
  return loose != null && loose > 0 ? Measure(loose, MeasureKind.unit) : null;
}

/// Preco e tamanho da embalagem: "25 reais o pacote de 5 quilos", "8 reais o quilo",
/// "o pacote de 5 kg custa 25 reais", "R$ 3,50 cada", "12 reais a duzia".
/// [pack] e null quando a pessoa disse so o preco (perguntar o tamanho).
({int cents, Measure? pack})? parsePriceWithPackage(String input) {
  final t = _prepNumbers(input).replaceAll(r'r$', r' r$ ');
  final tokens = t.split(RegExp(r'[^a-z0-9,.$]+')).where((w) => w.isNotEmpty).toList();
  final used = <int>{};
  int? cents;

  int? toCents(List<String> numTokens) {
    if (numTokens.length == 1 && RegExp(r'^\d+([.,]\d{1,2})$').hasMatch(numTokens.first)) {
      return (double.parse(numTokens.first.replaceAll(',', '.')) * 100).round();
    }
    final n = _numberOf(numTokens);
    return n == null ? null : (n * 100).round();
  }

  final ri = tokens.indexWhere((w) => w == 'reais' || w == 'real');
  if (ri >= 0) {
    var j = ri - 1;
    final num = <String>[];
    while (j >= 0 && (_isNumberWord(tokens[j]) || (tokens[j] == 'e' && num.isNotEmpty))) {
      num.insert(0, tokens[j]);
      j--;
    }
    while (num.isNotEmpty && num.first == 'e') {
      num.removeAt(0);
      j++;
    }
    cents = toCents(num);
    for (var k = j + 1; k <= ri; k++) {
      used.add(k);
    }
    // "... reais e cinquenta [centavos]"
    if (cents != null && ri + 2 < tokens.length && tokens[ri + 1] == 'e') {
      var k = ri + 2;
      final c = <String>[];
      while (k < tokens.length && (_isNumberWord(tokens[k]) || (tokens[k] == 'e' && c.isNotEmpty))) {
        c.add(tokens[k]);
        k++;
      }
      final cv = _numberOf(c);
      final isCentavos = k < tokens.length && RegExp(r'^centavos?$').hasMatch(tokens[k]);
      final nextIsUnit = k < tokens.length && _measureUnit(tokens[k]) != null;
      if (cv != null && cv < 100 && !nextIsUnit) {
        cents += cv.round();
        for (var x = ri + 1; x < k; x++) {
          used.add(x);
        }
        if (isCentavos) used.add(k);
      }
    }
  } else {
    // Sem "reais": "R$ 25" ou o primeiro numero que nao e seguido de unidade.
    for (var i = 0; i < tokens.length; i++) {
      if (!_isNumberWord(tokens[i])) continue;
      var k = i;
      final num = <String>[];
      while (k < tokens.length && (_isNumberWord(tokens[k]) || (tokens[k] == 'e' && num.isNotEmpty))) {
        num.add(tokens[k]);
        k++;
      }
      if (k < tokens.length && _measureUnit(tokens[k]) != null) {
        i = k;
        continue;
      }
      cents = toCents(num);
      for (var x = i; x < k; x++) {
        used.add(x);
      }
      break;
    }
  }
  if (cents == null || cents <= 0) return null;

  final rest = [
    for (var i = 0; i < tokens.length; i++)
      if (!used.contains(i) && tokens[i] != r'r$') tokens[i],
  ].join(' ');
  var pack = parseMeasure(rest.replaceAll(RegExp(r'\b(um|uma)\s+(pacote|saco|caixa|pote|lata|garrafa|fardo)\b'), r'\2'));
  if (pack == null &&
      RegExp(r'\b(cada|cada um|cada uma|a unidade|por unidade|o pacote|a caixa|a lata)\b')
          .hasMatch(rest)) {
    pack = const Measure(1, MeasureKind.unit);
  }
  return (cents: cents, pack: pack);
}

String _num(double v) {
  final r = (v * 100).round() / 100;
  return r == r.roundToDouble() ? '${r.toInt()}' : '$r'.replaceAll('.', ',');
}

/// Versao falada/exibida da quantidade: 1500 g -> "1,5 quilos", 300 ml -> "300 mililitros".
String speakMeasure(Measure m) {
  switch (m.kind) {
    case MeasureKind.mass:
      if (m.amount >= 1000) {
        final kg = m.amount / 1000;
        return '${_num(kg)} ${kg == 1 ? 'quilo' : 'quilos'}';
      }
      return '${_num(m.amount)} ${m.amount == 1 ? 'grama' : 'gramas'}';
    case MeasureKind.volume:
      if (m.amount >= 1000) {
        final l = m.amount / 1000;
        return '${_num(l)} ${l == 1 ? 'litro' : 'litros'}';
      }
      return '${_num(m.amount)} mililitros';
    case MeasureKind.unit:
      return '${_num(m.amount)} ${m.amount == 1 ? 'unidade' : 'unidades'}';
  }
}

/// Lista de materiais da triagem -> itens: "arroz, feijao e frango" -> [arroz, feijao, frango].
List<String> splitMaterials(String? text) {
  if (text == null) return const [];
  return text
      .split(RegExp(r'\s*(,|;|\be\b|\bmais\b)\s*', caseSensitive: false))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

/// Versao falada da duracao: 150 -> "2 horas e 30 minutos".
String speakDuration(int minutes) {
  final d = minutes ~/ (60 * 24);
  final h = (minutes % (60 * 24)) ~/ 60;
  final m = minutes % 60;
  String part(int n, String one, String many) => '$n ${n == 1 ? one : many}';
  final parts = [
    if (d > 0) part(d, 'dia', 'dias'),
    if (h > 0) part(h, 'hora', 'horas'),
    if (m > 0) part(m, 'minuto', 'minutos'),
  ];
  if (parts.length <= 1) return parts.isEmpty ? '0 minutos' : parts.first;
  return '${parts.sublist(0, parts.length - 1).join(', ')} e ${parts.last}';
}

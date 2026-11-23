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

/// Extrai um inteiro da fala: "20", "vinte", "vinte e cinco", "1.500".
int? parseInteger(String input) {
  final t = normalizePt(input);
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
    final c = parseInteger(t);
    return c == null ? null : c;
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

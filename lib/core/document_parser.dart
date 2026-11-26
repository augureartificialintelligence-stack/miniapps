import 'pt_br_parser.dart';

/// Texto lido de uma foto: receita (ingredientes e quantidades) ou compra (nota,
/// cupom fiscal, lista de precos).
enum DocKind { recipe, purchase }

/// Ingrediente de uma receita: nome, quanto se usa e a parte do produto (massa,
/// recheio...), quando a receita tem secoes.
class RecipeItem {
  const RecipeItem(this.name, this.used, {this.part});
  final String name;
  final Measure? used;
  final String? part;

  @override
  bool operator ==(Object other) =>
      other is RecipeItem && other.name == name && other.used == used && other.part == part;
  @override
  int get hashCode => Object.hash(name, used, part);
  @override
  String toString() => 'RecipeItem($name, $used, $part)';
}

/// Item de uma compra: nome (como esta na nota), preco pago e tamanho da embalagem.
class PurchaseItem {
  const PurchaseItem(this.name, this.cents, this.pack);
  final String name;
  final int cents;
  final Measure? pack;

  @override
  bool operator ==(Object other) =>
      other is PurchaseItem &&
      other.name == name &&
      other.cents == cents &&
      other.pack == pack;
  @override
  int get hashCode => Object.hash(name, cents, pack);
  @override
  String toString() => 'PurchaseItem($name, $cents, $pack)';
}

final _money = RegExp(r'(?:r\$\s*)?(\d{1,5}(?:\.\d{3})*,\d{2})(?!\d)', caseSensitive: false);

/// Receita ou compra? Conta sinais de cada tipo no texto.
DocKind classifyDocument(String text) {
  final t = normalizePt(text);
  var purchase = 0, recipe = 0;
  purchase += _money.allMatches(text).length * 2;
  if (RegExp(r'\b(total|subtotal|cnpj|cpf|cupom|nota fiscal|nfc|troco|pagamento|'
          r'cartao|debito|credito|pix|valor|qtd|qtde|vl\b|un\b|item)')
      .hasMatch(t)) {
    purchase += 4;
  }
  recipe += RegExp(r'\b(xicaras?|colher|colheres|pitada|a gosto|modo de preparo|'
          r'ingredientes|rendimento|rende|forno|massa|recheio|cobertura|misture|bata|asse)\b')
      .allMatches(t)
      .length *
      2;
  recipe += RegExp(r'^\s*[-•*]?\s*(\d+([.,/]\d+)?|½|¼|¾|uma?|duas|tres)\s', multiLine: true)
      .allMatches(t)
      .length;
  return purchase > recipe ? DocKind.purchase : DocKind.recipe;
}

/// Titulos de secao de receita que viram "parte" do produto.
final _section = RegExp(
    r'^\s*(?:para\s+(?:a|o)\s+)?(massa|recheio|cobertura|calda|creme|base|ganache|'
    r'decoracao|montagem|molho|farofa|glace|glacê|crosta|topping)s?\b\s*:?\s*$',
    caseSensitive: false);

final _stopRecipe = RegExp(
    r'^\s*(modo de preparo|preparo|como fazer|rendimento|rende|tempo de preparo|dicas?)\b',
    caseSensitive: false);

/// Extrai ingredientes de uma receita: "2 xicaras de farinha de trigo",
/// "200 g de manteiga", "3 ovos", "1 lata de leite condensado (395 g)".
/// Titulos "Massa:", "Recheio:", "Cobertura:" viram a parte de cada ingrediente.
List<RecipeItem> parseRecipe(String text) {
  final items = <RecipeItem>[];
  String? part;
  for (var raw in text.split(RegExp(r'\r?\n'))) {
    raw = raw.trim();
    if (raw.isEmpty) continue;
    final sec = _section.firstMatch(normalizePt(raw));
    if (sec != null) {
      final p = sec.group(1)!;
      part = p[0].toUpperCase() + p.substring(1);
      continue;
    }
    if (_stopRecipe.hasMatch(normalizePt(raw))) {
      part = null;
      // Depois do "modo de preparo" nao ha mais ingredientes.
      if (RegExp(r'preparo|como fazer', caseSensitive: false).hasMatch(normalizePt(raw))) break;
      continue;
    }
    final line = raw.replaceFirst(RegExp(r'^[-•*·▪>]+\s*'), '');
    final item = _recipeLine(line, part);
    if (item != null) items.add(item);
  }
  return items;
}

/// Quantidade + medida no comeco da linha ("1 e 1/2 xicara de", "2 colheres de sopa de",
/// "1 lata de"). O nome do ingrediente e o que vem depois.
final _qtyPrefix = RegExp(
    r'^\s*(?:(?:[\d½¼¾⅓/.,]+|uma?|duas|dois|tres|meia|meio)'
    r'(?:\s+e\s+(?:[\d½¼¾⅓/.,]+|meia|meio))?\s*)?'
    r'(?:(?:xicaras?(?:\s+de\s+cha)?|xic\.?|colher(?:es)?\s+de\s+(?:sopa|cha|sobremesa)|'
    r'colher(?:es|inhas?)?|copos?(?:\s+americanos?)?|kg|g|gr|gramas?|quilos?|ml|l|litros?|'
    r'latas?|caixas?|caixinhas?|pacotes?|potes?|unidades?|un|duzias?|pitadas?|dentes?|'
    r'fatias?|xicaras?)\b\s*)?'
    r'(?:(?:de|do|da)\s+)?');

RecipeItem? _recipeLine(String line, String? part) {
  // "colher (sopa)" / "xicara (cha)": o parenteses faz parte da medida.
  line = line.replaceAllMapped(
      RegExp(r'\(\s*(ch[aá]|sopa|sobremesa)\s*\)', caseSensitive: false), (m) => 'de ${m[1]}');
  // Peso entre parenteses vale mais que a medida caseira: "1 lata (395 g)".
  final paren = RegExp(r'\(([^)]*)\)').firstMatch(line);
  Measure? used;
  if (paren != null) {
    final m = parseMeasure(paren.group(1)!);
    if (m != null && m.kind != MeasureKind.unit) used = m;
  }
  final clean = line.replaceAll(RegExp(r'\([^)]*\)'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final hasQty = RegExp(r'^\s*([\d½¼¾⅓]|(uma?|duas|dois|tres|meia|meio)\s)', caseSensitive: false)
      .hasMatch(clean);
  if (hasQty) used ??= parseMeasure(clean);

  // Titulo da receita ou cabecalho ("BOLO DE CHOCOLATE", "Ingredientes"): nao e item.
  final letters = clean.replaceAll(RegExp(r'[^A-Za-zÀ-ú]'), '');
  if (!hasQty &&
      (RegExp(r'^ingredientes?\s*:?$', caseSensitive: false).hasMatch(normalizePt(clean)) ||
          (letters.isNotEmpty && letters == letters.toUpperCase()))) {
    return null;
  }

  // Nome: o que vem depois da quantidade e da medida. normalizePt preserva o tamanho do
  // texto, entao o indice vale para o texto original (com acentos).
  final qty = _qtyPrefix.firstMatch(normalizePt(clean));
  var name = hasQty && qty != null ? clean.substring(qty.end) : clean;
  name = name
      .replaceFirst(RegExp(r'^(uma?|duas|dois|tres|meia|meio)\s+', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*(a gosto|opcional|aproximadamente|aprox\.?|peneirad[ao]s?|'
              r'derretid[ao]s?|em temperatura ambiente|picad[ao]s?|ralad[ao]s?$)\s*',
              caseSensitive: false), ' ')
      .replaceAll(RegExp(r'[,;.:]+$'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (name.length < 2 || !RegExp(r'[a-zA-ZÀ-ú]').hasMatch(name)) return null;
  // Linha sem nenhuma quantidade e longa demais = frase de instrucao, nao ingrediente.
  if (used == null && name.split(' ').length > 6) return null;
  return RecipeItem(name[0].toLowerCase() + name.substring(1), used, part: part);
}

final _skipPurchase = RegExp(
    r'\b(total|subtotal|troco|desconto|acrescimo|cnpj|cpf|ie|im|cupom|nota|nfc|nfce|sat|'
    r'pagamento|cartao|debito|credito|pix|dinheiro|valor pago|tributos|lei|data|hora|'
    r'caixa|operador|consumidor|endereco|cep|tel|fone|obrigado|volte)\b',
    caseSensitive: false);

/// Extrai itens de uma compra (nota, cupom, lista de precos):
/// "FARINHA TRIGO DONA BENTA 5KG 1 UN 25,90" -> farinha trigo dona benta, R$ 25,90, 5 kg.
/// Quando ha quantidade x preco unitario, usa o total da linha.
List<PurchaseItem> parsePurchase(String text) {
  final items = <PurchaseItem>[];
  for (var line in text.split(RegExp(r'\r?\n'))) {
    line = line.trim();
    if (line.isEmpty || _skipPurchase.hasMatch(normalizePt(line))) continue;
    final prices = _money.allMatches(line).toList();
    if (prices.isEmpty) continue;
    // "2 UN X 5,49 10,98": o tamanho da embalagem e de UMA unidade, entao vale o preco
    // unitario (primeiro valor). Sem quantidade x preco, o ultimo valor e o do item.
    final multi = prices.length >= 2 &&
        RegExp(r'\b\d+([.,]\d+)?\s*(un|und|pc|pct|kg)?\s*x\s', caseSensitive: false)
            .hasMatch(line.substring(0, prices.first.start + 1));
    final cents = _toCents((multi ? prices.first : prices.last).group(1)!);
    if (cents == null || cents <= 0) continue;

    var name = line.substring(0, prices.first.start);
    final pack = _packIn(name);
    name = name
        .replaceAll(RegExp(r'\bc\s*/\s*\d+', caseSensitive: false), ' ') // "C/12"
        .replaceAll(RegExp(r'^\s*\d{1,4}\s+'), '') // numero do item
        .replaceAll(RegExp(r'\b\d{6,}\b'), ' ') // codigo de barras
        .replaceAll(RegExp(r'\b\d+([.,]\d+)?\s*(kg|g|gr|ml|l|lt|un|und|x)\b', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\b(un|und|pct|cx|lt|kg|x)\b', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'[^A-Za-zÀ-ú ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (name.length < 2) continue;
    items.add(PurchaseItem(name.toLowerCase(), cents, pack));
  }
  return items;
}

int? _toCents(String v) {
  final d = double.tryParse(v.replaceAll('.', '').replaceAll(',', '.'));
  return d == null ? null : (d * 100).round();
}

/// Tamanho da embalagem escrito no nome do produto ("5KG", "395G", "1L", "C/12").
Measure? _packIn(String name) {
  final n = normalizePt(name);
  final m = RegExp(r'(\d+(?:[.,]\d+)?)\s*(kg|g|gr|ml|l|lt)\b').firstMatch(n);
  if (m != null) return parseMeasure('${m[1]} ${m[2]}');
  final dz = RegExp(r'\b(?:c/|com\s+)(\d+)\b').firstMatch(n);
  if (dz != null) return Measure(double.parse(dz[1]!), MeasureKind.unit);
  if (RegExp(r'\bduzia\b').hasMatch(n)) return const Measure(12, MeasureKind.unit);
  return null;
}

const _ingredientStop = {
  'de', 'da', 'do', 'das', 'dos', 'em', 'com', 'para', 'tipo', 'sem', 'e', 'a', 'o',
};

Set<String> _ingredientTokens(String s) => normalizePt(s)
    .split(RegExp(r'[^a-z]+'))
    .where((w) => w.length > 2 && !_ingredientStop.contains(w))
    .map((w) => w.endsWith('s') && w.length > 3 ? w.substring(0, w.length - 1) : w)
    .toSet();

/// O item da compra e o ingrediente da receita sao a mesma coisa? A nota traz marca e
/// abreviacoes ("FARINHA TRIGO DONA BENTA"), entao basta a maior parte das palavras do
/// ingrediente aparecer no nome comprado (ou o contrario).
bool sameIngredient(String recipeName, String purchaseName) {
  final a = _ingredientTokens(recipeName), b = _ingredientTokens(purchaseName);
  if (a.isEmpty || b.isEmpty) return false;
  final inter = a.intersection(b).length;
  final small = a.length < b.length ? a.length : b.length;
  return inter / small >= 0.6 && inter >= 1;
}

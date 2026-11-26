import 'pt_br_parser.dart';

/// Como o produto e vendido: por pedaco, fatia, pote... e o que e o lote (o bolo
/// inteiro, a torta, a forma). Muda as frases: "12 pedacos de bolo de cenoura",
/// "preco do pedaco", "o bolo inteiro, com 12 pedacos".
class UnitWords {
  const UnitWords(this.one, this.many, {required this.feminine, this.batch, this.batchFeminine = false});

  /// Unidade generica (sem unidade de venda dita): mantem as frases de antes.
  static const generic = UnitWords('unidade', 'unidades', feminine: true);

  final String one;
  final String many;
  final bool feminine;

  /// Nome do lote ("bolo", "torta", "forma"); null = "lote".
  final String? batch;
  final bool batchFeminine;

  bool get isGeneric => one == 'unidade';

  /// "1 pedaço", "12 pedaços".
  String count(int n) => '$n ${n == 1 ? one : many}';

  /// "o pedaço", "a fatia".
  String get theOne => '${feminine ? 'a' : 'o'} $one';

  /// "do pedaço", "da fatia".
  String get ofTheOne => '${feminine ? 'da' : 'do'} $one';

  /// "cada pedaço".
  String get eachOne => 'cada $one';

  /// "Quantos pedaços", "Quantas fatias".
  String get howMany => '${feminine ? 'Quantas' : 'Quantos'} $many';

  /// "do lote de 12 unidades" ou "do bolo inteiro (12 pedaços)".
  String ofBatch(int y) => batch == null
      ? 'do lote de ${count(y)}'
      : '${batchFeminine ? 'da' : 'do'} $batch ${batchFeminine ? 'inteira' : 'inteiro'} (${count(y)})';

  /// "lote" ou "bolo".
  String get batchName => batch ?? 'lote';

  /// "cada lote" ou "cada bolo".
  String get eachBatch => 'cada $batchName';
}

/// Unidades de venda reconhecidas: forma sem acento (plural e singular) -> (singular,
/// plural, feminino).
const _units = <String, (String, String, bool)>{
  'pedaco': ('pedaço', 'pedaços', false),
  'pedacos': ('pedaço', 'pedaços', false),
  'fatia': ('fatia', 'fatias', true),
  'fatias': ('fatia', 'fatias', true),
  'porcao': ('porção', 'porções', true),
  'porcoes': ('porção', 'porções', true),
  'pote': ('pote', 'potes', false),
  'potes': ('pote', 'potes', false),
  'potinho': ('potinho', 'potinhos', false),
  'potinhos': ('potinho', 'potinhos', false),
  'copo': ('copo', 'copos', false),
  'copos': ('copo', 'copos', false),
  'caixa': ('caixa', 'caixas', true),
  'caixas': ('caixa', 'caixas', true),
  'caixinha': ('caixinha', 'caixinhas', true),
  'caixinhas': ('caixinha', 'caixinhas', true),
  'pacote': ('pacote', 'pacotes', false),
  'pacotes': ('pacote', 'pacotes', false),
  'saquinho': ('saquinho', 'saquinhos', false),
  'saquinhos': ('saquinho', 'saquinhos', false),
  'barra': ('barra', 'barras', true),
  'barras': ('barra', 'barras', true),
  'cone': ('cone', 'cones', false),
  'cones': ('cone', 'cones', false),
  'marmita': ('marmita', 'marmitas', true),
  'marmitas': ('marmita', 'marmitas', true),
  'quentinha': ('quentinha', 'quentinhas', true),
  'quentinhas': ('quentinha', 'quentinhas', true),
};

/// Lotes reconhecidos: forma sem acento -> (nome, feminino).
const _batches = <String, (String, bool)>{
  'bolo': ('bolo', false),
  'torta': ('torta', true),
  'forma': ('forma', true),
  'pudim': ('pudim', false),
  'panela': ('panela', true),
  'fornada': ('fornada', true),
  'assadeira': ('assadeira', true),
  'tabuleiro': ('tabuleiro', false),
  'travessa': ('travessa', true),
  'receita': ('receita', true),
  'lote': ('lote', false),
};

final _unitAlt = _units.keys.join('|');
final _batchAlt = _batches.keys.join('|');
const _num = r'(\d+|uma?|dois|duas|tres|quatro|cinco|seis|sete|oito|nove|dez|onze|doze|'
    r'treze|catorze|quatorze|quinze|dezesseis|dezoito|vinte|trinta|quarenta|cinquenta)';

/// Unidade de venda dita na fala:
/// - "sao 12 pedacos de 1 bolo" / "12 fatias de uma torta" -> pedaco, 12 por bolo;
/// - "cada bolo rende 12 pedacos" / "um bolo da 12 fatias" -> 12 por bolo;
/// - "vendo por pedaco" / "vendo em fatias" -> so a unidade;
/// - "12 pedacos" -> unidade e quantidade (o numero fica para a pergunta atual).
({String one, String many, bool feminine, String? batch, bool batchFeminine, int? perBatch, bool strong})?
    parseSaleUnit(String input) {
  final n = normalizePt(input);
  (String, String, bool)? unit;
  (String, bool)? batch;
  int? perBatch;

  var m = RegExp('\\b$_num\\s+($_unitAlt)\\s+(?:de|do|da|por)\\s+(?:1|um|uma|cada)\\s+($_batchAlt)\\b')
      .firstMatch(n);
  if (m != null) {
    unit = _units[m[2]];
    batch = _batches[m[3]];
    perBatch = parseInteger(m[1]!);
  }
  m ??= RegExp('\\b(?:cada|1|um|uma)\\s+($_batchAlt)\\s+(?:rende|rendem|da|tem|faz|sai|sao|e)\\s+'
          '(?:de\\s+)?$_num\\s+($_unitAlt)\\b')
      .firstMatch(n);
  if (m != null && unit == null) {
    batch = _batches[m[1]];
    perBatch = parseInteger(m[2]!);
    unit = _units[m[3]];
  }
  if (unit == null) {
    // Exige a preposicao: "vendo por pedaco", "vendido em potes" ("quero vender marmitas" e o
    // nome do produto, nao a unidade).
    final v = RegExp('\\b(?:vendo|vender|vende|venda|vendido|vendida)\\s+(?:em|por|no|na|a)\\s+'
            '(?:um|uma)?\\s*($_unitAlt)\\b')
        .firstMatch(n);
    if (v != null) unit = _units[v[1]];
  }
  // "12 pedacos" sozinho e fraco: so vale nas perguntas de quantidade/rendimento
  // (nos ingredientes, "3 potes de doce de leite" nao e unidade de venda).
  final strong = unit != null;
  if (unit == null) {
    final c = RegExp('\\b$_num\\s+($_unitAlt)\\b').firstMatch(n);
    if (c != null) unit = _units[c[2]];
  }
  if (unit == null) return null;
  return (
    one: unit.$1,
    many: unit.$2,
    feminine: unit.$3,
    batch: batch?.$1,
    batchFeminine: batch?.$2 ?? false,
    perBatch: perBatch != null && perBatch > 0 ? perBatch : null,
    strong: strong,
  );
}

/// Unidade guardada no cadastro ("pedaço") -> palavras completas.
UnitWords unitWordsFor(String? saleUnit, String? batchName) {
  if (saleUnit == null) {
    return batchName == null
        ? UnitWords.generic
        : UnitWords('unidade', 'unidades',
            feminine: true, batch: batchName, batchFeminine: _batchFem(batchName));
  }
  final u = _units[normalizePt(saleUnit)] ?? (saleUnit, '${saleUnit}s', saleUnit.endsWith('a'));
  return UnitWords(u.$1, u.$2,
      feminine: u.$3, batch: batchName, batchFeminine: batchName != null && _batchFem(batchName));
}

bool _batchFem(String b) => _batches[normalizePt(b)]?.$2 ?? b.endsWith('a');

import 'pt_br_parser.dart';

/// Ramo do negocio: adapta exemplos e as partes sugeridas para o produto.
class Sector {
  const Sector(this.name, this.keywords, {required this.materials, required this.parts});

  /// Nome exibido e salvo no cadastro.
  final String name;

  /// Palavras que identificam o ramo na fala (texto normalizado, sem acento).
  final String keywords;

  /// Exemplo de materiais/ingredientes ("farinha, ovos e acucar").
  final String materials;

  /// Exemplo de partes do produto ("massa, recheio e cobertura").
  final String parts;
}

const sectors = <Sector>[
  Sector('Confeitaria', r'confeit|doce|bolo|brigadeiro|torta|cupcake|bombo|trufa|pudim|sobremesa',
      materials: 'farinha, ovos e açúcar', parts: 'massa, recheio e cobertura'),
  Sector('Panificação', r'panific|padaria|pao|paes|biscoito|bolacha|rosca',
      materials: 'farinha, fermento e sal', parts: 'massa e cobertura'),
  Sector('Salgados', r'salgad|coxinha|pastel|esfiha|empada|kibe|quibe|pizza|lanche|hamburg',
      materials: 'farinha, frango e óleo', parts: 'massa e recheio'),
  Sector('Marmitas e refeições', r'marmit|refeic|comida|almoco|janta|quentinha|restaurante|prato',
      materials: 'arroz, feijão e frango', parts: 'arroz, feijão, proteína e salada'),
  Sector('Açaí e sorvetes', r'acai|sorvet|gelad|picole|milk ?shake',
      materials: 'polpa, leite e açúcar', parts: 'base, cobertura e acompanhamentos'),
  Sector('Bebidas', r'bebida|suco|cafe|drink|cerveja|vinho|cha\b|smoothie|refresco',
      materials: 'frutas, açúcar e gelo', parts: 'base e cobertura'),
  Sector('Cosméticos e sabonetes', r'cosmet|sabonete|sabao|creme|hidratante|shampoo|perfum|beleza',
      materials: 'glicerina, essência e corante', parts: 'base, essência e embalagem'),
  Sector('Velas e aromas', r'vela|aromatiz|difusor|incenso|home spray',
      materials: 'cera, pavio e essência', parts: 'base, essência e recipiente'),
  // Por ultimo: 'artesanal' tambem aparece em sabonetes, velas e doces.
  Sector('Artesanato', r'artesan|croche|costura|bordad|bijuteria|tricot|tric|macrame|papelaria|biscuit',
      materials: 'tecido, linha e cola', parts: 'estrutura, acabamento e embalagem'),
];

/// Ramo reconhecido na fala ("eu faco bolos" -> Confeitaria), ou null.
Sector? findSector(String? text) {
  if (text == null) return null;
  final t = normalizePt(text);
  for (final s in sectors) {
    if (s.name == text) return s;
    if (RegExp('(${s.keywords})').hasMatch(t)) return s;
  }
  return null;
}

/// Resposta da pergunta do ramo: nome do ramo conhecido, ou o texto dito (capitalizado).
String? parseSector(String input) {
  final s = findSector(input);
  if (s != null) return s.name;
  var t = input.trim().replaceAll(RegExp(r'[.!?]+$'), '');
  t = t.replaceFirst(
      RegExp(r'^((o\s+)?(meu\s+)?ramo\s+(e|é)\s+|(eu\s+)?(trabalho|mexo)\s+com\s+|(e|é)\s+)',
          caseSensitive: false),
      '');
  t = t.trim();
  return t.isEmpty ? null : t[0].toUpperCase() + t.substring(1);
}

/// Exemplos de partes para o ramo (ou um exemplo generico).
String partsExample(String? sector) =>
    findSector(sector)?.parts ?? 'massa, recheio e cobertura';

/// Exemplo de materiais para o ramo (ou um exemplo generico).
String materialsExample(String? sector) =>
    findSector(sector)?.materials ?? 'farinha, ovos e açúcar';

import 'pt_br_parser.dart';

/// Conversao de volume (ml) e unidades para peso (g), por ingrediente.
///
/// Receita costuma vir em volume ("2 xicaras de farinha") e a compra em peso ("farinha
/// 1 kg"). Os valores sao medias de referencia de cozinha brasileira (xicara de 240 ml);
/// quando o ingrediente nao esta na tabela, o app pergunta quanto pesa.

/// Gramas por mililitro. Chaves mais especificas vem antes (a primeira que casar vale).
const _gramsPerMl = <String, double>{
  'farinha de trigo': 0.50, // 1 xicara ~ 120 g
  'farinha de rosca': 0.45,
  'farinha de mandioca': 0.65,
  'farinha de milho': 0.40,
  'farinha de amendoa': 0.42,
  'farinha': 0.50, // sem tipo: considera de trigo
  'acucar mascavo': 0.63, // 1 xicara ~ 150 g
  'acucar demerara': 0.80,
  'acucar de confeiteiro': 0.50,
  'acucar cristal': 0.83,
  'acucar': 0.75, // refinado: 1 xicara ~ 180 g
  'chocolate em po': 0.38, // 1 xicara ~ 90 g
  'chocolate granulado': 0.60,
  'cacau': 0.38,
  'achocolatado': 0.38,
  'amido de milho': 0.50,
  'maisena': 0.50,
  'fuba': 0.50,
  'polvilho': 0.60,
  'aveia': 0.38,
  'coco ralado': 0.33,
  'leite condensado': 1.30,
  'leite em po': 0.50,
  'leite de coco': 1.00,
  'creme de leite': 1.00,
  'leite': 1.03,
  'iogurte': 1.05,
  'requeijao': 1.00,
  'oleo': 0.90,
  'azeite': 0.90,
  'manteiga': 0.95,
  'margarina': 0.95,
  'mel': 1.40,
  'agua': 1.00,
  'arroz': 0.80,
  'feijao': 0.80,
  'sal': 1.20,
  'fermento': 0.90,
  'bicarbonato': 0.90,
  'queijo ralado': 0.40,
  'amendoim': 0.60,
  'castanha': 0.55,
  'nozes': 0.45,
  'uva passa': 0.65,
  'goiabada': 1.10,
  'doce de leite': 1.30,
};

/// Gramas por unidade (media).
const _gramsPerUnit = <String, double>{
  'gema': 20,
  'clara': 30,
  'ovo': 50,
  'dente de alho': 5,
  'alho': 5,
  'cebola': 150,
  'tomate': 120,
  'batata': 150,
  'cenoura': 100,
  'banana': 120,
  'maca': 150,
  'laranja': 180,
  'limao': 80,
  'pao': 50,
};

/// Fator de conversao para gramas de [name] medido em [kind]:
/// gramas por ml (volume) ou gramas por unidade (unidade). Peso = 1. null = desconhecido.
double? gramsFactor(String name, MeasureKind kind) {
  if (kind == MeasureKind.mass) return 1;
  final table = kind == MeasureKind.volume ? _gramsPerMl : _gramsPerUnit;
  final n = ' ${normalizePt(name).replaceAll(RegExp(r'[^a-z ]'), ' ').replaceAll(RegExp(r'\s+'), ' ')} ';
  for (final e in table.entries) {
    // casa palavra inteira, aceitando plural simples ("ovos", "bananas")
    final k = e.key;
    if (n.contains(' $k ') || n.contains(' ${k}s ') || n.contains(' ${k}es ')) return e.value;
  }
  return null;
}

/// Converte [m] para gramas usando o fator conhecido (ou [override], dito pela pessoa).
double? toGrams(String name, Measure m, {double? override}) {
  if (m.kind == MeasureKind.mass) return m.amount;
  final f = override ?? gramsFactor(name, m.kind);
  return f == null ? null : m.amount * f;
}

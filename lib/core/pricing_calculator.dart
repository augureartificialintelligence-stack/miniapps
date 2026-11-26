import 'sale_unit.dart';

/// Calculadora de preco determinística (sem LLM). Todo valor monetario em CENTAVOS (int)
/// para evitar erros de ponto flutuante.
class PricingInput {
  const PricingInput({
    required this.quantity,
    required this.totalCostCents,
    required this.marginPercent,
  });

  /// Unidades a vender (>= 1).
  final int quantity;

  /// Custo total do lote (ingredientes, embalagem, etc.) em centavos.
  final int totalCostCents;

  /// Margem desejada sobre o PRECO de venda, 0..90.
  final int marginPercent;
}

class PricingResult {
  const PricingResult({
    required this.unitCostCents,
    required this.unitPriceCents,
    required this.totalRevenueCents,
    required this.profitCents,
    required this.input,
  });

  final PricingInput input;

  /// Custo por unidade, arredondado para cima.
  final int unitCostCents;

  /// Preco sugerido por unidade, arredondado para cima.
  final int unitPriceCents;

  /// unitPriceCents * quantity.
  final int totalRevenueCents;

  /// totalRevenueCents - custo total.
  final int profitCents;
}

class PricingException implements Exception {
  PricingException(this.message);
  final String message;
  @override
  String toString() => 'PricingException: $message';
}

int _ceilDiv(int a, int b) => (a + b - 1) ~/ b;

/// Preco = custo / (1 - margem). Arredonda sempre para cima, nunca vende abaixo da margem.
PricingResult calculatePricing(PricingInput input) {
  if (input.quantity < 1) {
    throw PricingException('A quantidade deve ser pelo menos 1.');
  }
  if (input.totalCostCents < 0) {
    throw PricingException('O custo nao pode ser negativo.');
  }
  if (input.marginPercent < 0 || input.marginPercent > 90) {
    throw PricingException('A margem deve ficar entre 0% e 90%.');
  }
  final revenueTarget =
      _ceilDiv(input.totalCostCents * 100, 100 - input.marginPercent);
  final unitPrice = _ceilDiv(revenueTarget, input.quantity);
  final revenue = unitPrice * input.quantity;
  return PricingResult(
    input: input,
    unitCostCents: _ceilDiv(input.totalCostCents, input.quantity),
    unitPriceCents: unitPrice,
    totalRevenueCents: revenue,
    profitCents: revenue - input.totalCostCents,
  );
}

/// Formata centavos como "R$ 12,50".
String formatBrl(int cents) {
  final sign = cents < 0 ? '-' : '';
  final abs = cents.abs();
  final reais = abs ~/ 100;
  final cs = (abs % 100).toString().padLeft(2, '0');
  final r = reais.toString();
  final buf = StringBuffer();
  for (var i = 0; i < r.length; i++) {
    if (i > 0 && (r.length - i) % 3 == 0) buf.write('.');
    buf.write(r[i]);
  }
  return '${sign}R\$ $buf,$cs';
}

/// Versao falada ("12 reais e 50 centavos") para o TTS.
String speakBrl(int cents) {
  final reais = cents ~/ 100;
  final cs = cents % 100;
  final rPart = '$reais ${reais == 1 ? 'real' : 'reais'}';
  final cPart = '$cs ${cs == 1 ? 'centavo' : 'centavos'}';
  if (cs == 0) return rPart;
  if (reais == 0) return cPart; // "50 centavos", nao "0 reais e 50 centavos"
  return '$rPart e $cPart';
}

/// Simulacao: a pessoa escolhe o preco ("quero vender por 6 reais") e o app mostra o
/// lucro e a margem REAL desse preco, comparando com o preco sugerido.
class PriceSimulation {
  const PriceSimulation({
    required this.priceCents,
    required this.unitCostCents,
    this.suggestedCents,
    this.batchYield,
  });

  /// Preco por unidade escolhido pela pessoa.
  final int priceCents;

  /// Custo de producao de cada unidade (sem arredondar para cima).
  final int unitCostCents;

  /// Preco sugerido pela margem desejada (para comparar).
  final int? suggestedCents;
  final int? batchYield;

  int get unitProfitCents => priceCents - unitCostCents;

  /// Margem real sobre o preco (mesma definicao da margem pedida no app).
  double get marginPercent => priceCents == 0 ? 0 : unitProfitCents * 100 / priceCents;

  bool get isLoss => unitProfitCents < 0;

  int? get batchRevenueCents => batchYield == null ? null : priceCents * batchYield!;
  int? get batchProfitCents => batchYield == null ? null : unitProfitCents * batchYield!;
}

/// Resumo falado da simulacao de preco.
String speakSimulation(PriceSimulation s, {UnitWords units = UnitWords.generic}) {
  final u = units;
  final b = StringBuffer('Vendendo ${u.theOne} por ${speakBrl(s.priceCents)}: ${u.eachOne} '
      'custa ${speakBrl(s.unitCostCents)} para produzir, ');
  if (s.isLoss) {
    b.write('então você tem prejuízo de ${speakBrl(-s.unitProfitCents)} por ${u.one}. '
        'Atenção: esse preço fica abaixo do custo de produção.');
  } else if (s.unitProfitCents == 0) {
    b.write('então você empata: não tem lucro nem prejuízo.');
  } else {
    b.write('então você lucra ${speakBrl(s.unitProfitCents)} por ${u.one}, uma margem de '
        '${s.marginPercent.round()} por cento.');
  }
  if (s.batchYield != null && !s.isLoss) {
    b.write(' N${u.ofBatch(s.batchYield!).substring(1)}, você recebe ${speakBrl(s.batchRevenueCents!)} '
        'e lucra ${speakBrl(s.batchProfitCents!)}.');
  }
  final sug = s.suggestedCents;
  if (sug != null && sug != s.priceCents) {
    b.write(s.priceCents < sug
        ? ' Esse preço está abaixo do sugerido, que é ${speakBrl(sug)}.'
        : ' Esse preço está acima do sugerido, que é ${speakBrl(sug)}.');
  }
  return b.toString();
}

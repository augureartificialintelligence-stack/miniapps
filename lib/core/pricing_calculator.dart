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
  if (cs == 0) return rPart;
  return '$rPart e $cs ${cs == 1 ? 'centavo' : 'centavos'}';
}

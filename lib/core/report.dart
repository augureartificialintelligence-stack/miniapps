import 'cost_breakdown.dart';
import 'dialog_machine.dart';
import 'pricing_calculator.dart';
import 'pt_br_parser.dart';

/// Resumo do resultado para compartilhar (WhatsApp, e-mail...): ficha do produto,
/// ingredientes com quantidade e custo, custos extras, precos e lucro.
String buildReport(SalesSession s,
    {PricingResult? result, CostBreakdown? costs, PriceSimulation? simulation, DateTime? date}) {
  final u = s.units;
  final b = StringBuffer();
  final d = date ?? DateTime.now();
  final day = '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  b.writeln('*${s.product ?? 'Produto'}*${s.company != null ? ' — ${s.company}' : ''}');
  b.writeln('Cálculo de preço de $day');
  b.writeln();

  final specs = [
    if (s.sector != null) 'Ramo: ${s.sector}',
    if (s.saleUnit != null) 'Vende por: ${u.one}',
    if (s.batchYield != null) 'Rende por ${u.batchName}: ${u.count(s.batchYield!)}',
    if (s.productionMinutes != null) 'Tempo de produção: ${speakDuration(s.productionMinutes!)}',
    if (s.characteristics != null) 'Características: ${s.characteristics}',
  ];
  if (specs.isNotEmpty) {
    b.writeln('*Ficha do produto*');
    for (final l in specs) {
      b.writeln('• $l');
    }
    b.writeln();
  }

  final t = costs;
  if (t != null && t.materials.isNotEmpty) {
    b.writeln('*Ingredientes e custos ${u.ofBatch(t.batchYield ?? s.batchYield ?? 1)}*');
    final parts = t.parts;
    void items(Iterable<MaterialCost> ms) {
      for (final m in ms) {
        final qty = m.used != null ? ' (${speakMeasure(m.used!)})' : '';
        final c = m.costCents != null ? formatBrl(m.costCents!) : 'sem preço';
        b.writeln('• ${m.name}$qty: $c');
      }
    }

    if (parts.isEmpty) {
      items(t.materials);
    } else {
      for (final p in parts) {
        b.writeln('_${p}_ (${formatBrl(t.partCents(p))})');
        items(t.materials.where((m) => m.part == p));
      }
      final rest = t.materials.where((m) => m.part == null);
      if (rest.isNotEmpty) {
        b.writeln('_Outros_');
        items(rest);
      }
    }
    if (t.packagingCents > 0) {
      b.writeln('• Embalagens (${formatBrl(t.packagingPerUnitCents!)} por ${u.one}): '
          '${formatBrl(t.packagingCents)}');
    }
    if ((t.freightCents ?? 0) > 0) b.writeln('• Frete: ${formatBrl(t.freightCents!)}');
    if ((t.wearCents ?? 0) > 0) b.writeln('• Gás, energia e desgaste: ${formatBrl(t.wearCents!)}');
    if ((t.laborCents ?? 0) > 0) {
      b.writeln('• Pró-labore${t.laborHourlyCents != null ? ' (${formatBrl(t.laborHourlyCents!)}/hora)' : ''}: '
          '${formatBrl(t.laborCents!)}');
    }
    if ((t.otherCents ?? 0) > 0) b.writeln('• Outros custos: ${formatBrl(t.otherCents!)}');
    b.writeln('Custo do ${u.batchName}: *${formatBrl(t.batchCents)}*');
    if (t.unitCostCents != null) b.writeln('Custo de produção ${u.ofTheOne}: ${formatBrl(t.unitCostCents!)}');
    b.writeln();
  }

  // Preco: da tabela detalhada (completa) ou do calculo principal.
  final complete = t != null && t.unitPriceCents != null && t.materials.every((m) => m.costCents != null);
  b.writeln('*Preço*');
  if (complete) {
    b.writeln('Margem: ${t.marginPercent}%');
    b.writeln('Preço ${u.ofTheOne}: *${formatBrl(t.unitPriceCents!)}*');
    b.writeln('Preço ${u.ofBatch(t.batchYield!)}: *${formatBrl(t.batchPriceCents!)}*');
    b.writeln('Lucro por ${u.one}: ${formatBrl(t.unitProfitCents!)}');
    b.writeln('Lucro ${u.ofBatch(t.batchYield!)}: ${formatBrl(t.batchProfitCents!)}');
  } else if (result != null) {
    final y = s.batchYield;
    b.writeln('Custo informado: ${formatBrl(result.input.totalCostCents)} para ${u.count(result.input.quantity)}');
    b.writeln('Margem: ${result.input.marginPercent}%');
    b.writeln('Custo de produção ${u.ofTheOne}: ${formatBrl(result.unitCostCents)}');
    b.writeln('Preço ${u.ofTheOne}: *${formatBrl(result.unitPriceCents)}*');
    if (y != null && y > 0) b.writeln('Preço ${u.ofBatch(y)}: *${formatBrl(result.unitPriceCents * y)}*');
    b.writeln('Lucro (${u.count(result.input.quantity)}): ${formatBrl(result.profitCents)}');
  }

  final sim = simulation;
  if (sim != null) {
    b.writeln();
    b.writeln('*Simulação com preço escolhido*');
    b.writeln('Preço ${u.ofTheOne}: ${formatBrl(sim.priceCents)} — '
        '${sim.isLoss ? 'prejuízo' : 'lucro'} de ${formatBrl(sim.unitProfitCents.abs())} '
        'por ${u.one} (margem real ${sim.marginPercent.round()}%)');
  }
  b.writeln();
  b.write('Calculado com o Assistente de Vendas AUGURE.');
  return b.toString();
}

/// Planilha (CSV com ";" e virgula decimal, abre certo no Excel e no Google Planilhas em
/// portugues) com a tabela de custo do lote.
String buildCsv(SalesSession s, CostBreakdown t) {
  final u = s.units;
  String money(int? c) => c == null ? '' : (c / 100).toStringAsFixed(2).replaceAll('.', ',');
  String qty(Measure? m) => m == null ? '' : speakMeasure(m);
  String cell(String v) => v.contains(RegExp(r'[;"\n]')) ? '"${v.replaceAll('"', '""')}"' : v;
  final rows = <List<String>>[
    ['Produto', s.product ?? '', '', '', '', ''],
    ['Empresa', s.company ?? '', '', '', '', ''],
    ['Rende por ${u.batchName}', s.batchYield == null ? '' : u.count(t.batchYield ?? s.batchYield!), '', '', '', ''],
    [],
    ['Parte', 'Ingrediente', 'Quantidade usada', 'Preço pago (R\$)', 'Tamanho da embalagem', 'Custo no ${u.batchName} (R\$)'],
    for (final m in t.materials)
      [m.part ?? '', m.name, qty(m.used), money(m.priceCents), qty(m.pack), money(m.costCents)],
    [],
    ['Custos extras', '', '', '', '', 'R\$'],
    ['Embalagens', '', '', '', '', money(t.packagingCents)],
    ['Frete', '', '', '', '', money(t.freightCents ?? 0)],
    ['Gás, energia e desgaste', '', '', '', '', money(t.wearCents ?? 0)],
    ['Pró-labore', '', '', '', '', money(t.laborCents ?? 0)],
    ['Outros custos', '', '', '', '', money(t.otherCents ?? 0)],
    [],
    ['Custo do ${u.batchName}', '', '', '', '', money(t.batchCents)],
    ['Custo de produção ${u.ofTheOne}', '', '', '', '', money(t.unitCostCents)],
    ['Margem (%)', '', '', '', '', '${t.marginPercent ?? ''}'],
    ['Preço ${u.ofTheOne}', '', '', '', '', money(t.unitPriceCents)],
    ['Preço ${u.ofBatch(t.batchYield ?? 1)}', '', '', '', '', money(t.batchPriceCents)],
    ['Lucro por ${u.one}', '', '', '', '', money(t.unitProfitCents)],
  ];
  // BOM no inicio: o Excel reconhece os acentos (UTF-8).
  return '﻿${rows.map((r) => r.map(cell).join(';')).join('\r\n')}\r\n';
}

import 'package:augure_miniapps/core/cost_breakdown.dart';
import 'package:augure_miniapps/core/dialog_machine.dart';
import 'package:augure_miniapps/core/pricing_calculator.dart';
import 'package:augure_miniapps/core/pt_br_parser.dart';
import 'package:augure_miniapps/core/report.dart';
import 'package:flutter_test/flutter_test.dart';

const s = SalesSession(
  company: 'Bolinho feliz',
  sector: 'Confeitaria',
  product: 'bolo de cenoura',
  batchYield: 12,
  productionMinutes: 70,
  saleUnit: 'pedaço',
  batchName: 'bolo',
);

CostBreakdown table() => CostBreakdown(
      materials: [
        MaterialCost('cenoura',
            part: 'Massa',
            used: const Measure(300, MeasureKind.mass),
            priceCents: 650,
            pack: const Measure(1000, MeasureKind.mass)),
        MaterialCost('chocolate em pó',
            part: 'Cobertura',
            used: const Measure(120, MeasureKind.volume),
            priceCents: 2800,
            pack: const Measure(200, MeasureKind.mass)),
      ],
      packagingPerUnitCents: 170,
      laborCents: 2333,
      laborHourlyCents: 2000,
      batchYield: 12,
      marginPercent: 70,
    );

void main() {
  test('resumo para compartilhar', () {
    final text = buildReport(s, costs: table(), date: DateTime(2026, 11, 26));
    expect(text, startsWith('*bolo de cenoura* — Bolinho feliz'));
    expect(text, contains('Cálculo de preço de 26/11/2026'));
    expect(text, contains('Rende por bolo: 12 pedaços'));
    expect(text, contains('_Massa_ (R\$ 1,95)'));
    expect(text, contains('• cenoura (300 gramas): R\$ 1,95'));
    expect(text, contains('• chocolate em pó (meia xícara): R\$ 6,38'));
    expect(text, contains('• Embalagens (R\$ 1,70 por pedaço): R\$ 20,40'));
    expect(text, contains('Pró-labore (R\$ 20,00/hora): R\$ 23,33'));
    expect(text, contains('Preço do pedaço: *'));
    expect(text, contains('Preço do bolo inteiro (12 pedaços): *'));
  });

  test('sem tabela de custo usa o calculo principal', () {
    final r = calculatePricing(
        const PricingInput(quantity: 12, totalCostCents: 2000, marginPercent: 70));
    final text = buildReport(s, result: r);
    expect(text, contains('Custo informado: R\$ 20,00 para 12 pedaços'));
    expect(text, contains('Preço do pedaço: *R\$ 5,56*'));
    expect(text, contains('Preço do bolo inteiro (12 pedaços): *R\$ 66,72*'));
  });

  test('planilha CSV com ; e virgula decimal', () {
    final csv = buildCsv(s, table());
    expect(csv, startsWith('﻿Produto;bolo de cenoura'));
    expect(csv, contains('Massa;cenoura;300 gramas;6,50;1 quilo;1,95'));
    expect(csv, contains('Cobertura;chocolate em pó;meia xícara;28,00;200 gramas;6,38'));
    expect(csv, contains('Embalagens;;;;;20,40'));
    expect(csv, contains('Preço do pedaço;;;;;'));
  });

  test('"compartilhar" por voz no resultado', () {
    final m = DialogMachine(profile: s)..start();
    m.handle('12');
    m.handle('20 reais');
    m.handle('70');
    m.handle('sim');
    expect(m.state, DialogState.offerDetail);
    expect(m.looksLikeAnswer('manda o resultado no zap'), isTrue);
    final r = m.handle('quero compartilhar o resultado');
    expect(r.share, isTrue);
    expect(r.state, DialogState.offerDetail);
    expect(m.handle('não').state, DialogState.result);
    expect(m.handle('exportar a planilha').share, isTrue);
  });
}

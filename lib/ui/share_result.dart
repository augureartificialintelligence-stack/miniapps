import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/cost_breakdown.dart';
import '../core/dialog_machine.dart';
import '../core/pricing_calculator.dart';
import '../core/pt_br_parser.dart' show normalizePt;
import '../core/report.dart';

/// Opcoes de envio do resultado (folha na parte de baixo da tela):
/// - resumo em texto (WhatsApp, e-mail, qualquer app do celular);
/// - planilha CSV da tabela de custo (abre no Excel / Google Planilhas).
Future<void> shareResultSheet(
  BuildContext context, {
  required SalesSession session,
  PricingResult? result,
  CostBreakdown? costs,
  PriceSimulation? simulation,
  void Function(Object error)? onError,
}) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('Compartilhar ou exportar', style: Theme.of(ctx).textTheme.titleLarge),
        ),
        ListTile(
          leading: const Icon(Icons.chat_outlined),
          title: const Text('Compartilhar resumo'),
          subtitle: const Text('Texto com ficha, ingredientes, custos e preços (WhatsApp, '
              'e-mail…)'),
          onTap: () => Navigator.pop(ctx, 'texto'),
        ),
        if (costs != null)
          ListTile(
            leading: const Icon(Icons.table_chart_outlined),
            title: const Text('Exportar planilha (CSV)'),
            subtitle: const Text('Tabela de custo para abrir no Excel ou Google Planilhas'),
            onTap: () => Navigator.pop(ctx, 'planilha'),
          ),
      ]),
    ),
  );
  if (choice == null) return;
  final product = session.product ?? 'produto';
  final subject = 'Preço de $product';
  try {
    if (choice == 'texto') {
      final text =
          buildReport(session, result: result, costs: costs, simulation: simulation);
      await SharePlus.instance.share(ShareParams(text: text, subject: subject));
    } else if (costs != null) {
      final dir = await getTemporaryDirectory();
      final safe = normalizePt(product).replaceAll(RegExp(r'[^a-z0-9]+'), '_');
      final file = File('${dir.path}${Platform.pathSeparator}custo_$safe.csv');
      await file.writeAsString(buildCsv(session, costs), encoding: utf8, flush: true);
      await SharePlus.instance.share(ShareParams(
        subject: subject,
        text: 'Tabela de custo de $product',
        files: [XFile(file.path, mimeType: 'text/csv')],
      ));
    }
  } catch (e) {
    onError?.call(e);
  }
}

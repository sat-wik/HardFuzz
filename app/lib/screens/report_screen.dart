// report_screen.dart — evidence summary + traceability table + PDF export.
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import '../store.dart';
import '../models.dart';
import '../report.dart';

class ReportScreen extends StatelessWidget {
  const ReportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final campaign = Store.i.campaign!;
    final results = Store.i.results;
    final byId = {for (final f in campaign.faults) f.id: f};
    final passed = results.where((r) => r.pass).length;
    final failed = results.length - passed;

    Future<void> exportPdf() async {
      final html = buildHtmlReport(campaign, results);
      final bytes = await Printing.convertHtml(format: PdfPageFormat.a4, html: html);
      await Printing.sharePdf(bytes: bytes, filename: '${campaign.name}.pdf');
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Report'), actions: [
        IconButton(icon: const Icon(Icons.ios_share), onPressed: exportPdf),
      ]),
      body: ListView(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(campaign.name, style: Theme.of(context).textTheme.titleLarge),
            Text('${campaign.target} · ${campaign.standard}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            Row(children: [
              _kpi(context, 'Total', '${results.length}', Colors.black87),
              _kpi(context, 'Passed', '$passed', Colors.green),
              _kpi(context, 'Failed', '$failed', Colors.red),
            ]),
          ]),
        ),
        const Divider(height: 1),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('Scenario')),
              DataColumn(label: Text('Requirement')),
              DataColumn(label: Text('Expect')),
              DataColumn(label: Text('Observed')),
              DataColumn(label: Text('Verdict')),
            ],
            rows: [
              for (final r in results)
                DataRow(cells: [
                  DataCell(Text(r.id)),
                  DataCell(Text(byId[r.id]?.requirement ?? '')),
                  DataCell(Text(byId[r.id]?.expect ?? '')),
                  DataCell(Text(r.observed ? 'detected' : 'not detected')),
                  DataCell(Text(r.pass ? 'PASS' : 'FAIL',
                      style: TextStyle(
                          color: r.pass ? Colors.green : Colors.red,
                          fontWeight: FontWeight.bold))),
                ]),
            ],
          ),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: exportPdf,
        icon: const Icon(Icons.picture_as_pdf),
        label: const Text('Export PDF'),
      ),
    );
  }

  Widget _kpi(BuildContext context, String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.only(right: 28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Text(value,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(color: color, fontWeight: FontWeight.bold)),
      ]),
    );
  }
}

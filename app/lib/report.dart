// report.dart — build the IEC 61508 / ISO 26262 evidence report from a completed run.
//
// Mirrors host/include/hardfuzz/report.hpp: joins the streamed results with the campaign
// (for requirement/expect traceability) and emits an HTML report. Render it in a WebView
// or convert to PDF with the `printing` package for the auditor deliverable.
import 'models.dart';

String buildHtmlReport(Campaign c, List<FaultResult> results, {DateTime? when}) {
  final byId = {for (final f in c.faults) f.id: f};
  final passed = results.where((r) => r.pass).length;
  final failed = results.length - passed;
  final ts = (when ?? DateTime.now()).toIso8601String();

  String esc(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  final rows = results.map((r) {
    final f = byId[r.id];
    final params = f == null ? '' : '${f.protocol} a=${f.a} b=${f.b}';
    final verdict = r.pass ? 'PASS' : 'FAIL';
    final cls = r.pass ? 'pass' : 'fail';
    return '''
      <tr class="$cls">
        <td>${esc(r.id)}</td>
        <td>${esc(f?.requirement ?? '')}</td>
        <td>${esc(params)}</td>
        <td>${esc(f?.expect ?? '')}</td>
        <td>${r.observed ? 'detected' : 'not detected'}</td>
        <td>${esc(r.detail)}</td>
        <td><b>$verdict</b></td>
      </tr>''';
  }).join();

  return '''
<!doctype html><html><head><meta charset="utf-8"><style>
  body{font:14px/1.5 system-ui,sans-serif;color:#111;margin:24px}
  h1{margin:0 0 4px} .sub{color:#666;margin-bottom:16px}
  .kpi{display:inline-block;margin-right:24px;font-size:15px}
  .kpi b{font-size:22px}
  table{border-collapse:collapse;width:100%;margin-top:12px;font-size:13px}
  th,td{border:1px solid #ddd;padding:6px 8px;text-align:left}
  th{background:#f4f4f4} tr.pass td:last-child{color:#137a2b}
  tr.fail td:last-child{color:#c0261a} tr.fail{background:#fff5f4}
</style></head><body>
  <h1>${esc(c.name)}</h1>
  <div class="sub">Target: ${esc(c.target)} &middot; Standard: ${esc(c.standard)}
       &middot; Generated: ${esc(ts)}</div>
  <div class="kpi">Total <b>${results.length}</b></div>
  <div class="kpi">Passed <b style="color:#137a2b">$passed</b></div>
  <div class="kpi">Failed <b style="color:#c0261a">$failed</b></div>
  <table>
    <thead><tr>
      <th>Scenario</th><th>Requirement</th><th>Fault</th><th>Expect</th>
      <th>Observed</th><th>Detail</th><th>Verdict</th>
    </tr></thead>
    <tbody>$rows</tbody>
  </table>
  <p class="sub">HardFuzz v2 — fault-injection evidence. A PASS means the DUT behaved as the
  requirement demands (caught a fault that must be detected, or rode through a tolerated one).</p>
</body></html>''';
}

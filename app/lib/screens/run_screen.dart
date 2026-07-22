// run_screen.dart — live campaign progress + streaming results.
import 'dart:async';
import 'package:flutter/material.dart';
import '../store.dart';
import '../models.dart';
import 'report_screen.dart';

class RunScreen extends StatefulWidget {
  const RunScreen({super.key});
  @override
  State<RunScreen> createState() => _RunScreenState();
}

class _RunScreenState extends State<RunScreen> {
  StreamSubscription<FaultResult>? _resSub;
  StreamSubscription<CampaignStatus>? _statSub;
  CampaignStatus _status = const CampaignStatus(RunState.running, 0, 0, '');

  @override
  void initState() {
    super.initState();
    _resSub = Store.i.ble.results.listen((r) {
      setState(() => Store.i.results.add(r));
    });
    _statSub = Store.i.ble.status.listen((s) {
      setState(() => _status = s);
    });
  }

  @override
  void dispose() {
    _resSub?.cancel();
    _statSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final done = _status.state == RunState.done;
    final results = Store.i.results;
    return Scaffold(
      appBar: AppBar(
        title: Text(Store.i.campaign?.name ?? 'Run'),
        actions: [
          if (!done)
            TextButton(
              onPressed: () => Store.i.ble.stop(),
              child: const Text('Stop', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            LinearProgressIndicator(value: _status.total == 0 ? null : _status.progress),
            const SizedBox(height: 8),
            Text(done
                ? 'Done — ${results.length} results'
                : 'Running ${_status.done}/${_status.total}   ${_status.currentId}'),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: results.length,
            itemBuilder: (_, i) {
              final r = results[results.length - 1 - i]; // newest first
              return ListTile(
                dense: true,
                leading: Icon(r.pass ? Icons.check_circle : Icons.cancel,
                    color: r.pass ? Colors.green : Colors.red),
                title: Text(r.id),
                subtitle: Text(r.detail.isEmpty
                    ? (r.observed ? 'detected' : 'not detected')
                    : r.detail),
                trailing: Text(r.pass ? 'PASS' : 'FAIL',
                    style: TextStyle(
                        color: r.pass ? Colors.green : Colors.red,
                        fontWeight: FontWeight.bold)),
              );
            },
          ),
        ),
        if (done)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(
                onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const ReportScreen())),
                icon: const Icon(Icons.description),
                label: const Text('View report'),
              ),
            ),
          ),
      ]),
    );
  }
}

// campaign_screen.dart — pick a campaign and push it to the board.
import 'package:flutter/material.dart';
import '../store.dart';
import '../models.dart';
import 'run_screen.dart';

class CampaignScreen extends StatefulWidget {
  const CampaignScreen({super.key});
  @override
  State<CampaignScreen> createState() => _CampaignScreenState();
}

class _CampaignScreenState extends State<CampaignScreen> {
  Campaign _selected = presets.first;
  bool _busy = false;

  Future<void> _pushAndRun() async {
    setState(() => _busy = true);
    try {
      Store.i.campaign = _selected;
      Store.i.results.clear();
      await Store.i.ble.pushCampaign(_selected);
      await Store.i.ble.start();
      if (mounted) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => const RunScreen()));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Campaign')),
      body: Column(children: [
        if (Store.i.deviceInfo.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              const Icon(Icons.memory, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(Store.i.deviceInfo,
                  style: Theme.of(context).textTheme.bodySmall)),
            ]),
          ),
        const Divider(height: 1),
        Expanded(
          child: ListView(children: [
            for (final c in presets)
              RadioListTile<Campaign>(
                value: c,
                groupValue: _selected,
                onChanged: (v) => setState(() => _selected = v!),
                title: Text(c.name),
                subtitle: Text('${c.target} · ${c.standard} · ${c.faults.length} faults'),
              ),
          ]),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: _busy ? null : _pushAndRun,
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow),
              label: Text(_busy ? 'Pushing…' : 'Push & Run'),
            ),
          ),
        ),
      ]),
    );
  }
}

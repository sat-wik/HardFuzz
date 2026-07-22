// connect_screen.dart — scan for the HardFuzz board and connect.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import '../store.dart';
import 'campaign_screen.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});
  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _devices = <String, DiscoveredDevice>{};
  StreamSubscription<DiscoveredDevice>? _scan;
  String? _connecting;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  void _startScan() {
    _scan = Store.i.ble.scan().listen((d) {
      setState(() => _devices[d.id] = d);
    }, onError: (_) {});
  }

  Future<void> _connect(DiscoveredDevice d) async {
    setState(() => _connecting = d.id);
    await _scan?.cancel();
    try {
      await Store.i.ble.connect(d.id);
      Store.i.deviceInfo = await Store.i.ble.readInfo();
      if (mounted) {
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const CampaignScreen()));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Connect failed: $e')));
        setState(() => _connecting = null);
        _startScan();
      }
    }
  }

  @override
  void dispose() {
    _scan?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = _devices.values.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('HardFuzz — connect')),
      body: list.isEmpty
          ? const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Scanning for HardFuzz…'),
            ]))
          : ListView(
              children: [
                for (final d in list)
                  ListTile(
                    leading: const Icon(Icons.bluetooth),
                    title: Text(d.name.isEmpty ? 'HardFuzz' : d.name),
                    subtitle: Text(d.id),
                    trailing: _connecting == d.id
                        ? const SizedBox(
                            width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.chevron_right),
                    onTap: _connecting == null ? () => _connect(d) : null,
                  ),
              ],
            ),
    );
  }
}

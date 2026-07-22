// hardfuzz_ble.dart — BLE client for the HardFuzz v2 controller.
//
// GATT contract (see firmware/esp32/main/hf_config.hpp + ble_service.cpp):
//   Service   00000000-0001-0000-6861-72647a7a7566
//   Info      ...0010  Read      device info string
//   Campaign  ...0011  Write     campaign JSON, chunked; a single 0x00 byte ends it
//   Control   ...0012  Write     [opcode] 0x01=START 0x02=STOP 0x10=ARM{proto,a,b}
//   Status    ...0013  Notify    [state][done:u16le][total:u16le][id]
//   Result    ...0014  Notify    [observed][pass] "id\0detail"
import 'dart:async';
import 'dart:convert';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'models.dart';

class HardFuzzBle {
  final _ble = FlutterReactiveBle();

  static final _svc = Uuid.parse('00000000-0001-0000-6861-72647a7a7566');
  static final _info = Uuid.parse('00000000-0010-0000-6861-72647a7a7566');
  static final _campaign = Uuid.parse('00000000-0011-0000-6861-72647a7a7566');
  static final _control = Uuid.parse('00000000-0012-0000-6861-72647a7a7566');
  static final _status = Uuid.parse('00000000-0013-0000-6861-72647a7a7566');
  static final _result = Uuid.parse('00000000-0014-0000-6861-72647a7a7566');

  // Control opcodes (match hf_config.hpp)
  static const _ctlStart = 0x01, _ctlStop = 0x02, _ctlArm = 0x10;
  static const _proto = {'spi': 0, 'i2c': 1, 'can': 2};

  String? _deviceId;
  StreamSubscription<ConnectionStateUpdate>? _conn;

  final _statusCtl = StreamController<CampaignStatus>.broadcast();
  final _resultCtl = StreamController<FaultResult>.broadcast();
  Stream<CampaignStatus> get status => _statusCtl.stream;
  Stream<FaultResult> get results => _resultCtl.stream;

  /// Scan for devices advertising the HardFuzz service.
  Stream<DiscoveredDevice> scan() =>
      _ble.scanForDevices(withServices: [_svc], scanMode: ScanMode.lowLatency);

  Future<void> connect(String deviceId) async {
    _deviceId = deviceId;
    final ready = Completer<void>();
    _conn = _ble.connectToDevice(id: deviceId).listen((u) async {
      if (u.connectionState == DeviceConnectionState.connected) {
        await _ble.requestMtu(deviceId: deviceId, mtu: 247); // bigger campaign chunks
        _subscribe(_status, (b) => _statusCtl.add(CampaignStatus.decode(b)));
        _subscribe(_result, (b) => _resultCtl.add(FaultResult.decode(b)));
        if (!ready.isCompleted) ready.complete();
      }
    });
    return ready.future;
  }

  void _subscribe(Uuid chr, void Function(List<int>) onData) {
    _ble
        .subscribeToCharacteristic(_qc(chr))
        .listen(onData, onError: (_) {});
  }

  QualifiedCharacteristic _qc(Uuid chr) => QualifiedCharacteristic(
      serviceId: _svc, characteristicId: chr, deviceId: _deviceId!);

  Future<String> readInfo() async =>
      utf8.decode(await _ble.readCharacteristic(_qc(_info)), allowMalformed: true);

  /// Push a campaign: chunk the JSON to fit the MTU, then send the 0x00 terminator.
  Future<void> pushCampaign(Campaign c) async {
    final bytes = utf8.encode(c.toJsonString());
    const chunk = 180; // safely under a 247-MTU ATT write
    for (var i = 0; i < bytes.length; i += chunk) {
      final end = (i + chunk < bytes.length) ? i + chunk : bytes.length;
      await _ble.writeCharacteristicWithResponse(_qc(_campaign),
          value: bytes.sublist(i, end));
    }
    await _ble.writeCharacteristicWithResponse(_qc(_campaign), value: [0x00]);
  }

  Future<void> start() =>
      _ble.writeCharacteristicWithResponse(_qc(_control), value: [_ctlStart]);
  Future<void> stop() =>
      _ble.writeCharacteristicWithResponse(_qc(_control), value: [_ctlStop]);

  /// Manual single-fault arm: [0x10, proto, a_lo, a_hi, b_lo, b_hi]
  Future<void> armManual(String protocol, int a, int b) =>
      _ble.writeCharacteristicWithResponse(_qc(_control), value: [
        _ctlArm,
        _proto[protocol] ?? 0,
        a & 0xff,
        (a >> 8) & 0xff,
        b & 0xff,
        (b >> 8) & 0xff,
      ]);

  Future<void> dispose() async {
    await _conn?.cancel();
    await _statusCtl.close();
    await _resultCtl.close();
  }
}

// models.dart — data models + the notification decoders.
//
// The decoders MUST match the firmware's byte layout in
// firmware/esp32/main/ble_service.cpp (notify_status / notify_result).
import 'dart:convert';

enum RunState { idle, running, done }

/// Status notification: [state:1][done:u16le][total:u16le][id:utf8...]
class CampaignStatus {
  final RunState state;
  final int done;
  final int total;
  final String currentId;
  const CampaignStatus(this.state, this.done, this.total, this.currentId);

  factory CampaignStatus.decode(List<int> b) {
    final s = b.isNotEmpty ? b[0].clamp(0, 2) : 0;
    final done = b.length > 2 ? b[1] | (b[2] << 8) : 0;
    final total = b.length > 4 ? b[3] | (b[4] << 8) : 0;
    final id = b.length > 5 ? utf8.decode(b.sublist(5), allowMalformed: true) : '';
    return CampaignStatus(RunState.values[s], done, total, id);
  }

  double get progress => total == 0 ? 0 : done / total;
}

/// Result notification: [observed:1][pass:1] "id\0detail"
class FaultResult {
  final String id;
  final bool observed; // did the DUT catch/handle the injected fault?
  final bool pass;     // did that match the campaign's expectation?
  final String detail; // e.g. "FLIP bit 3" / "I2C timeout"
  const FaultResult(this.id, this.observed, this.pass, this.detail);

  factory FaultResult.decode(List<int> b) {
    final observed = b.isNotEmpty && b[0] != 0;
    final pass = b.length > 1 && b[1] != 0;
    final rest = b.length > 2 ? b.sublist(2) : const <int>[];
    final z = rest.indexOf(0);
    final id = utf8.decode(z >= 0 ? rest.sublist(0, z) : rest, allowMalformed: true);
    final detail = (z >= 0 && z + 1 < rest.length)
        ? utf8.decode(rest.sublist(z + 1), allowMalformed: true)
        : '';
    return FaultResult(id, observed, pass, detail);
  }
}

/// A fault the app sends inside a campaign (matches host/campaigns/*.json).
class Fault {
  final String id;
  final String protocol; // "spi" | "i2c" | "can"
  final int a; // frame / byte / bit
  final int b; // bit / stretch_cycles / width
  final String expect; // "detected" | "tolerated"
  final String requirement; // IEC 61508 / ISO 26262 tag
  const Fault(this.id, this.protocol, this.a, this.b,
      {this.expect = 'detected', this.requirement = ''});

  Map<String, dynamic> toJson() {
    // param names differ per protocol (the parser accepts frame/byte/bit etc.)
    final names = {
      'spi': ['frame', 'bit'],
      'i2c': ['byte', 'stretch_cycles'],
      'can': ['bit', 'width'],
    }[protocol]!;
    return {
      'id': id,
      'protocol': protocol,
      names[0]: a,
      names[1]: b,
      'expect': expect,
      'requirement': requirement,
    };
  }
}

class Campaign {
  final String name;
  final String target;
  final String standard; // e.g. "IEC 61508"
  final List<Fault> faults;
  const Campaign(this.name, this.target, this.standard, this.faults);

  String toJsonString() => jsonEncode({
        'name': name,
        'target': target,
        'standard': standard,
        'faults': faults.map((f) => f.toJson()).toList(),
      });
}

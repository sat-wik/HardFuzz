// store.dart — tiny shared state (no extra deps) + preset campaigns.
import 'hardfuzz_ble.dart';
import 'models.dart';

class Store {
  static final Store i = Store._();
  Store._();

  final HardFuzzBle ble = HardFuzzBle();
  Campaign? campaign;                 // the one being run
  final List<FaultResult> results = [];
  String deviceInfo = '';
}

/// Preset campaigns (mirror host/campaigns/*.json).
final presets = <Campaign>[
  const Campaign('Mixed SPI + I2C', 'STM32F446 + multi_inject_top', 'IEC 61508', [
    Fault('SPI-f5-b3', 'spi', 5, 3, requirement: 'SR-SPI-01'),
    Fault('I2C-b2-timeout', 'i2c', 2, 60000, requirement: 'SR-I2C-01'),
    Fault('SPI-f2-b7', 'spi', 2, 7, requirement: 'SR-SPI-02'),
    Fault('I2C-b1-slow', 'i2c', 1, 6000, requirement: 'SR-I2C-02'),
    Fault('SPI-f7-b0', 'spi', 7, 0, requirement: 'SR-SPI-03'),
    Fault('I2C-b3-tol', 'i2c', 3, 100, expect: 'tolerated', requirement: 'SR-I2C-03'),
  ]),
  Campaign('SPI bit-flip sweep', 'STM32F446 SPI', 'ISO 26262', [
    for (var frame = 1; frame <= 8; frame++)
      for (var bit = 0; bit < 8; bit += 2)
        Fault('SPI-f$frame-b$bit', 'spi', frame, bit, requirement: 'SR-SPI-SWEEP'),
  ]),
];

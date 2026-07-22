# firmware/esp32/ — HardFuzz v2 standalone controller (ESP32-S3)

The on-board brain for the **computer-free** HardFuzz: an ESP32-S3 runs the campaign engine
and streams results to a phone app over BLE, replacing the host PC. See
[docs/HardFuzz_v2_Standalone.md](../../docs/HardFuzz_v2_Standalone.md) for the architecture.

**This is a scaffold.** The engine glue is real and matches the tested interfaces; the
NimBLE host bring-up needs an on-hardware pass (it can't be built in this repo). See
"What's real vs. stub" below.

## The key idea: the engine is reused verbatim

The host campaign engine ([`host/include/hardfuzz/`](../../host/include/hardfuzz/)) is
**header-only C++17**, so this firmware `#include`s the exact same headers. The whole
hardware dependency is **one class** — `EspUartTransport` — a `hardfuzz::Transport` over an
ESP-IDF UART. It's used twice: once for the FPGA `ctrl_regs` (via `RegClient`) and once for
the DUT (via the existing `SerialDutRunner`). The fault model, coverage-guided `Scheduler`,
`arm()`, and pass/fail `evaluate()` run **identically to the PC**.

## Layout

```
firmware/esp32/
  CMakeLists.txt            top-level ESP-IDF project
  sdkconfig.defaults        target esp32s3, NimBLE peripheral, C++17 + exceptions
  main/
    CMakeLists.txt          component; adds ../../../host/include (the engine)
    hf_config.hpp           pin map (matches gen/esp32_sheet.py) + BLE UUIDs/opcodes
    esp_uart_transport.hpp  EspUartTransport : hardfuzz::Transport   ← the only glue
    ble_service.hpp/.cpp    the GATT service (Info/Campaign/Control/Status/Result)
    main.cpp                wires engine + UARTs + BLE; live campaign loop
```

## What's real vs. stub

| Piece | State |
|---|---|
| `EspUartTransport` (UART ↔ engine) | ✅ real ESP-IDF UART driver code, matches `Transport` |
| `main.cpp` engine wiring + campaign loop | ✅ real — same arm/run/evaluate/record as `CampaignRunner`, streaming per result |
| BLE GATT table + access callback + notify helpers | ✅ real — dispatches Control/Campaign to the engine |
| NimBLE host init + GAP advertising (`ble_service.cpp` bottom) | ⚠️ **scaffold** — mirrors the ESP-IDF `bleprph` example; verify on hardware |
| Manual-arm opcode payload format | ⚠️ example encoding; align with the app |

Cannot be compiled/tested here (no ESP-IDF toolchain in this repo) — treat as a starting
point that already speaks the engine's interfaces correctly.

## Build & flash (with ESP-IDF v5.x installed)

```bash
cd firmware/esp32
idf.py set-target esp32s3
idf.py build
idf.py -p /dev/tty.usbmodemXXXX flash monitor    # program over the ESP's USB-C (native USB)
```

## Wiring (matches the schematic — gen/esp32_sheet.py)

| ESP32-S3 | net | goes to |
|---|---|---|
| IO17 | `HOST_TXD` | FPGA `uart_rx` (arm faults over `ctrl_regs`) |
| IO18 | `HOST_RXD` | FPGA `uart_tx` (read status) |
| IO4  | `DUT_TXD`  | DUT header J7 pin 1 (drive the target) |
| IO5  | `DUT_RXD`  | DUT header J7 pin 2 (read `RESULT`) |
| IO2  | `ESP_STAT` | BLE/activity LED |
| USB  | —          | USB-C J6 (program + power) |

## Flow

1. Phone connects, reads **Device Info**.
2. Phone writes the **Campaign** JSON (chunked; a single `0x00` byte ends it).
3. Phone writes **Control: START** (`0x01`) → `campaign_task` runs the coverage-guided loop.
4. Each result streams up **Result**; progress up **Status**. The app renders and exports
   the IEC 61508 / ISO 26262 evidence report.

## Next

Bring up NimBLE advertising on real hardware, finalize the manual-arm/opcode payloads with
the phone app, then build the app (BLE client — see the v2 doc). The v1 host flow keeps
working the whole time; this is additive.

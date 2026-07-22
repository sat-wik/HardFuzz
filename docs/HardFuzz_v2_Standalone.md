# HardFuzz v2 — Standalone + Bluetooth

> Forward-looking spec for the **computer-free** HardFuzz. v1 needs a host PC running the
> C++ campaign engine; v2 moves that brain onto the board (an ESP32) and reports to a phone
> app over BLE. The fault-injection core — FPGA RTL, `ctrl_regs` protocol, DUT run-command
> firmware, and the C++ engine itself — is **unchanged**; v2 swaps only *who runs the
> engine and how you see results*.

## 1. The idea

Run a fault-injection campaign with **no laptop attached**: press go (or tap the app), the
board injects faults and drives the target itself, and results stream live to a phone app
over Bluetooth. Same evidence, no bench PC.

## 2. Architecture

```
  ┌───────────────────── HardFuzz v2 board ─────────────────────┐
  │                                                             │
  │   ESP32-S3  ◄── BLE ──►  phone app (Flutter/RN)             │
  │   (campaign engine +     - pick/launch campaign             │
  │    BLE GATT server)      - live progress + results          │
  │     │  │                 - export the evidence report       │
  │     │  └── UART ──►  DUT (target under test)   [drive + read RESULT]
  │     │                                                       │
  │     └── UART ──►  FPGA  (arm faults / read status via ctrl_regs)
  │                    │                                        │
  │                   real-time fault injection (unchanged)     │
  │                                                             │
  │   FT2232  ── USB-C ──►  dev only: FPGA JTAG + flash program │
  └─────────────────────────────────────────────────────────────┘
```

The **ESP32-S3** replaces the host PC. It runs the campaign engine, arms the FPGA over UART
(the same `ctrl_regs` register protocol), drives the DUT and reads its `RESULT` lines, and
serves everything to the app over BLE. The **FT2232 stays for development only** (FPGA JTAG
+ flashing); its runtime UART is freed up and handed to the ESP32.

**Why ESP32-S3:** ~$2, integrated-antenna module (WROOM-1), BLE built in, dual-core, and it
compiles **C++17 via ESP-IDF** — which matters because the engine below ports almost as-is.

## 3. The engine ports almost unchanged

The host library ([`host/include/hardfuzz/`](../host/include/hardfuzz/)) is **header-only
C++17**, so the ESP32 firmware literally `#include`s the same headers. Only the platform glue
is new:

| Header | On ESP32 |
|---|---|
| `fault.hpp` (Protocol, Fault, CovKey) | ✅ ports as-is (pure data) |
| `coverage.hpp` (CoverageTracker, coverage-guided Scheduler) | ✅ ports as-is (std containers) |
| `campaign.hpp` (CampaignRunner, evaluate) | ✅ ports as-is |
| `reg_client.hpp` (arm → writes reg4/1/2/3/0) | ✅ ports as-is |
| `json.hpp` (campaign parser) | ✅ ports — parse the campaign the app pushes |
| `transport.hpp` → `SerialTransport` | 🔧 new: ESP32 UART driver to the FPGA `ctrl_regs` |
| `dut_serial.hpp` → `SerialDutRunner` | 🔧 new: ESP32 UART to the DUT (send `{proto,'R'}`, read `RESULT`) |
| `report.hpp` (JSON build) | ✅ JSON on-device; 🔧 stream over BLE instead of writing files |
| `report.hpp` (HTML/CSV) | ➡ moves to the **app** (renders the report, exports PDF) |

Net: the fault model, coverage-guided scheduling, arming, and pass/fail evaluation run
**identically** on the ESP32 — they were designed transport-agnostic (that's why the tests
use a `MockTransport`). New code is two UART transports + a BLE results sink.

## 4. Campaign lifecycle (standalone)

1. App connects over BLE, reads **Device Info** (fw version, capabilities, live `VREF`).
2. App pushes a **campaign** (JSON) to the device, or the user selects a pre-loaded one, or
   the device generates a coverage-guided sweep on its own.
3. App writes **Control: START**. The ESP32 runs `CampaignRunner`:
   for each fault → `arm()` the FPGA over UART → drive the DUT → read `RESULT` → evaluate.
4. Each result streams up the **Result** characteristic as it completes (id, verdict,
   detail); **Status** notifies progress (fault *i* of *N*).
5. On finish, the app has the full result set and renders/export the IEC 61508 / ISO 26262
   **evidence report** (PDF) — the auditor deliverable, now generated app-side.

## 5. BLE GATT service

One custom 128-bit service. Base UUID `HF-xxxx` (assign a real 128-bit at implementation).

| Characteristic | Props | Payload |
|---|---|---|
| **Device Info** | Read | fw version, protocol caps (SPI/I2C/CAN), current `VREF`, mode |
| **Campaign** | Write (chunked) | campaign JSON (name, target, standard, faults[]) — reassembled on device |
| **Control** | Write | `0x01`=START, `0x02`=STOP, `0x03`=SELECT idx, `0x10`=manual arm {proto,frame,bit,…} |
| **Status** | Notify/Read | state (idle/running/done), progress `i/N`, active fault id |
| **Result** | Notify | per fault: `{id, expect, observed(0/1), detail}` — streamed as each completes |

BLE throughput is a non-issue: a result is a few bytes; a 100-fault campaign is a few KB.
Use a raised MTU (247) and notifications; results stream faster than faults execute.

## 6. Firmware structure (ESP-IDF)

```
firmware/esp32/
  main.cpp            init UARTs (FPGA control, DUT) + NimBLE GATT server + engine
  ble_service.cpp     the GATT service above; Control writes -> engine calls;
                      Result/Status notifications
  esp_transport.hpp   Transport impl over UART1 -> FPGA ctrl_regs  (SerialTransport)
  esp_dut.hpp         DutRunner impl over UART2 -> DUT             (SerialDutRunner)
  # reuses host/include/hardfuzz/*.hpp verbatim (fault, coverage, campaign, reg_client, json)
```

The main loop is event-driven: a BLE **START** kicks the `CampaignRunner`; a small
`BleResultSink` pushes each `ScenarioResult` out the Result characteristic and updates
Status. The FPGA and DUT UARTs are the same wiring the PC used — just sourced from the ESP32.

## 7. What changes on the board (from v1)

- **Add** the ESP32-S3-WROOM-1 module: powered from `+3V3`, EN + IO0 boot circuits (pull-ups
  + reset/boot buttons), a status LED, and a USB-C for programming/power (native USB).
- **UART to FPGA:** ESP32 drives the existing `HOST_TXD`/`HOST_RXD` control nets — so the
  **FT2232's channel B is freed** (left as no-connect); FT2232 keeps JTAG for FPGA dev.
- **UART to DUT:** two ESP32 GPIOs to a 3-pin header (TX/RX/GND) — the standalone link that
  replaces the PC↔DUT USB.
- Everything else (FPGA, level shifters, CAN, power tree) is **unchanged**.

The ESP32 block is added as its own schematic sheet (`gen/esp32_sheet.py`) in the same
code-generated KiCad project.

## 8. Power & app

- **Power:** USB-C (5 V) or battery; ESP32 + FPGA on 5 V is a comfortable budget. USB-C on
  the ESP side becomes the product port (charge + firmware update); no data-USB to a PC
  needed at runtime.
- **App:** a BLE client — Flutter or React Native for one codebase on iOS + Android. Screens:
  connect, pick/configure campaign, live run (progress + streaming results), report export.

## 9. Status / roadmap

**Design only** (this doc). Foundation that already exists and carries over: the FPGA RTL,
`ctrl_regs`, the DUT run-command firmware, and the **header-only C++17 engine** (the thing
that makes the ESP32 port cheap). To build v2: add the ESP32 to the board (schematic sheet —
done in the KiCad project), write the two UART transports + BLE service on ESP-IDF, and the
phone app. The v1 board + host flow keeps working throughout — v2 is an additive path.

# app/ — HardFuzz v2 phone app (BLE client)

The phone app for the **computer-free** HardFuzz: connect to the board over Bluetooth, push
a campaign, watch results stream in live, and export the evidence report. It talks to the
ESP32-S3 controller ([firmware/esp32/](../firmware/esp32/)); see
[docs/HardFuzz_v2_Standalone.md](../docs/HardFuzz_v2_Standalone.md) for the whole picture.

**This is a scaffold** of the core — the BLE client, the notification decoders (byte-matched
to the firmware), the data models, and the report generator. The Flutter UI widgets are
described below but not yet built.

## Stack

Flutter/Dart — one codebase for iOS + Android. `flutter_reactive_ble` for BLE central,
`printing` for PDF export.

```
app/
  pubspec.yaml
  lib/
    main.dart          app entry (MaterialApp)
    store.dart         tiny shared state + preset campaigns
    models.dart        data models + the Status/Result decoders (match ble_service.cpp)
    hardfuzz_ble.dart  BLE client: scan/connect, subscribe, push campaign, control
    report.dart        HTML/PDF evidence report (mirrors host report.hpp)
    screens/
      connect_screen.dart    scan + connect
      campaign_screen.dart   pick a preset, Push & Run
      run_screen.dart        live progress + streaming results
      report_screen.dart     KPIs + traceability table + Export PDF
```

## GATT contract

Service `00000000-0001-0000-6861-72647a7a7566` (from `firmware/.../hf_config.hpp`):

| Char | UUID suffix | Op | Payload |
|---|---|---|---|
| Info | `…0010` | Read | device info string |
| Campaign | `…0011` | Write | campaign JSON, chunked; a single `0x00` byte ends it |
| Control | `…0012` | Write | `[opcode]` — `0x01` START, `0x02` STOP, `0x10` ARM `{proto,a,b}` |
| Status | `…0013` | Notify | `[state][done:u16le][total:u16le][id]` |
| Result | `…0014` | Notify | `[observed][pass] "id\0detail"` |

The decoders in [`models.dart`](lib/models.dart) (`CampaignStatus.decode`,
`FaultResult.decode`) match those byte layouts exactly — the one place the app and firmware
must agree.

## Flow

1. **Connect** — `scan()` filters on the service UUID; `connect()` negotiates a 247-byte MTU
   and subscribes to Status + Result. `readInfo()` shows fw version + supported protocols.
2. **Configure** — build a `Campaign` (name, target, standard, faults) or load a preset;
   `pushCampaign()` chunks the JSON up to the device (the same format `campaign_from_json`
   parses on the ESP32).
3. **Run** — `start()`. Status notifications drive a progress bar (`done/total`); each
   Result notification appends a row (id, verdict, detail) live.
4. **Report** — on `state == done`, `buildHtmlReport()` joins the results with the campaign
   (for requirement/expect traceability) and renders the IEC 61508 / ISO 26262 evidence
   report; `printing` exports it to PDF — the auditor deliverable.

## Screens (to build)

- **Connect** — device list (scan), tap to connect, show Device Info.
- **Campaign** — pick a preset or edit faults; "Push & Run".
- **Run** — progress bar + a live-updating results list (green/red per fault).
- **Report** — summary KPIs + traceability table; "Export PDF" / "Share".

## What's real vs. TODO

| Piece | State |
|---|---|
| Status/Result decoders (`models.dart`) | ✅ byte-matched to `ble_service.cpp` |
| BLE client (`hardfuzz_ble.dart`) — scan/connect/subscribe/push/control | ✅ scaffolded against `flutter_reactive_ble` |
| Campaign JSON encoder | ✅ matches `campaign_from_json` / `host/campaigns/*.json` |
| Report generator (`report.dart`) | ✅ HTML mirroring `report.hpp`; PDF via `printing` |
| Flutter UI (4 screens: connect / campaign / run / report) | ✅ built — wired to the BLE client + streams |
| On-device BLE bring-up | ⚠️ needs the ESP32 firmware running (pairs with its NimBLE TODO) |
| iOS/Android BLE permissions (Info.plist / AndroidManifest) | ⚠️ add before running on a device |
| `flutter create .` platform folders (android/ ios/) | ⚠️ generate locally (not committed) |

## Build (once the UI exists)

```bash
cd app
flutter pub get
flutter run          # on a physical device — BLE needs real hardware
```

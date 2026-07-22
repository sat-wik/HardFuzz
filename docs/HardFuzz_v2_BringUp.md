# HardFuzz v2 — Build & Bring-Up Checklist

The ordered path from the repos to a working **standalone** unit (board runs campaigns, phone
app shows results, no PC). Each phase has commands, the files involved, and a "done when"
signal. The genuinely hard steps are flagged **⚠️**.

Dependency graph: **PCB → assembly → power → FPGA** and **ESP32 firmware** and **app** can
proceed in parallel once you have a board; **integration** needs all three.

---

## Phase 0 — Tools & decisions

- [ ] Install: **KiCad 10**, **ESP-IDF v5.x**, **Flutter SDK**, **openFPGALoader**, and a
      **Vivado** path for the bitstream (cloud VM — see [vivado-cloud.md](vivado-cloud.md)).
- [ ] Decide fab/assembly: JLCPCB or PCBWay (they can also place the BGA/QFN for you).
- [ ] Skim [HardFuzz_v2_Standalone.md](HardFuzz_v2_Standalone.md) for the architecture.

---

## Phase 1 — Finish the PCB  ⚠️ (the skilled part)

Open `hardware/hardfuzz_v1/hardfuzz_v1.kicad_pro` in KiCad.

- [ ] **Stackup:** Board Setup → Physical Stackup → **4 layers** (SIG / GND / PWR / SIG),
      per [schematic_design.md §11](../hardware/schematic_design.md). (The generator emits
      2-layer; this is a one-time GUI change.)
- [ ] **Net classes / rules:** Board Setup → Net Classes — a **Power** class (wide traces,
      e.g. 0.4–0.8 mm), **USB** (90 Ω diff pairs, controlled impedance), **CAN** (120 Ω diff
      pair), Default. Add a custom rule to clear the **USB-C internal clearance** DRC (the
      GCT part's fine-pitch pads need <0.2 mm).
- [ ] **Re-arrange by subsystem** (the auto-placement is a functional strip): FPGA central,
      power near the USB-C input, level-shifter + target headers along one edge, CAN screw
      terminal at an edge, **ESP32 module at a board edge with a keep-out under its antenna**
      (no copper — critical for BLE range).
- [ ] ⚠️ **BGA fanout:** escape the 324-ball FPGA — via-in-pad or dog-bone vias to inner
      layers. This is done semi-manually; no autorouter does it for you.
- [ ] **Route:** the rest via **Freerouting** (File → Export → Specctra DSN → route →
      Import → Specctra Session) or KiCad's interactive router. Pour GND/PWR planes on the
      inner layers.
- [ ] Mounting holes (4× M2), silkscreen labels, board name/rev.
- [ ] **DRC clean** — 0 unrouted, 0 clearance.
- [ ] **Fab outputs:** `kicad-cli pcb export gerbers` + `pcb export drill` (or the fab's
      plugin), plus the BOM/position files (`export bom`, `export pos`).
- **Done when:** DRC passes and you have a Gerber set the fab accepts.

---

## Phase 2 — Order & assemble

- [ ] **BOM:** [hardware/bom.csv](../hardware/bom.csv) — the ICs/connectors have MPNs; add
      MPNs for the passives (generic 0402 R/C, per the values). Add the ESP32 line
      (`ESP32-S3-WROOM-1-N8`) and 2nd USB-C.
- [ ] Order boards + parts (or fab-assembly with the position file).
- [ ] Populate: reflow BGA (U1) + QFN (U2) with a stencil; hand-solder the rest — or let the
      fab place them.
- **Done when:** a populated board with no visible shorts.

---

## Phase 3 — Power bring-up

- [ ] **Before** populating logic ICs (or with current-limited supply): apply USB-C 5 V,
      check each rail with a meter — **+5V, +3V3, +1V0, +1V8** at the right voltages, no
      shorts to GND. `VREF` follows the target (3.3/5 V).
- [ ] Check the ESP32 and FPGA power pins read their rails.
- **Done when:** all rails correct under no load.

---

## Phase 4 — FPGA bitstream  ⚠️ (new pinout)

The RTL is unchanged from v1; only the **pin map** changes for CSG324.

- [ ] Write a **new `.xdc`** for the CSG324 ball assignments used in
      [gen/fpga_sheet.py](../hardware/hardfuzz_v1/gen/fpga_sheet.py) (SPI/I2C/CAN/UART/CLK/
      config balls). This is the one real FPGA task.
- [ ] Build `multi_inject_top` on the Vivado VM (`make bit TOP=multi_inject_top`), copy the
      `.bit` back.
- [ ] Program QSPI flash via the FT2232 JTAG: `make prog-flash` (persists across power-cycle).
- **Done when:** `led[0]` blinks ~1 Hz and the FPGA responds to a UART register read.

---

## Phase 5 — ESP32 firmware  ⚠️ (NimBLE bring-up)

- [ ] `cd firmware/esp32 && idf.py set-target esp32s3 && idf.py build`.
- [ ] Flash over the ESP's USB-C: `idf.py -p <port> flash monitor`.
- [ ] ⚠️ **Bring up NimBLE advertising** — the scaffolded host init in
      [ble_service.cpp](../firmware/esp32/main/ble_service.cpp) needs an on-hardware pass
      (verify against the ESP-IDF `bleprph` example). Scan with **nRF Connect** on a phone;
      confirm "HardFuzz" advertises and the 5 characteristics enumerate.
- [ ] **UART sanity:** confirm the ESP↔FPGA UART (IO17/18) and ESP↔DUT UART (IO4/5) with a
      logic analyzer; send a **manual arm** (Control `0x10`) and confirm the FPGA injects.
- **Done when:** the board advertises over BLE and can arm the FPGA.

---

## Phase 6 — Phone app

- [ ] `cd app && flutter create . && flutter pub get` (generates `android/` + `ios/`).
- [ ] **BLE permissions:** iOS `Info.plist` → `NSBluetoothAlwaysUsageDescription`; Android
      `AndroidManifest.xml` → `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT` (+ location on older API).
- [ ] `flutter run` on a **physical phone** (BLE needs real hardware).
- **Done when:** the app scans, connects, and shows Device Info.

---

## Phase 7 — System integration

- [ ] Flash the DUT (STM32) with the run-command firmware
      ([firmware/src/main_multi.c](../firmware/src/main_multi.c)); wire its UART to the ESP32
      **DUT header J7** (TX/RX/GND).
- [ ] Wire the target bus (SPI/I2C) to the level-shifted headers; set `VREF` to the target
      voltage.
- [ ] In the app: pick **"Mixed SPI + I2C"**, **Push & Run**, watch results stream, tap
      **Export PDF**.
- [ ] Cross-check against the known-good host result: `host/campaigns/multi.json` was **7/7**
      on the v1 bench flow — the standalone run should match.
- **Done when:** a full campaign runs from the phone with no PC, results stream live, and the
      evidence PDF exports.

---

## Phase 8 — Validation

- [ ] Full campaign, verdicts match the bench baseline.
- [ ] **Power-cycle test:** unplug/replug, run again from the phone only — proves standalone.
- [ ] (Optional) BLE range + a longer coverage-guided sweep.

---

## Risk map (where time actually goes)

| Step | Risk | Mitigation |
|---|---|---|
| BGA fanout + 4-layer routing (Ph.1) | High — skilled work | Freerouting for bulk; consider a fab layout service |
| CSG324 `.xdc` (Ph.4) | Medium — new pinout | Cross-check every ball against `fpga_sheet.py` |
| NimBLE advertising (Ph.5) | Medium — the one firmware TODO | Follow ESP-IDF `bleprph`; verify with nRF Connect |
| Antenna keep-out (Ph.1/2) | Medium — silent BLE range loss | No copper under the WROOM antenna |
| Passive MPNs (Ph.2) | Low — procurement | Fill in `bom.csv` |

Everything else — the RTL, the campaign engine, the schematic, the wire contracts, the app
logic — is already built and validated in-repo. This checklist is the physical last mile.

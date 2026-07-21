# HardFuzz v1 — Schematic Design

The electrical design for the v1 PCB, at the level of detail you draw straight into
KiCad: block diagram, power tree, part selection, and the net-by-net connection list per
block. This is the engineering; symbol placement and routing in KiCad are mechanical once
this is fixed. Pairs with [HardFuzz_v1_Spec.md](../docs/HardFuzz_v1_Spec.md) (the product
side) and [bom.csv](bom.csv) (part numbers + cost).

Design target: reuse the **proven Cmod A7 core** (Artix-7 XC7A35T die + FT2232H
USB-JTAG/UART + QSPI config) so the RTL we already run drops on unchanged (rebuilt against
a new `.xdc`), and add the productization: level-shifted bus I/O with `VREF` sensing, an
onboard CAN transceiver, and keyed target connectors. Package is CSG324 (stock KiCad
symbol, easy fan-out — see §10.2).

---

## 1. Block diagram

```
                 USB-C ─┬─ VBUS 5V ──► POWER TREE ──► 3V3 / 1V0 / 1V8 rails
                        │
                        └─ D± ──► FT2232H ─┬─ ch A: JTAG ──► FPGA config (+ QSPI flash)
                                           └─ ch B: UART ──► FPGA host link (internal)
                                                              │
   12 MHz osc ──► FPGA (XC7A35T) ◄── QSPI config flash        │
                    │  bank I/O @ 3V3                          │
                    │                                          │
          ┌─────────┼───────────────────────────┐             │
          │         │                            │            LEDs / reset / trig
     CAN TXD/RXD  8 bus lines (3V3)         (internal UART)
          │         │
   SN65HVD230   TXS0108E level shifter  A-side=3V3, B-side=VREF
          │         │
       CANH/CANL   8 lines @ VREF ──► target connectors
          │         │                   ├─ Qwiic (I2C: SDA/SCL)
     screw term.    ├─────────────────► ├─ SPI/UART IN/OUT keyed header
    (+120Ω term)    └─────────────────► └─ bus header + VREF + GND + TRIG
```

FPGA I/O stays at a fixed **3V3** bank voltage; the TXS0108E translates to the target's
`VREF` on its B-side. CAN logic (TXD/RXD) is already 3V3, so it wires to the FPGA directly
and only the differential CANH/CANL leaves the board.

---

## 2. Power tree

USB VBUS (5 V) is the only input. Three regulated rails feed the FPGA; `VREF` is supplied
by the *target*, not generated here.

| Rail | From | Regulator | Feeds | Notes |
|---|---|---|---|---|
| **+5V** | USB-C VBUS | — (input) | 3V3 buck | fused/ESD at connector |
| **+3V3** | +5V | AP63203 buck (2 A) | FPGA VCCO/VCCAUX_IO, FT2232H VCCIO, QSPI, CAN xcvr, TXS0108E VCCA, LEDs | main logic rail |
| **+1V0** | +3V3 | TLV62569 buck (2 A) | FPGA VCCINT + VCCBRAM | highest-current FPGA rail |
| **+1V8** | +3V3 | AP2112K-1.8 LDO | FPGA VCCAUX + VCCADC | low current; LDO fine |
| **VREF** | target VIO (external) | — | TXS0108E VCCB only | 1.8–5 V, sensed via XADC divider |

Power-up sequencing: Artix-7 is tolerant but prefers VCCINT → VCCAUX → VCCO. The buck for
1V0 and LDO for 1V8 come up off 3V3, so 3V3 gates them — acceptable for -1 speed grade
with the usual bulk caps; add a 10 ms RC enable delay on the 1V0 buck if margining tight.

Decoupling (per Xilinx UG483, scaled for CPG236): VCCINT 1×47µF + 4×4.7µF + 8×0.47µF;
VCCAUX 1×47µF + 4×4.7µF; each VCCO bank 1×4.7µF + 0.47µF/pin group; 100nF at every pair.

---

## 3. FPGA — XC7A35T-1CSG324C

Same die as the Cmod A7 (CSG324 package — stock KiCad symbol, §10.2); the signal *intent* carries
over, pin *numbers* are reassigned in a fresh `.xdc`. Key connections:

- **Power:** VCCINT/VCCBRAM=1V0, VCCAUX/VCCADC=1V8, VCCO (banks 14/15/16/34/35)=3V3.
- **Config:** master SPI (QSPI) boot — `M[2:0]=001`. Config bank (bank 0) at 3V3.
  - `CCLK`, `MOSI/DIN`, `DOUT/CSO_B`, `FCS_B` → QSPI flash (below).
  - `INIT_B`, `DONE` → 4.7k pull-ups + a DONE LED.
  - `PROGRAM_B` → 4.7k pull-up + reset button.
- **JTAG:** TCK/TMS/TDI/TDO → FT2232H channel A (see §5). 4.7k on TMS/TDI/TCK.
- **Clock:** 12 MHz oscillator → a global-clock-capable (MRCC/SRCC) pin, e.g. bank 14.
- **XADC (VREF sense):** `VP/VN` or an aux channel across a `VREF`÷ divider (see §7) so
  firmware can read the target voltage and confirm the shifter is powered.
- **Bus I/O (bank 34/35, 3V3):** 8 signals to the TXS0108E A-side + 2 to the CAN xcvr +
  1 `TRIG`. Assign to real pins in the `.xdc` at layout (keep each protocol's group on one
  bank for skew).

| FPGA bus signal | To | Notes |
|---|---|---|
| `spi_sclk, spi_mosi, spi_miso, spi_cs_n` | TXS0108E A1–A4 | SPI (matches current `.xdc` intent) |
| `i2c_scl, i2c_sda` | TXS0108E A5–A6 | open-drain; needs pull-ups on B-side |
| `uart_a_tx, uart_a_rx` | TXS0108E A7–A8 | target-facing UART (distinct from host UART) |
| `can_txd, can_rxd` | SN65HVD230 D, R | 3V3 direct, no shifter |
| `trig_out` | header (buffered) | scope sync / DUT GPIO in |

---

## 4. Configuration flash — QSPI

- **Part:** Micron N25Q032A13ESF40 (32 Mb, 3V3) — comfortably fits the 35T bitstream
  (~17 Mb) with room for the pre-loaded multi-protocol image and a user slot.
- **Nets:** `FCS_B→S#`, `CCLK→C`, `MOSI→DQ0`, `DOUT→DQ1`, plus `DQ2(W#/VPP)`,
  `DQ3(HOLD#)` pulled high (or wired for x4). 4.7k on `S#`. 100nF decoupling.

---

## 5. USB + FT2232HQ (JTAG + host UART)

Reuses the Cmod's dual-channel bridge: channel A does USB→JTAG for config; channel B is
the host UART the `ctrl_regs` interface already speaks.

- **Part:** FTDI FT2232HQ-REEL (QFN-64), USB 2.0 HS.
- **Its own 12 MHz crystal** (FT2232H requires a 12 MHz crystal on `OSCI/OSCO`) — separate
  from the FPGA oscillator.
- **EEPROM:** 93LC56B on the FT2232H MW bus for the USB VID/PID + serial (so the host app
  can auto-detect the board — see spec §4). Program the HardFuzz VID/PID here.
- **Power:** VCORE 1V8 via its internal reg (external decoupling per datasheet); VCCIO=3V3;
  VPLL/VPHY filtered per datasheet.
- **Channel A → JTAG:** ADBUS0=TCK, ADBUS1=TDI, ADBUS2=TDO, ADBUS3=TMS → FPGA JTAG.
- **Channel B → UART:** BDBUS0=TXD, BDBUS1=RXD → FPGA `uart_rx`/`uart_tx` (the host link).
- **USB-C:** VBUS→power tree; D+/D− → FT2232H DP/DM (22Ω series if needed); **CC1/CC2 each
  via 5.1k to GND** (upstream-facing device / sink). ESD: TVS array on D±.

---

## 6. CAN transceiver — SN65HVD230

- Logic side at 3V3: `D`←FPGA `can_txd`, `R`→FPGA `can_rxd`, `Rs`→ slope-control R (or GND
  for fastest edges). `VCC`=3V3, 100nF.
- Bus side: `CANH`/`CANL` → screw terminal. **120Ω split-termination selectable by jumper**
  (two 60Ω to a mid-point cap) so the board can be an end node or a passive tap.
- This is the transceiver the plan/BOM already calls for; it moves onboard for v1.

---

## 7. Level shifters + VREF

- **Part:** TXS0108EPWR (8-bit, auto-direction, TSSOP-20). One device covers the 8 bus
  lines (SPI 4 + I2C 2 + UART 2).
  - `VCCA`=3V3 (FPGA side), `VCCB`=`VREF` (target side), `OE`→3V3 via 100k (enable).
  - **Caveat:** TXS0108E has weak (~4k) internal one-shots — fine for I2C (open-drain,
    ≤400 kHz) and moderate SPI/UART. For SPI above ~2–4 MHz, populate the alt footprint
    for a **directional** shifter (74LVC1T45 per line, direction from `spi_cs_n`/known
    flow) — leave DNP pads so either can be fitted. Our validated SPI runs at 500 kHz, so
    TXS0108E is the default.
- **I2C pull-ups:** 4.7k from `SDA_B`/`SCL_B` to `VREF` (open-drain needs them on the
  target side); pads for stronger values.
- **VREF input & sense:** `VREF` pin → TXS0108E VCCB only (CAN is 3V3-fixed, so it doesn't
  use VREF). Per §10.3 the A-side VCCA is 3.3 V and the part needs VCCA ≤ VCCB, so **v1
  supports VREF = 3.3–5 V**; a **5.5 V TVS** clamps it and a bleeder resistor keeps VCCB
  from floating when VREF is left unconnected. Sense via a 2:1 divider into an XADC channel
  so firmware reads the target voltage and the app can warn "VREF not connected / out of
  range." Bulk 1µF on `VREF`.

---

## 8. Connectors / user I/O

| Ref | Connector | Pins | Signals |
|---|---|---|---|
| J_USB | USB-C receptacle | — | VBUS, GND, D+, D−, CC1, CC2 |
| J_I2C | Qwiic JST-SH 1mm 4-pin | 4 | GND, VREF, `SDA_B`, `SCL_B` |
| J_CAN | 3.5mm screw terminal, 3-pos | 3 | CANH, CANL, GND (+ term jumper) |
| J_SPI | keyed 2×5 0.1", IN + OUT sides | 10 | SCLK, MOSI, MISO, CS, UART TX/RX, VREF, GND, TRIG |
| J_BUS | 2×10 0.1" breakout | 20 | all `_B` bus lines + VREF + GND + TRIG (jumpers) |
| J_PROG | 2×7 0.1" (optional) | 14 | external JTAG (bypass USB) |

VREF appears on every target connector so the user makes one connection.

---

## 9. Misc / housekeeping

- **Reset:** momentary button → `PROGRAM_B` (reconfigure) + a separate soft-reset to FPGA
  logic. RC debounce.
- **LEDs:** power-good (3V3), `DONE` (config complete), heartbeat (FPGA `led[0]`), an RGB
  for status (reuse the current top's RGB), 2× activity (host UART / injection active).
- **Test points:** all rails, `VREF`, `TRIG`, CANH/CANL.
- **Mounting:** 4× M2, board outline ~60×40 mm, USB-C on a short edge.

---

## 10. Resolved decisions

Each open item from the design review, decided for v1 with rationale. Two ripple back into
earlier sections (flagged) and are reflected there and in [bom.csv](bom.csv).

**1. SPI level shifter → TXS0108E default; DNP 74LVC1T45 pads on the 4 SPI lines.**
Our validated SPI is 500 kHz and I2C 100 kHz — both well inside the TXS0108E's auto-
direction range, so one 8-bit part covers all bus lines on v1. SPI's four lines are also
statically directional (SCK/MOSI/CS out, MISO in), so lay out DNP footprints for per-line
74LVC1T45 directional shifters; a high-speed-SPI build then swaps parts with **no respin**.
(I2C's SDA must stay auto-direction → keep it on the TXS0108E.)

**2. FPGA package → CSG324 (0.8 mm).** *(ripples into §3, BOM U1)* **[updated during capture]**
Originally FTG256 (1.0 mm) was picked over CPG236 for fan-out. During KiCad capture we
switched to **CSG324**: KiCad's stock Artix-7 library ships an `XC7A35T-CSG324` symbol (and
CPG236, but **not** FTG256), so CSG324 needs **no external symbol import**. At 0.8 mm pitch
it still escapes on a standard 4-layer board (vs CPG236's 0.5 mm HDI risk), the RTL is
package-independent (only a fresh `.xdc` is needed), and it's the same XC7A35T die. The
generated schematic (`hardfuzz_v1/gen/fpga_sheet.py`) uses CSG324.

**3. Target voltage → 3.3 V and 5 V for v1; defer 1.8 V.** *(ripples into §2, §7, spec)*
The TXS0108E requires **VCCA ≤ VCCB**. With the FPGA bus bank (VCCA) at 3.3 V, VREF (VCCB)
must be ≥ 3.3 V — so v1 cleanly covers **3.3 V and 5 V** targets. Supporting 1.8 V targets
would need the shifter A-side at 1.8 V, i.e. a **dedicated 1.8 V FPGA bus bank**
(VCCA = 1.8 ≤ any VREF ≥ 1.8) with CAN/config/host kept on the 3.3 V banks — a genuine
power-tree change, deferred to a rev. Clamp VREF with a 5.5 V TVS and add a bleeder so an
unconnected VREF can't float VCCB. **The earlier "1.8 / 3.3 / 5 V" claim is corrected to
"3.3–5 V (v1)"** in the product spec.

**4. Inline SPI pass-through → route both IN and OUT to FPGA I/O; ship emulation as default.**
Bring the SPI/UART IN *and* OUT pins to FPGA pins so inline pass-through (forward IN→OUT,
inject by override) becomes a firmware feature addable **without a respin**. v1 ships with
the **validated peripheral-emulation** path (FPGA = slave) as the default; inline
pass-through is experimental until proven on hardware.

**5. CAN termination → jumper-selectable, default OFF.** A fault injector usually taps a bus
that is *already* terminated; a fixed 120 Ω would over-terminate it. The jumper enables the
split-120 Ω only when HardFuzz is an end node.

---

## 11. KiCad build order (mechanical, once the above is fixed)

1. New project `hardware/hardfuzz_v1/` (`.kicad_pro`, `.kicad_sch`, `.kicad_pcb`).
2. Symbols: pull FPGA (Xilinx lib / custom), FT2232H, SN65HVD230, TXS0108E, regulators,
   USB-C, connectors from KiCad libs; draw a custom symbol for any missing part.
3. Capture per block above (power, FPGA, config, USB/FT2232H, shifters, CAN, connectors),
   using the net names in this doc as labels so the netlist matches the `.xdc` intent.
4. ERC clean → assign footprints (BGA CPG236, QFN-64, TSSOP-20, SOIC-8, JST-SH, etc.).
5. PCB: 4-layer (SIG / GND / PWR / SIG), USB-C edge, FPGA power fan-out, keep bus groups
   short and length-matched, split CANH/CANL as a routed pair, guard `TRIG`.

# HardFuzz v1 — Product Spec

> Forward-looking spec for the productized **HardFuzz v1** board. The current repo is the
> validated proof-of-concept it's built on (see [status](#8-status--what-changes-for-v1));
> this document describes what a shippable v1 adds and how it's meant to be used.

HardFuzz is a low-cost FPGA fault-injection module. It clips onto a live embedded bus and
injects precisely-targeted hardware faults — SPI bit-flips, I2C clock stretching, CAN
frame corruption — so firmware and safety engineers can prove their systems detect and
recover from real faults, and produce the evidence that ISO 26262 / IEC 61508 require.
An open (MIT), ~$40-BOM alternative to $30K–$80K bench tools.

---

## 1. Core concept

**HardFuzz connects at the *bus* level, not the MCU level.** It doesn't care whether the
controller under test is an STM32, PIC, ESP32, or an automotive Renesas part — only which
*protocol* it speaks and at what *voltage*. That's what makes one tool work across targets.

---

## 2. The board

| Block | Purpose |
|---|---|
| **FPGA** (Xilinx Artix-7 XC7A35T) | real-time fault-injection engine — fast/precise enough to hit an exact bit at an exact microsecond on a live bus |
| **USB-C** (FTDI bridge) | single cable to the host: control, campaigns, firmware updates |
| **CAN transceiver** (SN65HVD230) | onboard, so CAN is just two screw terminals to the bus |
| **Level shifters** (TXS0108E) + `VREF` sense | adapt every bus line to the target's logic level (1.8 / 3.3 / 5 V) automatically |
| **Bus monitor** | passive capture that logs traffic and marks the injected fault — closes the loop without a separate logic analyzer |
| **Pre-programmed flash** | ships with the multi-protocol bitstream loaded — no FPGA toolchain, ever |

Form factor: ~60 × 40 mm PCB, stackable headers, USB-C on one edge.

---

## 3. How it connects to a device under test

There are two attach models, chosen by bus type — this is the key wiring distinction:

### Shared buses (I2C, CAN, LIN) → parallel tap
Open-drain / dominant-recessive: any node can pull the line and dominant wins, so HardFuzz
just connects **in parallel** to the live bus (no cutting traces) and injects by pulling
the line. You can hang it off a running system.

### Point-to-point buses (SPI, UART) → inline interposer *or* peripheral emulation
Push-pull and dedicated, so tap-and-override would make drivers fight. Two options:
- **Inline (series):** the board sits *in* the trace — an IN side to the MCU, an OUT side
  to the peripheral (`MCU → HardFuzz → flash`), passing traffic through and corrupting a
  chosen bit on the wire. True man-in-the-middle against a *real* peripheral.
- **Peripheral emulation:** the board *becomes* the peripheral (the FPGA acts as the SPI
  slave). For testing the MCU's fault handling without the real peripheral present.

| Protocol | Attach mode | Connector on v1 |
|---|---|---|
| I2C | parallel tap | **Qwiic/STEMMA** (plug a standard cable, no jumpers) |
| CAN | parallel tap | screw terminals (CANH/CANL) |
| SPI | inline interposer or peripheral emulation | keyed IN/OUT header + clip-on interposer |
| UART | inline interposer | keyed IN/OUT header |

Always: tie **`VREF`** to the target's logic rail (auto level-shifting) and share **`GND`**.
A **`TRIG`** pin drives a scope and accepts a DUT GPIO to sync injection to firmware state.

---

## 4. Out-of-box experience

Ranked by how much friction each removes:

1. **Pre-programmed board** — the bitstream is already in flash. The user never installs
   an FPGA toolchain or flashes anything. Plug in USB and it's a working injector.
2. **Passive injection = no DUT firmware changes.** The FPGA autonomously watches the bus
   and fires on the target event (Nth transaction, address match, external trigger). The
   user runs their **actual product firmware, unmodified** — "clip it on and go," not
   "instrument my firmware."
3. **Onboard bus monitor** shows the injected fault and what the target did next, so the
   user sees the effect without wiring their own logic analyzer.
4. **One self-contained app** (single binary / small GUI) — no Python, pyserial, or
   compiler — that **auto-detects** the board (USB VID/PID), the **voltage** (`VREF`), and
   the **port**.
5. **Keyed connectors + included cables** (Qwiic for I2C, CAN pigtail, SPI interposer) so
   there's no pin-counting or swapped-wire debugging.

### The 60-second first run
Plug HardFuzz into your laptop (USB-C) → snap the Qwiic cable onto your board's I2C bus and
touch `VREF` to its 3.3 V pin → open the app (it finds the board) → click *"Stretch I2C,
address 0x50, 1 ms"* → run your device → watch the monitor show the stalled transfer and
your firmware's timeout. No firmware changes, no toolchain, no wiring puzzle.

---

## 5. Two operating modes

- **Passive "clip-on" exploration (default):** zero effort, no firmware changes; the user
  judges the result (or reads the onboard monitor). Great for poking at a system.
- **Command-mode automated campaigns (opt-in):** the DUT runs a small run-command hook so
  the host can drive transactions and record verdicts hands-off — for CI and certification
  evidence runs where you want a report with no human in the loop.

---

## 6. Software

The `hardfuzz` host app runs **campaigns** — JSON descriptions of faults to try and the
expected DUT behaviour — with:
- **coverage-guided scheduling** (exercises untested fault tuples first),
- **live execution** over USB (arms the FPGA, optionally drives the DUT, records verdicts),
- **JSON / CSV / HTML reports** with ISO 26262 / IEC 61508 requirement traceability — the
  artifact you hand an auditor.

---

## 7. Cost & positioning

| | |
|---|---|
| BOM (100-unit run) | ~$40 |
| Target retail | $149–$199 |
| Competition | Lauterbach / Kraken / XCITE at **$30K–$80K per seat** |
| License | MIT — extend it to your own protocols and targets |

---

## 8. Status — what changes for v1

**Validated today (this repo, dev-board proof-of-concept):**
- SPI bit-flip and I2C clock-stretch injection — proven end-to-end on hardware
  (Cmod A7 + NUCLEO-F446RE), including a **mixed SPI+I2C campaign on one bitstream**.
- CAN frame corruption — built and simulation-verified.
- The full host campaign / coverage / scheduling / reporting engine (JSON/CSV/HTML).

**What v1 productization adds:**
- Custom PCB (KiCad) with onboard CAN transceiver, `VREF` sensing + level shifters, and
  keyed connectors (Qwiic / CAN / SPI interposer).
- Pre-programmed flash so the toolchain is invisible to users.
- Passive trigger modes (on-address, on-GPIO) + the bus monitor, for zero-firmware-change use.
- A single self-contained host app with auto-detection.

The engine is real and proven; v1 is the packaging that makes it plug-and-play.

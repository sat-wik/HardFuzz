# HardFuzz — Refined Plan for Cmod A7 + NUCLEO-F446RE

*Adaptation of the v1.0 product plan to the exact hardware on hand, with no FPGA
toolchain installed yet and no logic analyzer or oscilloscope.*

Your parts:
- **Digilent Cmod A7** — Artix-7 (XC7A35T or XC7A15T), 12 MHz clock, 44 GPIO on
  DIP + one Pmod, 3.3V I/O (not 5V tolerant), USB via FT2232HQ (JTAG + UART bridge).
- **NUCLEO-F446RE** — STM32F446RE Cortex-M4 @180 MHz, hardware SPI/I2C/UART/bxCAN,
  3.3V I/O. This is your Device Under Test *and* your test instrument.

---

## 1. The reality check

Three constraints reshape the roadmap. None of them are blockers for a real MVP,
but they move work around.

**No instrumentation is the big one.** The original plan's exit criteria lean on a
logic analyzer ("observe fault in logic analyzer") and implicitly a scope (glitch
width, jitter). You have neither. This does **not** stop digital fault work — see
§2 — but it *does* make analog fault work (voltage/clock glitching) undesignable-to-
verify for now. You can write and simulate `glitch_gen.v`, but you cannot measure a
5 ns pulse or "<10 ns jitter" without a scope. Treat glitch generation as
sim-only until you have a scope.

**One STM32 = no true inline injection yet.** "Inline" injection means the FPGA sits
*between* a bus controller and a separate peripheral. With a single STM32 you don't
have that controller+peripheral pair. The fix is clean and actually simpler for a
first build: **make the FPGA the peripheral.** STM32 is SPI/I2C master; the FPGA
emulates the slave and owns the whole data path, so it can corrupt anything. No
second chip, no bus-contention/tristate headaches (that CAN risk in the register
disappears for SPI/I2C this way).

**No CAN transceiver on either board.** CAN is out until you buy a breakout
(~$2–10, see §5). You can still develop and simulate `frame_corrupt.v`, but no
on-hardware CAN this month.

---

## 2. How you verify without a logic analyzer

This is the load-bearing change, so it gets its own section. You replace one
physical instrument with three free substitutes, in order of how much you'll lean
on each:

1. **Simulation is now your primary verifier**, not a pre-check. Every core gets a
   testbench and you confirm correctness on waveforms *before* touching hardware.
   Vivado's XSim does this; Icarus Verilog + GTKWave is a lighter alternative for
   fast iteration. ~90% of "is the fault logic correct" is answered here.

2. **The Xilinx ILA (Integrated Logic Analyzer) is your on-chip logic analyzer.**
   You instantiate an ILA core in the FPGA, wire it to the SPI/I2C signals and your
   injection points, and capture them over JTAG in Vivado — triggered on "frame ==
   N". This genuinely replaces a physical logic analyzer for *digital* signals
   (it can't show you analog glitch shape). It's the single biggest reason "no
   logic analyzer" is survivable. Requires Vivado.

3. **The STM32 is a self-checking DUT.** For a bit flip: STM32 sends a known SPI
   frame → FPGA echoes it back with frame-N/bit-B flipped → STM32 compares
   sent vs. received and prints `"frame 5 bit 3: expected 0xA4 got 0xAC — FLIP OK"`
   over UART. The test proves itself with zero external gear. This is your
   hardware-level acceptance test and it's better evidence than eyeballing a trace.

Net effect: **digital faults (bit flip, frame corruption, protocol timing) are
fully verifiable. Analog faults (voltage/clock glitch) are sim-only** until you get
a scope.

---

## 3. Revised MVP

Original MVP was SPI bit flip + CAN CRC error + coverage report + CLI. Swapping the
part you can't test yet (CAN) for one you can:

1. **SPI bit-flip injection** at user-specified frame + bit position — verified by
   STM32 loopback self-report + ILA + sim. *(fully reachable)*
2. **I2C timing distortion** (clock stretch / setup-hold violation) — verified by
   STM32 I2C master reporting timeouts/NACKs + ILA. *(fully reachable, replaces CAN
   as the second protocol)*
3. **Coverage report** (JSON/CSV) from the host library — pure software.
4. **CLI control on Linux/macOS** over the Cmod's UART bridge.

CAN CRC error moves to "first post-MVP milestone, unlocked by a $5 transceiver."
Voltage glitching stays where the original plan put it: v2.

---

## 4. Revised roadmap

Kept in the plan's month structure, but with content and — importantly — **exit
criteria** rewritten to things you can actually observe.

### Month 1 — Toolchain, links, and first SPI fault

Goal: prove the whole loop end-to-end on the simplest possible fault.

- [ ] Install Vivado (Standard/WebPACK edition covers XC7A35T/15T for free; budget
      ~30–100 GB and a long download). Add Digilent Cmod A7 board files.
- [ ] Toolchain bring-up: blink an LED on the Cmod A7.
- [ ] Host link bring-up: UART echo through the FT2232 bridge (this *is* your
      "host → FPGA" channel; no separate FT232H needed).
- [ ] DUT link bring-up: FPGA **SPI slave** core + STM32 SPI-master firmware doing
      plain loopback (no injection yet).
- [ ] `ctrl_regs`: a **UART-command → register-write FSM** in Verilog. *Skip
      AXI-Lite and a soft CPU for MVP* — you don't have MicroBlaze/PicoRV bring-up
      time to spare and don't need it (see §6).
- [ ] `bitflip_inj.v`: flip MOSI/MISO at target frame N, bit B, inserted into the
      SPI slave datapath.
- [ ] Add an ILA on the SPI signals for capture.

**Exit criteria (revised):** STM32 sends a known SPI stream through the FPGA; a
bit flip is injected at frame 5, bit 3; STM32 prints the expected-vs-received
mismatch over UART **and** the flip is visible in an ILA capture. *(No logic
analyzer required.)*

### Month 2 — I2C timing faults + host register driver

Goal: second protocol + a real host control path.

- [ ] `timing_distort.v`: I2C clock stretching + SPI setup/hold violation.
- [ ] FPGA I2C slave (or clock-line interposer) so the STM32 I2C master sees the
      distortion.
- [ ] Host register driver in C (`hardfuzz_regs.c`) over the UART bridge — this is
      **host-side C, not on-FPGA firmware** (see §6).
- [ ] Simple fault scheduler: trigger modes *immediate* and *on-frame-N*.
- [ ] Develop `frame_corrupt.v` (CAN) **in simulation only** so it's ready when the
      transceiver arrives.

**Exit criteria (revised):** From the host CLI, arm an I2C clock-stretch fault; the
STM32 master reports the resulting timeout/NACK over UART; ILA confirms the stretched
SCL.

### Month 3 — C++ orchestration, coverage, reporting

Unchanged from the original plan in spirit — it's mostly host software and needs no
new hardware. This is where the plan's C++ work fits cleanly.

- [ ] `FaultCampaign` API, coverage tracker bitmap, weighted scheduler.
- [ ] CLI: `hardfuzz run <campaign.json>`, `hardfuzz report --format=html`.
- [ ] JSON/CSV exporter with IEC 61508 traceability fields.
- [ ] Example campaigns for SPI + I2C targets (drop the CAN examples until §5).

**Exit criteria:** overnight campaign against the STM32 (many SPI/I2C faults),
producing a coverage map + pass/fail per scenario — pass/fail sourced from the
STM32's own UART verdicts.

### Month 4 — Hardening, CAN (if part arrived), docs

- [ ] If the CAN transceiver arrived: bring `frame_corrupt.v` to hardware.
- [ ] Edge cases: DUT reset-recovery detection (STM32 reports its own resets).
- [ ] Docs: quick start, Verilog architecture, host API.
- [ ] Defer PCB layout — you're on a dev board and that's the right call for a v1
      you can iterate on. KiCad work only makes sense once the design is frozen.

---

## 5. Parts that unlock the rest of the plan

Small, cheap additions, roughly in priority order:

| Part | ~Cost | Unlocks |
|---|---|---|
| CAN transceiver breakout (SN65HVD230, 3.3V) | $2–8 | CAN frame corruption on hardware; the MVP's original protocol #2 |
| Cheap logic analyzer (FX2-based, sigrok) or Saleae clone | $10–150 | Independent bus verification beyond ILA; a real second opinion |
| Oscilloscope (even a $25 DSO / a used ≥100 MHz scope) | $25–300+ | The *only* way to verify voltage/clock glitch width + jitter; gates all analog fault work |
| Second STM32 or any SPI peripheral (e.g. a real SPI flash) | $3–15 | True *inline* man-in-the-middle injection between two real devices |

You can reach the full revised MVP (§3) with **zero** of these. The CAN transceiver
is the highest-value next purchase; the scope is what turns glitch generation from
a simulation exercise into a real feature.

---

## 6. Simplifications worth taking vs. the original plan

The plan was written as an aspirational product spec. For a solo first build on this
hardware, these trims cut real work without hurting the MVP:

- **Drop AXI-Lite + soft CPU.** The plan's `ctrl_regs.v` as AXI-Lite implies a
  MicroBlaze/PicoRV32 running on-FPGA C firmware. Replace with a plain
  UART→register FSM in Verilog. The "C layer" then lives entirely on the host
  (talking UART), not on the FPGA. Big reduction in bring-up complexity.
- **FPGA-as-peripheral instead of inline** (§1) — removes the tristate/bus-guardian
  circuitry and the CAN-contention risk for the SPI/I2C MVP.
- **Glitch generator = sim-only** until a scope exists — don't sink hardware time
  into something you can't measure.
- **No PCB in v1** — stay on the Cmod A7. PCB is a post-freeze activity.
- **Coverage-guided scheduling stays post-MVP**, as the plan already says; a simple
  immediate/on-frame-N scheduler is enough to demonstrate the pipeline.

---

## 7. Suggested first concrete steps

1. Install Vivado + Cmod A7 board files; blink an LED.
2. UART echo through the FT2232 bridge.
3. STM32 SPI-master firmware + FPGA SPI-slave loopback (no injection).
4. Add the UART→register FSM and `bitflip_inj`; hit the Month 1 exit criteria.

Steps 1–3 are "hello world"s that de-risk the toolchain and both comms links before
any fault logic exists — the right order when nothing is set up yet.

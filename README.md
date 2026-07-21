# HardFuzz

FPGA-based fault injection test module. Target hardware for this build: **Digilent
Cmod A7** (Artix-7) + **ST NUCLEO-F446RE** as the first Device Under Test.

See [docs/HardFuzz_Product_Plan.md](../HardFuzz_Product_Plan%20(1).md) for the full
product vision and [HardFuzz_Refined_Plan.md](HardFuzz_Refined_Plan.md) for the
version adapted to exactly this hardware (single STM32, no instruments yet).

## Layout

```
rtl/            Verilog sources
  uart/         UART RX/TX (the host link over the Cmod's FT2232 bridge)
  ctrl/         ctrl_regs.v — UART->register-file command FSM (host control)
  spi/          spi_slave.v — mode-0 SPI slave, the DUT-facing bus (echo response)
  i2c/          i2c_slave.v — I2C slave (write xactions) with clock-stretch hook
  can/          frame_corrupt.v — CAN bus monitor + force-dominant injector
  inject/       bitflip_inj.v (SPI bit flip), timing_distort.v (I2C clock stretch)
  timing/       pulse_meter.v — scope-free timing measurement
  hardfuzz_top.v    bring-up top: LED heartbeat + UART echo
  spi_inject_top.v  Month 1 integration: host-armed SPI bit-flip injection
  i2c_inject_top.v  Month 2 integration: host-armed I2C clock-stretch injection
  can_inject_top.v  Month 2 integration: host-armed CAN frame corruption (sim-only)
sim/            testbenches + Icarus runner (primary verifier for now)
constraints/    cmod_a7.xdc  (pinout; SPI on Pmod JA)
scripts/        Vivado batch build / program TCL
firmware/       STM32 C — SPI master (main.c) + I2C master (main_i2c.c)
host/           arm.py + Month 3 C++ campaign library (include/hardfuzz/) & `hardfuzz` CLI
docs/           timing-verification.md and design notes
```

## Prerequisites

- **Icarus Verilog + Surfer** for fast simulation — `brew install icarus-verilog surfer`.
  (Surfer is the maintained, native-arm64 waveform viewer; the old `gtkwave` cask is
  discontinued and x86-only.)
- **Xilinx Vivado** (free ML Standard edition) for synthesis, bitstream, and the ILA
  — but Vivado has **no macOS build**, so run it on a Linux box / cloud instance and
  copy the `.bit` back. See [docs/vivado-cloud.md](docs/vivado-cloud.md).
- **openFPGALoader** (`brew install openfpgaloader`) to program the Cmod A7 from
  macOS natively — `make prog`. Board string: `cmoda7_35t` (or `cmoda7_15t`).

## Quick start

Simulate first — no board required:

```
make sim         # UART echo self-check   -> "ALL TESTS PASSED"
make sim-pulse   # timing meter self-check
make wave        # run a sim and open the waveform in Surfer
                 #   (pick another: make wave WAVE=tb_pulse_meter)
                 #   how to read it: docs/waveforms.md
```

Then, to get onto hardware (Vivado on Linux/cloud, program from the Mac):

```
make bit         # ON A LINUX/CLOUD BOX: synth + P&R + bitstream (docs/vivado-cloud.md)
                 #   copy build/vivado/spi_inject_top.bit back to the Mac
make prog        # ON THE MAC: openFPGALoader loads the .bit to the Cmod A7
```

On the board, `led[0]` blinks at ~1 Hz (clock/toolchain alive). Open the Cmod's USB
serial port at **115200 8N1** and type — every character echoes back and `led[1]`
toggles (host link alive).

## Verifying timing without a scope

You'll add a logic analyzer and oscilloscope later. Until then,
[docs/timing-verification.md](docs/timing-verification.md) covers how to measure
digital fault timing on-chip (cycle counting, loopback calibration, the ILA, and a
reserved `trig_out` pin) and — importantly — what stays invisible until the
instruments arrive.

## Month 1 core: SPI bit-flip injection

`spi_inject_top` is the FPGA-as-SPI-slave design from the refined plan. The host arms
a target over UART; the STM32 (SPI master) clocks frames; the injector flips the
chosen bit of the MISO echo; the STM32 reads back the corrupted byte. Register map:

| Access | Addr | Meaning |
|---|---|---|
| W/R | reg0 | control: bit0 `inj_enable`, bit1 `clr_frame` (pulse), bit2 `line_sel` (rsvd) |
| W/R | reg1 | `target_frame[7:0]` |
| W/R | reg2 | `target_frame[15:8]` |
| W/R | reg3 | `target_bit` (0=LSB .. 7=MSB) |
| R | 0x80 | `frame_idx[7:0]` (bytes seen since reset/clr) |
| R | 0x81 | `frame_idx[15:8]` |
| R | 0x82 | `flip_count` |

UART wire protocol: `W`(0x57) addr data to write; `R`(0x52) addr to read one byte.
E.g. to flip frame 5, bit 3: `W 01 05`, `W 02 00`, `W 03 03`, `W 00 01`.

`tb_spi_inject` proves this end-to-end in simulation (arm over UART → clock 8 frames →
only frame 5 / bit 3 flips, `flip_count == 1`). All four testbenches pass under Icarus:
`make sim`.

## Month 2 core: I2C clock-stretch injection

`i2c_inject_top` is the FPGA-as-I2C-slave counterpart to the SPI design. The host arms
a target byte + stretch length over UART; the STM32 (I2C master) writes a transaction;
on the target byte the slave holds SCL low for the programmed time — an abnormal clock
stretch that stalls the master and trips its timeout. Register map:

| Access | Addr | Meaning |
|---|---|---|
| W/R | reg0 | control: bit0 `distort_enable`, bit1 `clr` (reset stretch counter) |
| W/R | reg1 | `target_byte` (0=address, 1=first data byte, 2=second, ...) |
| W/R | reg2 | `stretch_len[7:0]` |
| W/R | reg3 | `stretch_len[15:8]` (SCL-low hold in 12 MHz cycles; 1200 ≈ 100 µs) |
| R | 0x80 | `byte_index` |
| R | 0x81/0x82 | `stretch_count` low/high |

I2C is open-drain on Pmod JA7 (SCL) / JA8 (SDA); slave address `0x42`. `tb_i2c_inject`
proves it end-to-end in sim (arm over UART → I2C write → SCL stretched only on the
target byte, ~20 µs, `stretch_count == 1`). **RTL is sim-verified; not yet run on
hardware** — needs STM32 I2C-master firmware (the current firmware is SPI-only) and a
separate bitstream (`make bit TOP=i2c_inject_top`).

## Month 2 core: CAN frame corruption (sim-only)

`can_inject_top` corrupts CAN frames without being the transmitter, exploiting the
bus's wired-AND rule: a dominant bit always wins. `frame_corrupt` watches the bus
(RXD from a transceiver), tracks the bit index from Start-Of-Frame, and on a host-armed
bit forces the bus dominant for `width` bits. Aim decides the fault: a data/CRC bit →
bad CRC; ≥6 forced bits → bit-stuffing violation; a bit in the EOF → form error.

| Access | Addr | Meaning |
|---|---|---|
| W/R | reg0 | control: bit0 `enable`, bit1 `clr` |
| W/R | reg1 | `target_bit[7:0]` (index from SOF; SOF = bit 0) |
| W/R | reg2 | `target_bit[15:8]` |
| W/R | reg3 | `width` (consecutive bits to force dominant; ≥6 = stuff error) |
| R | 0x80/0x81 | `corrupt_count` lo/hi |
| R | 0x82/0x83 | `frame_count` lo/hi |

Arm with `arm.py … can --bit 20 --width 1`. `tb_can_inject` proves it in sim (targeted
bits forced dominant, untargeted bits untouched, `corrupt_count` correct).
**SIM-ONLY** — hardware needs an SN65HVD230 transceiver on `can_txd`/`can_rxd` (shares
Pmod JA7/JA8) plus STM32 bxCAN firmware; neither exists yet.

## Status

**Working on hardware ✅** — the Month 1 MVP runs end to end on a Cmod A7 + NUCLEO-F446RE.
Host arms a target over UART (`arm.py`), the STM32 clocks SPI frames, the FPGA injects
exactly one bit on the chosen frame, and the STM32 reads back and reports the fault
(e.g. frame 5 bit 3: `0xA4 → 0xAC`, all other frames clean). Design is in the Cmod's
flash (`make prog-flash`), so it survives power cycles.

Bring-up gotchas (both fixed): `make prog` loads to **volatile SRAM** — use
`prog-flash` to persist; and the Cmod UART pins are `uart_rxd_out=J18`,
`uart_txd_in=J17` (do not swap — it silently kills the register interface while SPI
still works).

Both the **SPI bit-flip** (Month 1) and **I2C clock-stretch** (Month 2) cores now run
end to end on hardware — host arms over UART, the STM32 master runs a transaction, the
FPGA injects, and the master catches the fault (SPI: `0xA4→0xAC`; I2C: byte hits the
master's timeout at 2 ms while the slave holds SCL low).

**Verified in sim + hardware:** `spi_slave`, `bitflip_inj`, `spi_inject_top` + SPI
firmware; `i2c_slave`, `timing_distort`, `i2c_inject_top` + I2C firmware; `ctrl_regs`,
`arm.py`.
**Verified in sim (not yet on hardware):** `frame_corrupt`, `can_inject_top`.

**Month 3 C++ campaign layer (`host/`) — built + self-tested:** header-only C++17
(`FaultCampaign`, `CoverageTracker`, coverage-guided `Scheduler`, `RegClient`,
JSON/CSV reports with IEC 61508 traceability) + the `hardfuzz` CLI, with **live mode**:
it arms the FPGA over the Cmod UART and drives the STM32 run-command firmware (send
`'R'` → `RESULT` line) for real pass/fail verdicts. Verified against a mock transport
(`make -C host`, 18 checks); the run-command firmware is in `main.c`/`main_i2c.c`.

**Next:** validate live `hardfuzz run` on the boards (dry run + serial parsing are
tested; the end-to-end serial path needs a hardware pass); CAN hardware bring-up when
the SN65HVD230s arrive; HTML report + coverage heatmap. `trig_out` is ready for a scope.

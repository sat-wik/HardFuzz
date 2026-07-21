# Verifying timing without a scope

You'll have a logic analyzer and oscilloscope later. Until then, the trick is to
**turn time into a number you can print**: measure events in FPGA clock cycles on
the chip itself and read the counts out over UART. For *digital* timing this is not
a hack — it's a genuine measurement, often finer than a hobby logic analyzer.

## The core primitive

`rtl/timing/pulse_meter.v` counts how many clock cycles a signal is high (pulse
width) and how many elapse between rising edges (period), then reports the counts.
Resolution equals one clock period:

| Measurement clock | 1 count = | Good for |
|---|---|---|
| 12 MHz (raw sysclk) | 83.3 ns | coarse checks only |
| 100 MHz (via MMCM)  | 10.0 ns | SPI/I2C bit timing, clock stretch |
| 200 MHz (via MMCM)  | 5.0 ns  | short glitch widths, setup/hold |
| 400 MHz (via MMCM)  | 2.5 ns  | near the Cmod's practical ceiling |

So step one for real timing work is to **bring up an MMCM** that multiplies the
12 MHz sysclk up to 100–200 MHz, and run the meter (and later the injection cores)
on that clock. The raw 12 MHz clock is far too coarse for nanosecond faults.

## Five techniques, cheapest first

1. **Cycle counting (`pulse_meter`).** Feed it the signal under test, read
   `width_cnt`/`period_cnt` over UART, multiply by the clock period. This is your
   everyday ruler. `sim/tb_pulse_meter.v` shows it measuring a known pulse.

2. **Self-consistency / loopback calibration.** Have the FPGA *generate* a pulse of
   a programmed width (say N cycles) and feed it straight back into `pulse_meter`.
   If you command N and measure N, your generator and your ruler agree — that
   validates the injection logic's timing without any external reference at all.
   Do this for every width you plan to use; build a command→measured table.

3. **On-chip logic analyzer (Xilinx ILA).** Instantiate an ILA core, wire it to the
   bus and injection signals, sample it on your fast clock, and trigger on
   "frame == N". You get a timestamped digital capture downloaded over JTAG in
   Vivado — effectively a built-in logic analyzer at your clock's resolution.
   Requires Vivado (not Icarus), so it's a hardware-only tool.

4. **Statistical jitter estimate.** Sample an asynchronous edge with the fast clock
   over many repetitions and histogram where the edge lands. The spread estimates
   jitter to roughly one clock period — enough to catch gross instability before a
   scope confirms the exact number.

5. **Sub-nanosecond TDC (advanced, and it still beats waiting for the scope).**
   Artix-7 has `IDELAYE2` primitives with ~78 ps taps and fast carry chains. A
   tapped-delay-line time-to-digital converter measures edge position to well under
   1 ns entirely on-chip. This is real work — save it for when you actually need to
   prove "<10 ns jitter" and don't yet have a good scope.

## The one pin to reserve now: `trig_out`

The XDC keeps a Pmod pin (`JA9`) reserved as `trig_out`. Make **every injection
pulse it once**. Two payoffs:

- Now: route it to an LED or into `pulse_meter` for a zero-instrument sanity check.
- Later: when the scope/logic analyzer arrives, you trigger on this single clean
  digital edge instead of hunting for the fault in a noisy bus capture. Designing
  the trigger in from day one is the difference between a 5-second and a 5-minute
  capture setup.

## What this genuinely cannot see (wait for the instruments)

Counters observe *logical* transitions at the FPGA input buffer. They are blind to
everything analog:

- **Pulse shape and voltage** of a glitch — rise/fall time, overshoot, whether a
  "glitch" actually reached a valid logic threshold. Needs a scope.
- **Sub-threshold / power-rail glitches** — the whole point of voltage glitching is
  analog; the FPGA can't measure its own supply fast enough (XADC tops out ~1 MSPS).
- **Signal integrity** — ringing, reflections, crosstalk on the DUT wiring.

Practical split: **digital fault timing (bit flips, frame corruption, clock stretch,
setup/hold) is fully measurable on-chip today.** Analog fault work (voltage/clock
glitch amplitude and shape) is design-and-simulate-only until the scope arrives —
which matches the refined plan deferring glitch generation to sim-only for now.

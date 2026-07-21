# Viewing waveforms with Surfer

Waveforms are how you *see* what the RTL did — the sim's self-checking `PASS`/`FAIL`
lines tell you whether it's correct; the waveform tells you *why* when it isn't.

## Open one

```
make wave                      # runs tb_uart_echo, opens tb_uart_echo.vcd
make wave WAVE=tb_pulse_meter  # any other testbench
```

`make wave` regenerates the `.vcd` first (they're deleted by `make clean`), then
launches Surfer. Surfer runs in the foreground until you close its window.

## The layout

- **Left sidebar, top** — the *scope hierarchy*: `tb_uart_echo` › `dut` › `u_rx`,
  `u_tx`. Click a scope to select it.
- **Left sidebar, below** — the *variables* in the selected scope. Click one to add
  it to the wave view (or select several).
- **Center** — the waveform canvas.
- **Fastest way to add a signal:** press **Ctrl+Space** for the fuzzy command/-
  variable palette, type part of a name (e.g. `fpga_tx`), Enter.

Useful view controls: **Zoom-fit** to see the whole run first, then mouse-wheel /
toolbar to zoom into the region of interest. Click the canvas to drop a time marker;
a second marker measures the interval between two edges.

## A guided first look: the UART echo

The testbench sends `0x5A, 0xC3, 0x00, 0xFF` into the FPGA and checks the echo. The
whole run is ~663 µs; **zoom to roughly 0–200 µs** to see the first byte go in and
come back. Add these signals (top-to-bottom makes a readable stack):

| Signal (scope) | What it shows |
|---|---|
| `clk` (tb) | the 12 MHz timebase |
| `fpga_rx` (tb) | serial **in** (host → FPGA) — the stimulus |
| `state` (`dut.u_rx`) | receiver FSM walking IDLE→START→DATA→STOP |
| `rx_valid` (`dut`) | 1-cycle pulse when a byte is received |
| `rx_data` (`dut`) | the received byte — **set radix to hex** (see below) |
| `fpga_tx` (tb) | serial **out** (FPGA → host) — the echo |
| `tx_busy` (`dut`) | high while the byte is being sent back |

**Set a bus to hex:** right-click `rx_data` (or `got`) → *Format* → *Hexadecimal*.
Then it reads `5A` instead of a binary blob.

**Decode `fpga_rx` by eye** (UART is 8N1, LSB-first): one low **start** bit, then 8
data bits *least-significant first*, then a high **stop** bit. `0x5A` = `0101_1010`,
so on the wire after the start bit you'll see `0,1,0,1,1,0,1,0`. Each bit is ~8.68 µs
wide (115200 baud). You should see `rx_valid` pulse and `rx_data` become `5A` right
after the stop bit, then the same pattern reappear on `fpga_tx` as the echo.

## The timing-meter sim

For `tb_pulse_meter`, add `sig`, `dut.width_cnt`, `dut.period_cnt`, and `sample`.
Watch `width_cnt` latch `10` when `sig`'s pulse ends and `sample` strobes — that's
the "measure time as a cycle count" idea from
[timing-verification.md](timing-verification.md), on screen.

## Tip: save a view you like

Set up the signals/radix once, then use Surfer's save-state, and reopen with
`surfer -s <state-file> <file>.vcd` to skip re-adding everything. (Surfer's
`--command-file` scripting exists too but is marked unstable upstream, so a saved
state file is the durable option.)

# host/

Host-side tooling. Talks to the FPGA over the Cmod's USB-UART bridge (115200 8N1) —
the "C layer" from the product plan lives here on the host, not on the FPGA (no FTDI
FT232H or on-FPGA soft CPU needed).

## Now

- **`arm.py`** — arm / disarm / inspect the injectors over the Cmod USB port.
  ```
  pip install pyserial
  # SPI bit-flip (spi_inject_top):
  python3 arm.py --port /dev/tty.usbserial-XXXX arm --frame 5 --bit 3
  # I2C clock stretch (i2c_inject_top):  byte to target, hold in 12 MHz cycles
  python3 arm.py --port /dev/tty.usbserial-XXXX i2c --byte 2 --stretch 2400
  python3 arm.py --port /dev/tty.usbserial-XXXX status     # frame_idx, inj/stretch count
  python3 arm.py --port /dev/tty.usbserial-XXXX disarm
  ```
  Add `can --bit 40 --width 1` for the CAN corruptor. Find the port with
  `ls /dev/tty.usbserial-*` (macOS). All three injectors share `ctrl_regs`, so the
  subcommands just write the same registers with the right meaning per top.

## C++ campaign layer (Month 3)

Header-only C++17 library (`include/hardfuzz/`) + the `hardfuzz` CLI — the
`FaultCampaign` / coverage / scheduling / reporting layer from the product plan.
`arm.py` is the throwaway ancestor of `RegClient`.

```
make            # build the CLI + run the self-test (no board needed)
make run        # dry-run the example campaign through the CLI
```

Pieces:
- **`RegClient`** (`reg_client.hpp`) — arms each injector over a `Transport`
  (`SerialTransport` for the Cmod, `MockTransport` emulates `ctrl_regs` for offline tests).
- **`CoverageTracker` + `Scheduler`** (`coverage.hpp`) — bitmap of faulted
  `(protocol, a, b)` tuples; the scheduler runs the least-covered fault first, so
  duplicate tuples deprioritize automatically.
- **`CampaignRunner`** (`campaign.hpp`) — arm → run DUT → record verdict → update coverage.
- **`report.hpp`** — JSON/CSV export with IEC 61508 traceability fields.

CLI:
```
# dry run: coverage-guided schedule + exact arm bytes, no board
hardfuzz run campaigns/example.json --json report.json --csv report.csv --html report.html

# live: arm the FPGA (Cmod UART) + drive the STM32 for real pass/fail verdicts
hardfuzz run campaigns/i2c.json \
    --arm-port /dev/cu.usbserial-XXXX \       # Cmod (ctrl_regs)
    --dut-port /dev/cu.usbmodemXXXX  \        # STM32 (run-command firmware)
    --html report.html
```
`--json` / `--csv` / `--html` all optional. HTML is a self-contained, light/dark-aware
evidence page (summary, color-coded verdicts, coverage bars) — `open report.html`.
Live mode exits nonzero if any scenario fails (CI-friendly).

Campaign JSON (`campaigns/example.json`): each fault takes role-named params —
SPI `frame`/`bit`, I2C `byte`/`stretch_cycles`, CAN `bit`/`width` — plus `expect`
(`detected`|`tolerated`) and a `requirement` tag for traceability.

**Status:** library + CLI built and self-tested against mocks (`make`). Live mode is
implemented end to end — it needs the STM32 **run-command firmware** (send `'R'` → the
STM32 runs one transaction and prints a `RESULT` line), which `firmware/main.c` and
`main_i2c.c` now include. Both dry-run and the serial `RESULT` parsing are covered by
the self-test; the live path itself is exercised on hardware.

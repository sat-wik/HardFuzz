# kigen — HardFuzz v1 schematic generator

The v1 board is captured **as code**: [`kigen.py`](kigen.py) emits KiCad 10 `.kicad_sch`
files, and each `*_sheet.py` defines one sheet's parts and nets. Regenerate + validate:

```bash
KCLI=/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli
python3 gen/power_sheet.py                       # -> ../power.kicad_sch
$KCLI sch export netlist --format kicadxml -o /tmp/n.xml ../power.kicad_sch   # connectivity
$KCLI sch export pdf -o ../power.pdf ../power.kicad_sch                        # visual
$KCLI sch erc ../power.kicad_sch                                               # rules
```

## How it works

- **Authoritative symbols.** Each component's library symbol is pulled *verbatim* from
  KiCad's stock `.kicad_sym` files (`/Applications/KiCad/.../symbols`) — no re-serialized
  guesswork. Pin coordinates come from the same source, so labels land exactly on pins.
- **`extends` / derived symbols are flattened.** KiCad embeds derived symbols (e.g.
  `AP2112K-1.8` → `AP2204K-1.5`) with the parent's drawing copied in and child units
  renamed to the derived base; `kigen` does this so derived parts net correctly.
- **Connectivity via net labels.** Every component is placed at rotation 0 (transform is
  just a Y-flip) and each pin gets a local net-label at its endpoint. Same label name =
  same net — no fragile wire routing. Two pins with the same net join (verified in the
  netlist). Power symbols (`power:+3V3`, `GND`, …) merge into global rails.

The output is an **electrically-correct, ERC-checkable "netlist as schematic."** Aesthetic
placement/routing is left to eeschema; `kigen` guarantees the connections.

## Format notes (hard-won)

- KiCad 10.0.4 writes schematic format **`20260306`** — declare exactly this.
- The root needs `(embedded_fonts no)`; a `(title_block ...)` is expected.
- In `lib_symbols`, only the **top-level** symbol takes the `lib:name` id; child units keep
  a bare `<base>_<unit>_<style>` name whose base matches the top's un-prefixed name.
- Stock `.kicad_sym` libs are a newer format (`20251024`) than old bundled templates
  (`20250114`); mixing the version token with newer tokens is what made early files fail
  to load.

## Sheets

Each `*_sheet.py` has `populate(s)` (adds its parts/nets to a shared schematic) and a
standalone `build()`. `build_board.py` composes them into one flat **`board.kicad_sch`**,
placing each block in its own region via origin offsets — cross-block signals share
local-label names and rails are global, so the whole board nets as one connected design.

| Sheet | Contents | Status |
|---|---|---|
| `power_sheet.py` | 3 regulators (+3V3/+1V0/+1V8), feedback dividers, decoupling | ✅ netlist-verified |
| `can_sheet.py` | SN65HVD230, split-120R term, screw terminal | ✅ netlist-verified |
| `levelshift_sheet.py` | TXS0108E, I2C pull-ups, VREF sense+TVS, Qwiic + headers | ✅ netlist-verified |
| `usb_sheet.py` | FT2232HQ, USB-C, USBLC6, VBUS TVS, 12 MHz xtal, QSPI flash | ✅ netlist-verified |
| `fpga_sheet.py` | XC7A35T-**CSG324** (5 units), power/config/clock/bus auto-mapped, osc, PROG btn, DONE LED | ✅ netlist-verified |
| `build_board.py` | full board assembly | ✅ 67 parts, 300 nets, cross-block nets join |

**Verified end-to-end:** loads in KiCad 10, renders, netlist connectivity confirmed across
blocks (SPI↔FPGA↔level-shifter, JTAG↔FT2232, flash↔FPGA, VREF divider↔XADC, CAN↔FPGA), and
reviewed with the **kicad-happy skill** — it detected every subsystem (regulators, level
shifter, memory interface, crystals, clock, CAN, dividers, decoupling, ESD) at HIGH trust.
The generator's `check()` catches accidental net shorts at build time (0 on the board).

**Known / left for eeschema + PCB:** ~238 spare FPGA I/O read as unconnected (add NC flags
in layout); parts carry no MPNs yet (schematic-side; they live in [../bom.csv](../bom.csv));
the FTDI descriptor EEPROM is omitted (optional); footprint links need the exact installed
footprint names. Routing/placement is done in the GUI — the generator guarantees the nets.

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
standalone `build()`. `build_board.py` assembles them into a **hierarchical project**: one
readable sub-sheet per subsystem (`power/can/levelshift/usb/fpga.kicad_sch`) plus a root
`board.kicad_sch` that instantiates all five. Cross-sheet signals are emitted as **global
labels** (connect by name across the hierarchy); block-internal nets stay local; rails are
global via power symbols. One page per subsystem — far more legible than a flat sheet.

| Sheet | Contents | Status |
|---|---|---|
| `power_sheet.py` | 3 regulators (+3V3/+1V0/+1V8), feedback dividers, decoupling | ✅ netlist-verified |
| `can_sheet.py` | SN65HVD230, split-120R term, screw terminal | ✅ netlist-verified |
| `levelshift_sheet.py` | TXS0108E, I2C pull-ups, VREF sense+TVS, Qwiic + headers | ✅ netlist-verified |
| `usb_sheet.py` | FT2232HQ, USB-C, USBLC6, VBUS TVS, 12 MHz xtal, QSPI flash | ✅ netlist-verified |
| `fpga_sheet.py` | XC7A35T-**CSG324** (5 units), power/config/clock/bus auto-mapped, osc, PROG btn, DONE LED | ✅ netlist-verified |
| `build_board.py` | hierarchical assembly (root + 5 sub-sheets) | ✅ 68 parts, 300 nets, cross-sheet nets join via global labels |

**Verified end-to-end:** loads in KiCad 10, renders, netlist connectivity confirmed across
blocks (SPI↔FPGA↔level-shifter, JTAG↔FT2232, flash↔FPGA, VREF divider↔XADC, CAN↔FPGA), and
reviewed with the **kicad-happy skill** — it detected every subsystem (regulators, level
shifter, memory interface, crystals, clock, CAN, dividers, decoupling, ESD) at HIGH trust.
The generator's `check()` catches accidental net shorts at build time (0 on the board).

**Review state (kicad-happy skill):** 1 error — SS-001 sourcing gate (passives still need
MPNs; the 16 ICs/connectors carry them) — plus benign info. Cleared during this pass:
no-connect flags on all spare FPGA/IC pins (238 → 0 unconnected warnings), grid-snapped
endpoints, VBUS TVS (UC-002), correct PG/PWR_FLAG typing, and the FT core rail renamed
`VDDCORE_FT` so PP-001 reads it as an internal rail (info, not error).

**Left for eeschema + PCB:** passive MPNs (procurement), the optional FTDI EEPROM, and
**routing** (GUI/autorouter). The generator guarantees the netlist.

## PCB — `kigen_pcb.py`

`kigen_pcb.py` generates **`../hardfuzz_v1.kicad_pcb`**: it pulls the canonical netlist from
the schematic, loads each part's stock `.kicad_mod`, shelf-packs every footprint (origin
offset from bbox so courtyards don't overlap), injects `(net N "name")` into each pad, and
adds a board outline + 2-layer stackup (switch to 4-layer in Board Setup). All footprints
resolve to real KiCad libraries — including the **BGA-324** FPGA and the **QFN-64** FT2232.

```bash
python3 gen/build_board.py     # schematic first (netlist source)
python3 gen/kigen_pcb.py       # -> ../hardfuzz_v1.kicad_pcb
$KCLI pcb drc hardfuzz_v1.kicad_pcb            # 317 unconnected = unrouted (expected)
$KCLI pcb render --side top -o /tmp/pcb.png hardfuzz_v1.kicad_pcb
```

**State:** loads in pcbnew, 68 footprints placed (non-overlapping), 302 nets on the right
pads, board outline present. The 317 "unconnected" are the **unrouted nets** — this is the
*imported-from-schematic, auto-placed, unrouted* board. Remaining ~29 DRC items are internal
USB-C fine-pitch clearance (needs a net-class rule) + one silk overlap. **Routing and final
placement are interactive** (pcbnew / an external autorouter) — the generator sets it up;
it does not draw copper. The project opens as `hardfuzz_v1.kicad_pro` (schematic + PCB
linked, matching base names).

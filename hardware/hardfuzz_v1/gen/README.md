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

## Status

- `power_sheet.py` — **generated, loads, renders, netlist-verified** (3 regulators, rails,
  feedback dividers; only NC pins unconnected). Known: power-symbol refs need
  auto-annotation in eeschema (cosmetic ERC warnings).
- Next sheets: USB/FT2232H + config flash, level shifters + connectors, CAN, FPGA (needs an
  imported FTG256 symbol — see [../kicad_parts.md](../kicad_parts.md)).

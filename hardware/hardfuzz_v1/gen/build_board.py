#!/usr/bin/env python3
"""HardFuzz v1 — assemble every block into one flat board.kicad_sch.

Each block's populate() is placed in its own coordinate region (via origin
offsets) so nothing overlaps; cross-block signals share local-label names and
power rails are global, so the whole board nets up as one connected schematic.
Reference designators are pre-partitioned per block, so there are no clashes.

Run: python3 gen/build_board.py  -> ../board.kicad_sch (validated by kicad-cli).
"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from kigen import Schematic
import fpga_sheet, power_sheet, can_sheet, levelshift_sheet, usb_sheet

# (block populate fn, origin x, origin y) — regions chosen not to overlap
BLOCKS = [
    (fpga_sheet.populate,      0,    0),
    (power_sheet.populate,     0,  760),
    (can_sheet.populate,     460,  760),
    (levelshift_sheet.populate, 0,  980),
    (usb_sheet.populate,     520,  980),
]


# rails whose only source is a regulator output pin (not typed as a power driver)
# need an explicit PWR_FLAG so ERC sees them as driven.
FLAGS = ["+3V3", "+1V0", "+1V8", "VREF", "FT_1V8", "FT_REF"]


def build():
    s = Schematic("HardFuzz v1", paper="A0")
    for fn, ox, oy in BLOCKS:
        s.origin(ox, oy)
        fn(s)
    s.origin(0, 0)
    for i, net in enumerate(FLAGS):
        s.add("power:PWR_FLAG", f"#FLG{50+i}", "PWR_FLAG", 900 + i * 20, 760, {"1": net})
    return s


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(__file__), "..", "board.kicad_sch")
    conflicts = build().write(out)
    print("wrote", os.path.normpath(out), "| collisions:", len(conflicts))

#!/usr/bin/env python3
"""HardFuzz v1 — assemble the blocks into a HIERARCHICAL project.

Each block is its own readable sub-sheet (one page per subsystem); a root sheet
(board.kicad_sch) instantiates all five. Cross-sheet signals are emitted as
global labels (so they connect by name across the hierarchy) while block-internal
nets stay local; power rails are global via power symbols. This is how FPGA boards
are normally organised — far more legible than one flat page.

Run: python3 gen/build_board.py  -> ../board.kicad_sch + ../<block>.kicad_sch
"""
import sys, os
from collections import Counter
sys.path.insert(0, os.path.dirname(__file__))
from kigen import Schematic, uid
import fpga_sheet, power_sheet, can_sheet, levelshift_sheet, usb_sheet

HERE = os.path.join(os.path.dirname(__file__), "..")
# (sheet name, file, populate fn, paper size)
BLOCKS = [
    ("FPGA",        "fpga.kicad_sch",       fpga_sheet.populate,       "A1"),
    ("Power",       "power.kicad_sch",      power_sheet.populate,      "A3"),
    ("CAN",         "can.kicad_sch",        can_sheet.populate,        "A4"),
    ("Level Shift", "levelshift.kicad_sch", levelshift_sheet.populate, "A3"),
    ("USB",         "usb.kicad_sch",        usb_sheet.populate,        "A3"),
]
RAILS = {"+5V", "+3V3", "+1V0", "+1V8", "GND"}   # global already (power symbols)
# rails needing a PWR_FLAG: regulator outputs (driven through the inductor, not a
# power-output pin) + VREF (sourced externally). FT_1V8/FT_REF are driven by the
# FT2232's own VREGOUT/REF outputs, so they must NOT get a flag (double-driver).
FLAGS = ["+3V3", "+1V0", "+1V8", "VREF"]


def _block_nets(fn):
    s = Schematic()
    fn(s)
    return {v for c in s.comps for v in c.nets.values() if v}


def _global_nets():
    cnt = Counter()
    for _, _, fn, _ in BLOCKS:
        for n in _block_nets(fn):
            cnt[n] += 1
    return {n for n, c in cnt.items() if c > 1 and n not in RAILS}


def _sheet_block(name, file, x, y, sheet_uuid, root_uuid, page):
    return (
        f'\t(sheet\n'
        f'\t\t(at {x} {y})\n\t\t(size 60 40)\n'
        f'\t\t(exclude_from_sim no)\n\t\t(in_bom yes)\n\t\t(on_board yes)\n\t\t(dnp no)\n'
        f'\t\t(fields_autoplaced yes)\n'
        f'\t\t(stroke (width 0.1524) (type solid))\n'
        f'\t\t(fill (color 0 0 0 0.0000))\n'
        f'\t\t(uuid "{sheet_uuid}")\n'
        f'\t\t(property "Sheetname" "{name}" (at {x} {y-1} 0)\n'
        f'\t\t\t(effects (font (size 1.524 1.524)) (justify left bottom)))\n'
        f'\t\t(property "Sheetfile" "{file}" (at {x} {y+41} 0)\n'
        f'\t\t\t(effects (font (size 1.27 1.27)) (justify left top)))\n'
        f'\t\t(instances\n\t\t\t(project "hardfuzz_v1"\n'
        f'\t\t\t\t(path "/{root_uuid}" (page "{page}"))))\n'
        f'\t)')


def _root(root_uuid, sheet_uuids):
    p = ['(kicad_sch', '\t(version 20260306)', '\t(generator "hardfuzz-kigen")',
         '\t(generator_version "10.0")', f'\t(uuid "{root_uuid}")', '\t(paper "A3")',
         '\t(title_block\n\t\t(title "HardFuzz v1"))', '\t(lib_symbols\n\t)']
    for i, (name, file, _, _) in enumerate(BLOCKS):
        x = 30 + (i % 3) * 90
        y = 30 + (i // 3) * 70
        p.append(_sheet_block(name, file, x, y, sheet_uuids[i], root_uuid, str(i + 2)))
    p.append('\t(sheet_instances\n\t\t(path "/" (page "1")))')
    p.append('\t(embedded_fonts no)')
    p.append(')')
    return "\n".join(p) + "\n"


def build():
    root_uuid = uid()
    sheet_uuids = [uid() for _ in BLOCKS]
    gnets = _global_nets()
    total_conflicts = 0
    for i, (name, file, fn, paper) in enumerate(BLOCKS):
        s = Schematic(f"HardFuzz v1 - {name}", paper=paper)
        s.root_uuid = root_uuid
        s.sheet_uuid = sheet_uuids[i]
        s.page = str(i + 2)
        s.global_nets = gnets
        fn(s)
        if name == "USB":                      # PWR_FLAGs live with the regulators/rails
            for j, net in enumerate(FLAGS):
                s.add("power:PWR_FLAG", f"#FLG{50+j}", "PWR_FLAG", 40 + j * 18, 250, {"1": net})
        s.autofit()                            # frame every sheet with a margin, size paper to fit
        total_conflicts += len(s.write(os.path.join(HERE, file)))
    with open(os.path.join(HERE, "hardfuzz_v1.kicad_sch"), "w") as f:
        f.write(_root(root_uuid, sheet_uuids))
    return gnets, total_conflicts


if __name__ == "__main__":
    gnets, conflicts = build()
    print(f"wrote hardfuzz_v1.kicad_sch + {len(BLOCKS)} sub-sheets | "
          f"global nets: {len(gnets)} | collisions: {conflicts}")

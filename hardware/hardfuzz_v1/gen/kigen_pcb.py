#!/usr/bin/env python3
"""Generate board.kicad_pcb — every footprint placed with its pads on the right
nets, a board outline, and a layer stackup. This is the "imported from schematic,
auto-placed, unrouted" board: it opens in pcbnew ready to arrange and route.

Approach (parallels kigen.py): take the canonical netlist from board.kicad_sch,
load each component's stock .kicad_mod, place it (shelf-packed so nothing
overlaps), rename its Reference, and inject `(net N "name")` into each pad. The
2-layer stackup is copied from a KiCad template (switch to 4-layer in Board
Setup — a one-click GUI change). Routing is intentionally left to the GUI/router.
"""
import os, re, sys, uuid, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
FPDIR = "/Applications/KiCad/KiCad.app/Contents/SharedSupport/footprints"
KCLI = "/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli"
SCH = os.path.join(HERE, "..", "hardfuzz_v1.kicad_sch")
OUT = os.path.join(HERE, "..", "hardfuzz_v1.kicad_pcb")


def uid():
    return str(uuid.uuid4())


def _match(text, start):
    depth = 0; i = start; instr = False
    while i < len(text):
        c = text[i]
        if instr:
            if c == '"' and text[i-1] != '\\': instr = False
        elif c == '"': instr = True
        elif c == '(': depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0: return i + 1
        i += 1
    raise ValueError("unbalanced")


def netlist():
    """Canonical {ref: {fp,val,pins{pad:net}}} and ordered net names from the schematic."""
    tmp = "/tmp/hf_board_net.xml"
    subprocess.run([KCLI, "sch", "export", "netlist", "--format", "kicadxml", "-o", tmp, SCH],
                   check=True, capture_output=True)
    t = open(tmp).read()
    comps = {}
    for m in re.finditer(r'<comp ref="([^"]+)">(.*?)</comp>', t, re.S):
        body = m.group(2)
        fp = re.search(r'<footprint>([^<]*)</footprint>', body)
        val = re.search(r'<value>([^<]*)</value>', body)
        comps[m.group(1)] = {"fp": fp.group(1) if fp else "",
                             "val": val.group(1) if val else "", "pins": {}}
    nets = []
    for m in re.finditer(r'<net code="\d+" name="([^"]*)"[^>]*>(.*?)</net>', t, re.S):
        name = m.group(1)
        if name not in nets:
            nets.append(name)
        for n in re.finditer(r'<node ref="([^"]+)" pin="([^"]+)"', m.group(2)):
            r, p = n.group(1), n.group(2)
            if r in comps:
                comps[r]["pins"][p] = name
    return comps, nets


def load_mod(lib_id):
    lib, name = lib_id.split(":", 1)
    with open(os.path.join(FPDIR, lib + ".pretty", name + ".kicad_mod")) as f:
        return f.read()


def fp_bbox(raw):
    """Bounding box (minx, miny, maxx, maxy) relative to the footprint origin, from
    pad copper + courtyard/silk graphics (the origin is often pin 1, not the centre)."""
    xs, ys = [], []
    for m in re.finditer(r'\(pad\s+"[^"]+".*?\(at\s+([-\d.]+)\s+([-\d.]+)[^)]*\)\s*'
                         r'\(size\s+([-\d.]+)\s+([-\d.]+)\)', raw, re.S):
        cx, cy, w, h = map(float, m.groups())
        xs += [cx - w/2, cx + w/2]; ys += [cy - h/2, cy + h/2]
    for m in re.finditer(r'\(fp_(?:line|rect)\s*\(start\s+([-\d.]+)\s+([-\d.]+)\)\s*'
                         r'\(end\s+([-\d.]+)\s+([-\d.]+)\)', raw):
        x1, y1, x2, y2 = map(float, m.groups())
        xs += [x1, x2]; ys += [y1, y2]
    if not xs:
        return -4.0, -4.0, 4.0, 4.0
    return min(xs) - 1, min(ys) - 1, max(xs) + 1, max(ys) + 1


def place(lib_id, ref, val, x, y, pins, netidx):
    raw = load_mod(lib_id)
    raw = re.sub(r'\(footprint\s+"[^"]+"', f'(footprint "{lib_id}"', raw, count=1)
    raw = re.sub(r'\n\s*\(version[^)]*\)', '', raw, count=1)
    raw = re.sub(r'\n\s*\(generator_version[^)]*\)', '', raw, count=1)
    raw = re.sub(r'\n\s*\(generator[^)]*\)', '', raw, count=1)
    raw = raw.replace('(layer "F.Cu")',
                      f'(layer "F.Cu")\n\t(uuid "{uid()}")\n\t(at {x:.3f} {y:.3f})', 1)
    raw = re.sub(r'(\(property "Reference" )"REF\*\*"',
                 lambda m: m.group(1) + f'"{ref}"', raw, count=1)
    raw = re.sub(r'(\(property "Value" )"[^"]*"',
                 lambda m: m.group(1) + f'"{val}"', raw, count=1)
    # inject nets into pads (back-to-front so indices stay valid)
    pads = [(m.start(), m.group(1)) for m in re.finditer(r'\(pad\s+"([^"]+)"', raw)]
    for start, pad in reversed(pads):
        net = pins.get(pad)
        if not net:
            continue
        end = _match(raw, start)
        raw = raw[:end-1] + f'\n\t\t(net {netidx[net]} "{net}")\n\t' + raw[end-1:]
    return "\n".join("\t" + ln if ln else ln for ln in raw.splitlines())


def main():
    comps, netnames = netlist()
    netidx = {"": 0}
    for i, n in enumerate(netnames, 1):
        netidx[n] = i

    refs = [r for r in comps if not r.startswith("#") and comps[r]["fp"]]
    sized = []
    for r in refs:
        bb = fp_bbox(load_mod(comps[r]["fp"]))
        sized.append((r, bb))
    sized.sort(key=lambda t: -(t[1][3] - t[1][1]))  # tallest first -> tidy shelves

    GAP, BOARD_W, MARGIN = 4.0, 165.0, 12.0   # squarer board, real clearance
    x = y = MARGIN
    rowh = 0.0
    fps = []
    for r, (minx, miny, maxx, maxy) in sized:
        w, h = maxx - minx, maxy - miny
        if x + w > BOARD_W and x > MARGIN:
            x = MARGIN; y += rowh + GAP; rowh = 0.0
        # place the origin so the footprint's bbox min-corner lands at the cell corner
        fps.append(place(comps[r]["fp"], r, comps[r]["val"], x - minx, y - miny,
                         comps[r]["pins"], netidx))
        x += w + GAP; rowh = max(rowh, h)
    bw = BOARD_W + MARGIN
    bh = y + rowh + MARGIN

    layers = open(os.path.join(HERE, "_pcb_layers.txt")).read().strip()
    setup = open(os.path.join(HERE, "_pcb_setup.txt")).read().strip()
    p = ['(kicad_pcb', '\t(version 20241229)', '\t(generator "pcbnew")',
         '\t(generator_version "9.0")',
         '\t(general\n\t\t(thickness 1.6)\n\t\t(legacy_teardrops no)\n\t)',
         '\t(paper "A2")',
         '\t(title_block\n\t\t(title "HardFuzz v1"))',
         '\t' + layers, '\t' + setup, '\t(net 0 "")']
    for n in netnames:
        p.append(f'\t(net {netidx[n]} "{n}")')
    p += fps
    # board outline rectangle on Edge.Cuts
    o = 3.0
    corners = [(o, o, bw, o), (bw, o, bw, bh), (bw, bh, o, bh), (o, bh, o, o)]
    for x1, y1, x2, y2 in corners:
        p.append(f'\t(gr_line (start {x1} {y1}) (end {x2} {y2}) '
                 f'(stroke (width 0.15) (type default)) (layer "Edge.Cuts") (uuid "{uid()}"))')
    p.append(')')
    with open(OUT, "w") as f:
        f.write("\n".join(p) + "\n")
    print(f"wrote hardfuzz_v1.kicad_pcb: {len(fps)} footprints, {len(netnames)} nets, "
          f"board {bw:.0f}x{bh:.0f}mm")


if __name__ == "__main__":
    main()

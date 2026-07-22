#!/usr/bin/env python3
"""pcb_layout.py — PCB bring-up steps 1-4 via KiCad's pcbnew API (valid by construction):
4-layer stackup, placement grouped by subsystem, sized board outline, and GND/+3V3 planes.
Leaves routing (step 5) + mounting holes + zone-fill (press B) to the GUI.

Runs in TWO passes because pcbnew's LoadBoard works only once per process and zone-ops
after SetCopperLayerCount segfault in-session — so placement and planes go in separate
processes. Just run it once; it re-invokes itself for the plane pass.

  <kicad>/Frameworks/Python.framework/Versions/3.9/bin/python3.9 gen/pcb_layout.py
"""
import os, re, sys, subprocess
import pcbnew
import wx   # headless pcbnew needs a wxApp before zone ops (else segfault)

HERE = os.path.dirname(os.path.abspath(__file__)) + "/.."
PCB = os.path.normpath(HERE + "/hardfuzz_v1.kicad_pcb")
NET = "/tmp/n.xml"
MM = pcbnew.FromMM
def mm(v): return pcbnew.ToMM(v)


def sheet_of():
    t = open(NET).read()
    out = {}
    for m in re.finditer(r'<comp ref="([^"]+)">(.*?)</comp>', t, re.S):
        sp = re.search(r'<sheetpath names="([^"]*)"', m.group(2))
        out[m.group(1)] = (sp.group(1) if sp else '/').strip('/') or 'root'
    return out


def fp_size(fp):
    try:
        poly = fp.GetCourtyard(pcbnew.F_CrtYd)
        if poly.OutlineCount():
            b = poly.BBox()
            return mm(b.GetWidth()), mm(b.GetHeight())
    except Exception:
        pass
    b = fp.GetBoundingBox(False, False)
    return mm(b.GetWidth()), mm(b.GetHeight())


def place_pass():
    """Pass 1: 4 layers + grouped placement + board outline."""
    _app = wx.App()
    board = pcbnew.LoadBoard(PCB)
    board.SetCopperLayerCount(4)                    # F.Cu / In1.Cu / In2.Cu / B.Cu

    sheet = sheet_of()
    groups = {}
    for fp in board.GetFootprints():
        groups.setdefault(sheet.get(fp.GetReference(), 'root'), []).append(fp)

    GAP, PAD, MARGIN = 2.5, 9.0, 10.0

    def pack(fps, wmax):                            # shelf-pack a subsystem, big parts first
        items = sorted(fps, key=lambda f: -max(fp_size(f)))
        placed, x, y, rowh, bw = [], 0.0, 0.0, 0.0, 0.0
        for f in items:
            w, h = fp_size(f)
            if x + w > wmax and x > 0:
                x = 0; y += rowh + GAP; rowh = 0.0
            placed.append((f, x + w / 2, y + h / 2))
            x += w + GAP; rowh = max(rowh, h); bw = max(bw, x - GAP)
        return placed, bw, y + rowh

    order = ['FPGA', 'USB', 'ESP32', 'Power', 'Level Shift', 'CAN']
    blocks = {n: pack(groups[n], 46.0) for n in order if n in groups}

    colw = [0.0, 0.0, 0.0]; rowh = [0.0, 0.0]
    for i, n in enumerate(order):
        if n in blocks:
            _, w, h = blocks[n]
            colw[i % 3] = max(colw[i % 3], w); rowh[i // 3] = max(rowh[i // 3], h)
    colx = [MARGIN, MARGIN + colw[0] + PAD, MARGIN + colw[0] + colw[1] + 2 * PAD]
    rowy = [MARGIN, MARGIN + rowh[0] + PAD]
    for i, n in enumerate(order):
        if n not in blocks:
            continue
        placed, _, _ = blocks[n]
        ox, oy = colx[i % 3], rowy[i // 3]
        for f, dx, dy in placed:
            f.SetPosition(pcbnew.VECTOR2I(MM(ox + dx), MM(oy + dy)))

    # board outline sized to the placement + margin
    xs, ys = [], []
    for fp in board.GetFootprints():
        b = fp.GetBoundingBox(False, False)
        xs += [mm(b.GetLeft()), mm(b.GetRight())]; ys += [mm(b.GetTop()), mm(b.GetBottom())]
    x0, y0, x1, y1 = min(xs) - MARGIN, min(ys) - MARGIN, max(xs) + MARGIN, max(ys) + MARGIN
    for d in list(board.GetDrawings()):
        if d.GetLayer() == pcbnew.Edge_Cuts:
            board.Remove(d)
    rect = pcbnew.PCB_SHAPE(board)
    rect.SetShape(pcbnew.SHAPE_T_RECT)
    rect.SetStart(pcbnew.VECTOR2I(MM(x0), MM(y0)))
    rect.SetEnd(pcbnew.VECTOR2I(MM(x1), MM(y1)))
    rect.SetLayer(pcbnew.Edge_Cuts)
    rect.SetWidth(MM(0.1))
    board.Add(rect)

    board.Save(PCB)
    print(f"pass 1: {len(board.GetFootprints())} footprints grouped, "
          f"board {x1-x0:.0f}x{y1-y0:.0f}mm, 4 layers")


def zones_pass():
    """Pass 2 (fresh process): GND on In1.Cu, +3V3 on In2.Cu, over the board area."""
    _app = wx.App()
    board = pcbnew.LoadBoard(PCB)
    bb = board.GetBoardEdgesBoundingBox()
    x0, y0, x1, y1 = mm(bb.GetLeft()), mm(bb.GetTop()), mm(bb.GetRight()), mm(bb.GetBottom())
    ncs = {p.GetNetname(): p.GetNetCode() for p in board.GetPads()}
    for z in list(board.Zones()):                  # idempotent: clear old planes first
        board.Remove(z)

    def add_plane(layer, netname):
        nc = ncs.get(netname, -1)
        if nc < 0:
            print("  no net", netname); return
        z = pcbnew.ZONE(board)
        z.SetLayer(layer); z.SetNetCode(nc)
        o = z.Outline(); o.NewOutline()
        for px, py in [(x0+.5, y0+.5), (x1-.5, y0+.5), (x1-.5, y1-.5), (x0+.5, y1-.5)]:
            o.Append(MM(px), MM(py))
        board.Add(z)

    add_plane(pcbnew.In1_Cu, "GND")
    add_plane(pcbnew.In2_Cu, "+3V3")
    board.Save(PCB)
    print(f"pass 2: {len(list(board.Zones()))} planes added (GND/In1, +3V3/In2) — "
          f"press B in pcbnew to pour them")


if __name__ == "__main__":
    if "--zones" in sys.argv:
        zones_pass()
    else:
        place_pass()
        subprocess.run([sys.executable, os.path.abspath(__file__), "--zones"], check=True)

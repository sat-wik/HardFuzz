#!/usr/bin/env python3
"""kigen — a tiny KiCad 10 schematic generator for the HardFuzz v1 board.

The board is defined as code (see sheets/*.py); this emits a valid `.kicad_sch`
(format 20250114) that opens in eeschema and passes ERC. Approach:

  * pull each library symbol's *raw text* from KiCad's stock .kicad_sym files so
    quoting/formatting is authoritative (no re-serialization guesswork),
  * place every component at rotation 0 so the pin transform is just Y-flip
    (sheet_pin = origin + (px, -py)),
  * connect pins with local net *labels* dropped exactly on each pin endpoint —
    same label name == same net, no fragile wire routing.

The result is an electrically-correct, ERC-checkable "netlist as schematic".
Aesthetic routing is left to eeschema; correctness is what we generate.
"""
import os, re, sys, uuid, math

SYMDIR = "/Applications/KiCad/KiCad.app/Contents/SharedSupport/symbols"
SKILL = "/Users/satwikpattanaik/.claude/plugins/marketplaces/kicad-happy/skills/kicad/scripts"
sys.path.insert(0, SKILL)
import sexp_parser as S


def _match_block(text, start):
    """Given index of '(' at `start`, return end index just past matching ')'."""
    depth = 0
    i = start
    in_str = False
    while i < len(text):
        c = text[i]
        if in_str:
            if c == '"' and text[i-1] != '\\':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError("unbalanced")


class LibCache:
    def __init__(self):
        self._files = {}   # libname -> text
        self._raw = {}     # lib_id -> renamed raw symbol block
        self._pins = {}    # lib_id -> [(number,x,y,angle)]

    def _load(self, libname):
        if libname not in self._files:
            with open(os.path.join(SYMDIR, libname + ".kicad_sym")) as f:
                self._files[libname] = f.read()
        return self._files[libname]

    def _find_symbol_span(self, text, name):
        pat = re.compile(r'\(symbol\s+"' + re.escape(name) + r'"')
        m = pat.search(text)
        if not m:
            raise KeyError(name)
        end = _match_block(text, m.start())
        return m.start(), end

    def _base_block(self, lib_id):
        """(raw text, base symbol name) of the ancestor that actually carries pins,
        following `extends` down the chain."""
        libname, name = lib_id.split(":")
        text = self._load(libname)
        s, e = self._find_symbol_span(text, name)
        block = text[s:e]
        m = re.search(r'\(extends\s+"([^"]+)"', block)
        if m:
            return self._base_block(f"{libname}:{m.group(1)}")
        return block, name

    def raw(self, lib_id):
        """Self-contained '(symbol "lib:name" ...)' block for lib_symbols embedding.
        Derived symbols are flattened onto the ancestor's drawing, and BOTH the top
        symbol and its child units are renamed so the child base matches the top's
        un-prefixed name (KiCad requires "<TopBase>_<unit>_<style>")."""
        if lib_id in self._raw:
            return self._raw[lib_id]
        block, base = self._base_block(lib_id)
        top_base = lib_id.split(":")[1]
        # child units: "<base>_u_s" -> "<top_base>_u_s"
        block = re.sub(r'(\(symbol\s+")' + re.escape(base) + r'(_)',
                       lambda mm: mm.group(1) + top_base + mm.group(2), block)
        # top-level: "<base>" -> "lib:name"
        block = re.sub(r'(\(symbol\s+")' + re.escape(base) + r'(")',
                       lambda mm: mm.group(1) + lib_id + mm.group(2), block, count=1)
        self._raw[lib_id] = block
        return block

    def _sym_node(self, libname, name):
        doc = S.parse_file(os.path.join(SYMDIR, libname + ".kicad_sym"))
        root = doc[0] if doc and isinstance(doc[0], list) else doc
        for n in root:
            if isinstance(n, list) and n and n[0] == "symbol" and len(n) > 1 and n[1] == name:
                return n
        raise KeyError(name)

    def extends(self, lib_id):
        """Parent lib_id if this symbol derives from another (via (extends ...)), else None.
        Reads the ORIGINAL library block — raw() flattens the extends token away."""
        libname, name = lib_id.split(":")
        text = self._load(libname)
        s, e = self._find_symbol_span(text, name)
        m = re.search(r'\(extends\s+"([^"]+)"', text[s:e])
        return f"{libname}:{m.group(1)}" if m else None

    def pins(self, lib_id):
        if lib_id in self._pins:
            return self._pins[lib_id]
        libname, name = lib_id.split(":")
        sym = self._sym_node(libname, name)
        out = []
        for unit in sym:
            if isinstance(unit, list) and unit and unit[0] == "symbol":
                for m in unit:
                    if isinstance(m, list) and m and m[0] == "pin":
                        at = S.find_first(m, "at")
                        num = S.find_first(m, "number")
                        if at and num:
                            out.append((num[1], float(at[1]), float(at[2]), float(at[3])))
        if not out:                       # derived symbol: pins live on the parent
            parent = self.extends(lib_id)
            if parent:
                out = self.pins(parent)
        self._pins[lib_id] = out
        return out


def uid():
    return str(uuid.uuid4())


class Comp:
    def __init__(self, lib_id, ref, value, x, y, nets, footprint="", rot=0):
        self.lib_id, self.ref, self.value = lib_id, ref, value
        self.x, self.y, self.rot = float(x), float(y), rot
        self.nets = nets            # {pin_number: net_name}
        self.footprint = footprint
        self.uuid = uid()

    def pin_xy(self, px, py):
        # rotation 0 only: schematic Y is inverted vs symbol library
        return self.x + px, self.y - py


class Schematic:
    def __init__(self, title="HardFuzz v1"):
        self.lib = LibCache()
        self.comps = []
        self.title = title
        self.uuid = uid()

    def add(self, *a, **k):
        c = Comp(*a, **k)
        self.comps.append(c)
        return c

    def _sym_instance(self, c):
        lines = []
        L = lines.append
        L(f'\t(symbol')
        L(f'\t\t(lib_id "{c.lib_id}")')
        L(f'\t\t(at {c.x:.2f} {c.y:.2f} {c.rot})')
        L(f'\t\t(unit 1)')
        L(f'\t\t(exclude_from_sim no)')
        L(f'\t\t(in_bom yes)')
        L(f'\t\t(on_board yes)')
        L(f'\t\t(dnp no)')
        L(f'\t\t(uuid "{c.uuid}")')
        L(f'\t\t(property "Reference" "{c.ref}" (at {c.x+2.54:.2f} {c.y-1.27:.2f} 0)')
        L(f'\t\t\t(effects (font (size 1.27 1.27)) (justify left)))')
        L(f'\t\t(property "Value" "{c.value}" (at {c.x+2.54:.2f} {c.y+1.27:.2f} 0)')
        L(f'\t\t\t(effects (font (size 1.27 1.27)) (justify left)))')
        fp = c.footprint
        L(f'\t\t(property "Footprint" "{fp}" (at {c.x:.2f} {c.y:.2f} 0)')
        L(f'\t\t\t(effects (font (size 1.27 1.27)) (hide yes)))')
        # pin uuids
        for (num, px, py, ang) in self.lib.pins(c.lib_id):
            L(f'\t\t(pin "{num}" (uuid "{uid()}"))')
        L(f'\t\t(instances')
        L(f'\t\t\t(project "hardfuzz_v1"')
        L(f'\t\t\t\t(path "/{self.uuid}" (reference "{c.ref}") (unit 1))))')
        L(f'\t)')
        return "\n".join(lines)

    def _labels(self, c, stub=5.08):
        """For each connected pin: a short wire stub pointing outward from the symbol,
        with the net label at the stub's far end so labels sit clear of the body."""
        out = []
        for (num, px, py, ang) in self.lib.pins(c.lib_id):
            net = c.nets.get(num)
            if not net:
                continue
            x, y = c.pin_xy(px, py)                 # pin connection point (sheet coords)
            out_ang = math.radians((ang + 180) % 360)   # pin `ang` points into body; go opposite
            ex = round(x + math.cos(out_ang) * stub, 2)
            ey = round(y - math.sin(out_ang) * stub, 2)  # Y is flipped in schematic space
            lang = 0 if abs(ex - x) >= abs(ey - y) else 90
            out.append(
                f'\t(wire (pts (xy {x:.2f} {y:.2f}) (xy {ex:.2f} {ey:.2f}))\n'
                f'\t\t(stroke (width 0) (type default)) (uuid "{uid()}"))')
            out.append(
                f'\t(label "{net}" (at {ex:.2f} {ey:.2f} {lang})\n'
                f'\t\t(effects (font (size 1.27 1.27)) (justify left))\n'
                f'\t\t(uuid "{uid()}"))')
        return "\n".join(out)

    def render(self):
        used = {}                               # raw() flattens extends, so each
        for c in self.comps:                    # lib_id embeds as a self-contained symbol
            if c.lib_id not in used:
                used[c.lib_id] = self.lib.raw(c.lib_id)
        parts = []
        parts.append('(kicad_sch')
        parts.append('\t(version 20260306)')
        parts.append('\t(generator "hardfuzz-kigen")')
        parts.append('\t(generator_version "9.0")')
        parts.append(f'\t(uuid "{self.uuid}")')
        parts.append('\t(paper "A2")')
        parts.append('\t(title_block')
        parts.append(f'\t\t(title "{self.title}")')
        parts.append('\t)')
        parts.append('\t(lib_symbols')
        for lid, raw in used.items():
            # indent raw block by one tab
            parts.append("\n".join("\t" + ln for ln in raw.splitlines()))
        parts.append('\t)')
        for c in self.comps:
            parts.append(self._sym_instance(c))
            lbl = self._labels(c)
            if lbl:
                parts.append(lbl)
        parts.append(f'\t(sheet_instances\n\t\t(path "/" (page "1")))')
        parts.append('\t(embedded_fonts no)')
        parts.append(')')
        return "\n".join(parts) + "\n"

    def write(self, path):
        with open(path, "w") as f:
            f.write(self.render())

#!/usr/bin/env python3
"""HardFuzz v1 — power tree sheet, defined as code (see ../schematic_design.md §2).

USB VBUS(+5V) -> +3V3 buck -> {+1V0 buck (VCCINT), +1V8 LDO (VCCAUX)}.
Regulators use in-stock KiCad symbols: TLV62566 bucks, AP2112K LDO. Feedback
dividers set Vout; decoupling per rail. Generated to a KiCad 10 .kicad_sch and
validated with kicad-cli (load + netlist + ERC). Blocks are spread ~100 mm apart
for readability; connectivity is by net name, so placement is purely cosmetic.
"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from kigen import Schematic

BUCK = "Regulator_Switching:TLV62566DBVx"   # 1=EN 2=GND 3=SW 4=VIN 5=FB
LDO  = "Regulator_Linear:AP2112K-1.8"       # 1=VIN 2=GND 3=EN 5=VOUT (4=NC)
C, R, IND = "Device:C", "Device:R", "Device:L"
FP_C = "Capacitor_SMD:C_0402_1005Metric"
FP_R = "Resistor_SMD:R_0402_1005Metric"
FP_L = "Inductor_SMD:L_0805_2012Metric"


def populate(s):
    def rail(net, x, y, ref):        # rail flag / power symbol
        s.add(f"power:{net}", ref, net, x, y, {"1": net})

    def gnd(x, y, ref):
        s.add("power:GND", ref, "GND", x, y, {"1": "GND"})

    # ---------------- +5V input (from USB VBUS) ----------------
    rail("+5V", 40, 40, "#PWR01")
    s.add("power:PWR_FLAG", "#FLG01", "PWR_FLAG", 60, 40, {"1": "+5V"})
    s.add(C, "C1", "10uF", 40, 75, {"1": "+5V", "2": "GND"}, FP_C)
    s.add(C, "C2", "10uF", 55, 75, {"1": "+5V", "2": "GND"}, FP_C)
    gnd(47, 95, "#PWR02")

    # ---------------- +3V3 buck (U6) ----------------
    x = 130
    rail("+3V3", x, 40, "#PWR03")
    s.add(BUCK, "U6", "TLV62566", x, 80, {"4": "+5V", "1": "+5V", "2": "GND",
                                          "3": "SW_3V3", "5": "FB_3V3"})
    s.add(IND, "L1", "2.2uH", x + 28, 58, {"1": "SW_3V3", "2": "+3V3"}, FP_L)
    s.add(C, "C3", "22uF", x + 28, 92, {"1": "+3V3", "2": "GND"}, FP_C)
    s.add(C, "C4", "22uF", x + 43, 92, {"1": "+3V3", "2": "GND"}, FP_C)
    s.add(R, "R1", "412k", x + 58, 72, {"1": "+3V3", "2": "FB_3V3"}, FP_R)
    s.add(R, "R2", "91k", x + 58, 92, {"1": "FB_3V3", "2": "GND"}, FP_R)
    gnd(x, 108, "#PWR04")

    # ---------------- +1V0 buck (U7) — VCCINT ----------------
    x = 230
    rail("+1V0", x, 40, "#PWR05")
    s.add(BUCK, "U7", "TLV62566", x, 80, {"4": "+3V3", "1": "+3V3", "2": "GND",
                                          "3": "SW_1V0", "5": "FB_1V0"})
    s.add(IND, "L2", "1.5uH", x + 28, 58, {"1": "SW_1V0", "2": "+1V0"}, FP_L)
    s.add(C, "C5", "22uF", x + 28, 92, {"1": "+1V0", "2": "GND"}, FP_C)
    s.add(C, "C6", "22uF", x + 43, 92, {"1": "+1V0", "2": "GND"}, FP_C)
    s.add(R, "R3", "133k", x + 58, 72, {"1": "+1V0", "2": "FB_1V0"}, FP_R)
    s.add(R, "R4", "200k", x + 58, 92, {"1": "FB_1V0", "2": "GND"}, FP_R)
    gnd(x, 108, "#PWR06")

    # ---------------- +1V8 LDO (U8) — VCCAUX ----------------
    x = 330
    rail("+1V8", x, 40, "#PWR07")
    s.add(LDO, "U8", "AP2112K-1.8", x, 80, {"3": "+3V3", "1": "+3V3", "2": "GND",
                                            "5": "+1V8"})
    s.add(C, "C7", "1uF", x - 20, 92, {"1": "+3V3", "2": "GND"}, FP_C)
    s.add(C, "C8", "1uF", x + 25, 92, {"1": "+1V8", "2": "GND"}, FP_C)
    gnd(x, 108, "#PWR08")


def build():
    s = Schematic("HardFuzz v1 - Power")
    populate(s)
    return s


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(__file__), "..", "power.kicad_sch")
    build().write(out)
    print("wrote", os.path.normpath(out))

#!/usr/bin/env python3
"""HardFuzz v1 — power tree sheet, defined as code (see ../schematic_design.md §2).

USB VBUS(+5V) -> +3V3 buck -> {+1V0 buck (VCCINT), +1V8 LDO (VCCAUX)}.
Regulators use in-stock KiCad symbols: TLV62566 bucks, AP2112K LDO. Feedback
dividers set Vout; decoupling per rail. Generated to a KiCad 10 .kicad_sch and
validated with kicad-cli (load + netlist + ERC).
"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from kigen import Schematic

BUCK = "Regulator_Switching:TLV62566DBVx"   # 1=EN 2=GND 3=SW 4=VIN 5=FB
LDO  = "Regulator_Linear:AP2112K-1.8"       # 1=VIN 2=GND 3=EN 4=NC 5=VOUT (extends AP2112K-3.3)
C, R, L, IND = "Device:C", "Device:R", "Device:L", "Device:L"
FP_C = "Capacitor_SMD:C_0402_1005Metric"
FP_R = "Resistor_SMD:R_0402_1005Metric"
FP_L = "Inductor_SMD:L_0805_2012Metric"


def build():
    s = Schematic("HardFuzz v1 - Power")
    x = 60  # column cursor

    def rail_flag(net, px, py, ref):
        s.add("power:PWR_FLAG", ref, "PWR_FLAG", px, py, {"1": net})

    def pwr(sym, net, px, py, ref):
        s.add(sym, ref, net, px, py, {"1": net})

    # ---- +5V input (from USB VBUS) ----
    pwr("power:+5V", "+5V", x, 40, "#PWR_5V")
    rail_flag("+5V", x + 10, 40, "#FLG_5V")
    s.add(C, "C1", "10uF", x + 20, 46, {"1": "+5V", "2": "GND"}, FP_C)
    s.add(C, "C2", "10uF", x + 28, 46, {"1": "+5V", "2": "GND"}, FP_C)

    # ================= +3V3 buck (U6) =================
    bx = 100
    s.add(BUCK, "U6", "TLV62566", bx, 60,
          {"4": "+5V", "1": "+5V", "2": "GND", "3": "SW_3V3", "5": "FB_3V3"})
    s.add(IND, "L1", "2.2uH", bx, 48, {"1": "SW_3V3", "2": "+3V3"}, FP_L)
    s.add(C, "C3", "22uF", bx + 12, 66, {"1": "+3V3", "2": "GND"}, FP_C)
    s.add(C, "C4", "22uF", bx + 20, 66, {"1": "+3V3", "2": "GND"}, FP_C)
    # feedback divider FB=0.6V nominal: R1 top / R2 bottom -> 3.3V
    s.add(R, "R1", "412k", bx + 30, 55, {"1": "+3V3", "2": "FB_3V3"}, FP_R)
    s.add(R, "R2", "91k", bx + 30, 65, {"1": "FB_3V3", "2": "GND"}, FP_R)
    pwr("power:+3V3", "+3V3", bx, 40, "#PWR_3V3")

    # ================= +1V0 buck (U7) — VCCINT =================
    cx = 160
    s.add(BUCK, "U7", "TLV62566", cx, 60,
          {"4": "+3V3", "1": "+3V3", "2": "GND", "3": "SW_1V0", "5": "FB_1V0"})
    s.add(IND, "L2", "1.5uH", cx, 48, {"1": "SW_1V0", "2": "+1V0"}, FP_L)
    s.add(C, "C5", "22uF", cx + 12, 66, {"1": "+1V0", "2": "GND"}, FP_C)
    s.add(C, "C6", "22uF", cx + 20, 66, {"1": "+1V0", "2": "GND"}, FP_C)
    s.add(R, "R3", "133k", cx + 30, 55, {"1": "+1V0", "2": "FB_1V0"}, FP_R)
    s.add(R, "R4", "200k", cx + 30, 65, {"1": "FB_1V0", "2": "GND"}, FP_R)
    pwr("power:+1V0", "+1V0", cx, 40, "#PWR_1V0")

    # ================= +1V8 LDO (U8) — VCCAUX =================
    dx = 220
    s.add(LDO, "U8", "AP2112K-1.8", dx, 60,
          {"3": "+3V3", "1": "+3V3", "2": "GND", "5": "+1V8"})
    s.add(C, "C7", "1uF", dx - 8, 66, {"1": "+3V3", "2": "GND"}, FP_C)
    s.add(C, "C8", "1uF", dx + 12, 66, {"1": "+1V8", "2": "GND"}, FP_C)
    pwr("power:+1V8", "+1V8", dx, 40, "#PWR_1V8")

    # shared ground reference flag
    s.add("power:GND", "#PWR_GND", "GND", 40, 80, {"1": "GND"})
    rail_flag("GND", 48, 80, "#FLG_GND")
    return s


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(__file__), "..", "power.kicad_sch")
    build().write(out)
    print("wrote", os.path.normpath(out))

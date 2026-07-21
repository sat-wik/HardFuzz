#!/usr/bin/env python3
"""HardFuzz v1 — CAN sheet (see ../schematic_design.md §6).

SN65HVD230 transceiver: logic side (D/R) at 3V3 straight to the FPGA; bus side
(CANH/CANL) to a 3-pos screw terminal with split-120R termination (two 60R + a
4.7nF AC-ground cap). Rs sets slope. Vref (pin 5) left open. Standalone sheet —
CAN_TXD/CAN_RXD tie into the FPGA sheet at assembly; +3V3/GND are global.
"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from kigen import Schematic

XCVR = "Interface_CAN_LIN:SN65HVD230"   # 1=D 2=GND 3=VCC 4=R 5=Vref 6=CANL 7=CANH 8=Rs
C, R = "Device:C", "Device:R"
TERM = "Connector:Screw_Terminal_01x03"
FP_C = "Capacitor_SMD:C_0402_1005Metric"
FP_R = "Resistor_SMD:R_0402_1005Metric"


def populate(s):
    def gnd(x, y, ref): s.add("power:GND", ref, "GND", x, y, {"1": "GND"})

    # transceiver
    s.add(XCVR, "U9", "SN65HVD230", 150, 80,
          {"1": "CAN_TXD", "2": "GND", "3": "+3V3", "4": "CAN_RXD",
           "6": "CANL", "7": "CANH", "8": "CAN_RS"},   # pin 5 Vref: NC
          nc_unused=True, mpn="SN65HVD230DR")
    s.add("power:+3V3", "#PWR11", "+3V3", 150, 45, {"1": "+3V3"})
    gnd(150, 112, "#PWR12")

    # VCC decoupling + Rs slope-control resistor
    s.add(C, "C20", "100nF", 118, 70, {"1": "+3V3", "2": "GND"}, FP_C)
    s.add(R, "R20", "10k", 185, 92, {"1": "CAN_RS", "2": "GND"}, FP_R)   # Rs->GND: slope mode
    gnd(118, 84, "#PWR13")

    # split-120R termination (jumper-selectable per §10.5; shown populated)
    s.add(R, "R21", "60R", 210, 60, {"1": "CANH", "2": "CAN_MID"}, FP_R)
    s.add(R, "R22", "60R", 210, 100, {"1": "CAN_MID", "2": "CANL"}, FP_R)
    s.add(C, "C21", "4.7nF", 230, 80, {"1": "CAN_MID", "2": "GND"}, FP_C)
    gnd(230, 96, "#PWR14")

    # bus screw terminal: CANH / CANL / GND
    s.add(TERM, "J5", "CAN", 270, 80, {"1": "CANH", "2": "CANL", "3": "GND"},
          "TerminalBlock_Phoenix:TerminalBlock_Phoenix_MPT-0,5-3-2.54_1x03")


def build():
    s = Schematic("HardFuzz v1 - CAN")
    populate(s)
    return s


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(__file__), "..", "can.kicad_sch")
    build().write(out)
    print("wrote", os.path.normpath(out))

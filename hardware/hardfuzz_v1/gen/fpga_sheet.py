#!/usr/bin/env python3
"""HardFuzz v1 — FPGA (XC7A35T-CSG324) (see ../schematic_design.md §3, §10.2).

CSG324 (0.8mm, stock KiCad symbol) chosen over FTG256 so no external symbol import
is needed. The 5-unit symbol is placed as 5 instances of U1. Nets are assigned by
pin name: power/ground by rail, JTAG/config to the USB sheet, CCLK+D00..D03+FCS_B
to the config flash, MRCC to the oscillator, and the SPI/I2C/UART/CAN/TRIG bus
signals to bank-34/35 I/O (which join the level-shifter and CAN sheets).
"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from kigen import Schematic
import sexp_parser as S

SYMDIR = "/Applications/KiCad/KiCad.app/Contents/SharedSupport/symbols"
FPGA = "FPGA_Xilinx_Artix7:XC7A35T-CSG324"
OSC = "Oscillator:ASE-xxxMHz"
C, R, LED, SW = "Device:C", "Device:R", "Device:LED", "Switch:SW_Push"
FP_C = "Capacitor_SMD:C_0402_1005Metric"
FP_R = "Resistor_SMD:R_0402_1005Metric"

BUS = ["SPI_SCLK", "SPI_MOSI", "SPI_MISO", "SPI_CS", "I2C_SCL", "I2C_SDA",
       "UART_TTX", "UART_TRX", "CAN_TXD", "CAN_RXD", "TRIG",
       "HOST_TXD", "HOST_RXD"]   # host UART link to the FT2232 (ctrl_regs)


def _pins_named():
    doc = S.parse_file(os.path.join(SYMDIR, "FPGA_Xilinx_Artix7.kicad_sym"))
    def find(n, nm):
        for x in n:
            if isinstance(x, list) and x and x[0] == "symbol" and len(x) > 1 and x[1] == nm:
                return x
    sym = find(doc, "XC7A35T-CSG324")
    out = []
    import re
    for u in sym:
        if isinstance(u, list) and u and u[0] == "symbol":
            if not re.match(r'XC7A35T-CSG324_\d+_\d+$', u[1]):
                continue
            for k in u:
                if isinstance(k, list) and k and k[0] == "pin":
                    a = S.find_first(k, "name"); b = S.find_first(k, "number")
                    if a and b:
                        out.append((b[1], a[1]))
    return out


def _netmap():
    net, bus_balls = {}, []
    for num, name in _pins_named():
        if name == "GND": net[num] = "GND"
        elif name.startswith(("VCCINT", "VCCBRAM")): net[num] = "+1V0"
        elif name.startswith(("VCCAUX", "VCCADC")): net[num] = "+1V8"
        elif name.startswith("VCCO"): net[num] = "+3V3"
        elif name == "CCLK_0": net[num] = "FLASH_CCLK"
        elif name == "TCK_0": net[num] = "JTAG_TCK"
        elif name == "TDI_0": net[num] = "JTAG_TDI"
        elif name == "TDO_0": net[num] = "JTAG_TDO"
        elif name == "TMS_0": net[num] = "JTAG_TMS"
        elif name == "INIT_B_0": net[num] = "FPGA_INIT"
        elif name == "PROGRAM_B_0": net[num] = "FPGA_PROG"
        elif name == "DONE_0": net[num] = "FPGA_DONE"
        elif name == "M0_0": net[num] = "+3V3"          # master SPI x1 boot = M[2:0]=001
        elif name in ("M1_0", "M2_0"): net[num] = "GND"
        elif name == "CFGBVS_0": net[num] = "+3V3"       # 3.3V config bank
        elif name == "VP_0": net[num] = "VREF_SENSE"     # XADC reads target VREF
        elif name in ("VN_0", "VREFN_0"): net[num] = "GND"
        elif "_D00_MOSI_" in name: net[num] = "FLASH_D0"
        elif "_D01_DIN_" in name: net[num] = "FLASH_D1"
        elif "_D02_" in name: net[num] = "FLASH_D2"
        elif "_D03_" in name: net[num] = "FLASH_D3"
        elif "FCS_B" in name: net[num] = "FLASH_CS"
        elif name == "IO_L13P_T2_MRCC_15": net[num] = "CLK12"   # H16 clock in
        elif name.startswith("IO_") and (name.endswith("_34") or name.endswith("_35")) \
                and "VREF" not in name:
            bus_balls.append(num)
    for sig, num in zip(BUS, bus_balls):                 # map bus signals to bank34/35 I/O
        net[num] = sig
    return net


def populate(s):
    def gnd(x, y, ref): s.add("power:GND", ref, "GND", x, y, {"1": "GND"})
    def rail(net, x, y, ref): s.add(f"power:{net}", ref, net, x, y, {"1": net})
    def cap(ref, val, net, x, y): s.add(C, ref, val, x, y, {"1": net, "2": "GND"}, FP_C)

    nets = _netmap()
    # 5 units of U1, spread across the sheet (stub off — dense pin fields)
    locs = [(150, 150), (420, 150), (690, 150), (150, 470), (420, 470)]
    for u, (x, y) in enumerate(locs, start=1):
        s.add(FPGA, "U1", "XC7A35T-CSG324", x, y, nets,
              "Package_BGA:Xilinx_CSG324", unit=u, stub=False)

    # rails for reference on this sheet
    rail("+3V3", 700, 470, "#PWR40"); rail("+1V0", 730, 470, "#PWR41")
    rail("+1V8", 760, 470, "#PWR42"); gnd(790, 470, "#PWR43")

    # ---- 12 MHz oscillator ----
    s.add(OSC, "Y1", "12MHz", 700, 540, {"1": "+3V3", "2": "GND", "3": "CLK12", "4": "+3V3"},
          "Oscillator:Oscillator_SMD_Abracon_ASE-4Pin_3.2x2.5mm")
    cap("C50", "100nF", "+3V3", 730, 555)

    # ---- config housekeeping: pull-ups + PROG button + DONE LED ----
    s.add(R, "R50", "4.7k", 150, 640, {"1": "+3V3", "2": "FPGA_PROG"}, FP_R)
    s.add(SW, "SW1", "PROG", 180, 655, {"1": "FPGA_PROG", "2": "GND"},
          "Button_Switch_SMD:SW_SPST_CK_RS282G05A3")
    s.add(R, "R51", "4.7k", 220, 640, {"1": "+3V3", "2": "FPGA_INIT"}, FP_R)
    s.add(R, "R52", "3.3k", 260, 640, {"1": "+3V3", "2": "FPGA_DONE"}, FP_R)
    s.add(R, "R53", "330", 300, 640, {"1": "FPGA_DONE", "2": "DONE_LED"}, FP_R)
    s.add(LED, "D40", "DONE", 300, 660, {"1": "DONE_LED", "2": "GND"},
          "LED_SMD:LED_0603_1608Metric")
    gnd(200, 675, "#PWR44")

    # ---- a few FPGA bulk/decoupling caps (full PDN handled on the power sheet) ----
    for i, (net, xx) in enumerate([("+1V0", 480), ("+1V8", 540), ("+3V3", 600)]):
        cap(f"C5{i+1}", "4.7uF", net, xx, 640)


def build():
    s = Schematic("HardFuzz v1 - FPGA (XC7A35T-CSG324)", paper="A1")
    populate(s)
    return s


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(__file__), "..", "fpga.kicad_sch")
    conflicts = build().write(out)
    print("wrote", os.path.normpath(out), "| collisions:", len(conflicts))

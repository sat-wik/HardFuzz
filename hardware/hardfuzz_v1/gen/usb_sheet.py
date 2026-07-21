#!/usr/bin/env python3
"""HardFuzz v1 — USB + FT2232H + config flash (see ../schematic_design.md §4,§5).

FT2232HQ dual bridge: channel A -> JTAG (FPGA config), channel B -> host UART.
USB-C in via USBLC6 ESD; 12 MHz crystal; internal 1V8 reg (VREGOUT) feeds VCORE/
VPLL/VPHY; VCCIO @ +3V3. QSPI config flash (MX25L3233F) to the FPGA config bus.
JTAG_*/HOST_*/FLASH_* nets join the FPGA sheet at assembly.

NOTE: the FTDI descriptor EEPROM (93LC56) is omitted here — optional (FT2232H
runs on default VID/PID without it); add later for the auto-detect USB id.
"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from kigen import Schematic

FT = "Interface_USB:FT2232HQ"
USBC = "Connector:USB_C_Receptacle"
ESD = "Power_Protection:USBLC6-2SC6"
XTAL = "Device:Crystal_GND24"
FLASH = "Memory_Flash:MX25L3233FM"
C, R = "Device:C", "Device:R"
FP_C = "Capacitor_SMD:C_0402_1005Metric"
FP_R = "Resistor_SMD:R_0402_1005Metric"


def populate(s):
    def gnd(x, y, ref): s.add("power:GND", ref, "GND", x, y, {"1": "GND"})
    def rail(net, x, y, ref): s.add(f"power:{net}", ref, net, x, y, {"1": net})
    def cap(ref, val, net, x, y): s.add(C, ref, val, x, y, {"1": net, "2": "GND"}, FP_C)

    # ---------------- FT2232HQ ----------------
    s.add(FT, "U2", "FT2232HQ", 150, 120, {
        # power
        "50": "+3V3", "49": "FT_1V8", "12": "FT_1V8", "37": "FT_1V8", "64": "FT_1V8",
        "9": "FT_1V8", "4": "FT_1V8", "6": "FT_REF",
        "20": "+3V3", "31": "+3V3", "42": "+3V3", "56": "+3V3",
        # grounds (incl AGND, thermal pad 65)
        "1": "GND", "5": "GND", "10": "GND", "11": "GND", "15": "GND", "25": "GND",
        "35": "GND", "47": "GND", "51": "GND", "65": "GND",
        # USB + housekeeping
        "7": "USB_DM", "8": "USB_DP", "14": "FT_RESET", "13": "GND",
        "2": "FT_OSCI", "3": "FT_OSCO",
        # channel A -> JTAG   (ADBUS0=TCK, 1=TDI, 2=TDO, 3=TMS)
        "16": "JTAG_TCK", "17": "JTAG_TDI", "18": "JTAG_TDO", "19": "JTAG_TMS",
        # channel B -> host UART (BDBUS0=TXD out, BDBUS1=RXD in)
        "38": "HOST_TXD", "39": "HOST_RXD"})
    rail("+3V3", 60, 205, "#PWR30")
    gnd(150, 200, "#PWR31")
    # decoupling row (below the FT symbol, spread horizontally so stubs don't overlap)
    cap("C40", "10uF", "+3V3", 55, 215); cap("C41", "100nF", "+3V3", 70, 215)
    cap("C42", "4.7uF", "FT_1V8", 85, 215); cap("C43", "100nF", "FT_1V8", 100, 215)
    cap("C44", "100nF", "FT_REF", 115, 215)
    s.add(R, "R40", "10k", 205, 90, {"1": "+3V3", "2": "FT_RESET"}, FP_R)  # RESET pull-up

    # ---------------- 12 MHz crystal ----------------
    s.add(XTAL, "Y2", "12MHz", 90, 160, {"1": "FT_OSCI", "3": "FT_OSCO", "2": "GND", "4": "GND"},
          "Crystal:Crystal_SMD_3225-4Pin_3.2x2.5mm")
    cap("C45", "18pF", "FT_OSCI", 60, 170); cap("C46", "18pF", "FT_OSCO", 75, 170)

    # ---------------- USB-C + ESD ----------------
    s.add(USBC, "J1", "USB-C", 300, 110, {
        "A1": "GND", "A12": "GND", "B1": "GND", "B12": "GND", "SH": "GND",
        "A4": "+5V", "A9": "+5V", "B4": "+5V", "B9": "+5V",
        "A5": "CC1", "B5": "CC2", "A6": "USB_DP", "B6": "USB_DP",
        "A7": "USB_DM", "B7": "USB_DM"},
        "Connector_USB:USB_C_Receptacle_GCT_USB4085")
    rail("+5V", 300, 55, "#PWR32")
    gnd(300, 175, "#PWR33")
    s.add(R, "R41", "5.1k", 260, 90, {"1": "CC1", "2": "GND"}, FP_R)
    s.add(R, "R42", "5.1k", 272, 90, {"1": "CC2", "2": "GND"}, FP_R)
    cap("C47", "10uF", "+5V", 340, 90)
    s.add("Device:D_TVS", "D31", "SMAJ5.0A", 355, 90, {"1": "+5V", "2": "GND"},
          "Diode_SMD:D_SMA")   # VBUS ESD/surge clamp (skill UC-002)
    s.add(ESD, "D30", "USBLC6-2SC6", 230, 130,
          {"1": "USB_DP", "6": "USB_DP", "3": "USB_DM", "4": "USB_DM",
           "5": "+5V", "2": "GND"}, "Package_TO_SOT_SMD:SOT-23-6")

    # ---------------- QSPI config flash ----------------
    s.add(FLASH, "U3", "MX25L3233F", 400, 120, {
        "16": "FLASH_CCLK", "7": "FLASH_CS", "15": "FLASH_D0", "8": "FLASH_D1",
        "9": "FLASH_D2", "1": "FLASH_D3", "2": "+3V3", "10": "GND"},
        "Package_SO:SOIC-8_5.23x5.23mm_P1.27mm")
    rail("+3V3", 400, 70, "#PWR34")
    gnd(400, 165, "#PWR35")
    s.add(R, "R43", "10k", 435, 95, {"1": "+3V3", "2": "FLASH_CS"}, FP_R)
    cap("C48", "100nF", "+3V3", 370, 95)


def build():
    s = Schematic("HardFuzz v1 - USB + FT2232H + Flash", paper="A2")
    populate(s)
    return s


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(__file__), "..", "usb.kicad_sch")
    build().write(out)
    print("wrote", os.path.normpath(out))

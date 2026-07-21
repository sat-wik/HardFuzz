#!/usr/bin/env python3
"""HardFuzz v1 — level shifters + target connectors (see ../schematic_design.md §7,§8).

TXS0108E: A-side @ +3V3 (FPGA), B-side @ VREF (target). 8 bus lines = SPI(4) +
I2C(2) + UART(2). I2C pull-ups + VREF divider sense + TVS clamp. Target I/O:
Qwiic (I2C), bus breakout header, SPI/UART keyed header. A-side net names match
the FPGA sheet so they join at assembly; B-side names go to the connectors.
"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from kigen import Schematic

TXS = "Logic_LevelTranslator:TXS0108EPW"   # 1:A1 2:VCCA 3:A2 4:A3 5:A4 6:A5 7:A6 8:A7
#                                            9:A8 10:OE 11:GND 12:B8 13:B7 14:B6 15:B5
#                                            16:B4 17:B3 18:B2 19:VCCB 20:B1
C, R, TVS = "Device:C", "Device:R", "Device:D_TVS"
QWIIC = "Connector_Generic:Conn_01x04"
HDR20 = "Connector_Generic:Conn_02x10_Odd_Even"
HDR10 = "Connector_Generic:Conn_02x05_Odd_Even"
FP_C = "Capacitor_SMD:C_0402_1005Metric"
FP_R = "Resistor_SMD:R_0402_1005Metric"


def populate(s):
    def gnd(x, y, ref): s.add("power:GND", ref, "GND", x, y, {"1": "GND"})
    def rail(net, x, y, ref): s.add(f"power:{net}", ref, net, x, y, {"1": net})

    # ---- TXS0108E ----
    s.add(TXS, "U10", "TXS0108EPW", 150, 110, {
        "2": "+3V3", "19": "VREF", "10": "LS_OE", "11": "GND",
        # A side (FPGA, 3V3)
        "1": "SPI_SCLK", "3": "SPI_MOSI", "4": "SPI_MISO", "5": "SPI_CS",
        "6": "I2C_SCL", "7": "I2C_SDA", "8": "UART_TTX", "9": "UART_TRX",
        # B side (target, VREF)
        "20": "SPI_SCLK_B", "18": "SPI_MOSI_B", "17": "SPI_MISO_B", "16": "SPI_CS_B",
        "15": "I2C_SCL_B", "14": "I2C_SDA_B", "13": "UART_TTX_B", "12": "UART_TRX_B"},
        mpn="TXS0108EPWR")
    rail("+3V3", 130, 60, "#PWR20")
    gnd(150, 155, "#PWR21")
    s.add(C, "C30", "100nF", 110, 100, {"1": "+3V3", "2": "GND"}, FP_C)
    s.add(C, "C31", "100nF", 190, 100, {"1": "VREF", "2": "GND"}, FP_C)
    s.add(R, "R30", "100k", 130, 75, {"1": "+3V3", "2": "LS_OE"}, FP_R)   # OE enable pull-up

    # ---- I2C pull-ups to VREF (B side) ----
    s.add(R, "R31", "4.7k", 210, 80, {"1": "I2C_SCL_B", "2": "VREF"}, FP_R)
    s.add(R, "R32", "4.7k", 222, 80, {"1": "I2C_SDA_B", "2": "VREF"}, FP_R)

    # ---- VREF divider sense (2:1) + TVS clamp + bulk ----
    s.add(R, "R33", "100k", 250, 70, {"1": "VREF", "2": "VREF_SENSE"}, FP_R)
    s.add(R, "R34", "100k", 250, 95, {"1": "VREF_SENSE", "2": "GND"}, FP_R)
    s.add(C, "C32", "1uF", 268, 82, {"1": "VREF", "2": "GND"}, FP_C)
    s.add(TVS, "D20", "SMAJ5.0A", 282, 82, {"1": "VREF", "2": "GND"},
          "Diode_SMD:D_SOD-923")
    gnd(266, 108, "#PWR22")

    # ---- Qwiic / STEMMA I2C (GND, VREF, SDA, SCL) ----
    s.add(QWIIC, "J2", "Qwiic", 320, 70,
          {"1": "GND", "2": "VREF", "3": "I2C_SDA_B", "4": "I2C_SCL_B"},
          "Connector_JST:JST_SH_SM04B-SRSS-TB_1x04-1MP_P1.00mm_Horizontal")

    # ---- bus breakout header (signals odd, GND even) ----
    s.add(HDR20, "J3", "BUS", 360, 130, {
        "1": "SPI_SCLK_B", "3": "SPI_MOSI_B", "5": "SPI_MISO_B", "7": "SPI_CS_B",
        "9": "I2C_SCL_B", "11": "I2C_SDA_B", "13": "UART_TTX_B", "15": "UART_TRX_B",
        "17": "TRIG", "19": "VREF",
        "2": "GND", "4": "GND", "6": "GND", "8": "GND", "10": "GND",
        "12": "GND", "14": "GND", "16": "GND", "18": "GND", "20": "GND"},
        "Connector_PinHeader_2.54mm:PinHeader_2x10_P2.54mm_Vertical")

    # ---- SPI/UART keyed header (inline interposer) ----
    s.add(HDR10, "J4", "SPI/UART", 420, 130, {
        "1": "SPI_SCLK_B", "2": "SPI_MISO_B", "3": "SPI_MOSI_B", "4": "SPI_CS_B",
        "5": "UART_TTX_B", "6": "UART_TRX_B", "7": "VREF", "8": "GND",
        "9": "TRIG", "10": "GND"},
        "Connector_PinHeader_2.54mm:PinHeader_2x05_P2.54mm_Vertical")


def build():
    s = Schematic("HardFuzz v1 - Level Shifters + Connectors")
    populate(s)
    return s


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(__file__), "..", "levelshift.kicad_sch")
    build().write(out)
    print("wrote", os.path.normpath(out))

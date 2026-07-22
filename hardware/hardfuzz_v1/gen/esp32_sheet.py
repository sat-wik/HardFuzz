#!/usr/bin/env python3
"""HardFuzz v2 — ESP32-S3 controller + BLE (see ../../docs/HardFuzz_v2_Standalone.md).

The ESP32-S3-WROOM-1 runs the campaign engine and serves results over BLE, replacing
the host PC. It arms the FPGA over the control UART (the HOST_TXD/HOST_RXD nets the
FT2232 used — now freed for the ESP32), and drives the DUT over a second UART to a
3-pin header. Native USB (D+/D-) to a USB-C for programming/power; EN + IO0 boot
circuits; a BLE/status LED. Integrated-antenna module — no external RF.
"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from kigen import Schematic

ESP = "RF_Module:ESP32-S3-WROOM-1"   # 2:3V3 3:EN 27:IO0 13:USB_D- 14:USB_D+
#   10:IO17 11:IO18 4:IO4 5:IO5 38:IO2   1/40/41:GND
USBC = "Connector:USB_C_Receptacle"
HDR3 = "Connector_Generic:Conn_01x03"
C, R, LED, SW = "Device:C", "Device:R", "Device:LED", "Switch:SW_Push"
FP_C = "Capacitor_SMD:C_0402_1005Metric"
FP_R = "Resistor_SMD:R_0402_1005Metric"
FP_SW = "Button_Switch_SMD:SW_SPST_CK_RS282G05A3"


def populate(s):
    def gnd(x, y, ref): s.add("power:GND", ref, "GND", x, y, {"1": "GND"})
    def rail(net, x, y, ref): s.add(f"power:{net}", ref, net, x, y, {"1": net})
    def cap(ref, val, net, x, y): s.add(C, ref, val, x, y, {"1": net, "2": "GND"}, FP_C)

    # ---------------- ESP32-S3-WROOM-1 ----------------
    s.add(ESP, "U12", "ESP32-S3-WROOM-1", 150, 120, {
        "2": "+3V3", "1": "GND", "40": "GND", "41": "GND",
        "3": "ESP_EN", "27": "ESP_IO0",
        "13": "ESP_USB_DM", "14": "ESP_USB_DP",
        "10": "HOST_TXD", "11": "HOST_RXD",      # UART1 -> FPGA ctrl_regs (arm faults)
        "4": "DUT_TXD", "5": "DUT_RXD",          # UART2 -> DUT (drive + read RESULT)
        "38": "ESP_STAT"},                        # IO2 -> BLE/activity LED
        "RF_Module:ESP32-S3-WROOM-1", nc_unused=True, mpn="ESP32-S3-WROOM-1-N8")
    rail("+3V3", 120, 55, "#PWR50")
    gnd(150, 175, "#PWR51")
    cap("C60", "10uF", "+3V3", 105, 70)
    cap("C61", "100nF", "+3V3", 118, 70)

    # ---- EN (chip enable): pull-up + RC + reset button ----
    s.add(R, "R60", "10k", 100, 95, {"1": "+3V3", "2": "ESP_EN"}, FP_R)
    cap("C62", "1uF", "ESP_EN", 100, 110)
    s.add(SW, "SW2", "RST", 100, 130, {"1": "ESP_EN", "2": "GND"}, FP_SW)

    # ---- IO0 (boot): pull-up + boot button ----
    s.add(R, "R61", "10k", 205, 95, {"1": "+3V3", "2": "ESP_IO0"}, FP_R)
    s.add(SW, "SW3", "BOOT", 205, 130, {"1": "ESP_IO0", "2": "GND"}, FP_SW)

    # ---- BLE / status LED ----
    s.add(R, "R62", "330", 205, 155, {"1": "ESP_STAT", "2": "ESP_LED_A"}, FP_R)
    s.add(LED, "D50", "BLE", 205, 172, {"1": "ESP_LED_A", "2": "GND"},
          "LED_SMD:LED_0603_1608Metric")

    # ---- USB-C (native USB: programming + power) ----
    s.add(USBC, "J6", "USB-C", 300, 100, {
        "A1": "GND", "A12": "GND", "B1": "GND", "B12": "GND", "SH": "GND",
        "A4": "+5V", "A9": "+5V", "B4": "+5V", "B9": "+5V",
        "A5": "ESP_CC1", "B5": "ESP_CC2",
        "A6": "ESP_USB_DP", "B6": "ESP_USB_DP",
        "A7": "ESP_USB_DM", "B7": "ESP_USB_DM"},
        "Connector_USB:USB_C_Receptacle_GCT_USB4085", nc_unused=True, mpn="USB4085-GF-A")
    rail("+5V", 300, 50, "#PWR52")
    gnd(300, 165, "#PWR53")
    s.add(R, "R63", "5.1k", 265, 80, {"1": "ESP_CC1", "2": "GND"}, FP_R)
    s.add(R, "R64", "5.1k", 277, 80, {"1": "ESP_CC2", "2": "GND"}, FP_R)
    cap("C63", "10uF", "+5V", 340, 80)

    # ---- DUT UART header (TX / RX / GND to the target under test) ----
    s.add(HDR3, "J7", "DUT", 360, 130, {"1": "DUT_TXD", "2": "DUT_RXD", "3": "GND"},
          "Connector_PinHeader_2.54mm:PinHeader_1x03_P2.54mm_Vertical")


def build():
    s = Schematic("HardFuzz v2 - ESP32 + BLE")
    populate(s)
    return s


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(__file__), "..", "esp32.kicad_sch")
    build().write(out)
    print("wrote", os.path.normpath(out))

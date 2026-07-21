# HardFuzz v1 — KiCad parts readiness

Every BOM line sorted by whether its symbol + footprint already ship with KiCad 8 or need
to be grabbed/drawn first. Do the small "needs work" list *before* opening the schematic —
then capture is pure wiring.

> Library names are for KiCad 8 stock libs; exact contents drift between versions, so treat
> the ✅ rows as "expect it, confirm in your install" and the ⚠️/🔧 rows as the real work.

## Summary

- **✅ In stock (~85% of the BOM):** all passives, connectors, and most ICs.
- **⚠️ Verify variant/footprint (3):** FT2232H, TLV62569, oscillator.
- **🔧 Grab or draw (2–3):** the FPGA (the big one), the AP63203 buck, and the exact QSPI
  flash if you want the specific part vs. a generic.

## Full breakdown

| Ref | Part | Symbol source | Footprint | Status |
|---|---|---|---|---|
| U1 | XC7A35T-1CSG324C | `FPGA_Xilinx_Artix7:XC7A35T-CSG324` ✅ (stock; chose CSG324 over FTG256 precisely because the symbol ships with KiCad) | **BGA-324, 0.8 mm** — confirm/create against Xilinx UG475 | ✅ symbol / 🔧 footprint |
| U2 | FT2232HQ | `Interface_USB` (has FT2232H, likely the HL/LQFP symbol) | needs **QFN-64 9×9 0.5 mm** (HQ), not the LQFP | ⚠️ reuse symbol, pick QFN-64 fp |
| U3 | N25Q032 QSPI | `Memory_Flash` — generic SPI/QSPI or W25Q32 equivalent | SOIC-8 (stock) | ✅ use generic if exact absent |
| U4 | SN65HVD230 | `Interface_CAN_LIN` ✅ | SOIC-8 (stock) | ✅ |
| U5 | TXS0108EPWR | `Logic_LevelTranslator` ✅ | TSSOP-20 (stock) | ✅ |
| U5b | 74LVC1T45 (DNP) | `Logic_LevelTranslator` ✅ | SOT-363 (stock) | ✅ |
| U6 | AP63203 buck | **not in stock** — SnapEDA / vendor, or draw (simple, ~6 pins) | TSOT-23-6 (stock fp) | 🔧 grab symbol |
| U7 | TLV62569 buck | `Regulator_Switching` may have it — **verify** | SOT-23-5 (stock) | ⚠️ verify / draw |
| U8 | AP2112K-1.8 | `Regulator_Linear` (AP2112K) ✅ | SOT-23-5 (stock) | ✅ |
| U9 | 93LC56B | `Memory_EEPROM` (93Cxx) ✅ | SOT-23-6 (stock) | ✅ |
| Y1 | 12 MHz osc | `Oscillator` generic 4-pin ✅ | SMD 2016/2520 (stock) | ⚠️ pick body size |
| Y2 | 12 MHz crystal | `Device:Crystal_GND24` ✅ | SMD 3225 (stock) | ✅ |
| J1 | USB-C USB2 | `Connector:USB_C_Receptacle_USB2.0` ✅ | match your exact receptacle | ✅ confirm fp part |
| J2 | JST-SH 4-pin | `Connector_Generic:Conn_01x04` ✅ | `Connector_JST:JST_SH_*_1x04` ✅ | ✅ |
| J3 | 3-pos screw term | `Connector:Screw_Terminal_01x03` ✅ | TerminalBlock (stock) | ✅ |
| J4/J5/J6 | 0.1" headers | `Connector_Generic:Conn_02xNN` ✅ | PinHeader (stock) | ✅ |
| D1 | USBLC6-2SC6 | `Power_Protection:USBLC6-2SC6` ✅ | SOT-23-6 (stock) | ✅ |
| D2 | LED 0603 | `Device:LED` ✅ | LED_0603 (stock) | ✅ |
| D3 | RGB LED | `Device:LED_RGB` ✅ | pick PLCC-4/6 fp | ✅ |
| D4 | TVS 5.5 V | `Device:D_TVS` ✅ | SOD-923 (stock) | ✅ |
| SW1 | tact switch | `Switch:SW_Push` ✅ | pick tact fp | ✅ |
| L1 | 2.2 µH | `Device:L` ✅ | your inductor fp | ✅ |
| R*/C* | passives | `Device:R` / `Device:C` ✅ | 0402/0603/0805 (stock) | ✅ |

## The "grab or draw before capture" list

1. **FPGA (U1)** — the one real task. Options, best first:
   - Confirm `FPGA_Xilinx_Artix7` has an **XC7A35T-FTG256** symbol; if it's only CSG/CPG,
     the *pin functions* match but *ball numbers* don't — you need the FTG256 variant.
   - Pull symbol **and** the BGA-256 footprint from **SnapEDA / Ultra Librarian /
     ComponentSearchEngine** (all export KiCad). This is the fastest correct route.
   - The BGA-256 (16×16, 1.0 mm) footprint: verify pad size/soldermask against Xilinx
     UG475 (7-series packaging) before trusting a third-party one.
2. **AP63203 buck (U6)** — grab from SnapEDA, or draw it (~6-pin part, trivial symbol).
3. **TLV62569 (U7)** — check `Regulator_Switching`; if absent, SnapEDA or draw.
4. **FT2232HQ footprint (U2)** — the symbol is reusable; just bind it to a **QFN-64 9×9
   0.5 mm** footprint (stock `Package_DFN_QFN`), not the LQFP the symbol may default to.
5. **QSPI flash (U3)** — a generic 8-SOIC SPI-flash symbol is fine; only chase the exact
   N25Q032 part if you want the datasheet timing in the symbol.

Everything else is stock KiCad — place and wire directly.

## Sources for third-party symbols/footprints

- **SnapEDA**, **Ultra Librarian**, **ComponentSearchEngine (SamacSys)** — all export KiCad
  symbol + footprint + 3D for the FPGA, FT2232H, and the buck ICs.
- **Xilinx UG475** — authoritative FTG256 ball map + package mechanicals (trust this over a
  third-party footprint for the BGA).
- Keep imported parts in a **project-local library** (`hardfuzz_v1/hardfuzz.kicad_sym` +
  `.pretty`) so the project is self-contained and reproducible.

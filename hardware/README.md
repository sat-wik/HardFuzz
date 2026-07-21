# hardware/ — HardFuzz v1 PCB

The custom board that turns the validated dev-board prototype (Cmod A7 + NUCLEO in the
repo root) into a plug-and-play product. Design captured here; the KiCad project lands in
`hardfuzz_v1/` once the schematic is drawn from the spec.

## What's here

| File | What it is |
|---|---|
| [schematic_design.md](schematic_design.md) | the electrical design — block diagram, power tree, part selection, and net-by-net connections per block. **Start here.** |
| [bom.csv](bom.csv) | bill of materials with part numbers, packages, and 100-unit costs (~$40 total) |
| `hardfuzz_v1/` | KiCad 8 project (`.kicad_pro/.kicad_sch/.kicad_pcb`) — created by drawing the schematic from the spec |

Product-side rationale (attach modes, out-of-box experience) lives in
[../docs/HardFuzz_v1_Spec.md](../docs/HardFuzz_v1_Spec.md).

## Design approach

Reuse the **proven Cmod A7 core** (Artix-7 XC7A35T-CPG236 + FT2232H USB-JTAG/UART + QSPI
config) so the bitstream we already run on hardware drops on unchanged, and add the
productization layer: level-shifted bus I/O with `VREF` sensing, an onboard SN65HVD230 CAN
transceiver, and keyed target connectors (Qwiic / CAN screw terminal / SPI interposer).

## Status

**Design spec complete; KiCad capture is the next step.** The schematic is fully specified
at the net level in `schematic_design.md` — the remaining work is mechanical: place
symbols, wire per the connection lists, run ERC, assign footprints, and lay out a 4-layer
board. Open decisions to resolve before layout are listed in §10 of the spec.

## Doing the KiCad capture

1. `kicad` → new project `hardware/hardfuzz_v1/`.
2. Work block by block through `schematic_design.md` §3–§9, using the doc's net names as
   labels so the netlist matches the RTL `.xdc` pin intent.
3. ERC clean → footprints (BGA-236, QFN-64, TSSOP-20, SOIC-8, JST-SH…) → PCB per §11.

KiCad's own files are the source of truth once created; regenerate the BOM from the
schematic at that point (this `bom.csv` is the design-time reference).

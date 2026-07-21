#!/usr/bin/env python3
"""Generate an SPI bit-flip campaign: every (frame, bit). Prints JSON to stdout.

  python3 gen_spi_sweep.py > spi_sweep.json

The firmware clocks 9 frames and checks frames 1..8 (frame 0 is the echo pipeline
fill). Any injected bit flip is a mismatch, so every SPI scenario expects "detected".
"""
import json
import sys

frames = range(1, 9)   # frame 0 is pipeline fill (not checked)
bits = range(0, 8)

faults = []
for f in frames:
    for b in bits:
        faults.append({"id": f"SPI-f{f}-b{b}", "protocol": "spi", "frame": f, "bit": b,
                       "expect": "detected", "requirement": f"SR-SPI-F{f}"})

# re-test a few tuples so the coverage-guided scheduler has repeats to defer
for f in (1, 4, 8):
    faults.append({"id": f"SPI-f{f}-retest", "protocol": "spi", "frame": f, "bit": 3,
                   "expect": "detected", "requirement": f"SR-SPI-F{f}"})

campaign = {
    "name": "SPI bit-flip sweep",
    "target": "STM32F446 SPI master vs spi_inject_top",
    "standard": "IEC 61508",
    "faults": faults,
}
json.dump(campaign, sys.stdout, indent=2)
sys.stdout.write("\n")

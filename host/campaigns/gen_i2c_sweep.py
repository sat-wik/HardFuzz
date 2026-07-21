#!/usr/bin/env python3
"""Generate a swept I2C clock-stretch campaign: every target byte x a set of stretch
lengths. Prints JSON to stdout. Regenerate/resize by editing `bytes_` / `levels`.

  python3 gen_i2c_sweep.py > i2c_sweep.json
"""
import json
import sys

# The firmware sends 4 data bytes, so a stretch on target byte T is felt on byte T's
# transfer for T in 0..3 (0 = address). Those are the observable targets.
bytes_ = [0, 1, 2, 3]

# (stretch_cycles, expected DUT behaviour). ~cycles/12 = microseconds of SCL-low hold.
# < ~700 cycles keeps the byte under the firmware's 150 us "slow" threshold (tolerated);
# larger is detected as a slow byte, and > ~24000 (2 ms) trips the master timeout.
levels = [
    (100,   "tolerated"),   # ~8 us
    (300,   "tolerated"),   # ~25 us
    (1200,  "detected"),    # ~100 us  (slow)
    (3000,  "detected"),    # ~250 us
    (6000,  "detected"),    # ~500 us
    (12000, "detected"),    # ~1 ms
    (30000, "detected"),    # ~2.5 ms  (timeout)
    (60000, "detected"),    # ~5 ms    (timeout)
]

faults = []
for b in bytes_:
    for s, exp in levels:
        faults.append({"id": f"I2C-b{b}-s{s}", "protocol": "i2c", "byte": b,
                       "stretch_cycles": s, "expect": exp, "requirement": f"SR-I2C-B{b}"})

# Re-test the worst case on each byte, so those tuples get hit twice — exercises the
# coverage-guided scheduler (it defers the repeats until everything novel has run).
for b in bytes_:
    faults.append({"id": f"I2C-b{b}-retest", "protocol": "i2c", "byte": b,
                   "stretch_cycles": 60000, "expect": "detected", "requirement": f"SR-I2C-B{b}"})

campaign = {
    "name": "I2C clock-stretch sweep",
    "target": "STM32F446 I2C master vs i2c_inject_top (slave 0x42)",
    "standard": "IEC 61508",
    "faults": faults,
}
json.dump(campaign, sys.stdout, indent=2)
sys.stdout.write("\n")

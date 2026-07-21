#!/usr/bin/env bash
# Fast simulation with Icarus Verilog — no Vivado required.
#   Usage: ./sim/run_icarus.sh [tb_uart_echo|tb_pulse_meter]
# Writes a .vcd in the repo root; open it with: gtkwave <tb>.vcd
set -euo pipefail
cd "$(dirname "$0")/.."
TB="${1:-tb_uart_echo}"
mkdir -p build/sim
# Compile every RTL source; iverilog elaborates from the selected testbench top.
iverilog -g2012 -o "build/sim/${TB}.out" -s "${TB}" \
    $(find rtl -name '*.v' | sort) \
    "sim/${TB}.v"
vvp "build/sim/${TB}.out"
echo "---"
echo "waveform: surfer ${TB}.vcd"

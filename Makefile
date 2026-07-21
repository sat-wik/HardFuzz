# HardFuzz build shortcuts.
# Cmod A7-35T by default; for the A7-15T:  make bit PART=xc7a15tcpg236-1
TOP  ?= spi_inject_top
PART ?= xc7a35tcpg236-1

.PHONY: sim sim-all sim-echo sim-pulse sim-ctrl sim-spi wave clean bit prog

# Fast simulation (Icarus) — the primary verifier until instruments arrive.
sim: sim-all

sim-all:
	@for tb in tb_uart_echo tb_pulse_meter tb_ctrl_regs tb_spi_inject tb_i2c_inject tb_can_inject tb_multi_inject; do \
	  echo "=== $$tb ==="; ./sim/run_icarus.sh $$tb | grep -E 'PASS|FAIL|ALL|TEST'; echo; \
	done

sim-echo:
	./sim/run_icarus.sh tb_uart_echo

sim-pulse:
	./sim/run_icarus.sh tb_pulse_meter

sim-ctrl:
	./sim/run_icarus.sh tb_ctrl_regs

sim-spi:
	./sim/run_icarus.sh tb_spi_inject

sim-i2c:
	./sim/run_icarus.sh tb_i2c_inject

sim-can:
	./sim/run_icarus.sh tb_can_inject

sim-multi:
	./sim/run_icarus.sh tb_multi_inject

# Run a sim and open its waveform in Surfer.  make wave WAVE=tb_spi_inject
WAVE ?= tb_spi_inject
wave:
	./sim/run_icarus.sh $(WAVE)
	surfer $(WAVE).vcd

# Synthesis + place/route + bitstream (Vivado). Vivado has no macOS build — run this
# on a Linux box / cloud instance (see docs/vivado-cloud.md), then copy the .bit back.
bit:
	vivado -mode batch -source scripts/build.tcl -tclargs $(PART) $(TOP)

# Program the board from macOS with openFPGALoader (native, no Vivado needed).
# Loads to SRAM (volatile). Board is the A7-35T; for the 15T: make prog BOARD=cmoda7_15t
BOARD ?= cmoda7_35t
prog:
	openFPGALoader -b $(BOARD) build/vivado/$(TOP).bit

# Persist the bitstream to the Cmod's SPI flash (survives power cycle).
prog-flash:
	openFPGALoader -b $(BOARD) -f build/vivado/$(TOP).bit

# Program via Vivado's own tools (only if you're on the Linux/cloud box).
prog-vivado:
	vivado -mode batch -source scripts/program.tcl -tclargs build/vivado/$(TOP).bit

clean:
	rm -rf build *.vcd *.jou *.log .Xil

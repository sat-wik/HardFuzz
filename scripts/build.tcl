# build.tcl — headless Vivado synth + place/route + bitstream for the Cmod A7.
#   vivado -mode batch -source scripts/build.tcl
#   vivado -mode batch -source scripts/build.tcl -tclargs <part> <top>
# Defaults target the Cmod A7-35T; for the A7-15T pass xc7a15tcpg236-1.

set part [lindex $argv 0]
if {$part eq ""} { set part "xc7a35tcpg236-1" }
set top  [lindex $argv 1]
if {$top eq ""} { set top "spi_inject_top" }

set outdir "build/vivado"
file mkdir $outdir

# All RTL: top-level plus every one-level subdirectory (uart, ctrl, spi, inject, timing).
read_verilog -sv [glob -nocomplain rtl/*.v rtl/*/*.v]
read_xdc constraints/cmod_a7.xdc

synth_design -top $top -part $part
opt_design
place_design
route_design

report_timing_summary -file $outdir/timing.rpt
report_utilization      -file $outdir/util.rpt

write_bitstream -force $outdir/${top}.bit
puts "Bitstream written: $outdir/${top}.bit"

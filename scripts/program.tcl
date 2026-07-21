# program.tcl — load a bitstream onto the Cmod A7 over USB-JTAG.
#   vivado -mode batch -source scripts/program.tcl
#   vivado -mode batch -source scripts/program.tcl -tclargs build/vivado/hardfuzz_top.bit
# (Vivado 2019.2+; for older versions replace open_hw_manager with open_hw.)

set bit [lindex $argv 0]
if {$bit eq ""} { set bit "build/vivado/hardfuzz_top.bit" }

open_hw_manager
connect_hw_server
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
set_property PROGRAM.FILE $bit [current_hw_device]
program_hw_devices [current_hw_device]
puts "Programmed: $bit"

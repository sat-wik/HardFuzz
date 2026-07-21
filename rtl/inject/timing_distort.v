`timescale 1ns / 1ps
//
// timing_distort.v — I2C clock-stretch fault injector.
//
// Thin decision core (like bitflip_inj): when armed and the slave is completing the
// targeted byte, tell the slave to hold SCL low for `stretch_len` cycles. The slave
// owns the actual bus timing; this just picks when to distort. `stretch_len` is in
// clk cycles — at 12 MHz, 1200 cycles ~= 100 us, enough to trip a typical master's
// I2C timeout.
//
// (SPI setup/hold distortion is a planned second mode for this module; today it does
// the I2C clock stretch that the Month 2 exit criterion needs.)
//
module timing_distort (
    input  wire        enable,
    input  wire [7:0]  target_byte,
    input  wire [15:0] stretch_len_in,
    input  wire [7:0]  byte_index,       // current byte, from i2c_slave
    output wire        do_stretch,        // -> i2c_slave.do_stretch
    output wire [15:0] stretch_len_out    // -> i2c_slave.stretch_len
);
    assign do_stretch      = enable & (byte_index == target_byte);
    assign stretch_len_out = stretch_len_in;
endmodule

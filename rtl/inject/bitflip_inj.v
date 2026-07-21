`timescale 1ns / 1ps
//
// bitflip_inj.v — flip one serial bit at a target (frame, bit) position.
//
// Purely combinational: it XORs the serial line during exactly the bit whose frame
// index and byte-bit number match the armed target. The frame/bit tracking lives in
// spi_slave (which already decodes the bus), so this stays a thin, reusable "corrupt
// the wire" primitive. `flip_active` drives the trig_out probe pin and a host-visible
// injection counter.
//
// target_bit uses byte-bit numbering: 0 = LSB .. 7 = MSB, matching spi_slave.bit_num.
//
module bitflip_inj (
    input  wire        enable,
    input  wire [15:0] target_frame,
    input  wire [2:0]  target_bit,
    input  wire [15:0] frame_idx,    // current frame, from spi_slave
    input  wire [2:0]  bit_num,      // current byte-bit on the wire, from spi_slave
    input  wire        line_in,      // clean serial bit
    output wire        line_out,     // possibly-flipped serial bit
    output wire        flip_active   // high during the injected bit
);
    assign flip_active = enable
                       & (frame_idx == target_frame)
                       & (bit_num   == target_bit);
    assign line_out = line_in ^ flip_active;
endmodule

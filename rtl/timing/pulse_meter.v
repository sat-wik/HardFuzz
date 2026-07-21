`timescale 1ns / 1ps
//
// pulse_meter.v — measure signal timing in clock cycles. No scope required.
//
// Counts how many `clk` cycles an input pulse stays high (width) and how many
// cycles elapse between successive rising edges (period), latching both when a
// pulse ends and pulsing `sample` for one cycle. Multiply a count by the clock
// period to get time: at 100 MHz, 1 count = 10 ns.
//
// This is the "turn time into a number you can print" primitive: run it on a fast
// MMCM clock, feed it the signal you want to characterize (a glitch pulse, an SPI
// setup window, an I2C clock stretch), and read width_cnt / period_cnt out over
// UART. See docs/timing-verification.md for the technique and its limits.
//
module pulse_meter #(
    parameter integer WIDTH = 32
) (
    input  wire              clk,
    input  wire              rst,        // active high, synchronous
    input  wire              sig,        // signal under measurement (async ok)
    output reg  [WIDTH-1:0]  width_cnt,  // cycles sig was high     (latched)
    output reg  [WIDTH-1:0]  period_cnt, // cycles rise-to-rise     (latched)
    output reg               sample      // 1-cycle strobe on new results
);
    // Synchronize + build 1-cycle-delayed copies for edge detection.
    reg sig_d0 = 1'b0, sig_s = 1'b0, sig_p = 1'b0;
    always @(posedge clk) begin
        sig_d0 <= sig;
        sig_s  <= sig_d0;
        sig_p  <= sig_s;
    end
    wire rising  =  sig_s & ~sig_p;
    wire falling = ~sig_s &  sig_p;

    reg [WIDTH-1:0] w_run = 0;   // running high-time
    reg [WIDTH-1:0] p_run = 0;   // running rising-edge-to-rising-edge time
    reg             armed = 1'b0;

    always @(posedge clk) begin
        if (rst) begin
            w_run <= 0; p_run <= 0; armed <= 1'b0;
            width_cnt <= 0; period_cnt <= 0; sample <= 1'b0;
        end else begin
            sample <= 1'b0;

            if (armed) p_run <= p_run + 1'b1;   // period runs continuously

            if (rising) begin
                if (armed) period_cnt <= p_run + 1'b1;  // latch completed period
                p_run <= 0;
                w_run <= 0;
                armed <= 1'b1;
            end else if (sig_s) begin
                w_run <= w_run + 1'b1;           // accumulate high time
            end

            if (falling) begin
                width_cnt <= w_run + 1'b1;       // include the rising-edge cycle
                sample    <= 1'b1;
            end
        end
    end
endmodule

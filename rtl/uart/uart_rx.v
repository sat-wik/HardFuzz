`timescale 1ns / 1ps
//
// uart_rx.v — 8N1 UART receiver.
//
// Samples the async RX line through a 2-FF synchronizer, aligns to the middle of
// each bit using a clock-cycle counter, and raises `valid` for one cycle when a
// full byte is available on `data`.
//
module uart_rx #(
    parameter integer CLKS_PER_BIT = 104   // clk_hz / baud  (12e6/115200 = 104)
) (
    input  wire        clk,
    input  wire        rst,     // active high, synchronous
    input  wire        rx,      // async serial in (idle high)
    output reg         valid,   // 1-cycle strobe: byte ready
    output reg  [7:0]  data
);
    localparam [2:0] S_IDLE  = 3'd0,
                     S_START = 3'd1,
                     S_DATA  = 3'd2,
                     S_STOP  = 3'd3,
                     S_DONE  = 3'd4;

    // Synchronize the asynchronous RX line into the clk domain.
    reg rx_d0 = 1'b1, rx_sync = 1'b1;
    always @(posedge clk) begin
        rx_d0   <= rx;
        rx_sync <= rx_d0;
    end

    reg [2:0]  state   = S_IDLE;
    reg [15:0] clk_cnt = 16'd0;
    reg [2:0]  bit_idx = 3'd0;

    always @(posedge clk) begin
        if (rst) begin
            state   <= S_IDLE;
            valid   <= 1'b0;
            clk_cnt <= 16'd0;
            bit_idx <= 3'd0;
            data    <= 8'h00;
        end else begin
            valid <= 1'b0;   // default; pulsed only in S_DONE
            case (state)
                S_IDLE: begin
                    clk_cnt <= 16'd0;
                    bit_idx <= 3'd0;
                    if (rx_sync == 1'b0)          // falling edge = start bit
                        state <= S_START;
                end
                S_START: begin
                    if (clk_cnt == (CLKS_PER_BIT-1)/2) begin
                        if (rx_sync == 1'b0) begin  // still low at mid-bit: real start
                            clk_cnt <= 16'd0;
                            state   <= S_DATA;
                        end else begin
                            state <= S_IDLE;        // glitch, not a start bit
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end
                S_DATA: begin
                    if (clk_cnt == CLKS_PER_BIT-1) begin
                        clk_cnt        <= 16'd0;
                        data[bit_idx]  <= rx_sync;  // sample at bit center
                        if (bit_idx == 3'd7) begin
                            bit_idx <= 3'd0;
                            state   <= S_STOP;
                        end else begin
                            bit_idx <= bit_idx + 3'd1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end
                S_STOP: begin
                    if (clk_cnt == CLKS_PER_BIT-1) begin
                        clk_cnt <= 16'd0;
                        state   <= S_DONE;
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end
                S_DONE: begin
                    valid <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

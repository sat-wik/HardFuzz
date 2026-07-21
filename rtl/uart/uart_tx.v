`timescale 1ns / 1ps
//
// uart_tx.v — 8N1 UART transmitter.
//
// Pulse `start` for one cycle with `data` valid; the byte is shifted out LSB-first
// framed by a start (low) and stop (high) bit. `busy` is high for the whole frame.
//
module uart_tx #(
    parameter integer CLKS_PER_BIT = 104
) (
    input  wire        clk,
    input  wire        rst,     // active high, synchronous
    input  wire        start,   // 1-cycle strobe to begin a frame
    input  wire [7:0]  data,
    output reg         tx,      // serial out (idle high)
    output reg         busy
);
    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    reg [1:0]  state   = S_IDLE;
    reg [15:0] clk_cnt = 16'd0;
    reg [2:0]  bit_idx = 3'd0;
    reg [7:0]  shreg   = 8'h00;

    always @(posedge clk) begin
        if (rst) begin
            state   <= S_IDLE;
            tx      <= 1'b1;
            busy    <= 1'b0;
            clk_cnt <= 16'd0;
            bit_idx <= 3'd0;
            shreg   <= 8'h00;
        end else begin
            case (state)
                S_IDLE: begin
                    tx      <= 1'b1;
                    busy    <= 1'b0;
                    clk_cnt <= 16'd0;
                    bit_idx <= 3'd0;
                    if (start) begin
                        shreg <= data;
                        busy  <= 1'b1;
                        state <= S_START;
                    end
                end
                S_START: begin
                    tx <= 1'b0;                  // start bit
                    if (clk_cnt == CLKS_PER_BIT-1) begin
                        clk_cnt <= 16'd0;
                        state   <= S_DATA;
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end
                S_DATA: begin
                    tx <= shreg[bit_idx];       // LSB first
                    if (clk_cnt == CLKS_PER_BIT-1) begin
                        clk_cnt <= 16'd0;
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
                    tx <= 1'b1;                  // stop bit
                    if (clk_cnt == CLKS_PER_BIT-1) begin
                        clk_cnt <= 16'd0;
                        busy    <= 1'b0;
                        state   <= S_IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 16'd1;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

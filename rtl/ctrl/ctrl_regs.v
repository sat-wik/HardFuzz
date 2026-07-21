`timescale 1ns / 1ps
//
// ctrl_regs.v — host register file over UART. Replaces the plan's AXI-Lite + soft
// CPU with a plain command FSM (see the refined plan's simplifications).
//
// Wire protocol (bytes, over the Cmod's USB-UART bridge):
//   Write:  'W' (0x57)  addr  data      -> regs[addr] = data
//   Read:   'R' (0x52)  addr             -> device replies with one byte
// Read addresses < NREGS return the register; addresses >= 0x80 return a status byte
// supplied by the top (frame counter, injection counter, ...). Any unrecognized byte
// in the idle state is ignored, so line noise can't wedge the FSM.
//
// The write side-channel (wr_stb/wr_addr/wr_data) lets the top act on specific writes
// (e.g. pulse clr_frame) without baking app semantics into this generic file.
//
module ctrl_regs #(
    parameter integer NREGS = 8
) (
    input  wire        clk,
    input  wire        rst,
    // from uart_rx
    input  wire        rx_valid,
    input  wire [7:0]  rx_data,
    // to uart_tx
    input  wire        tx_busy,
    output reg         tx_start,
    output reg  [7:0]  tx_data,
    // register file (flattened: reg k = regs_flat[8*k +: 8])
    output reg  [8*NREGS-1:0] regs_flat,
    // write side-channel
    output reg         wr_stb,
    output reg  [7:0]  wr_addr,
    output reg  [7:0]  wr_data,
    // read-only status bytes (status k = status_flat[8*k +: 8], addr 0x80+k)
    input  wire [8*8-1:0] status_flat
);
    localparam [7:0] CMD_W = 8'h57;   // 'W'
    localparam [7:0] CMD_R = 8'h52;   // 'R'
    localparam [7:0] STATUS_BASE = 8'h80;

    localparam [2:0] S_IDLE   = 3'd0,
                     S_W_ADDR = 3'd1,
                     S_W_DATA = 3'd2,
                     S_R_ADDR = 3'd3,
                     S_R_SEND = 3'd4;
    reg [2:0] state  = S_IDLE;
    reg [7:0] addr_l = 8'h00;

    function [7:0] read_reg(input [7:0] a);
        begin
            if (a >= STATUS_BASE)
                read_reg = status_flat[8*a[2:0] +: 8];
            else if (a < NREGS)
                read_reg = regs_flat[8*a[2:0] +: 8];
            else
                read_reg = 8'h00;
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            tx_start  <= 1'b0;
            tx_data   <= 8'h00;
            wr_stb    <= 1'b0;
            wr_addr   <= 8'h00;
            wr_data   <= 8'h00;
            addr_l    <= 8'h00;
            regs_flat <= {(8*NREGS){1'b0}};
        end else begin
            tx_start <= 1'b0;   // default: single-cycle pulses
            wr_stb   <= 1'b0;
            case (state)
                S_IDLE: if (rx_valid) begin
                    if      (rx_data == CMD_W) state <= S_W_ADDR;
                    else if (rx_data == CMD_R) state <= S_R_ADDR;
                end
                S_W_ADDR: if (rx_valid) begin
                    addr_l <= rx_data;
                    state  <= S_W_DATA;
                end
                S_W_DATA: if (rx_valid) begin
                    if (addr_l < NREGS)
                        regs_flat[8*addr_l[2:0] +: 8] <= rx_data;
                    wr_stb  <= 1'b1;
                    wr_addr <= addr_l;
                    wr_data <= rx_data;
                    state   <= S_IDLE;
                end
                S_R_ADDR: if (rx_valid) begin
                    addr_l <= rx_data;
                    state  <= S_R_SEND;
                end
                S_R_SEND: if (!tx_busy) begin
                    tx_data  <= read_reg(addr_l);
                    tx_start <= 1'b1;
                    state    <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

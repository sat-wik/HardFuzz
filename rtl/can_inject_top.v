`timescale 1ns / 1ps
//
// can_inject_top.v — Month 2 (CAN): host-armed CAN frame corruption. SIM-ONLY until a
// CAN transceiver (SN65HVD230) is wired to can_txd/can_rxd.
//
//   host (USB-UART) --> uart_rx --> ctrl_regs --> config registers
//   CAN bus <--(SN65HVD230)--> frame_corrupt   (forces the bus dominant on a target bit)
//
// The host arms a target bit index + width; the corruptor watches the bus, and on that
// bit of the next frame drives TXD dominant, breaking the frame (bad CRC / stuff error /
// form error depending on where you aim). trig_out pulses while forcing.
//
// TXD/RXD are single-ended logic to the transceiver (TXD=0 => dominant on the bus).
//
// Register map (write 'W' addr data; read 'R' addr):
//   reg0  control : bit0 enable, bit1 clr (reset counters)
//   reg1  target_bit[7:0]
//   reg2  target_bit[15:8]  (bit index from SOF; SOF = bit 0)
//   reg3  width             (consecutive bits to force dominant; >=6 => stuff error)
//   status 0x80/0x81 = corrupt_count lo/hi, 0x82/0x83 = frame_count lo/hi
//
module can_inject_top #(
    parameter integer CLK_HZ      = 12_000_000,
    parameter integer BAUD        = 115_200,
    parameter integer CAN_BITRATE = 500_000
) (
    input  wire        sysclk,
    input  wire [1:0]  btn,
    output wire [1:0]  led,
    // host UART (FT2232 bridge)
    output wire        uart_rxd_out,
    input  wire        uart_txd_in,
    // CAN transceiver (single-ended logic side)
    input  wire        can_rxd,          // R pin of the transceiver
    output wire        can_txd,          // D pin (0 = dominant)
    // scope/logic-analyzer trigger
    output wire        trig_out
);
    localparam integer CLKS_PER_BIT = CLK_HZ / BAUD;
    localparam integer NREGS = 8;
    wire rst = btn[0];

    // ---- host UART ----------------------------------------------------------
    wire       rx_valid; wire [7:0] rx_data;
    wire       tx_busy;  wire       tx_start; wire [7:0] tx_data;
    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(sysclk), .rst(rst), .rx(uart_txd_in), .valid(rx_valid), .data(rx_data));
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(sysclk), .rst(rst), .start(tx_start), .data(tx_data),
        .tx(uart_rxd_out), .busy(tx_busy));

    // ---- control registers --------------------------------------------------
    wire [8*NREGS-1:0] regs_flat;
    wire        wr_stb; wire [7:0] wr_addr, wr_data;
    reg  [8*8-1:0] status_flat;
    ctrl_regs #(.NREGS(NREGS)) u_regs (
        .clk(sysclk), .rst(rst),
        .rx_valid(rx_valid), .rx_data(rx_data),
        .tx_busy(tx_busy), .tx_start(tx_start), .tx_data(tx_data),
        .regs_flat(regs_flat),
        .wr_stb(wr_stb), .wr_addr(wr_addr), .wr_data(wr_data),
        .status_flat(status_flat));

    wire        cor_enable = regs_flat[8*0 + 0];
    wire [15:0] target_bit = {regs_flat[8*2 +: 8], regs_flat[8*1 +: 8]};
    wire [7:0]  width      = regs_flat[8*3 +: 8];
    wire        clr        = wr_stb & (wr_addr == 8'd0) & wr_data[1];

    // ---- frame corruptor ----------------------------------------------------
    wire        force_dominant;
    wire [15:0] frame_count, corrupt_count;
    frame_corrupt #(.CLK_HZ(CLK_HZ), .CAN_BITRATE(CAN_BITRATE)) u_cor (
        .clk(sysclk), .rst(rst),
        .can_rx(can_rxd), .force_dominant(force_dominant),
        .enable(cor_enable), .target_bit(target_bit), .width(width), .clr(clr),
        .frame_count(frame_count), .corrupt_count(corrupt_count));

    assign can_txd  = force_dominant ? 1'b0 : 1'b1;   // dominant when forcing, else recessive
    assign trig_out = force_dominant;

    always @(*) begin
        status_flat = 64'd0;
        status_flat[8*0 +: 8] = corrupt_count[7:0];
        status_flat[8*1 +: 8] = corrupt_count[15:8];
        status_flat[8*2 +: 8] = frame_count[7:0];
        status_flat[8*3 +: 8] = frame_count[15:8];
    end

    // ---- LEDs ---------------------------------------------------------------
    reg [$clog2(CLK_HZ/2)-1:0] hb_cnt = 0;
    reg hb = 1'b0;
    always @(posedge sysclk) begin
        if (hb_cnt == (CLK_HZ/2)-1) begin hb_cnt <= 0; hb <= ~hb; end
        else hb_cnt <= hb_cnt + 1'b1;
    end
    assign led[0] = hb;
    assign led[1] = cor_enable;
endmodule

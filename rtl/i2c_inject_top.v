`timescale 1ns / 1ps
//
// i2c_inject_top.v — Month 2 integration: host-armed I2C clock-stretch injection.
//
//   host (USB-UART) --> uart_rx --> ctrl_regs --> config registers
//   STM32 (I2C master) <--> i2c_slave <--> timing_distort  (holds SCL low)
//
// The host arms a target byte + stretch length over UART; the STM32 writes an I2C
// transaction; on the target byte the slave stretches SCL abnormally; the STM32
// master stalls / times out and reports it. trig_out pulses while stretching.
//
// I2C is open-drain: i2c_scl / i2c_sda are inout, pulled low by the FPGA only.
// External ~4.7k pull-ups (or the XDC's internal PULLUP) provide the high level.
//
// Register map (write 'W' addr data; read 'R' addr):
//   reg0  control : bit0 distort_enable, bit1 clr (reset stretch counter)
//   reg1  target_byte     (0=addr, 1=first data byte, 2=second, ...)
//   reg2  stretch_len[7:0]
//   reg3  stretch_len[15:8]     (SCL-low hold, in 12 MHz cycles; 1200 ~= 100 us)
//   status 0x80 = byte_index, 0x81 = stretch_count[7:0], 0x82 = stretch_count[15:8]
//
module i2c_inject_top #(
    parameter integer CLK_HZ = 12_000_000,
    parameter integer BAUD   = 115_200,
    parameter [6:0]   I2C_ADDR = 7'h42
) (
    input  wire        sysclk,
    input  wire [1:0]  btn,
    output wire [1:0]  led,
    // host UART (FT2232 bridge)
    output wire        uart_rxd_out,
    input  wire        uart_txd_in,
    // I2C slave (to STM32 master) — open-drain
    inout  wire        i2c_scl,
    inout  wire        i2c_sda,
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

    wire        distort_enable = regs_flat[8*0 + 0];
    wire [7:0]  target_byte    = regs_flat[8*1 +: 8];
    wire [15:0] stretch_len    = {regs_flat[8*3 +: 8], regs_flat[8*2 +: 8]};
    wire        clr            = wr_stb & (wr_addr == 8'd0) & wr_data[1];

    // ---- I2C slave + timing distorter ---------------------------------------
    wire        scl_oe, sda_oe, do_stretch, stretching;
    wire [15:0] dist_len;
    wire [7:0]  byte_index, i2c_rx_data;
    wire        i2c_rx_valid;

    // open-drain bus
    assign i2c_scl = scl_oe ? 1'b0 : 1'bz;
    assign i2c_sda = sda_oe ? 1'b0 : 1'bz;

    i2c_slave #(.ADDR(I2C_ADDR)) u_i2c (
        .clk(sysclk), .rst(rst),
        .scl_i(i2c_scl), .sda_i(i2c_sda),
        .scl_oe(scl_oe), .sda_oe(sda_oe),
        .do_stretch(do_stretch), .stretch_len(dist_len),
        .byte_index(byte_index), .rx_data(i2c_rx_data), .rx_valid(i2c_rx_valid),
        .stretching(stretching));

    timing_distort u_dist (
        .enable(distort_enable),
        .target_byte(target_byte), .stretch_len_in(stretch_len),
        .byte_index(byte_index),
        .do_stretch(do_stretch), .stretch_len_out(dist_len));

    assign trig_out = stretching;

    // ---- stretch counter (rising edges of `stretching`) ---------------------
    reg [15:0] stretch_count = 16'd0;
    reg        str_d = 1'b0;
    always @(posedge sysclk) begin
        if (rst || clr) begin stretch_count <= 16'd0; str_d <= 1'b0; end
        else begin
            str_d <= stretching;
            if (stretching & ~str_d) stretch_count <= stretch_count + 16'd1;
        end
    end

    always @(*) begin
        status_flat = 64'd0;
        status_flat[8*0 +: 8] = byte_index;
        status_flat[8*1 +: 8] = stretch_count[7:0];
        status_flat[8*2 +: 8] = stretch_count[15:8];
    end

    // ---- LEDs ---------------------------------------------------------------
    reg [$clog2(CLK_HZ/2)-1:0] hb_cnt = 0;
    reg hb = 1'b0;
    always @(posedge sysclk) begin
        if (hb_cnt == (CLK_HZ/2)-1) begin hb_cnt <= 0; hb <= ~hb; end
        else hb_cnt <= hb_cnt + 1'b1;
    end
    assign led[0] = hb;
    assign led[1] = distort_enable;
endmodule

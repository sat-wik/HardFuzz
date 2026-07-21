`timescale 1ns / 1ps
//
// spi_inject_top.v — Month 1 integration: host-armed SPI bit-flip injection.
//
//   host (USB-UART) --> uart_rx --> ctrl_regs --> config registers
//   STM32 (SPI master) <--> spi_slave <--> bitflip_inj --> MISO pin
//
// The host arms a target (frame, bit) over UART; the STM32 clocks SPI frames; the
// injector flips the chosen bit of the MISO echo; the STM32 reads back the corrupted
// byte and self-reports. trig_out pulses on every injected bit for a future scope.
//
// Register map (write with 'W' addr data; read with 'R' addr):
//   reg0  control : bit0 inj_enable, bit1 clr_frame (pulse), bit2 line_sel (rsvd)
//   reg1  target_frame[7:0]
//   reg2  target_frame[15:8]
//   reg3  target_bit[2:0]        (0=LSB .. 7=MSB)
//   status 0x80 = frame_idx[7:0], 0x81 = frame_idx[15:8], 0x82 = flip_count
//
module spi_inject_top #(
    parameter integer CLK_HZ = 12_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire        sysclk,
    input  wire [1:0]  btn,
    output wire [1:0]  led,
    // host UART (FT2232 bridge)
    output wire        uart_rxd_out,
    input  wire        uart_txd_in,
    // SPI slave (to STM32 master)
    input  wire        spi_sclk,
    input  wire        spi_cs_n,
    input  wire        spi_mosi,
    output wire        spi_miso,
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

    wire        inj_enable   = regs_flat[8*0 + 0];
    wire [15:0] target_frame = {regs_flat[8*2 +: 8], regs_flat[8*1 +: 8]};
    wire [2:0]  target_bit   = regs_flat[8*3 +: 3];
    // clear the frame counter when reg0 is written with bit1 set
    wire        clr_frame    = wr_stb & (wr_addr == 8'd0) & wr_data[1];

    // ---- SPI slave + injector ----------------------------------------------
    wire        miso_clean, miso_inj, flip_active;
    wire [2:0]  bit_num;
    wire [15:0] frame_idx;
    wire [7:0]  spi_rx_data; wire spi_rx_valid;

    spi_slave u_spi (
        .clk(sysclk), .rst(rst),
        .sclk(spi_sclk), .cs_n(spi_cs_n), .mosi(spi_mosi),
        .miso_bit(miso_clean),
        .rx_data(spi_rx_data), .rx_valid(spi_rx_valid),
        .frame_idx(frame_idx), .bit_num(bit_num),
        .clr_frame(clr_frame));

    bitflip_inj u_inj (
        .enable(inj_enable),
        .target_frame(target_frame), .target_bit(target_bit),
        .frame_idx(frame_idx), .bit_num(bit_num),
        .line_in(miso_clean), .line_out(miso_inj),
        .flip_active(flip_active));

    // drive MISO only while selected (tri-state otherwise)
    assign spi_miso = (spi_cs_n == 1'b0) ? miso_inj : 1'bz;
    assign trig_out = flip_active;

    // ---- injection counter (rising edges of flip_active) --------------------
    reg [7:0] flip_count = 8'h00;
    reg       flip_d     = 1'b0;
    always @(posedge sysclk) begin
        if (rst) begin flip_count <= 8'h00; flip_d <= 1'b0; end
        else begin
            flip_d <= flip_active;
            if (flip_active & ~flip_d) flip_count <= flip_count + 8'd1;
        end
    end

    always @(*) begin
        status_flat = 64'd0;
        status_flat[8*0 +: 8] = frame_idx[7:0];
        status_flat[8*1 +: 8] = frame_idx[15:8];
        status_flat[8*2 +: 8] = flip_count;
    end

    // ---- LEDs: heartbeat + injection-armed ----------------------------------
    reg [$clog2(CLK_HZ/2)-1:0] hb_cnt = 0;
    reg hb = 1'b0;
    always @(posedge sysclk) begin
        if (hb_cnt == (CLK_HZ/2)-1) begin hb_cnt <= 0; hb <= ~hb; end
        else hb_cnt <= hb_cnt + 1'b1;
    end
    assign led[0] = hb;
    assign led[1] = inj_enable;
endmodule

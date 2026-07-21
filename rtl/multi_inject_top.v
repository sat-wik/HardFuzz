`timescale 1ns / 1ps
//
// multi_inject_top.v — combined SPI + I2C injector in one bitstream (Month 4 polish).
//
// One `ctrl_regs` drives both the SPI bit-flip and I2C clock-stretch injectors; reg4
// selects which protocol is live, so you switch protocols by re-arming over UART
// instead of reflashing the FPGA. Only the selected protocol drives its bus; the other
// is held idle (SPI MISO tri-stated, I2C lines released), so both can stay wired at once.
//
// CAN is left out of this build for pin budget (Pmod JA holds SPI's 4 + I2C's 2 + trig);
// use can_inject_top (or a future 3-way top) when a transceiver is available.
//
// Register map (write 'W' addr data; read 'R' addr):
//   reg0  control : bit0 enable, bit1 clr
//   reg1..reg3    : protocol params —
//                     SPI: reg1/2 = frame,  reg3 = bit
//                     I2C: reg1 = byte,     reg2/3 = stretch_len
//   reg4  protocol: 0 = SPI, 1 = I2C
//   status 0x80..0x82 = the active protocol's counters (matches the standalone tops):
//     SPI: frame_idx lo/hi, flip_count     I2C: byte_index, stretch_count lo/hi
//
module multi_inject_top #(
    parameter integer CLK_HZ   = 12_000_000,
    parameter integer BAUD     = 115_200,
    parameter [6:0]   I2C_ADDR = 7'h42
) (
    input  wire        sysclk,
    input  wire [1:0]  btn,
    output wire [1:0]  led,
    // host UART
    output wire        uart_rxd_out,
    input  wire        uart_txd_in,
    // SPI slave (to STM32 master)
    input  wire        spi_sclk,
    input  wire        spi_cs_n,
    input  wire        spi_mosi,
    output wire        spi_miso,
    // I2C slave (open-drain)
    inout  wire        i2c_scl,
    inout  wire        i2c_sda,
    // scope/logic-analyzer trigger
    output wire        trig_out
);
    localparam integer CLKS_PER_BIT = CLK_HZ / BAUD;
    localparam integer NREGS = 8;
    wire rst = btn[0];

    // ---- host UART + control registers --------------------------------------
    wire       rx_valid; wire [7:0] rx_data;
    wire       tx_busy;  wire       tx_start; wire [7:0] tx_data;
    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(sysclk), .rst(rst), .rx(uart_txd_in), .valid(rx_valid), .data(rx_data));
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(sysclk), .rst(rst), .start(tx_start), .data(tx_data),
        .tx(uart_rxd_out), .busy(tx_busy));

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

    wire [1:0]  protocol = regs_flat[8*4 +: 2];      // 0 = SPI, 1 = I2C
    wire        enable   = regs_flat[8*0 + 0];
    wire        clr      = wr_stb & (wr_addr == 8'd0) & wr_data[1];
    wire        sel_spi  = (protocol == 2'd0);
    wire        sel_i2c  = (protocol == 2'd1);

    // ---- SPI injector -------------------------------------------------------
    wire        miso_clean, miso_inj, spi_flip;
    wire [2:0]  spi_bit_num;
    wire [15:0] spi_frame_idx;
    wire [15:0] spi_target_frame = {regs_flat[8*2 +: 8], regs_flat[8*1 +: 8]};
    wire [2:0]  spi_target_bit   = regs_flat[8*3 +: 3];

    spi_slave u_spi (
        .clk(sysclk), .rst(rst),
        .sclk(spi_sclk), .cs_n(spi_cs_n), .mosi(spi_mosi),
        .miso_bit(miso_clean), .rx_data(), .rx_valid(),
        .frame_idx(spi_frame_idx), .bit_num(spi_bit_num),
        .clr_frame(clr & sel_spi));
    bitflip_inj u_bf (
        .enable(enable & sel_spi),
        .target_frame(spi_target_frame), .target_bit(spi_target_bit),
        .frame_idx(spi_frame_idx), .bit_num(spi_bit_num),
        .line_in(miso_clean), .line_out(miso_inj), .flip_active(spi_flip));

    // drive MISO only in SPI mode while selected
    assign spi_miso = (sel_spi && spi_cs_n == 1'b0) ? miso_inj : 1'bz;

    // ---- I2C injector -------------------------------------------------------
    wire        scl_oe, sda_oe, do_stretch, i2c_stretching;
    wire [15:0] dist_len;
    wire [7:0]  i2c_byte_index;
    wire [7:0]  i2c_target_byte  = regs_flat[8*1 +: 8];
    wire [15:0] i2c_stretch_len  = {regs_flat[8*3 +: 8], regs_flat[8*2 +: 8]};

    // drive the open-drain bus only in I2C mode
    assign i2c_scl = (sel_i2c && scl_oe) ? 1'b0 : 1'bz;
    assign i2c_sda = (sel_i2c && sda_oe) ? 1'b0 : 1'bz;

    i2c_slave #(.ADDR(I2C_ADDR)) u_i2c (
        .clk(sysclk), .rst(rst),
        .scl_i(i2c_scl), .sda_i(i2c_sda),
        .scl_oe(scl_oe), .sda_oe(sda_oe),
        .do_stretch(do_stretch), .stretch_len(dist_len),
        .byte_index(i2c_byte_index), .rx_data(), .rx_valid(),
        .stretching(i2c_stretching));
    timing_distort u_td (
        .enable(enable & sel_i2c),
        .target_byte(i2c_target_byte), .stretch_len_in(i2c_stretch_len),
        .byte_index(i2c_byte_index),
        .do_stretch(do_stretch), .stretch_len_out(dist_len));

    assign trig_out = spi_flip | i2c_stretching;

    // ---- counters (per protocol) --------------------------------------------
    reg [7:0]  flip_count = 8'd0;   reg flip_d = 1'b0;
    reg [15:0] stretch_count = 16'd0; reg str_d = 1'b0;
    always @(posedge sysclk) begin
        if (rst || clr) begin
            flip_count <= 8'd0; flip_d <= 1'b0; stretch_count <= 16'd0; str_d <= 1'b0;
        end else begin
            flip_d <= spi_flip;
            if (spi_flip & ~flip_d) flip_count <= flip_count + 8'd1;
            str_d <= i2c_stretching;
            if (i2c_stretching & ~str_d) stretch_count <= stretch_count + 16'd1;
        end
    end

    always @(*) begin
        status_flat = 64'd0;
        if (sel_i2c) begin
            status_flat[8*0 +: 8] = i2c_byte_index;
            status_flat[8*1 +: 8] = stretch_count[7:0];
            status_flat[8*2 +: 8] = stretch_count[15:8];
        end else begin
            status_flat[8*0 +: 8] = spi_frame_idx[7:0];
            status_flat[8*1 +: 8] = spi_frame_idx[15:8];
            status_flat[8*2 +: 8] = flip_count;
        end
    end

    // ---- LEDs: heartbeat + armed/protocol -----------------------------------
    reg [$clog2(CLK_HZ/2)-1:0] hb_cnt = 0;
    reg hb = 1'b0;
    always @(posedge sysclk) begin
        if (hb_cnt == (CLK_HZ/2)-1) begin hb_cnt <= 0; hb <= ~hb; end
        else hb_cnt <= hb_cnt + 1'b1;
    end
    assign led[0] = hb;
    assign led[1] = enable;
endmodule

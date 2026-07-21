`timescale 1ns / 1ps
//
// hardfuzz_top.v — scaffolding bring-up top for the Cmod A7.
//
// Proves two things at once so a partial failure is self-isolating:
//   * clock + toolchain -> led[0] blinks at ~1 Hz from a free-running counter.
//   * host UART link     -> every byte received on the FT2232 bridge is echoed
//                           back, and led[1] toggles on each received byte.
//
// If led[0] blinks but the echo is dead, the toolchain/clock are fine and the
// problem is in the UART logic — not the build.
//
// Clock : 12 MHz onboard oscillator (sysclk).
// Reset : btn[0], active high.
//
module hardfuzz_top #(
    parameter integer CLK_HZ = 12_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire        sysclk,        // 12 MHz
    input  wire [1:0]  btn,           // btn[0] = reset
    output wire [1:0]  led,           // led[0] heartbeat, led[1] rx activity
    output wire        uart_rxd_out,  // FPGA -> host (TX)
    input  wire        uart_txd_in    // host -> FPGA (RX)
);
    localparam integer CLKS_PER_BIT = CLK_HZ / BAUD;   // 104 at 12 MHz / 115200

    wire rst = btn[0];

    // ---- ~1 Hz heartbeat: proves the clock is toggling -----------------------
    localparam integer HALF_SEC = CLK_HZ / 2;
    reg [$clog2(HALF_SEC)-1:0] hb_cnt = 0;
    reg hb = 1'b0;
    always @(posedge sysclk) begin
        if (rst) begin
            hb_cnt <= 0;
            hb     <= 1'b0;
        end else if (hb_cnt == HALF_SEC-1) begin
            hb_cnt <= 0;
            hb     <= ~hb;
        end else begin
            hb_cnt <= hb_cnt + 1'b1;
        end
    end

    // ---- UART echo: proves the host link ------------------------------------
    wire       rx_valid;
    wire [7:0] rx_data;
    wire       tx_busy;
    reg        tx_start = 1'b0;
    reg  [7:0] tx_data  = 8'h00;
    reg        rx_led   = 1'b0;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk   (sysclk),
        .rst   (rst),
        .rx    (uart_txd_in),
        .valid (rx_valid),
        .data  (rx_data)
    );

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk   (sysclk),
        .rst   (rst),
        .start (tx_start),
        .data  (tx_data),
        .tx    (uart_rxd_out),
        .busy  (tx_busy)
    );

    // On each received byte, echo it and toggle the activity LED. At matched baud
    // the transmitter is idle by the time the next byte fully arrives; a byte that
    // lands while tx is still busy is dropped (fine for a bring-up echo).
    always @(posedge sysclk) begin
        if (rst) begin
            tx_start <= 1'b0;
            tx_data  <= 8'h00;
            rx_led   <= 1'b0;
        end else begin
            tx_start <= 1'b0;                     // default: single-cycle pulse
            if (rx_valid && !tx_busy) begin
                tx_data  <= rx_data;
                tx_start <= 1'b1;
                rx_led   <= ~rx_led;
            end
        end
    end

    assign led[0] = hb;
    assign led[1] = rx_led;
endmodule

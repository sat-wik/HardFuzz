`timescale 1ns / 1ps
//
// spi_slave.v — SPI mode-0 slave (CPOL=0, CPHA=0, MSB-first), oversampled.
//
// The FPGA is the SPI *peripheral* on the DUT bus (see the refined plan): the STM32
// drives SCLK/CS/MOSI as master, and this slave both captures the incoming byte and
// shifts a response byte back on MISO. The response is the previously received byte
// (a 1-frame-delayed echo), which makes the master's read-back fully predictable —
// the basis for self-checking bit-flip injection without a logic analyzer.
//
// SPI is oversampled in the `clk` domain (no external clock brought into fabric), so
// SCLK must be well below clk/4. At 12 MHz clk keep SCLK < ~2 MHz; on a fast MMCM
// clock it scales up. This clock-domain independence is also what later lets the
// injector act with fine timing.
//
// Frame model: a "frame" is one byte. `frame_idx` is the byte index within the
// current CS-low transaction — it resets to 0 on each CS assertion (and on
// `clr_frame`), so "frame #5" means the 5th byte after CS goes low. This makes a
// host-armed injection repeatable: arm once, and every transaction injects the same
// frame. `bit_num` is the byte-bit currently on MISO, 7=MSB .. 0=LSB — the injector
// keys off both.
//
module spi_slave (
    input  wire        clk,
    input  wire        rst,
    // SPI pins (from the master)
    input  wire        sclk,
    input  wire        cs_n,
    input  wire        mosi,
    output wire        miso_bit,    // intended MISO bit, pre-injection
    // received-byte stream
    output reg  [7:0]  rx_data,
    output reg         rx_valid,    // 1-cycle strobe when a byte completes
    // frame/bit position for the injector and host status
    output reg  [15:0] frame_idx,   // byte index of the frame in flight
    output wire [2:0]  bit_num,     // byte-bit on MISO now (7=MSB..0=LSB)
    input  wire        clr_frame    // 1-cycle: reset frame_idx to 0
);
    // ---- synchronize the asynchronous SPI inputs ----------------------------
    reg [1:0] sclk_sr = 2'b00, cs_sr = 2'b11, mosi_sr = 2'b00;
    always @(posedge clk) begin
        sclk_sr <= {sclk_sr[0], sclk};
        cs_sr   <= {cs_sr[0],   cs_n};
        mosi_sr <= {mosi_sr[0], mosi};
    end
    reg sclk_d = 1'b0, cs_d = 1'b1;
    always @(posedge clk) begin
        sclk_d <= sclk_sr[1];
        cs_d   <= cs_sr[1];
    end
    wire sclk_rise = ~sclk_d      &  sclk_sr[1];
    wire sclk_fall =  sclk_d      & ~sclk_sr[1];
    wire cs_active = ~cs_sr[1];
    wire cs_assert =  cs_d        & ~cs_sr[1];   // cs_n 1 -> 0

    // ---- shift registers, counters ------------------------------------------
    reg [7:0] rx_shift = 8'h00;
    reg [7:0] tx_byte  = 8'h00;   // byte currently shifting out on MISO
    reg [7:0] resp     = 8'h00;   // response for the next byte (echo of last rx)
    reg [2:0] bit_cnt  = 3'd0;    // rising-edge count within the current byte
    reg [2:0] tx_pos   = 3'd0;    // which MISO bit is presented (0=MSB..7=LSB)
    reg       reload   = 1'b0;    // reload tx_byte at the next falling edge

    assign miso_bit = tx_byte[3'd7 - tx_pos];
    assign bit_num  = 3'd7 - tx_pos;

    always @(posedge clk) begin
        if (rst) begin
            rx_shift <= 8'h00; tx_byte <= 8'h00; resp <= 8'h00;
            bit_cnt  <= 3'd0;  tx_pos  <= 3'd0;  reload <= 1'b0;
            rx_data  <= 8'h00; rx_valid <= 1'b0; frame_idx <= 16'd0;
        end else begin
            rx_valid <= 1'b0;
            if (clr_frame) frame_idx <= 16'd0;

            if (cs_assert) begin
                bit_cnt   <= 3'd0;
                tx_pos    <= 3'd0;
                tx_byte   <= resp;      // present response MSB before first clock
                reload    <= 1'b0;
                frame_idx <= 16'd0;     // frame index = byte # within this transaction
            end

            if (cs_active) begin
                if (sclk_rise) begin
                    rx_shift <= {rx_shift[6:0], mosi_sr[1]};   // sample MOSI, MSB first
                    if (bit_cnt == 3'd7) begin                  // byte complete
                        rx_data   <= {rx_shift[6:0], mosi_sr[1]};
                        rx_valid  <= 1'b1;
                        resp      <= {rx_shift[6:0], mosi_sr[1]}; // echo it next frame
                        frame_idx <= frame_idx + 16'd1;
                        bit_cnt   <= 3'd0;
                        reload    <= 1'b1;
                    end else begin
                        bit_cnt <= bit_cnt + 3'd1;
                    end
                end
                if (sclk_fall) begin
                    if (reload) begin
                        tx_byte <= resp;   // load next byte's response
                        tx_pos  <= 3'd0;
                        reload  <= 1'b0;
                    end else begin
                        tx_pos  <= tx_pos + 3'd1;   // advance to next MISO bit
                    end
                end
            end
        end
    end
endmodule

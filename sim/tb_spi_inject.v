`timescale 1ns / 1ps
//
// tb_spi_inject.v — end-to-end test of host-armed SPI bit-flip injection.
//
// Plays both roles the real setup has: the host (arming the injector over UART) and
// the STM32 (SPI master clocking frames and reading back the echo). Verifies that
// exactly frame 5, bit 3 of the MISO stream is flipped and every other bit is clean —
// the Month 1 exit criterion, checked without any external instrument.
//
module tb_spi_inject;
    localparam integer CLK_HZ = 12_000_000;
    localparam integer BAUD   = 115_200;
    localparam real    CLK_PERIOD_NS = 1.0e9 / CLK_HZ;   // ~83.33 ns
    localparam real    BIT_NS        = 1.0e9 / BAUD;     // ~8681 ns UART bit
    localparam real    SPI_HALF_NS   = 1000.0;           // 500 kHz SPI

    reg        clk = 1'b0;
    reg  [1:0] btn = 2'b00;
    wire [1:0] led;
    wire       fpga_tx;                 // uart_rxd_out
    reg        fpga_rx  = 1'b1;         // uart_txd_in (idle high)
    reg        spi_sclk = 1'b0;
    reg        spi_cs_n = 1'b1;
    reg        spi_mosi = 1'b0;
    wire       spi_miso;
    wire       trig_out;

    pulldown(spi_miso);                 // defined level while MISO is tri-stated

    always #(CLK_PERIOD_NS/2.0) clk = ~clk;

    spi_inject_top #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) dut (
        .sysclk(clk), .btn(btn), .led(led),
        .uart_rxd_out(fpga_tx), .uart_txd_in(fpga_rx),
        .spi_sclk(spi_sclk), .spi_cs_n(spi_cs_n),
        .spi_mosi(spi_mosi), .spi_miso(spi_miso), .trig_out(trig_out));

    integer errors = 0;

    // ---- host UART: send one 8N1 byte ---------------------------------------
    task uart_send(input [7:0] b);
        integer i;
        begin
            fpga_rx = 1'b0; #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin fpga_rx = b[i]; #(BIT_NS); end
            fpga_rx = 1'b1; #(BIT_NS);
        end
    endtask

    // ---- host UART: receive one 8N1 byte ------------------------------------
    task uart_recv(output [7:0] b);
        integer i;
        begin
            @(negedge fpga_tx); #(BIT_NS*1.5);
            for (i = 0; i < 8; i = i + 1) begin b[i] = fpga_tx; #(BIT_NS); end
        end
    endtask

    task reg_write(input [7:0] a, input [7:0] d);
        begin uart_send(8'h57); uart_send(a); uart_send(d); end
    endtask

    // ---- SPI master: mode 0, MSB-first, full-duplex byte --------------------
    task spi_byte(input [7:0] mosi_b, output [7:0] miso_b);
        integer b;
        begin
            for (b = 7; b >= 0; b = b - 1) begin
                spi_mosi = mosi_b[b];
                #(SPI_HALF_NS);
                spi_sclk = 1'b1;
                miso_b[b] = spi_miso;      // master samples MISO on the rising edge
                #(SPI_HALF_NS);
                spi_sclk = 1'b0;
            end
        end
    endtask

    integer   k;
    reg [7:0] miso_got  [0:7];
    reg [7:0] miso_exp  [0:7];
    reg [7:0] rd;

    initial begin
        $dumpfile("tb_spi_inject.vcd");
        $dumpvars(0, tb_spi_inject);

        btn = 2'b01; repeat (20) @(posedge clk); btn = 2'b00;
        repeat (20) @(posedge clk);

        // Arm: flip frame 5, bit 3, on MISO.
        reg_write(8'd1, 8'd5);      // target_frame low
        reg_write(8'd2, 8'd0);      // target_frame high
        reg_write(8'd3, 8'd3);      // target_bit
        reg_write(8'd0, 8'h01);     // enable

        // Expected 1-frame-delayed echo, with frame 5 bit 3 flipped.
        miso_exp[0] = 8'h00;                 // frame0: initial response
        miso_exp[1] = 8'hA0;
        miso_exp[2] = 8'hA1;
        miso_exp[3] = 8'hA2;
        miso_exp[4] = 8'hA3;
        miso_exp[5] = 8'hA4 ^ 8'h08;         // 0xAC  <-- injected
        miso_exp[6] = 8'hA5;
        miso_exp[7] = 8'hA6;

        // Clock 8 frames in one CS-low burst; MOSI = 0xA0..0xA7.
        spi_cs_n = 1'b0;
        #(SPI_HALF_NS*2);
        for (k = 0; k < 8; k = k + 1) spi_byte(8'hA0 + k[7:0], miso_got[k]);
        #(SPI_HALF_NS);
        spi_cs_n = 1'b1;

        for (k = 0; k < 8; k = k + 1) begin
            if (miso_got[k] !== miso_exp[k]) begin
                $display("FAIL: frame %0d MISO = 0x%02X, expected 0x%02X",
                         k, miso_got[k], miso_exp[k]);
                errors = errors + 1;
            end else begin
                $display("PASS: frame %0d MISO = 0x%02X%s",
                         k, miso_got[k], (k==5) ? "  <-- injected" : "");
            end
        end

        // flip_count status (0x82) should read exactly 1.
        fork
            begin uart_send(8'h52); uart_send(8'h82); end
            uart_recv(rd);
        join
        if (rd !== 8'd1) begin
            $display("FAIL: flip_count = %0d, expected 1", rd);
            errors = errors + 1;
        end else $display("PASS: flip_count = %0d", rd);

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TEST(S) FAILED", errors);
        $finish;
    end

    initial begin
        #20_000_000; $display("TIMEOUT"); $finish;
    end
endmodule

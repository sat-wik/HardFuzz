`timescale 1ns / 1ps
//
// tb_multi_inject.v — verify the combined SPI+I2C top: arm+run each protocol through
// the one design, switching with reg4, and confirm each injects correctly while the
// other bus stays idle.
//
module tb_multi_inject;
    localparam integer CLK_HZ = 12_000_000;
    localparam integer BAUD   = 115_200;
    localparam real    CLK_PERIOD_NS = 1.0e9 / CLK_HZ;
    localparam real    BIT_NS        = 1.0e9 / BAUD;
    localparam real    SPI_HALF_NS   = 1000.0;              // 500 kHz SPI
    localparam integer TQ            = CLK_HZ / 250_000;    // I2C 250 kHz
    localparam real    CAN_BIT_NS    = 0;                   // (unused)
    localparam real    SCL_HALF      = 2000.0;
    localparam real    STRETCH_THRESH = 5000.0;
    localparam integer STRETCH_CYC   = 240;

    reg        clk = 1'b0;
    reg  [1:0] btn = 2'b00;
    wire [1:0] led;
    wire       fpga_tx;
    reg        fpga_rx = 1'b1;
    wire       trig_out;

    // SPI bus
    reg  spi_sclk = 1'b0, spi_cs_n = 1'b1, spi_mosi = 1'b0;
    wire spi_miso; pulldown(spi_miso);

    // I2C open-drain bus
    wire i2c_scl, i2c_sda; pullup(i2c_scl); pullup(i2c_sda);
    reg  m_scl_oe = 1'b0, m_sda_oe = 1'b0;
    assign i2c_scl = m_scl_oe ? 1'b0 : 1'bz;
    assign i2c_sda = m_sda_oe ? 1'b0 : 1'bz;

    always #(CLK_PERIOD_NS/2.0) clk = ~clk;

    multi_inject_top #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .I2C_ADDR(7'h42)) dut (
        .sysclk(clk), .btn(btn), .led(led),
        .uart_rxd_out(fpga_tx), .uart_txd_in(fpga_rx),
        .spi_sclk(spi_sclk), .spi_cs_n(spi_cs_n), .spi_mosi(spi_mosi), .spi_miso(spi_miso),
        .i2c_scl(i2c_scl), .i2c_sda(i2c_sda), .trig_out(trig_out));

    integer errors = 0;

    // ---- host UART + arming --------------------------------------------------
    task uart_send(input [7:0] b);
        integer i; begin
            fpga_rx = 1'b0; #(BIT_NS);
            for (i=0;i<8;i=i+1) begin fpga_rx=b[i]; #(BIT_NS); end
            fpga_rx = 1'b1; #(BIT_NS);
        end
    endtask
    task reg_write(input [7:0] a, input [7:0] d);
        begin uart_send(8'h57); uart_send(a); uart_send(d); end
    endtask

    // ---- SPI master ----------------------------------------------------------
    task spi_byte(input [7:0] mosi_b, output [7:0] miso_b);
        integer b; begin
            for (b=7;b>=0;b=b-1) begin
                spi_mosi = mosi_b[b]; #(SPI_HALF_NS);
                spi_sclk = 1'b1; miso_b[b] = spi_miso; #(SPI_HALF_NS);
                spi_sclk = 1'b0;
            end
        end
    endtask

    // ---- I2C master (clock-stretch aware) ------------------------------------
    integer big_count; real last_stretch_ns; integer cur_byte, stretch_at_byte;
    task i2c_start; begin
        m_sda_oe=1'b0; m_scl_oe=1'b0; #(SCL_HALF);
        m_sda_oe=1'b1; #(SCL_HALF); m_scl_oe=1'b1; #(SCL_HALF);
    end endtask
    task i2c_bit(input b);
        real t0; begin
            m_sda_oe = b ? 1'b0 : 1'b1; #(SCL_HALF);
            m_scl_oe = 1'b0; t0 = $realtime; wait (i2c_scl === 1'b1);
            if (($realtime - t0) > STRETCH_THRESH) begin
                big_count=big_count+1; last_stretch_ns=$realtime-t0; stretch_at_byte=cur_byte; end
            #(SCL_HALF); m_scl_oe = 1'b1;
        end
    endtask
    task i2c_byte(input [7:0] d, output ack);
        integer i; begin
            for (i=7;i>=0;i=i-1) i2c_bit(d[i]);
            m_sda_oe=1'b0; #(SCL_HALF); m_scl_oe=1'b0; wait (i2c_scl===1'b1); #(SCL_HALF);
            ack = i2c_sda; m_scl_oe = 1'b1;
        end
    endtask
    task i2c_stop; begin
        m_sda_oe=1'b1; #(SCL_HALF); m_scl_oe=1'b0; wait (i2c_scl===1'b1); #(SCL_HALF);
        m_sda_oe=1'b0; #(SCL_HALF);
    end endtask

    integer k; reg [7:0] mg [0:7]; reg a0,a1,a2,a3;

    initial begin
        $dumpfile("tb_multi_inject.vcd");
        $dumpvars(0, tb_multi_inject);
        btn=2'b01; repeat(20) @(posedge clk); btn=2'b00; repeat(20) @(posedge clk);

        // ===== SPI: protocol 0, flip frame 5 bit 3 =====
        reg_write(8'd4, 8'd0);       // protocol = SPI
        reg_write(8'd1, 8'd5);       // frame lo
        reg_write(8'd2, 8'd0);       // frame hi
        reg_write(8'd3, 8'd3);       // bit
        reg_write(8'd0, 8'h01);      // enable
        spi_cs_n = 1'b0; #(SPI_HALF_NS*2);
        for (k=0;k<8;k=k+1) spi_byte(8'hA0 + k[7:0], mg[k]);
        #(SPI_HALF_NS); spi_cs_n = 1'b1;
        if (mg[5] !== (8'hA4 ^ 8'h08)) begin
            $display("FAIL: SPI frame 5 = 0x%02X, expected 0xAC", mg[5]); errors=errors+1;
        end else $display("PASS: SPI frame 5 flipped to 0x%02X", mg[5]);
        if (mg[4] !== 8'hA3 || mg[6] !== 8'hA5) begin
            $display("FAIL: SPI neighbors corrupted (f4=0x%02X f6=0x%02X)", mg[4], mg[6]); errors=errors+1;
        end else $display("PASS: SPI neighbor frames clean");

        // ===== I2C: protocol 1, stretch byte 2 =====
        big_count=0; last_stretch_ns=0; stretch_at_byte=-1;
        reg_write(8'd4, 8'd1);           // protocol = I2C
        reg_write(8'd1, 8'd2);           // target byte
        reg_write(8'd2, STRETCH_CYC[7:0]);
        reg_write(8'd3, 8'd0);
        reg_write(8'd0, 8'h01);          // enable (also disarms SPI)
        cur_byte=0; i2c_start;
        cur_byte=0; i2c_byte(8'h84, a0);
        cur_byte=1; i2c_byte(8'hAA, a1);
        cur_byte=2; i2c_byte(8'hBB, a2);
        cur_byte=3; i2c_byte(8'hCC, a3);
        i2c_stop;
        if (a0||a1||a2||a3) begin $display("FAIL: I2C byte NACKed"); errors=errors+1; end
        else $display("PASS: I2C all bytes ACKed");
        if (big_count !== 1 || stretch_at_byte !== 3) begin
            $display("FAIL: I2C stretch count=%0d at byte %0d (want 1 @ 3)", big_count, stretch_at_byte);
            errors=errors+1;
        end else $display("PASS: I2C stretch injected once, on byte after target (%.0f ns)", last_stretch_ns);

        if (errors==0) $display("ALL TESTS PASSED");
        else           $display("%0d TEST(S) FAILED", errors);
        $finish;
    end

    initial begin #20_000_000; $display("TIMEOUT"); $finish; end
endmodule

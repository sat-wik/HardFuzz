`timescale 1ns / 1ps
//
// tb_i2c_inject.v — end-to-end test of host-armed I2C clock-stretch injection.
//
// Plays host (arms the distorter over UART) and STM32 (an I2C master BFM that writes
// address + data bytes). Verifies the FPGA slave ACKs the transaction, and that on the
// targeted byte it stretches SCL by the programmed duration — and only there. The
// master is clock-stretch-aware: after releasing SCL it waits for SCL to actually go
// high, and measures how long that took, which is how it "feels" the injected fault.
//
module tb_i2c_inject;
    localparam integer CLK_HZ = 12_000_000;
    localparam integer BAUD   = 115_200;
    localparam real    CLK_PERIOD_NS = 1.0e9 / CLK_HZ;   // ~83.33 ns
    localparam real    BIT_NS        = 1.0e9 / BAUD;     // UART bit
    localparam real    SCL_HALF      = 2000.0;           // 250 kHz I2C
    localparam real    STRETCH_THRESH = 5000.0;          // >5 us wait = injected stretch
    localparam integer STRETCH_CYC   = 240;              // ~20 us at 12 MHz

    reg        clk = 1'b0;
    reg  [1:0] btn = 2'b00;
    wire [1:0] led;
    wire       fpga_tx;
    reg        fpga_rx = 1'b1;
    wire       trig_out;

    // open-drain I2C bus with pull-ups
    wire scl, sda;
    pullup(scl);
    pullup(sda);
    reg m_scl_oe = 1'b0, m_sda_oe = 1'b0;
    assign scl = m_scl_oe ? 1'b0 : 1'bz;
    assign sda = m_sda_oe ? 1'b0 : 1'bz;

    always #(CLK_PERIOD_NS/2.0) clk = ~clk;

    i2c_inject_top #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .I2C_ADDR(7'h42)) dut (
        .sysclk(clk), .btn(btn), .led(led),
        .uart_rxd_out(fpga_tx), .uart_txd_in(fpga_rx),
        .i2c_scl(scl), .i2c_sda(sda), .trig_out(trig_out));

    integer errors = 0;

    // measurement state
    integer big_count = 0;
    real    last_stretch_ns = 0.0;
    integer stretch_at_byte = -1;
    integer cur_byte = 0;

    // ---- host UART ----------------------------------------------------------
    task uart_send(input [7:0] b);
        integer i;
        begin
            fpga_rx = 1'b0; #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin fpga_rx = b[i]; #(BIT_NS); end
            fpga_rx = 1'b1; #(BIT_NS);
        end
    endtask
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

    // ---- I2C master BFM (clock-stretch aware) -------------------------------
    task i2c_start;
        begin
            m_sda_oe = 1'b0; m_scl_oe = 1'b0; #(SCL_HALF);   // idle high
            m_sda_oe = 1'b1; #(SCL_HALF);                    // START: SDA low, SCL high
            m_scl_oe = 1'b1; #(SCL_HALF);                    // SCL low
        end
    endtask

    task i2c_bit(input b);
        real t0;
        begin
            m_sda_oe = b ? 1'b0 : 1'b1;   // release for 1, pull low for 0
            #(SCL_HALF);
            m_scl_oe = 1'b0;              // release SCL -> should rise
            t0 = $realtime;
            wait (scl === 1'b1);          // clock-stretch aware wait
            if (($realtime - t0) > STRETCH_THRESH) begin
                big_count       = big_count + 1;
                last_stretch_ns = $realtime - t0;
                stretch_at_byte = cur_byte;
            end
            #(SCL_HALF);
            m_scl_oe = 1'b1;             // SCL low
        end
    endtask

    task i2c_byte(input [7:0] d, output ack);
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) i2c_bit(d[i]);
            // ACK slot: release SDA, clock once, sample
            m_sda_oe = 1'b0; #(SCL_HALF);
            m_scl_oe = 1'b0; wait (scl === 1'b1); #(SCL_HALF);
            ack = sda;                   // 0 = slave ACKed
            m_scl_oe = 1'b1;
        end
    endtask

    task i2c_stop;
        begin
            m_sda_oe = 1'b1; #(SCL_HALF);          // SDA low, SCL low
            m_scl_oe = 1'b0; wait (scl === 1'b1); #(SCL_HALF);  // SCL high
            m_sda_oe = 1'b0; #(SCL_HALF);          // STOP: SDA rises while SCL high
        end
    endtask

    reg a0, a1, a2, a3;
    reg [7:0] rd;

    initial begin
        $dumpfile("tb_i2c_inject.vcd");
        $dumpvars(0, tb_i2c_inject);

        btn = 2'b01; repeat (20) @(posedge clk); btn = 2'b00;
        repeat (20) @(posedge clk);

        // Arm: stretch byte 2 (2nd data byte) for STRETCH_CYC cycles.
        reg_write(8'd1, 8'd2);                    // target_byte
        reg_write(8'd2, STRETCH_CYC[7:0]);        // stretch_len low
        reg_write(8'd3, 8'd0);                    // stretch_len high
        reg_write(8'd0, 8'h01);                   // enable

        // I2C write: address 0x42 (write) + 3 data bytes.
        cur_byte = 0; i2c_start;
        cur_byte = 0; i2c_byte(8'h84, a0);        // (0x42<<1)|0
        cur_byte = 1; i2c_byte(8'hAA, a1);
        cur_byte = 2; i2c_byte(8'hBB, a2);        // target byte
        cur_byte = 3; i2c_byte(8'hCC, a3);        // stretch is felt here
        i2c_stop;

        if (a0 || a1 || a2 || a3) begin
            $display("FAIL: a byte was NACKed (a0..a3 = %b %b %b %b)", a0,a1,a2,a3);
            errors = errors + 1;
        end else $display("PASS: all 4 bytes ACKed by slave");

        if (big_count !== 1) begin
            $display("FAIL: %0d stretches detected, expected exactly 1", big_count);
            errors = errors + 1;
        end else $display("PASS: exactly one clock stretch injected");

        if (stretch_at_byte !== 3) begin
            $display("FAIL: stretch appeared before byte %0d, expected 3 (after target 2)",
                     stretch_at_byte);
            errors = errors + 1;
        end else $display("PASS: stretch is on the byte after target (byte 3)");

        if (last_stretch_ns < 15000.0 || last_stretch_ns > 25000.0) begin
            $display("FAIL: stretch = %.0f ns, expected ~20000 ns", last_stretch_ns);
            errors = errors + 1;
        end else $display("PASS: stretch duration = %.0f ns (~20 us)", last_stretch_ns);

        // stretch_count status (0x81) should read 1.
        fork
            begin uart_send(8'h52); uart_send(8'h81); end
            uart_recv(rd);
        join
        if (rd !== 8'd1) begin
            $display("FAIL: stretch_count = %0d, expected 1", rd);
            errors = errors + 1;
        end else $display("PASS: stretch_count = %0d", rd);

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TEST(S) FAILED", errors);
        $finish;
    end

    initial begin
        #20_000_000; $display("TIMEOUT"); $finish;
    end
endmodule

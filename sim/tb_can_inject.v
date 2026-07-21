`timescale 1ns / 1ps
//
// tb_can_inject.v — host-armed CAN frame corruption.
//
// A CAN transmitter BFM drives the (wired-AND) bus; the FPGA corruptor forces the bus
// dominant on the armed bit. The BFM samples the real bus each bit and we check that
// the targeted bit(s) came back dominant even though the transmitter sent recessive,
// and that untargeted recessive bits were left alone. Two runs: a single-bit corruption
// (bad-CRC style) and a 6-bit force (bit-stuffing violation).
//
module tb_can_inject;
    localparam integer CLK_HZ      = 12_000_000;
    localparam integer BAUD        = 115_200;
    localparam integer CAN_BITRATE = 500_000;
    localparam real    CLK_PERIOD_NS = 1.0e9 / CLK_HZ;      // ~83.33 ns
    localparam real    BIT_NS        = 1.0e9 / BAUD;
    localparam integer TQ           = CLK_HZ / CAN_BITRATE; // 24
    localparam real    CAN_BIT_NS    = TQ * CLK_PERIOD_NS;  // ~2000 ns
    localparam integer NBITS         = 45;

    reg        clk = 1'b0;
    reg  [1:0] btn = 2'b00;
    wire [1:0] led;
    wire       fpga_tx;
    reg        fpga_rx = 1'b1;
    wire       trig_out;

    // wired-AND CAN bus (dominant 0 wins): bus = bfm_tx AND fpga_txd
    reg  bfm_tx = 1'b1;          // recessive idle
    wire fpga_txd;
    wire can_bus = bfm_tx & fpga_txd;

    always #(CLK_PERIOD_NS/2.0) clk = ~clk;

    can_inject_top #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .CAN_BITRATE(CAN_BITRATE)) dut (
        .sysclk(clk), .btn(btn), .led(led),
        .uart_rxd_out(fpga_tx), .uart_txd_in(fpga_rx),
        .can_rxd(can_bus), .can_txd(fpga_txd), .trig_out(trig_out));

    integer errors = 0;
    reg     bus_sample [0:NBITS-1];

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

    // ---- CAN transmitter BFM ------------------------------------------------
    // frame bit pattern: dominant every 3rd bit so recessive runs stay < the idle
    // threshold (keeps the corruptor "in frame"); SOF (bit 0) is dominant.
    function automatic bit_val(input integer i);
        bit_val = (i % 3 == 0) ? 1'b0 : 1'b1;
    endfunction

    task idle_bits(input integer n);
        integer i;
        begin bfm_tx = 1'b1; for (i=0;i<n;i=i+1) #(CAN_BIT_NS); end
    endtask

    // send one frame, sampling the real bus at each bit's midpoint
    task send_frame;
        integer i;
        begin
            for (i = 0; i < NBITS; i = i + 1) begin
                bfm_tx = bit_val(i);
                #(CAN_BIT_NS/2.0);
                bus_sample[i] = can_bus;     // reflects any FPGA corruption
                #(CAN_BIT_NS/2.0);
            end
            bfm_tx = 1'b1;                    // release to recessive (EOF/idle)
        end
    endtask

    task expect_bit(input integer i, input exp, input [127:0] label);
        begin
            if (bus_sample[i] !== exp) begin
                $display("FAIL: %0s bit %0d = %b, expected %b", label, i, bus_sample[i], exp);
                errors = errors + 1;
            end else $display("PASS: %0s bit %0d = %b", label, i, bus_sample[i]);
        end
    endtask

    reg [7:0] rd;
    integer i;

    initial begin
        $dumpfile("tb_can_inject.vcd");
        $dumpvars(0, tb_can_inject);

        btn = 2'b01; repeat (20) @(posedge clk); btn = 2'b00;
        repeat (20) @(posedge clk);

        // ---- run 1: single-bit corruption at bit 20 ----
        reg_write(8'd1, 8'd20);      // target_bit low
        reg_write(8'd2, 8'd0);       // target_bit high
        reg_write(8'd3, 8'd1);       // width = 1
        reg_write(8'd0, 8'h01);      // enable

        idle_bits(20);               // let the corruptor go idle
        send_frame;

        // bit 20 was recessive in the pattern (20%3=2 -> 1) but must come back dominant
        expect_bit(20, 1'b0, "corrupt");
        // bit 25 (25%3=1 -> recessive) is untargeted: must be left recessive
        expect_bit(25, 1'b1, "clean  ");
        // bit 3 (3%3=0) is naturally dominant
        expect_bit(3,  1'b0, "natural");

        // ---- run 2: 6-bit force at bit 20 (bit-stuffing violation) ----
        reg_write(8'd3, 8'd6);       // width = 6
        idle_bits(20);
        send_frame;
        for (i = 20; i < 26; i = i + 1) begin
            if (bus_sample[i] !== 1'b0) begin
                $display("FAIL: stuff-force bit %0d = %b, expected 0", i, bus_sample[i]);
                errors = errors + 1;
            end
        end
        if (bus_sample[26] === 1'b0 && bit_val(26)) begin
            $display("FAIL: bit 26 forced but should be outside the width-6 window");
            errors = errors + 1;
        end
        $display("PASS: bits 20..25 all forced dominant (stuff-error width)");

        // corrupt_count status (0x80) should read 2 after two corrupted frames
        fork
            begin uart_send(8'h52); uart_send(8'h80); end
            uart_recv(rd);
        join
        if (rd !== 8'd2) begin
            $display("FAIL: corrupt_count = %0d, expected 2", rd);
            errors = errors + 1;
        end else $display("PASS: corrupt_count = %0d", rd);

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TEST(S) FAILED", errors);
        $finish;
    end

    initial begin
        #20_000_000; $display("TIMEOUT"); $finish;
    end
endmodule

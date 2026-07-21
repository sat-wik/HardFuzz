`timescale 1ns / 1ps
//
// tb_pulse_meter.v — verifies the scope-free timing primitive.
//
// Runs the meter on a 100 MHz clock (1 count = 10 ns) and feeds it pulses of a
// known width so you can confirm the counts before trusting them on hardware.
//
module tb_pulse_meter;
    reg         clk = 1'b0, rst = 1'b1, sig = 1'b0;
    wire [31:0] width_cnt, period_cnt;
    wire        sample;
    integer     errors = 0;

    always #5 clk = ~clk;    // 100 MHz -> 10 ns/cycle

    pulse_meter #(.WIDTH(32)) dut (
        .clk(clk), .rst(rst), .sig(sig),
        .width_cnt(width_cnt), .period_cnt(period_cnt), .sample(sample)
    );

    task make_pulse(input integer high_cycles, input integer low_cycles);
        integer i;
        begin
            sig = 1'b1;
            for (i = 0; i < high_cycles; i = i + 1) @(posedge clk);
            sig = 1'b0;
            for (i = 0; i < low_cycles;  i = i + 1) @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("tb_pulse_meter.vcd");
        $dumpvars(0, tb_pulse_meter);

        repeat (5) @(posedge clk); rst = 1'b0;
        repeat (5) @(posedge clk);

        // `sample` is a 1-cycle strobe that fires mid-pulse; the results it
        // latches persist, so we read the latched registers directly. Keep the two
        // pulses back-to-back so rise-to-rise is exactly 10 + 20 = 30 cycles.
        make_pulse(10, 20);          // width 10 cycles = 100 ns
        if (width_cnt !== 32'd10) begin
            $display("FAIL: width_cnt=%0d expected 10", width_cnt);
            errors = errors + 1;
        end else $display("PASS: width_cnt=%0d (100 ns @100MHz)", width_cnt);

        make_pulse(10, 20);          // establishes rise-to-rise = 30 cycles
        if (period_cnt !== 32'd30) begin
            $display("FAIL: period_cnt=%0d expected 30", period_cnt);
            errors = errors + 1;
        end else $display("PASS: period_cnt=%0d (300 ns @100MHz)", period_cnt);

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TEST(S) FAILED", errors);
        $finish;
    end

    initial begin
        #1_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule

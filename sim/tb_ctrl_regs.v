`timescale 1ns / 1ps
//
// tb_ctrl_regs.v — unit test for the UART register FSM at its parallel interface.
// Drives byte strobes directly (no serial timing) to check writes, reads, and status.
//
module tb_ctrl_regs;
    localparam NREGS = 8;

    reg              clk = 1'b0, rst = 1'b1;
    reg              rx_valid = 1'b0;
    reg  [7:0]       rx_data  = 8'h00;
    reg              tx_busy  = 1'b0;
    wire             tx_start;
    wire [7:0]       tx_data;
    wire [8*NREGS-1:0] regs_flat;
    wire             wr_stb;
    wire [7:0]       wr_addr, wr_data;
    reg  [8*8-1:0]   status_flat = 64'd0;
    integer          errors = 0;

    always #5 clk = ~clk;   // 100 MHz (unit test; rate irrelevant)

    ctrl_regs #(.NREGS(NREGS)) dut (
        .clk(clk), .rst(rst),
        .rx_valid(rx_valid), .rx_data(rx_data),
        .tx_busy(tx_busy), .tx_start(tx_start), .tx_data(tx_data),
        .regs_flat(regs_flat),
        .wr_stb(wr_stb), .wr_addr(wr_addr), .wr_data(wr_data),
        .status_flat(status_flat));

    // one byte into the FSM. Drive 1 ns after the edge so the DUT samples a clean
    // one-cycle rx_valid pulse instead of racing our deassert on the same edge.
    task ubyte(input [7:0] b);
        begin
            @(posedge clk); #1; rx_data = b; rx_valid = 1'b1;
            @(posedge clk); #1; rx_valid = 1'b0; rx_data = 8'h00;
            @(posedge clk); #1;
        end
    endtask

    task expect_reg(input [7:0] idx, input [7:0] val);
        begin
            if (regs_flat[8*idx +: 8] !== val) begin
                $display("FAIL: reg%0d = 0x%02X, expected 0x%02X",
                         idx, regs_flat[8*idx +: 8], val);
                errors = errors + 1;
            end else $display("PASS: reg%0d = 0x%02X", idx, val);
        end
    endtask

    reg [7:0] got;
    // issue a read and capture the byte the FSM sends back
    task do_read(input [7:0] addr, input [7:0] exp);
        begin
            fork
                begin ubyte(8'h52); ubyte(addr); end   // 'R', addr
                begin @(posedge tx_start); got = tx_data; end
            join
            if (got !== exp) begin
                $display("FAIL: read 0x%02X = 0x%02X, expected 0x%02X", addr, got, exp);
                errors = errors + 1;
            end else $display("PASS: read 0x%02X = 0x%02X", addr, got);
        end
    endtask

    initial begin
        $dumpfile("tb_ctrl_regs.vcd");
        $dumpvars(0, tb_ctrl_regs);

        repeat (4) @(posedge clk); rst = 1'b0;
        repeat (4) @(posedge clk);

        // writes: 'W' addr data
        ubyte(8'h57); ubyte(8'd1); ubyte(8'h05);   // reg1 = 5
        ubyte(8'h57); ubyte(8'd3); ubyte(8'h03);   // reg3 = 3
        ubyte(8'h57); ubyte(8'd0); ubyte(8'h01);   // reg0 = 1
        expect_reg(8'd1, 8'h05);
        expect_reg(8'd3, 8'h03);
        expect_reg(8'd0, 8'h01);

        // reads of registers
        do_read(8'd1, 8'h05);
        do_read(8'd0, 8'h01);

        // status read: 0x80 + k
        status_flat[8*0 +: 8] = 8'h42;   // status byte 0
        status_flat[8*2 +: 8] = 8'h99;   // status byte 2
        do_read(8'h80, 8'h42);
        do_read(8'h82, 8'h99);

        // a bad opcode in idle must be ignored (no wedge)
        ubyte(8'hFF);
        ubyte(8'h57); ubyte(8'd2); ubyte(8'hAB);   // reg2 = 0xAB still works
        expect_reg(8'd2, 8'hAB);

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TEST(S) FAILED", errors);
        $finish;
    end

    initial begin
        #100000; $display("TIMEOUT"); $finish;
    end
endmodule

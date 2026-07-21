`timescale 1ns / 1ps
//
// tb_uart_echo.v — self-checking sim for hardfuzz_top's UART echo.
//
// Drives bytes into the FPGA RX line at 115200 baud and checks that the same
// bytes come back on the TX line. This is your primary verifier until hardware
// instruments arrive: if this passes, the UART logic is correct by construction.
//
module tb_uart_echo;
    localparam integer CLK_HZ        = 12_000_000;
    localparam integer BAUD          = 115_200;
    localparam real    CLK_PERIOD_NS = 1.0e9 / CLK_HZ;   // ~83.33 ns
    localparam real    BIT_NS        = 1.0e9 / BAUD;     // ~8680 ns

    reg        clk = 1'b0;
    reg  [1:0] btn = 2'b00;
    wire [1:0] led;
    wire       fpga_tx;             // uart_rxd_out
    reg        fpga_rx = 1'b1;      // uart_txd_in (idle high)

    always #(CLK_PERIOD_NS/2.0) clk = ~clk;

    hardfuzz_top #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) dut (
        .sysclk       (clk),
        .btn          (btn),
        .led          (led),
        .uart_rxd_out (fpga_tx),
        .uart_txd_in  (fpga_rx)
    );

    // Drive one 8N1 byte, LSB first.
    task send_byte(input [7:0] b);
        integer i;
        begin
            fpga_rx = 1'b0;                 // start bit
            #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin
                fpga_rx = b[i];
                #(BIT_NS);
            end
            fpga_rx = 1'b1;                 // stop bit
            #(BIT_NS);
        end
    endtask

    // Capture one 8N1 byte from the FPGA, sampling at each bit center.
    task recv_byte(output [7:0] b);
        integer i;
        begin
            @(negedge fpga_tx);             // start bit
            #(BIT_NS*1.5);                  // step to center of bit 0
            for (i = 0; i < 8; i = i + 1) begin
                b[i] = fpga_tx;
                #(BIT_NS);
            end
        end
    endtask

    reg [7:0] got;
    integer   errors = 0;

    task check(input [7:0] sent);
        begin
            fork
                send_byte(sent);
                recv_byte(got);
            join
            if (got !== sent) begin
                $display("FAIL: sent 0x%02X, echoed 0x%02X", sent, got);
                errors = errors + 1;
            end else begin
                $display("PASS: echoed 0x%02X", got);
            end
        end
    endtask

    initial begin
        $dumpfile("tb_uart_echo.vcd");
        $dumpvars(0, tb_uart_echo);

        btn = 2'b01; repeat (10) @(posedge clk); btn = 2'b00;  // reset pulse
        repeat (10) @(posedge clk);

        check(8'h5A);
        check(8'hC3);
        check(8'h00);
        check(8'hFF);

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TEST(S) FAILED", errors);
        $finish;
    end

    initial begin
        #10_000_000;                        // 10 ms safety timeout
        $display("TIMEOUT — no completion");
        $finish;
    end
endmodule

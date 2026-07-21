`timescale 1ns / 1ps
//
// frame_corrupt.v — CAN frame corruptor (monitor + force-dominant injector).
//
// CAN is a wired-AND bus: a dominant bit (0) always overrides a recessive bit (1).
// So a node can corrupt any frame simply by driving the bus dominant at the right
// moment — no need to be the transmitter. This core watches the bus (RXD from the
// transceiver), tracks the bit position from Start-Of-Frame, and on a host-chosen bit
// forces the bus dominant for `width` bits. Depending on where you aim it, that one
// primitive produces all three faults from the plan:
//   * a corrupted data/CRC bit  -> receivers see a CRC mismatch  (bad CRC)
//   * >=6 forced dominant bits   -> violates the 5-bit stuffing rule (stuff error)
//   * a dominant bit in the EOF  -> EOF must be recessive          (form error)
// Any of these makes real receivers flag an error and emit an error frame.
//
// SIM-ONLY so far: on hardware it needs a CAN transceiver (SN65HVD230) on TXD/RXD.
// Bit timing is a simple SOF-synced divider (CLK_HZ/CAN_BITRATE clocks per bit);
// good enough for injection since we control both clocks.
//
module frame_corrupt #(
    parameter integer CLK_HZ      = 12_000_000,
    parameter integer CAN_BITRATE = 500_000
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        can_rx,           // bus via transceiver: 1=recessive, 0=dominant
    output wire        force_dominant,   // 1 => drive TXD dominant (0) to corrupt
    // config
    input  wire        enable,
    input  wire [15:0] target_bit,       // bit index from SOF (SOF = bit 0)
    input  wire [7:0]  width,            // consecutive bits to force dominant
    input  wire        clr,
    // status
    output reg  [15:0] frame_count,
    output reg  [15:0] corrupt_count
);
    localparam integer TQ      = CLK_HZ / CAN_BITRATE;   // clocks per CAN bit
    localparam integer IDLE_TH = 11 * TQ;                // recessive clocks => bus idle

    // synchronize RX + edge detect
    reg rx_d0 = 1'b1, rx_s = 1'b1, rx_p = 1'b1;
    always @(posedge clk) begin rx_d0 <= can_rx; rx_s <= rx_d0; rx_p <= rx_s; end
    wire fall = rx_p & ~rx_s;                             // recessive -> dominant

    reg                          in_frame  = 1'b0;
    reg [$clog2(TQ)-1:0]         phase     = 0;
    reg [15:0]                   bit_index = 16'd0;
    reg [$clog2(IDLE_TH+1)-1:0]  rec_run   = 0;
    wire idle = (rec_run >= IDLE_TH[$clog2(IDLE_TH+1)-1:0]);

    // force the bus dominant while the tracked bit is in the armed window
    assign force_dominant = enable & in_frame &
                            (bit_index >= target_bit) &
                            (bit_index <  target_bit + {8'd0, width});

    reg fd_d = 1'b0;
    always @(posedge clk) begin
        if (rst) begin
            in_frame<=1'b0; phase<=0; bit_index<=16'd0; rec_run<=0;
            frame_count<=16'd0; corrupt_count<=16'd0; fd_d<=1'b0;
        end else begin
            if (clr) begin frame_count<=16'd0; corrupt_count<=16'd0; end

            // recessive-run counter for idle detection (raw clocks)
            if (rx_s) begin if (rec_run < IDLE_TH[$clog2(IDLE_TH+1)-1:0]) rec_run <= rec_run + 1'b1; end
            else          rec_run <= 0;

            if (!in_frame) begin
                if (fall && idle) begin                  // Start Of Frame
                    in_frame    <= 1'b1;
                    phase       <= 0;
                    bit_index   <= 16'd0;
                    frame_count <= frame_count + 16'd1;
                end
            end else begin
                if (idle) begin
                    in_frame <= 1'b0;                    // frame ended (bus idle)
                end else if (phase == TQ-1) begin
                    phase     <= 0;
                    bit_index <= bit_index + 16'd1;
                end else begin
                    phase <= phase + 1'b1;
                end
            end

            fd_d <= force_dominant;
            if (force_dominant & ~fd_d) corrupt_count <= corrupt_count + 16'd1;
        end
    end
endmodule

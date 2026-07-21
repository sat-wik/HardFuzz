`timescale 1ns / 1ps
//
// i2c_slave.v — minimal I2C slave (write transactions), oversampled, with a
// clock-stretch injection hook.
//
// The FPGA is the I2C peripheral on the DUT bus (mirrors the SPI approach): the STM32
// drives SCL/SDA as master and writes bytes to this slave. The slave ACKs its address
// and each data byte. On a byte the injector targets, it holds SCL low for a
// configurable number of cycles — an abnormal clock stretch — which stalls the master
// and (if long enough) trips its timeout. That is the Month 2 fault.
//
// I2C is open-drain: this core never drives a line high. `scl_oe`/`sda_oe` mean
// "pull low"; releasing (oe=0) lets the bus pull-up bring the line high. The top wires
// them as  pin = oe ? 1'b0 : 1'bz.  Bus is oversampled in the `clk` domain, so keep
// SCL well below clk/4 (100 kHz vs 12 MHz here is very safe).
//
// Byte model: byte_index 0 = address byte, 1 = first data byte, 2 = second, ...
// It holds the current byte's index during reception and increments at that byte's
// ACK, so the injector keys off it the same way the SPI frame counter worked.
//
module i2c_slave #(
    parameter [6:0] ADDR = 7'h42
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        scl_i,        // SCL as seen on the bus
    input  wire        sda_i,        // SDA as seen on the bus
    output reg         scl_oe,       // 1 = pull SCL low (clock stretch)
    output reg         sda_oe,       // 1 = pull SDA low (ACK / data 0)
    // injection control (from timing_distort)
    input  wire        do_stretch,   // stretch the byte currently completing
    input  wire [15:0] stretch_len,  // cycles to hold SCL low
    // status
    output reg  [7:0]  byte_index,   // 0 = addr, 1 = first data byte, ...
    output reg  [7:0]  rx_data,      // last data byte received
    output reg         rx_valid,     // 1-cycle strobe on a received data byte
    output reg         stretching    // high while a stretch is being injected
);
    // ---- synchronize the open-drain bus lines --------------------------------
    reg [1:0] scl_sr = 2'b11, sda_sr = 2'b11;
    always @(posedge clk) begin
        scl_sr <= {scl_sr[0], scl_i};
        sda_sr <= {sda_sr[0], sda_i};
    end
    wire scl = scl_sr[1];
    wire sda = sda_sr[1];
    reg scl_d = 1'b1, sda_d = 1'b1;
    always @(posedge clk) begin scl_d <= scl; sda_d <= sda; end
    wire scl_rise = ~scl_d &  scl;
    wire scl_fall =  scl_d & ~scl;
    wire start_cond = scl &  sda_d & ~sda;   // SDA falls while SCL high
    wire stop_cond  = scl & ~sda_d &  sda;   // SDA rises while SCL high

    localparam [2:0] S_IDLE=3'd0, S_RECV=3'd1, S_ACK=3'd2, S_STRETCH=3'd3;
    reg [2:0]  state = S_IDLE;
    reg [3:0]  bitc  = 4'd0;
    reg [7:0]  shift = 8'd0;
    reg        active = 1'b0;         // address matched -> we own the transaction
    reg [15:0] stretch_cnt = 16'd0;

    always @(posedge clk) begin
        if (rst) begin
            state<=S_IDLE; bitc<=0; shift<=0; active<=0;
            scl_oe<=0; sda_oe<=0; byte_index<=0; rx_data<=0; rx_valid<=0;
            stretch_cnt<=0; stretching<=0;
        end else begin
            rx_valid <= 1'b0;

            if (start_cond) begin
                // (re)start: begin a fresh transaction, release lines
                state<=S_RECV; bitc<=0; shift<=0; active<=0;
                sda_oe<=0; scl_oe<=0; byte_index<=0;
                stretch_cnt<=0; stretching<=0;
            end else if (stop_cond) begin
                state<=S_IDLE; sda_oe<=0; scl_oe<=0; active<=0;
                stretch_cnt<=0; stretching<=0;
            end else begin
                case (state)
                    S_IDLE: begin sda_oe<=0; scl_oe<=0; end

                    S_RECV: begin
                        if (scl_rise) begin
                            shift <= {shift[6:0], sda};   // MSB first
                            bitc  <= bitc + 4'd1;
                        end
                        if (scl_fall && bitc==4'd8) begin  // byte complete
                            bitc <= 4'd0;
                            if (byte_index==8'd0) begin
                                // address byte: ACK only on match + write bit
                                if (shift[7:1]==ADDR && shift[0]==1'b0) begin
                                    sda_oe <= 1'b1;   // ACK
                                    active <= 1'b1;
                                end else begin
                                    sda_oe <= 1'b0;   // NACK (ignore)
                                    active <= 1'b0;
                                end
                            end else begin
                                rx_data  <= shift;
                                rx_valid <= 1'b1;
                                sda_oe   <= 1'b1;      // ACK data
                            end
                            state <= S_ACK;
                        end
                    end

                    S_ACK: begin
                        // sda_oe holds the ACK low through the 9th SCL high
                        if (scl_fall) begin            // 9th falling edge
                            sda_oe <= 1'b0;            // release SDA
                            byte_index <= byte_index + 8'd1;
                            if (!active) begin
                                state <= S_IDLE;       // address didn't match
                            end else if (do_stretch) begin
                                stretch_cnt <= stretch_len;
                                scl_oe     <= 1'b1;    // begin holding SCL low
                                stretching <= 1'b1;
                                state      <= S_STRETCH;
                            end else begin
                                state <= S_RECV;       // next byte
                            end
                        end
                    end

                    S_STRETCH: begin
                        if (stretch_cnt != 16'd0) begin
                            stretch_cnt <= stretch_cnt - 16'd1;
                        end else begin
                            scl_oe     <= 1'b0;        // release SCL, master resumes
                            stretching <= 1'b0;
                            state      <= S_RECV;
                        end
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end
endmodule

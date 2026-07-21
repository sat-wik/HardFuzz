#!/usr/bin/env python3
"""Arm / inspect the HardFuzz FPGA injector over the Cmod A7 USB-UART bridge.

The FPGA register interface (ctrl_regs) speaks a tiny protocol at 115200 8N1:
    write:  b'W' addr data
    read:   b'R' addr        -> one byte back
This talks to the FT2232 serial port that appears when you plug the Cmod into USB.

Examples:
    python3 arm.py --port /dev/tty.usbserial-210328AABBCC arm --frame 5 --bit 3
    python3 arm.py --port /dev/tty.usbserial-210328AABBCC status
    python3 arm.py --port /dev/tty.usbserial-210328AABBCC disarm

Register map (see rtl/spi_inject_top.v):
    reg0 control: bit0 enable, bit1 clr_frame(pulse), bit2 line_sel(rsvd)
    reg1 target_frame[7:0]   reg2 target_frame[15:8]   reg3 target_bit(0..7)
    read 0x80 frame_idx[7:0]  0x81 frame_idx[15:8]  0x82 flip_count
"""
import argparse, sys, time

try:
    import serial  # pyserial:  pip install pyserial
except ImportError:
    sys.exit("pyserial not found — install with:  pip install pyserial")


def reg_write(ser, addr, data):
    ser.write(bytes((0x57, addr & 0xFF, data & 0xFF)))
    ser.flush()
    time.sleep(0.005)


def reg_read(ser, addr):
    ser.reset_input_buffer()
    ser.write(bytes((0x52, addr & 0xFF)))
    ser.flush()
    b = ser.read(1)
    if len(b) != 1:
        sys.exit(f"no response reading addr {addr:#04x} (check port / baud / wiring)")
    return b[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", required=True, help="Cmod A7 serial port")
    ap.add_argument("--baud", type=int, default=115200)
    sub = ap.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("arm", help="SPI: arm a MISO bit-flip at (frame, bit)")
    a.add_argument("--frame", type=int, required=True)
    a.add_argument("--bit", type=int, required=True, choices=range(8))

    z = sub.add_parser("i2c", help="I2C: arm a clock stretch at (byte, stretch cycles)")
    z.add_argument("--byte", type=int, required=True, help="target byte (0=address, 1=first data, ...)")
    z.add_argument("--stretch", type=int, required=True, help="SCL-low hold in 12 MHz cycles (1200 ~= 100 us)")

    c = sub.add_parser("can", help="CAN: force the bus dominant at (bit, width)")
    c.add_argument("--bit", type=int, required=True, help="target bit index from SOF (SOF = bit 0)")
    c.add_argument("--width", type=int, default=1, help="consecutive bits to force dominant (>=6 = stuff error)")

    sub.add_parser("disarm", help="disable injection")
    sub.add_parser("clr", help="clear the frame counter (keeps enable state)")
    sub.add_parser("status", help="read frame_idx and flip_count")

    args = ap.parse_args()
    with serial.Serial(args.port, args.baud, timeout=0.5) as ser:
        if args.cmd == "arm":
            reg_write(ser, 4, 0)               # protocol = SPI (combined top; ignored by standalone)
            reg_write(ser, 3, args.bit)
            reg_write(ser, 1, args.frame & 0xFF)
            reg_write(ser, 2, (args.frame >> 8) & 0xFF)
            reg_write(ser, 0, 0x01)            # enable
            print(f"armed: flip frame {args.frame}, bit {args.bit} (MISO)")
        elif args.cmd == "i2c":
            reg_write(ser, 4, 1)               # protocol = I2C
            reg_write(ser, 1, args.byte & 0xFF)          # target_byte
            reg_write(ser, 2, args.stretch & 0xFF)       # stretch_len[7:0]
            reg_write(ser, 3, (args.stretch >> 8) & 0xFF)  # stretch_len[15:8]
            reg_write(ser, 0, 0x01)            # enable
            print(f"armed: stretch byte {args.byte} for {args.stretch} cycles (~{args.stretch/12:.0f} us)")
        elif args.cmd == "can":
            reg_write(ser, 4, 2)               # protocol = CAN
            reg_write(ser, 1, args.bit & 0xFF)           # target_bit[7:0]
            reg_write(ser, 2, (args.bit >> 8) & 0xFF)    # target_bit[15:8]
            reg_write(ser, 3, args.width & 0xFF)         # width
            reg_write(ser, 0, 0x01)            # enable
            print(f"armed: force bus dominant at bit {args.bit} for {args.width} bit(s)")
        elif args.cmd == "disarm":
            reg_write(ser, 0, 0x00)
            print("injection disabled")
        elif args.cmd == "clr":
            en = reg_read(ser, 0) & 0x01
            reg_write(ser, 0, en | 0x02)       # pulse clr_frame, keep enable
            print("frame counter cleared")
        elif args.cmd == "status":
            lo, hi = reg_read(ser, 0x80), reg_read(ser, 0x81)
            flips = reg_read(ser, 0x82)
            print(f"frame_idx = {(hi << 8) | lo}    flip_count = {flips}")


if __name__ == "__main__":
    main()

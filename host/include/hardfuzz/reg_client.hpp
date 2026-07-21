// hardfuzz/reg_client.hpp — arm/disarm the FPGA injectors over ctrl_regs.
#pragma once
#include "transport.hpp"
#include "fault.hpp"

namespace hardfuzz {

// Talks the ctrl_regs W/R protocol; arm() writes the right registers for each
// injector top (matching host/arm.py exactly).
class RegClient {
    Transport& t_;
public:
    explicit RegClient(Transport& t) : t_(t) {}

    void    write(uint8_t addr, uint8_t data) { t_.send({0x57, addr, data}); }
    uint8_t read(uint8_t addr) {
        t_.send({0x52, addr});
        uint8_t b = 0; t_.recv(&b, 1); return b;
    }
    void disarm() { write(0, 0x00); }

    void arm(const Fault& f) {
        switch (f.proto) {
            case Protocol::Spi:  // reg3=bit, reg1/2=frame, reg0=enable
                write(3, (uint8_t)(f.b & 0xFF));
                write(1, (uint8_t)(f.a & 0xFF));
                write(2, (uint8_t)((f.a >> 8) & 0xFF));
                write(0, 0x01);
                break;
            case Protocol::I2c:  // reg1=byte, reg2/3=stretch, reg0=enable
                write(1, (uint8_t)(f.a & 0xFF));
                write(2, (uint8_t)(f.b & 0xFF));
                write(3, (uint8_t)((f.b >> 8) & 0xFF));
                write(0, 0x01);
                break;
            case Protocol::Can:  // reg1/2=bit, reg3=width, reg0=enable
                write(1, (uint8_t)(f.a & 0xFF));
                write(2, (uint8_t)((f.a >> 8) & 0xFF));
                write(3, (uint8_t)(f.b & 0xFF));
                write(0, 0x01);
                break;
        }
    }

    // read one of the status bytes (0x80..0x87)
    uint8_t status(uint8_t idx) { return read(0x80 + (idx & 0x7)); }
};

}  // namespace hardfuzz

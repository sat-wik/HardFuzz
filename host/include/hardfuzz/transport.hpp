// hardfuzz/transport.hpp — byte transport to the FPGA + a mock for offline testing.
#pragma once
#include <cstdint>
#include <cstddef>
#include <deque>
#include <initializer_list>
#include <string>
#include <vector>

namespace hardfuzz {

// Abstract byte pipe to the Cmod's USB-UART (the ctrl_regs interface).
struct Transport {
    virtual void   send(const uint8_t* p, std::size_t n) = 0;
    virtual std::size_t recv(uint8_t* p, std::size_t n) = 0;   // up to n bytes; 0 = timeout
    virtual ~Transport() = default;
    void send(std::initializer_list<uint8_t> b) {
        std::vector<uint8_t> v(b); send(v.data(), v.size());
    }
};

// Emulates ctrl_regs (8 registers + status page at 0x80) so the whole campaign layer
// can be built and tested with no board. Speaks the same W/R wire protocol as the RTL.
class MockTransport : public Transport {
    uint8_t              regs_[8] = {0};
    std::deque<uint8_t>  out_;      // bytes queued for the host to read back
    std::vector<uint8_t> in_;       // partial incoming command
public:
    uint8_t status[8] = {0};        // status bytes returned for reads at 0x80..0x87
    const uint8_t* regs() const { return regs_; }

    void send(const uint8_t* p, std::size_t n) override {
        for (std::size_t i = 0; i < n; ++i) { in_.push_back(p[i]); process(); }
    }
    std::size_t recv(uint8_t* p, std::size_t n) override {
        std::size_t k = 0;
        while (k < n && !out_.empty()) { p[k++] = out_.front(); out_.pop_front(); }
        return k;
    }
private:
    void process() {
        if (in_.empty()) return;
        uint8_t cmd = in_[0];
        if (cmd == 0x57) {                       // 'W' addr data
            if (in_.size() >= 3) {
                uint8_t a = in_[1], d = in_[2];
                if (a < 8) regs_[a] = d;
                in_.erase(in_.begin(), in_.begin() + 3);
            }
        } else if (cmd == 0x52) {                // 'R' addr
            if (in_.size() >= 2) {
                uint8_t a = in_[1];
                uint8_t v = (a >= 0x80) ? status[a & 0x7] : (a < 8 ? regs_[a] : 0);
                out_.push_back(v);
                in_.erase(in_.begin(), in_.begin() + 2);
            }
        } else {
            in_.erase(in_.begin());              // resync on junk
        }
    }
};

}  // namespace hardfuzz

// SerialTransport (POSIX) is only needed for real hardware; keep it out of the core
// so the library stays dependency-free on platforms without termios.
#if defined(HARDFUZZ_ENABLE_SERIAL)
#include <fcntl.h>
#include <termios.h>
#include <unistd.h>
#include <stdexcept>
namespace hardfuzz {
class SerialTransport : public Transport {
    int fd_ = -1;
public:
    explicit SerialTransport(const std::string& dev, int /*baud*/ = 115200) {
        fd_ = ::open(dev.c_str(), O_RDWR | O_NOCTTY | O_NONBLOCK);
        if (fd_ < 0) throw std::runtime_error("open " + dev);
        termios tio{};
        tcgetattr(fd_, &tio);
        cfmakeraw(&tio);
        cfsetispeed(&tio, B115200);
        cfsetospeed(&tio, B115200);
        tio.c_cc[VMIN] = 0; tio.c_cc[VTIME] = 5;   // 0.5 s read timeout
        tcsetattr(fd_, TCSANOW, &tio);
        int fl = fcntl(fd_, F_GETFL, 0); fcntl(fd_, F_SETFL, fl & ~O_NONBLOCK);
    }
    ~SerialTransport() override { if (fd_ >= 0) ::close(fd_); }
    void send(const uint8_t* p, std::size_t n) override {
        (void)::write(fd_, p, n);
        tcdrain(fd_);                 // block until the bytes are actually transmitted
    }
    std::size_t recv(uint8_t* p, std::size_t n) override {
        ssize_t k = ::read(fd_, p, n); return k > 0 ? (std::size_t)k : 0;
    }
};
}  // namespace hardfuzz
#endif

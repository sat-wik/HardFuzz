// hardfuzz/dut_serial.hpp — drive the STM32 DUT over serial: send 'R', read RESULT.
#pragma once
#include "campaign.hpp"
#include "transport.hpp"
#include <string>

namespace hardfuzz {

// Parse a firmware "RESULT <0|1> <detail>" line into a DutResult. Tolerant of the
// human-readable table the firmware prints before it — the caller passes just the
// RESULT line (or the whole buffer; we locate the marker).
inline DutResult parse_result(const std::string& text) {
    auto p = text.find("RESULT ");
    if (p == std::string::npos) return {false, "(no RESULT line)"};
    p += 7;
    DutResult r;
    r.fault_observed = (p < text.size() && text[p] == '1');
    auto sp = text.find(' ', p);
    if (sp != std::string::npos) {
        auto eol = text.find_first_of("\r\n", sp + 1);
        r.detail = text.substr(sp + 1, eol == std::string::npos ? std::string::npos : eol - (sp + 1));
    }
    return r;
}

// The protocol byte the combined firmware uses to pick which transaction to run.
// Standalone firmwares ignore it (they only react to 'R'), so it's always safe to send.
inline char proto_cmd(Protocol p) {
    switch (p) { case Protocol::Spi: return 'S'; case Protocol::I2c: return 'I';
                 case Protocol::Can: return 'C'; }
    return 'R';
}

// Runs one DUT transaction by sending {protocol, 'R'} and reading back until a RESULT
// line arrives (or a bounded number of empty reads = timeout). Works over any Transport,
// so it can be exercised with a fake transport in tests and a real serial one on hardware.
class SerialDutRunner : public DutRunner {
    Transport& t_;
    int        max_polls_;
public:
    explicit SerialDutRunner(Transport& t, int max_polls = 400) : t_(t), max_polls_(max_polls) {}

    DutResult run(const Fault& f) override {
        t_.send({(uint8_t)proto_cmd(f.proto), (uint8_t)'R'});   // select protocol + run
        std::string buf;
        uint8_t chunk[128];
        for (int i = 0; i < max_polls_; ++i) {
            std::size_t n = t_.recv(chunk, sizeof chunk);
            if (n) buf.append(reinterpret_cast<char*>(chunk), n);
            // stop once we have a full RESULT line
            auto r = buf.find("RESULT ");
            if (r != std::string::npos && buf.find_first_of("\r\n", r) != std::string::npos)
                return parse_result(buf);
            if (n == 0 && !buf.empty() && buf.find("RESULT ") != std::string::npos)
                return parse_result(buf);
        }
        if (buf.find("RESULT ") != std::string::npos) return parse_result(buf);
        return {false, "(no RESULT / DUT timeout)"};
    }
};

}  // namespace hardfuzz

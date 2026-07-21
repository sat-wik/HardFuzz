// hardfuzz/fault.hpp — the fault scenario model and coverage key.
#pragma once
#include <string>
#include <tuple>

namespace hardfuzz {

enum class Protocol { Spi, I2c, Can };

inline const char* to_string(Protocol p) {
    switch (p) {
        case Protocol::Spi: return "spi";
        case Protocol::I2c: return "i2c";
        case Protocol::Can: return "can";
    }
    return "?";
}
inline bool protocol_from(const std::string& s, Protocol& out) {
    if (s == "spi") { out = Protocol::Spi; return true; }
    if (s == "i2c") { out = Protocol::I2c; return true; }
    if (s == "can") { out = Protocol::Can; return true; }
    return false;
}

// One fault scenario. `a`/`b` are the two injection parameters, meaning per protocol:
//   SPI: a = frame,  b = bit          I2C: a = byte, b = stretch_cycles
//   CAN: a = bit,    b = width
struct Fault {
    std::string id;                    // scenario id / test id
    Protocol    proto = Protocol::Spi;
    int         a = 0;
    int         b = 0;
    std::string expect = "detected";   // "detected" => DUT must catch it; "tolerated" => ride through
    std::string requirement;           // IEC 61508 / ISO 26262 traceability tag

    // human-readable "(a, b)" role names for reports
    std::pair<const char*, const char*> param_names() const {
        switch (proto) {
            case Protocol::Spi: return {"frame", "bit"};
            case Protocol::I2c: return {"byte", "stretch_cycles"};
            case Protocol::Can: return {"bit", "width"};
        }
        return {"a", "b"};
    }
};

// Coverage tuple — (protocol, address/frame/byte/bit, bit-position/width/stretch).
// This is the plan's (protocol, address, opcode, bit-position) space, projected onto
// the two parameters each injector actually takes.
struct CovKey {
    Protocol proto; int a; int b;
    bool operator<(const CovKey& o) const {
        return std::tie(proto, a, b) < std::tie(o.proto, o.a, o.b);
    }
    bool operator==(const CovKey& o) const {
        return proto == o.proto && a == o.a && b == o.b;
    }
};
inline CovKey key_of(const Fault& f) { return CovKey{f.proto, f.a, f.b}; }

}  // namespace hardfuzz

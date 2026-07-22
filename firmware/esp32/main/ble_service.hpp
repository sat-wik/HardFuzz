// ble_service.hpp — the HardFuzz GATT service (see docs/HardFuzz_v2_Standalone.md §5).
// The app-layer (main.cpp) wires callbacks for Control/Campaign writes; the server
// pushes Status/Result notifications back to the phone.
#pragma once
#include <cstdint>
#include <functional>
#include <string>
#include "hardfuzz/campaign.hpp"      // hardfuzz::ScenarioResult

namespace hf {

struct BleCallbacks {
    std::function<void()>                   on_start;      // Control: START
    std::function<void()>                   on_stop;       // Control: STOP
    std::function<void(const std::string&)> on_campaign;   // full campaign JSON received
    std::function<void(const uint8_t*, std::size_t)> on_control_arm;  // Control: manual arm
};

class BleServer {
public:
    void init(const BleCallbacks& cb);   // bring up NimBLE + register the GATT service

    // notifications up to the app (no-ops until a client subscribes)
    void notify_status(uint8_t state, uint16_t done, uint16_t total, const char* id);
    void notify_result(const hardfuzz::ScenarioResult& r);

    void set_info(const std::string& info);   // Device Info characteristic value
};

}  // namespace hf

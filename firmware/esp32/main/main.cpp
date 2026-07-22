// main.cpp — HardFuzz v2 ESP32-S3 controller.
//
// Wires the REUSED campaign engine (host/include/hardfuzz/*.hpp) to two UARTs and BLE:
//   FPGA UART  --RegClient.arm()-->        the ctrl_regs interface
//   DUT  UART  --SerialDutRunner.run()-->   the target under test
//   BLE        --BleServer-->               the phone app
// The only new code is EspUartTransport (hardware glue) + the BLE service; the fault
// model, coverage-guided scheduling, arming, and pass/fail evaluation are unchanged.
#include <algorithm>
#include <vector>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "hardfuzz/fault.hpp"
#include "hardfuzz/coverage.hpp"
#include "hardfuzz/campaign.hpp"
#include "hardfuzz/reg_client.hpp"
#include "hardfuzz/dut_serial.hpp"     // SerialDutRunner (reused verbatim over our UART)
#include "hardfuzz/json.hpp"           // json_parse + campaign_from_json

#include "hf_config.hpp"
#include "esp_uart_transport.hpp"
#include "ble_service.hpp"

using namespace hardfuzz;

namespace {
// engine, built once in app_main and held for the campaign task
RegClient*       g_reg     = nullptr;
SerialDutRunner* g_dutrun  = nullptr;
CoverageTracker  g_cov;
hf::BleServer    g_ble;
FaultCampaign    g_campaign;                 // current campaign (pushed over BLE)
volatile bool    g_running = false;

// Live campaign loop — same steps as hardfuzz::CampaignRunner::run(), but it streams each
// result over BLE as it completes (arm -> settle -> drive DUT -> evaluate -> record).
void campaign_task(void*) {
    Scheduler sched;
    std::vector<std::size_t> pending;
    for (std::size_t i = 0; i < g_campaign.faults.size(); ++i) pending.push_back(i);
    const uint16_t total = g_campaign.faults.size();
    uint16_t done = 0;

    while (!pending.empty() && g_running) {
        std::size_t pi = sched.next(g_campaign.faults, pending, g_cov);   // coverage-guided
        const Fault& f = g_campaign.faults[pi];

        g_reg->arm(f);                               // arm the FPGA over the control UART
        vTaskDelay(pdMS_TO_TICKS(hf::ARM_SETTLE_MS)); // let it settle

        ScenarioResult sr;
        sr.fault            = f;
        sr.coverage_at_run  = g_cov.count(f);
        sr.dut              = g_dutrun->run(f);      // {proto,'R'} -> DUT, parse RESULT
        sr.pass             = evaluate(f, sr.dut);   // detected/tolerated verdict
        g_cov.mark(f);

        g_ble.notify_result(sr);                     // stream to the app
        g_ble.notify_status(hf::ST_RUNNING, ++done, total, f.id.c_str());
        pending.erase(std::remove(pending.begin(), pending.end(), pi), pending.end());
    }
    g_ble.notify_status(hf::ST_DONE, done, total, "");
    g_running = false;
    vTaskDelete(nullptr);
}
}  // namespace

extern "C" void app_main() {
    // two UART transports — the whole hardware dependency of the engine
    static hf::EspUartTransport fpga(hf::FPGA_UART, hf::FPGA_TX, hf::FPGA_RX, hf::FPGA_BAUD);
    static hf::EspUartTransport dut (hf::DUT_UART,  hf::DUT_TX,  hf::DUT_RX,  hf::DUT_BAUD);
    static RegClient       reg(fpga);
    static SerialDutRunner dutrun(dut);
    g_reg = &reg; g_dutrun = &dutrun;

    hf::BleCallbacks cb;
    cb.on_campaign = [](const std::string& js) {
        g_campaign = campaign_from_json(json_parse(js));   // reuse the host JSON parser
    };
    cb.on_start = []() {
        if (!g_running && !g_campaign.faults.empty()) {
            g_running = true;
            xTaskCreate(campaign_task, "campaign", 8192, nullptr, 5, nullptr);
        }
    };
    cb.on_stop = []() { g_running = false; };
    cb.on_control_arm = [](const uint8_t* p, std::size_t n) {
        // manual single-fault arm: {proto, a_lo, a_hi, b_lo, b_hi} -> RegClient.arm()
        if (n < 5) return;
        Fault f;
        f.proto = static_cast<Protocol>(p[0]);
        f.a = p[1] | (p[2] << 8);
        f.b = p[3] | (p[4] << 8);
        g_reg->arm(f);
    };

    g_ble.set_info("HardFuzz v2  fw 0.1  proto:spi,i2c,can");
    g_ble.init(cb);
}

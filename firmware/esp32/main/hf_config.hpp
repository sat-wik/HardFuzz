// hf_config.hpp — board pin map + BLE UUIDs for the HardFuzz v2 ESP32-S3 controller.
// Pin numbers match gen/esp32_sheet.py (ESP32-S3-WROOM-1 IO assignments).
#pragma once
#include "driver/uart.h"

namespace hf {

// ---- UART to the FPGA ctrl_regs (schematic nets HOST_TXD / HOST_RXD) ----
constexpr uart_port_t FPGA_UART = UART_NUM_1;
constexpr int  FPGA_TX   = 17;    // ESP IO17 -> HOST_TXD -> FPGA uart_rx
constexpr int  FPGA_RX   = 18;    // ESP IO18 <- HOST_RXD <- FPGA uart_tx
constexpr int  FPGA_BAUD = 115200;

// ---- UART to the DUT (schematic nets DUT_TXD / DUT_RXD, header J7) ----
constexpr uart_port_t DUT_UART = UART_NUM_2;
constexpr int  DUT_TX   = 4;      // ESP IO4 -> DUT_TXD
constexpr int  DUT_RX   = 5;      // ESP IO5 <- DUT_RXD
constexpr int  DUT_BAUD = 115200;

constexpr int  STAT_LED = 2;      // ESP IO2 -> BLE/activity LED

constexpr int  ARM_SETTLE_MS = 40;   // let the FPGA arm before running the DUT

// ---- BLE: one custom service, five characteristics (see docs/HardFuzz_v2_Standalone.md §5).
// 128-bit UUIDs under a HardFuzz base. Replace with a registered base for production.
// Base: 48ARDFZ-xxxx-...  (bytes little-endian for NimBLE).
#define HF_UUID128(b2, b3) \
    BLE_UUID128_INIT(0x66, 0x75, 0x7a, 0x7a, 0x64, 0x72, 0x61, 0x68, \
                     0x00, 0x00, (b3), (b2), 0x00, 0x00, 0x00, 0x00)
// service 0x0001, chars 0x0010..0x0014
#define HF_SVC_UUID      HF_UUID128(0x00, 0x01)
#define HF_CHR_INFO      HF_UUID128(0x00, 0x10)
#define HF_CHR_CAMPAIGN  HF_UUID128(0x00, 0x11)
#define HF_CHR_CONTROL   HF_UUID128(0x00, 0x12)
#define HF_CHR_STATUS    HF_UUID128(0x00, 0x13)
#define HF_CHR_RESULT    HF_UUID128(0x00, 0x14)

// Control opcodes (first byte of a Control write)
enum : uint8_t { CTL_START = 0x01, CTL_STOP = 0x02, CTL_SELECT = 0x03, CTL_ARM = 0x10 };
// Status states
enum : uint8_t { ST_IDLE = 0, ST_RUNNING = 1, ST_DONE = 2 };

}  // namespace hf

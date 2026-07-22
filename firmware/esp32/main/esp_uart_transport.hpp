// esp_uart_transport.hpp — the ONE piece of hardware glue for the port.
//
// hardfuzz::Transport over an ESP-IDF UART. Used twice: once for the FPGA ctrl_regs
// (consumed by RegClient), once for the DUT (consumed by the existing SerialDutRunner).
// Everything else in the campaign engine is reused verbatim from host/include/hardfuzz/.
#pragma once
#include <cstdint>
#include <cstddef>
#include "driver/uart.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "hardfuzz/transport.hpp"     // hardfuzz::Transport (abstract byte pipe)

namespace hf {

class EspUartTransport : public hardfuzz::Transport {
    uart_port_t port_;
public:
    EspUartTransport(uart_port_t port, int tx, int rx, int baud) : port_(port) {
        uart_config_t c{};
        c.baud_rate  = baud;
        c.data_bits  = UART_DATA_8_BITS;
        c.parity     = UART_PARITY_DISABLE;
        c.stop_bits  = UART_STOP_BITS_1;
        c.flow_ctrl  = UART_HW_FLOWCTRL_DISABLE;
        c.source_clk = UART_SCLK_DEFAULT;
        uart_driver_install(port_, 1024, 1024, 0, nullptr, 0);
        uart_param_config(port_, &c);
        uart_set_pin(port_, tx, rx, UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE);
    }

    // Transport interface — the exact signatures the engine calls.
    void send(const uint8_t* p, std::size_t n) override {
        uart_write_bytes(port_, reinterpret_cast<const char*>(p), n);
    }
    std::size_t recv(uint8_t* p, std::size_t n) override {
        int r = uart_read_bytes(port_, p, n, pdMS_TO_TICKS(20));  // 20 ms window; 0 = timeout
        return r > 0 ? static_cast<std::size_t>(r) : 0;
    }

    using hardfuzz::Transport::send;   // keep the {..} initializer-list helper
};

}  // namespace hf

## HardFuzz — Cmod A7 constraints (subset of the Digilent master XDC)
## Board: Digilent Cmod A7  (XC7A35T-1CPG236  or  XC7A15T-1CPG236)

## 12 MHz system clock
set_property -dict { PACKAGE_PIN L17 IOSTANDARD LVCMOS33 } [get_ports { sysclk }];
create_clock -add -name sys_clk_pin -period 83.33 -waveform {0 41.66} [get_ports { sysclk }];

## User LEDs
set_property -dict { PACKAGE_PIN A17 IOSTANDARD LVCMOS33 } [get_ports { led[0] }];
set_property -dict { PACKAGE_PIN C16 IOSTANDARD LVCMOS33 } [get_ports { led[1] }];

## Buttons  (btn[0] is used as an active-high reset)
set_property -dict { PACKAGE_PIN A18 IOSTANDARD LVCMOS33 } [get_ports { btn[0] }];
set_property -dict { PACKAGE_PIN B18 IOSTANDARD LVCMOS33 } [get_ports { btn[1] }];

## USB-UART bridge (FT2232 second channel — this is your host link)
##   uart_rxd_out : FPGA -> host   (FPGA transmits)
##   uart_txd_in  : host -> FPGA   (FPGA receives)
set_property -dict { PACKAGE_PIN J18 IOSTANDARD LVCMOS33 } [get_ports { uart_rxd_out }];
set_property -dict { PACKAGE_PIN J17 IOSTANDARD LVCMOS33 } [get_ports { uart_txd_in }];

## ------------------------------------------------------------------------
## Pmod JA — DUT bus (SPI to the STM32 master) + a scope/logic-analyzer trigger.
## Used by spi_inject_top. Wire the STM32F446 to Pmod JA with jumpers:
##   JA1 spi_sclk   JA2 spi_mosi   JA3 spi_miso   JA4 spi_cs_n   JA9 trig_out
## On NUCLEO-F446RE (SPI1): SCLK=PA5, MISO=PA6, MOSI=PA7, NSS=PA4 (or a GPIO CS).
## Note MISO direction: the FPGA is the SPI slave, so FPGA spi_miso -> STM32 MISO(PA6).
## trig_out pulses on every injected bit — the one pin to probe once you have a scope.
##
## I2C pins (JA7/JA8) stay commented until the Month 2 timing-distortion core.
## ------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN G17 IOSTANDARD LVCMOS33 } [get_ports { spi_sclk }];
set_property -dict { PACKAGE_PIN G19 IOSTANDARD LVCMOS33 } [get_ports { spi_mosi }];
set_property -dict { PACKAGE_PIN N18 IOSTANDARD LVCMOS33 } [get_ports { spi_miso }];
set_property -dict { PACKAGE_PIN L18 IOSTANDARD LVCMOS33 } [get_ports { spi_cs_n }];
set_property -dict { PACKAGE_PIN J19 IOSTANDARD LVCMOS33 } [get_ports { trig_out }];
## I2C (open-drain) for i2c_inject_top on Pmod JA7/JA8. PULLUP enables the FPGA's weak
## internal pull-up; for reliable I2C add external ~4.7k pull-ups to 3.3V as well.
## NUCLEO-F446RE I2C1: SCL=PB8 (D15), SDA=PB9 (D14). Wire PB8->JA7, PB9->JA8, + GND.
set_property -dict { PACKAGE_PIN H17 IOSTANDARD LVCMOS33 PULLUP TRUE } [get_ports { i2c_scl }];
set_property -dict { PACKAGE_PIN H19 IOSTANDARD LVCMOS33 PULLUP TRUE } [get_ports { i2c_sda }];

## CAN (single-ended logic to an SN65HVD230) for can_inject_top. Shares the JA7/JA8
## physical pins with I2C above — only one bitstream is loaded at a time, so per-build
## warnings about the other top's ports are expected. Transceiver: R -> can_rxd, D -> can_txd.
set_property -dict { PACKAGE_PIN H17 IOSTANDARD LVCMOS33 } [get_ports { can_rxd }];
set_property -dict { PACKAGE_PIN H19 IOSTANDARD LVCMOS33 } [get_ports { can_txd }];

## Configuration bank voltage
set_property CFGBVS VCCO        [current_design];
set_property CONFIG_VOLTAGE 3.3 [current_design];

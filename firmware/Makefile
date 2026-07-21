# HardFuzz STM32F446 firmware — bare-metal, no HAL.
# Toolchain:  brew install --cask gcc-arm-embedded   (arm-none-eabi-gcc)
# Flashing:   brew install stlink   (st-flash),  or use OpenOCD.
#
# Pick the app:  make            -> SPI master (main.c, for spi_inject_top)
#                make APP=main_i2c -> I2C master (main_i2c.c, for i2c_inject_top)
# Same for flashing:  make flash APP=main_i2c
CROSS  ?= arm-none-eabi-
CC      = $(CROSS)gcc
OBJCOPY = $(CROSS)objcopy
SIZE    = $(CROSS)size

CFLAGS  = -mcpu=cortex-m4 -mthumb -mfloat-abi=soft \
          -O2 -g3 -Wall -Wextra -ffreestanding -fno-common \
          -ffunction-sections -fdata-sections
LDFLAGS = -T stm32f446.ld -nostdlib -Wl,--gc-sections -Wl,-Map=build/fw.map

APP ?= main
SRC = src/startup_stm32f446.c src/$(APP).c
BUILD = build

.PHONY: all flash flash-openocd clean

all: $(BUILD)/fw.bin

$(BUILD)/fw.elf: $(SRC) stm32f446.ld
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) $(SRC) -o $@
	$(SIZE) $@

$(BUILD)/fw.bin: $(BUILD)/fw.elf
	$(OBJCOPY) -O binary $< $@

# Flash over ST-Link (the NUCLEO's onboard programmer).
flash: $(BUILD)/fw.bin
	st-flash --reset write $(BUILD)/fw.bin 0x08000000

flash-openocd: $(BUILD)/fw.elf
	openocd -f board/st_nucleo_f4.cfg \
	  -c "program $(BUILD)/fw.elf verify reset exit"

clean:
	rm -rf $(BUILD)

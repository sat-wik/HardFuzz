# firmware/ — STM32F446RE (NUCLEO) SPI master

The STM32 is both the Device Under Test and the test instrument: it clocks SPI frames
into the FPGA, reads back the echo, and self-reports over the ST-Link virtual COM
port. When the FPGA injector is armed, one bit comes back flipped and the STM32 names
it — the Month 1 exit criterion, no logic analyzer required.

Bare-metal, no HAL. Runs on the reset-default **16 MHz HSI** clock (no PLL to
misconfigure). Built and vector-table-verified on Arm GNU Toolchain 15.2.

## Build & flash

```
brew install --cask gcc-arm-embedded    # arm-none-eabi-gcc
brew install stlink                      # st-flash (uses the NUCLEO's onboard ST-Link)

cd firmware
make            # -> build/main.bin  (SPI); make APP=main_i2c -> build/main_i2c.bin
make flash      # writes to 0x08000000 and resets (add APP=main_i2c for the I2C app)
```

Each app builds to its own `build/<app>.bin`, so switching `APP` always rebuilds
(no stale-binary surprises). Drag-drop flashing: `cp build/main.bin /Volumes/<NUCLEO>/`.
(`make flash-openocd` is there if you prefer OpenOCD.)

## Wiring — do this with both boards powered off

STM32 Arduino header → Cmod A7 Pmod JA (6 jumper wires):

| STM32 pin | Arduino | signal | Cmod JA |
|---|---|---|---|
| PA5 | D13 | SPI1_SCK  | JA1 `spi_sclk` |
| PA7 | D11 | SPI1_MOSI | JA2 `spi_mosi` |
| PA6 | D12 | SPI1_MISO | JA3 `spi_miso` (FPGA drives this) |
| PB6 | D10 | CS (GPIO) | JA4 `spi_cs_n` |
| GND | GND | ground    | JA GND |
| —   | —   | (optional) trig | JA9 `trig_out` → a scope later |

**⚠️ Use the `D13/D12/D11/D10` digital-header labels — NOT `A5/A6/A7`.** On the NUCLEO,
`A5` is Arduino *analog* pin 5 (= PC0), a different pin. `PA5` is Arduino **D13**.
D13/D12/D11/D10 sit four-in-a-row on the right-side digital header, with a GND pin
just above them near AREF.

**Common ground is required.** Both boards run 3.3 V I/O, so no level shifting.
Pmod JA pin order per the Digilent pinout: top row JA1–JA4 (pin1..4), and a GND pin
on each row — see constraints/cmod_a7.xdc for the exact FPGA pins.

## Run the demo

1. Program the FPGA with `spi_inject_top` (repo root: `make bit && make prog`).
2. `make flash` this firmware onto the NUCLEO.
3. Open the STM32 console: `screen /dev/tty.usbmodem<ST-Link> 115200`
   (on macOS the ST-Link VCP shows up as `usbmodem…`).
4. **Loopback check (injector off):** press the blue button (B1). You should see a
   clean table — each frame's `recv` equals the previous frame's `sent`, result `ok`.
   That proves the SPI wiring and the FPGA slave before any injection.
5. **Arm the injector** from a second terminal, over the Cmod's USB port:
   ```
   pip install pyserial
   python3 ../host/arm.py --port /dev/tty.usbserial-XXXX arm --frame 5 --bit 3
   ```
6. Press B1 again. Frame 5 now comes back with bit 3 flipped and the STM32 prints
   `FLIP bit 3`. Because the FPGA resets its frame counter each CS transaction, every
   button press injects again — no need to re-arm.

Typical output:
```
frame  sent  recv  expect  result
  1    0xA1  0xA0  0xA0   ok
  ...
  5    0xA5  0xAC  0xA4   FLIP bit 3
  ...
--> injected fault observed on 1 frame(s)
```

## Run command (for `hardfuzz run` live mode)

Both apps also accept a **`'R'`** byte over this same UART: it runs one campaign and
prints a machine-parseable `RESULT <0|1> <detail>` line (1 = fault observed). That's how
the host `hardfuzz run --dut-port …` executes campaigns and collects real pass/fail
verdicts. The blue button still works for manual runs.

## Notes / limits

- SPI is 500 kHz (fPCLK/32). The FPGA oversamples at 12 MHz, so keep SPI ≲ 2 MHz
  unless you raise the FPGA clock with an MMCM.
- The green LED LD2 shares PA5 with SPI1_SCK, so it is not used here.
- `recv` for frame 0 is the pipeline fill (previous transaction's last byte) and is
  intentionally not checked.

---

# I2C master (Month 2) — `main_i2c.c`

Second app for the same NUCLEO, driving the FPGA's `i2c_inject_top` (I2C slave, clock-
stretch injection). Build/flash it with `APP=main_i2c`:

```
cd firmware
make APP=main_i2c
make flash APP=main_i2c
```

Wiring (STM32 Arduino header → Cmod A7 Pmod JA):

| STM32 pin | Arduino | signal | Cmod JA |
|---|---|---|---|
| PB8 | D15 | I2C1_SCL | JA7 `i2c_scl` |
| PB9 | D14 | I2C1_SDA | JA8 `i2c_sda` |
| GND | GND | ground | JA GND |

I2C is **open-drain** — both sides enable internal pull-ups, but they're weak. If the
bus is unreliable, add external **~4.7 kΩ pull-ups** from SCL and SDA to 3.3 V (a
breadboard makes this easy). Slave address is `0x42`.

## Run the I2C demo

1. Build & flash the **I2C bitstream** to the Cmod (on the Linux/cloud box):
   `make bit TOP=i2c_inject_top`, copy the `.bit` back, then `make prog-flash TOP=i2c_inject_top`.
2. `make flash APP=main_i2c` this firmware onto the NUCLEO.
3. Open the console (`115200`) and press **B1** — the STM32 writes address + 4 bytes and
   prints each byte's transfer time. With the injector disarmed, every byte is ~90 µs:
   ```
   dbyte  time(us)  result
     0     90       ok
     1     90       ok
     2     90       ok
     3     90       ok
   total ~450 us  --> clean
   ```
4. **Arm** over the Cmod USB (small stretch, ~200 µs = 2400 cycles):
   ```
   python3 ../host/arm.py --port /dev/tty.usbserial-XXXX i2c --byte 2 --stretch 2400
   ```
5. Press B1 again → the byte after the target reads much longer (e.g. ~290 µs). For a
   long stretch — `i2c --byte 2 --stretch 60000` (~5 ms) — the STM32 blows past its 2 ms
   timeout and prints `TIMEOUT (slave stretched) - aborting` — the injected fault,
   caught by the master.

## I2C notes / limits

- I2C is 100 kHz standard mode (so each byte is ~90 µs even when clean).
- Software timeout per byte is ~2 ms; a stretch longer than that trips it (the dramatic
  "master timeout" case). Shorter stretches just show up as a slow byte.
- The stretch is felt on the byte *after* the targeted one (the slave holds SCL low
  after that byte's ACK), so target byte 2 shows up as a slow byte 3.

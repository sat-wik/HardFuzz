// HardFuzz — STM32F446RE (NUCLEO) SPI master + host console.
//
// Role: the STM32 is both the Device Under Test and the test instrument. It clocks
// SPI frames into the FPGA (which echoes each byte back one frame later), reads the
// echo, and self-reports over the ST-Link virtual COM port. When the FPGA injector is
// armed (by the host over the Cmod's USB-UART; see host/arm.py), one bit of one frame
// comes back flipped and the STM32 detects and names it — the Month 1 exit criterion,
// proven without a logic analyzer.
//
// Bare-metal, no HAL. Runs on the reset-default 16 MHz HSI clock (APB1=APB2=16 MHz),
// so there is no PLL to misconfigure.
//
// Wiring (STM32 Arduino header  ->  Cmod A7 Pmod JA):
//   PA5  D13  SPI1_SCK   -> JA1 spi_sclk
//   PA7  D11  SPI1_MOSI  -> JA2 spi_mosi
//   PA6  D12  SPI1_MISO  <- JA3 spi_miso
//   PB6  D10  CS (GPIO)  -> JA4 spi_cs_n
//   GND       GND        -> JA GND     (common ground is required)
// Console: USART2 -> ST-Link VCP over the same USB, 115200 8N1.

#include <stdint.h>

// ---- minimal register map (STM32F446) -----------------------------------
#define REG(a) (*(volatile uint32_t *)(a))
#define REG8(a) (*(volatile uint8_t *)(a))

#define RCC_AHB1ENR REG(0x40023830)
#define RCC_APB1ENR REG(0x40023840)
#define RCC_APB2ENR REG(0x40023844)

#define GPIOA 0x40020000u
#define GPIOB 0x40020400u
#define GPIOC 0x40020800u
#define MODER(p)   REG((p) + 0x00)
#define OSPEEDR(p) REG((p) + 0x08)
#define PUPDR(p)   REG((p) + 0x0C)
#define IDR(p)     REG((p) + 0x10)
#define BSRR(p)    REG((p) + 0x18)
#define AFRL(p)    REG((p) + 0x20)

#define USART2      0x40004400u
#define USART2_SR   REG(USART2 + 0x00)
#define USART2_DR   REG(USART2 + 0x04)
#define USART2_BRR  REG(USART2 + 0x08)
#define USART2_CR1  REG(USART2 + 0x0C)

#define SPI1        0x40013000u
#define SPI1_CR1    REG(SPI1 + 0x00)
#define SPI1_SR     REG(SPI1 + 0x08)
#define SPI1_DR8    REG8(SPI1 + 0x0C)

// ---- tiny helpers -------------------------------------------------------
static void delay_ms(uint32_t ms) {
    // Rough busy-wait at 16 MHz; precision is not needed here.
    for (volatile uint32_t i = 0; i < ms * 2000u; i++) __asm__ volatile("nop");
}

static void uputc(char c) {
    while (!(USART2_SR & (1u << 7))) {}   // wait TXE
    USART2_DR = (uint8_t)c;
}
static void uputs(const char *s) { while (*s) uputc(*s++); }
static void uhex2(uint8_t v) {
    const char *h = "0123456789ABCDEF";
    uputc('0'); uputc('x'); uputc(h[(v >> 4) & 0xF]); uputc(h[v & 0xF]);
}
static void udec(uint32_t v) {
    char buf[10]; int n = 0;
    if (v == 0) { uputc('0'); return; }
    while (v) { buf[n++] = '0' + (v % 10); v /= 10; }
    while (n) uputc(buf[--n]);
}

#define CS_LOW()  (BSRR(GPIOB) = (1u << (6 + 16)))   // PB6 = 0
#define CS_HIGH() (BSRR(GPIOB) = (1u << 6))          // PB6 = 1
#define BTN_PRESSED() ((IDR(GPIOC) & (1u << 13)) == 0)   // B1, active low

static uint8_t spi_xfer(uint8_t b) {
    while (!(SPI1_SR & (1u << 1))) {}   // TXE
    SPI1_DR8 = b;                        // 8-bit write (DFF=0)
    while (!(SPI1_SR & (1u << 0))) {}   // RXNE
    return SPI1_DR8;
}

// ---- init ---------------------------------------------------------------
static void clocks_gpio_init(void) {
    RCC_AHB1ENR |= (1u << 0) | (1u << 1) | (1u << 2);  // GPIOA, GPIOB, GPIOC
    RCC_APB1ENR |= (1u << 17);                         // USART2
    RCC_APB2ENR |= (1u << 12);                         // SPI1

    // PA2,PA3 = USART2 (AF7); PA5,PA6,PA7 = SPI1 (AF5) — all alternate-function.
    uint32_t m = MODER(GPIOA);
    m &= ~((3u << (2*2)) | (3u << (2*3)) | (3u << (2*5)) | (3u << (2*6)) | (3u << (2*7)));
    m |=  ((2u << (2*2)) | (2u << (2*3)) | (2u << (2*5)) | (2u << (2*6)) | (2u << (2*7)));
    MODER(GPIOA) = m;
    uint32_t a = AFRL(GPIOA);
    a &= ~((0xFu << (4*2)) | (0xFu << (4*3)) | (0xFu << (4*5)) | (0xFu << (4*6)) | (0xFu << (4*7)));
    a |=  ((7u << (4*2)) | (7u << (4*3)) | (5u << (4*5)) | (5u << (4*6)) | (5u << (4*7)));
    AFRL(GPIOA) = a;
    OSPEEDR(GPIOA) |= (2u << (2*5)) | (2u << (2*6)) | (2u << (2*7));  // high speed on SPI pins

    // PB6 = push-pull output for chip-select, idle high.
    uint32_t bm = MODER(GPIOB);
    bm &= ~(3u << (2*6)); bm |= (1u << (2*6));
    MODER(GPIOB) = bm;
    CS_HIGH();

    // PC13 = input with pull-up (blue user button B1).
    MODER(GPIOC) &= ~(3u << (2*13));
    PUPDR(GPIOC) &= ~(3u << (2*13)); PUPDR(GPIOC) |= (1u << (2*13));
}

static void usart2_init(void) {
    USART2_BRR = 0x8B;                                  // 115200 @ 16 MHz
    USART2_CR1 = (1u << 13) | (1u << 3) | (1u << 2);    // UE | TE | RE
}

static void spi1_init(void) {
    // Master, mode 0 (CPOL=0,CPHA=0), MSB-first, 8-bit, fPCLK/32 = 500 kHz,
    // software slave management (SSM|SSI) so the FPGA never sees NSS from us.
    SPI1_CR1 = (1u << 2) | (4u << 3) | (1u << 9) | (1u << 8);
    SPI1_CR1 |= (1u << 6);                              // SPE
}

// ---- one injection campaign ---------------------------------------------
#define NF 9   // frames per campaign; frame 0 is pipeline fill (ignored)

static void run_campaign(void) {
    uint8_t sent[NF], recv[NF];
    int i, fails = 0, flips = 0;

    for (i = 0; i < NF; i++) sent[i] = (uint8_t)(0xA0 + i);

    CS_LOW();
    delay_ms(1);                       // let the FPGA see CS and load its response
    for (i = 0; i < NF; i++) recv[i] = spi_xfer(sent[i]);
    CS_HIGH();

    uputs("\r\nframe  sent  recv  expect  result\r\n");
    for (i = 1; i < NF; i++) {
        uint8_t exp = sent[i - 1];     // echo is delayed by one frame
        uint8_t diff = recv[i] ^ exp;
        uputs("  ");   udec(i);
        uputs("    "); uhex2(sent[i]);
        uputs("  ");   uhex2(recv[i]);
        uputs("   ");  uhex2(exp);
        uputs("   ");
        if (diff == 0) {
            uputs("ok\r\n");
        } else {
            int b;
            uputs("FLIP bit");
            for (b = 0; b < 8; b++) if (diff & (1u << b)) { uputc(' '); udec(b); }
            uputs("\r\n");
            fails++; flips++;
        }
    }

    uputs("--> ");
    if (flips == 0) uputs("clean echo (injector disarmed)\r\n");
    else { uputs("injected fault observed on "); udec(flips); uputs(" frame(s)\r\n"); }
    (void)fails;

    // machine-parseable result for `hardfuzz run` (the host scans for "RESULT <0|1> ...")
    uputs("RESULT "); uputc(flips ? '1' : '0'); uputc(' ');
    if (flips) { uputs("SPI flip on "); udec(flips); uputs(" frame(s)"); }
    else         uputs("SPI clean");
    uputs("\r\n");
}

int main(void) {
    clocks_gpio_init();
    usart2_init();
    spi1_init();

    uputs("\r\n=== HardFuzz STM32 SPI master ===\r\n");
    uputs("Wire (Arduino hdr -> Cmod JA): SCK PA5->JA1, MOSI PA7->JA2, "
          "MISO PA6<-JA3, CS PB6->JA4, plus GND.\r\n");
    uputs("Press B1 (or send 'R' over this port) to run a campaign.\r\n");
    uputs("Arm the FPGA injector from the host: host/arm.py or `hardfuzz run`.\r\n");

    for (;;) {
        if (BTN_PRESSED()) {
            run_campaign();
            while (BTN_PRESSED()) {}   // wait for release
            delay_ms(50);              // debounce
        }
        if (USART2_SR & (1u << 5)) {           // RXNE: host command byte
            if ((uint8_t)USART2_DR == 'R') run_campaign();   // run one campaign
        }
    }
}

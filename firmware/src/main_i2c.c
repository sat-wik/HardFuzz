// HardFuzz — STM32F446RE (NUCLEO) I2C master + host console (Month 2).
//
// Companion to main.c (SPI). The STM32 is I2C master; the FPGA (i2c_inject_top) is the
// slave at 0x42. On a button press the STM32 writes address + 4 data bytes, times each
// byte's transfer with the cycle counter, and reports over the ST-Link VCP. When the
// FPGA injector is armed (host: arm.py over the Cmod USB), the slave stretches SCL on
// the targeted byte — the STM32 either sees that byte take much longer or, for a long
// stretch, hits its software timeout and aborts. That timeout/slow byte is the fault.
//
// Bare-metal, no HAL. Reset-default 16 MHz HSI (APB1 = 16 MHz).
//
// Wiring (STM32 Arduino header  ->  Cmod A7 Pmod JA):
//   PB8  D15  I2C1_SCL  <-> JA7 i2c_scl
//   PB9  D14  I2C1_SDA  <-> JA8 i2c_sda
//   GND       GND       -> JA GND
// I2C is open-drain: both boards enable internal pull-ups; add external ~4.7k to 3.3V
// on SCL and SDA if it's flaky. Console: USART2 -> ST-Link VCP, 115200 8N1.

#include <stdint.h>

#define REG(a)  (*(volatile uint32_t *)(a))
#define CLK_MHZ 16u
#define TIMEOUT_CYC (2u * 1000u * CLK_MHZ)   // ~2 ms software timeout per byte

#define RCC_AHB1ENR REG(0x40023830)
#define RCC_APB1ENR REG(0x40023840)

#define GPIOA 0x40020000u
#define GPIOB 0x40020400u
#define GPIOC 0x40020800u
#define MODER(p)   REG((p) + 0x00)
#define OTYPER(p)  REG((p) + 0x04)
#define OSPEEDR(p) REG((p) + 0x08)
#define PUPDR(p)   REG((p) + 0x0C)
#define IDR(p)     REG((p) + 0x10)
#define AFRL(p)    REG((p) + 0x20)
#define AFRH(p)    REG((p) + 0x24)

#define USART2     0x40004400u
#define USART2_SR  REG(USART2 + 0x00)
#define USART2_DR  REG(USART2 + 0x04)
#define USART2_BRR REG(USART2 + 0x08)
#define USART2_CR1 REG(USART2 + 0x0C)

#define I2C1       0x40005400u
#define I2C1_CR1   REG(I2C1 + 0x00)
#define I2C1_CR2   REG(I2C1 + 0x04)
#define I2C1_DR    REG(I2C1 + 0x10)
#define I2C1_SR1   REG(I2C1 + 0x14)
#define I2C1_SR2   REG(I2C1 + 0x18)
#define I2C1_CCR   REG(I2C1 + 0x1C)
#define I2C1_TRISE REG(I2C1 + 0x20)

// I2C1 register bits
#define CR1_PE    (1u<<0)
#define CR1_START (1u<<8)
#define CR1_STOP  (1u<<9)
#define CR1_ACK   (1u<<10)
#define CR1_SWRST (1u<<15)
#define SR1_SB    (1u<<0)
#define SR1_ADDR  (1u<<1)
#define SR1_BTF   (1u<<2)
#define SR1_TXE   (1u<<7)
#define SR1_AF    (1u<<10)
#define SR2_BUSY  (1u<<1)

// DWT cycle counter (for timing)
#define DEMCR      REG(0xE000EDFC)
#define DWT_CTRL   REG(0xE0001000)
#define DWT_CYCCNT REG(0xE0001004)

// ---- console + timing helpers -------------------------------------------
static void dwt_init(void)  { DEMCR |= (1u<<24); DWT_CYCCNT = 0; DWT_CTRL |= 1u; }
static void delay_ms(uint32_t ms) {
    for (volatile uint32_t i = 0; i < ms * 2000u; i++) __asm__ volatile("nop");
}
static void uputc(char c) { while (!(USART2_SR & (1u<<7))) {} USART2_DR = (uint8_t)c; }
static void uputs(const char *s) { while (*s) uputc(*s++); }
static void udec(uint32_t v) {
    char b[10]; int n = 0;
    if (!v) { uputc('0'); return; }
    while (v) { b[n++] = '0' + (v % 10); v /= 10; }
    while (n) uputc(b[--n]);
}
#define BTN_PRESSED() ((IDR(GPIOC) & (1u<<13)) == 0)

// Wait for an SR1 bit, with a cycle-accurate timeout and NACK detection.
// returns 0 = bit set, 1 = timeout, 2 = AF/NACK; *el = elapsed cycles.
static int wait_sr1(uint32_t bit, uint32_t *el) {
    uint32_t t0 = DWT_CYCCNT;
    for (;;) {
        uint32_t sr1 = I2C1_SR1;
        if (sr1 & bit)             { *el = DWT_CYCCNT - t0; return 0; }
        if (sr1 & SR1_AF)          { *el = DWT_CYCCNT - t0; return 2; }
        if ((DWT_CYCCNT - t0) > TIMEOUT_CYC) { *el = DWT_CYCCNT - t0; return 1; }
    }
}
static void i2c_stop(void) { I2C1_CR1 |= CR1_STOP; }

// ---- init ---------------------------------------------------------------
static void clocks_gpio_init(void) {
    RCC_AHB1ENR |= (1u<<0) | (1u<<1) | (1u<<2);   // GPIOA, GPIOB, GPIOC
    RCC_APB1ENR |= (1u<<17) | (1u<<21);           // USART2, I2C1

    // PA2,PA3 = USART2 (AF7)
    uint32_t m = MODER(GPIOA);
    m &= ~((3u<<(2*2)) | (3u<<(2*3)));
    m |=  ((2u<<(2*2)) | (2u<<(2*3)));
    MODER(GPIOA) = m;
    uint32_t a = AFRL(GPIOA);
    a &= ~((0xFu<<(4*2)) | (0xFu<<(4*3)));
    a |=  ((7u<<(4*2)) | (7u<<(4*3)));
    AFRL(GPIOA) = a;

    // PB8=SCL, PB9=SDA : AF4, open-drain, internal pull-up, high speed
    uint32_t bm = MODER(GPIOB);
    bm &= ~((3u<<(2*8)) | (3u<<(2*9)));
    bm |=  ((2u<<(2*8)) | (2u<<(2*9)));           // alternate function
    MODER(GPIOB) = bm;
    OTYPER(GPIOB) |= (1u<<8) | (1u<<9);           // open-drain
    OSPEEDR(GPIOB) |= (2u<<(2*8)) | (2u<<(2*9));
    uint32_t bp = PUPDR(GPIOB);
    bp &= ~((3u<<(2*8)) | (3u<<(2*9)));
    bp |=  ((1u<<(2*8)) | (1u<<(2*9)));           // pull-up
    PUPDR(GPIOB) = bp;
    uint32_t ah = AFRH(GPIOB);                    // AFRH covers pins 8..15
    ah &= ~((0xFu<<(4*0)) | (0xFu<<(4*1)));       // pin8 -> [3:0], pin9 -> [7:4]
    ah |=  ((4u<<(4*0)) | (4u<<(4*1)));           // AF4
    AFRH(GPIOB) = ah;

    // PC13 = button input, pull-up
    MODER(GPIOC) &= ~(3u<<(2*13));
    PUPDR(GPIOC) &= ~(3u<<(2*13)); PUPDR(GPIOC) |= (1u<<(2*13));
}

static void usart2_init(void) {
    USART2_BRR = 0x8B;                            // 115200 @ 16 MHz
    USART2_CR1 = (1u<<13) | (1u<<3) | (1u<<2);    // UE | TE | RE
}

static void i2c1_init(void) {
    I2C1_CR1 = CR1_SWRST;                         // reset the peripheral
    I2C1_CR1 = 0;
    I2C1_CR2   = 16u;                             // FREQ = APB1 in MHz
    I2C1_CCR   = 80u;                             // 100 kHz standard mode
    I2C1_TRISE = 17u;                             // FREQ + 1
    I2C1_CR1   = CR1_PE;                          // enable
}

// machine-parseable result line for `hardfuzz run` (host scans for "RESULT <0|1> ...")
static void emit_result(int observed, const char* detail) {
    uputs("RESULT "); uputc(observed ? '1' : '0'); uputc(' '); uputs(detail); uputs("\r\n");
}

// ---- one I2C write campaign ---------------------------------------------
static void run_campaign(void) {
    static const uint8_t data[4] = { 0xA0, 0xA1, 0xA2, 0xA3 };
    uint32_t el, t_start, bt0, total_us, byte_us[4];
    int r, i, fault = 0, byte_res[4], nbytes = 0;

    // bus must be free
    t_start = DWT_CYCCNT;
    while (I2C1_SR2 & SR2_BUSY) {
        if ((DWT_CYCCNT - t_start) > TIMEOUT_CYC) {
            uputs("\r\nbus stuck busy\r\n"); emit_result(0, "I2C bus stuck busy"); return; }
    }

    t_start = DWT_CYCCNT;
    I2C1_CR1 |= CR1_START;
    if (wait_sr1(SR1_SB, &el)) { uputs("\r\nSTART failed\r\n"); emit_result(0, "I2C START failed"); i2c_stop(); return; }
    (void)I2C1_SR1;
    I2C1_DR = (0x42u << 1) | 0u;                  // address + write
    r = wait_sr1(SR1_ADDR, &el);
    if (r == 2) { uputs("\r\naddress NACK - no slave at 0x42\r\n"); emit_result(0, "I2C address NACK"); i2c_stop(); return; }
    if (r == 1) { uputs("\r\naddress timeout\r\n"); emit_result(0, "I2C address timeout"); i2c_stop(); return; }
    (void)I2C1_SR1; (void)I2C1_SR2;               // clear ADDR

    // Send data bytes back-to-back, timing each. Print AFTER the transaction so
    // UART time doesn't stall the bus between bytes (that hid short stretches).
    for (i = 0; i < 4; i++) {
        bt0 = DWT_CYCCNT;
        I2C1_DR = data[i];
        r = wait_sr1(SR1_BTF, &el);
        byte_us[i]  = (DWT_CYCCNT - bt0) / CLK_MHZ;
        byte_res[i] = r;
        nbytes++;
        if (r) break;                 // stop on timeout / NACK
    }
    i2c_stop();
    total_us = (DWT_CYCCNT - t_start) / CLK_MHZ;

    uputs("\r\ndbyte  time(us)  result\r\n");
    for (i = 0; i < nbytes; i++) {
        uputs("  "); udec(i); uputs("     "); udec(byte_us[i]); uputs("      ");
        if      (byte_res[i] == 1) { uputs("TIMEOUT (slave stretched)\r\n"); fault = 1; }
        else if (byte_res[i] == 2) { uputs("NACK\r\n");                      fault = 1; }
        else if (byte_us[i] > 150) { uputs("SLOW - stretched\r\n");          fault = 1; }
        else                         uputs("ok\r\n");
    }
    uputs("total "); udec(total_us); uputs(" us  --> ");
    if (fault) uputs("I2C FAULT observed (clock stretch)\r\n");
    else       uputs("clean (bytes ~90us each, no abnormal stretch)\r\n");
    emit_result(fault, fault ? "I2C stretch fault" : "I2C clean");
}

int main(void) {
    clocks_gpio_init();
    usart2_init();
    i2c1_init();
    dwt_init();

    uputs("\r\n=== HardFuzz STM32 I2C master ===\r\n");
    uputs("Wire: SCL PB8(D15)<->JA7, SDA PB9(D14)<->JA8, plus GND. Slave addr 0x42.\r\n");
    uputs("Press B1 (or send 'R' over this port) to run an I2C write campaign.\r\n");
    uputs("Arm the FPGA distorter from the host: host/arm.py or `hardfuzz run`.\r\n");

    for (;;) {
        if (BTN_PRESSED()) {
            run_campaign();
            while (BTN_PRESSED()) {}
            delay_ms(50);
        }
        if (USART2_SR & (1u << 5)) {           // RXNE: host command byte
            if ((uint8_t)USART2_DR == 'R') run_campaign();   // run one campaign
        }
    }
}

// HardFuzz — STM32F446RE combined SPI + I2C master (for multi_inject_top).
//
// One firmware drives both DUT roles so you switch protocols without reflashing the
// STM32 (matching the FPGA's multi_inject_top). Command protocol over the ST-Link VCP:
//   'S' -> select SPI    'I' -> select I2C    'R' -> run the selected protocol once
// The host `hardfuzz` CLI sends {proto, 'R'}; the standalone firmwares ignore the proto
// byte and just run on 'R', so this stays compatible. Each run prints a RESULT line.
//
// Wiring: SPI  SCK PA5>JA1, MOSI PA7>JA2, MISO PA6<JA3, CS PB6>JA4
//         I2C  SCL PB8<>JA7, SDA PB9<>JA8   (+ shared GND). Bare-metal, 16 MHz HSI.

#include <stdint.h>

#define REG(a)  (*(volatile uint32_t *)(a))
#define REG8(a) (*(volatile uint8_t  *)(a))
#define CLK_MHZ 16u
#define TIMEOUT_CYC (2u * 1000u * CLK_MHZ)          // ~2 ms per-byte I2C timeout

#define RCC_AHB1ENR REG(0x40023830)
#define RCC_APB1ENR REG(0x40023840)
#define RCC_APB2ENR REG(0x40023844)
#define GPIOA 0x40020000u
#define GPIOB 0x40020400u
#define GPIOC 0x40020800u
#define MODER(p)   REG((p)+0x00)
#define OTYPER(p)  REG((p)+0x04)
#define OSPEEDR(p) REG((p)+0x08)
#define PUPDR(p)   REG((p)+0x0C)
#define IDR(p)     REG((p)+0x10)
#define BSRR(p)    REG((p)+0x18)
#define AFRL(p)    REG((p)+0x20)
#define AFRH(p)    REG((p)+0x24)
#define USART2 0x40004400u
#define USART2_SR  REG(USART2+0x00)
#define USART2_DR  REG(USART2+0x04)
#define USART2_BRR REG(USART2+0x08)
#define USART2_CR1 REG(USART2+0x0C)
#define SPI1 0x40013000u
#define SPI1_CR1 REG(SPI1+0x00)
#define SPI1_SR  REG(SPI1+0x08)
#define SPI1_DR8 REG8(SPI1+0x0C)
#define I2C1 0x40005400u
#define I2C1_CR1 REG(I2C1+0x00)
#define I2C1_CR2 REG(I2C1+0x04)
#define I2C1_DR  REG(I2C1+0x10)
#define I2C1_SR1 REG(I2C1+0x14)
#define I2C1_SR2 REG(I2C1+0x18)
#define I2C1_CCR REG(I2C1+0x1C)
#define I2C1_TRISE REG(I2C1+0x20)
#define CR1_PE (1u<<0)
#define SR1_SB (1u<<0)
#define SR1_ADDR (1u<<1)
#define SR1_BTF (1u<<2)
#define SR1_AF (1u<<10)
#define SR2_BUSY (1u<<1)
#define DEMCR      REG(0xE000EDFC)
#define DWT_CTRL   REG(0xE0001000)
#define DWT_CYCCNT REG(0xE0001004)

// ---- helpers ------------------------------------------------------------
static void dwt_init(void)   { DEMCR |= (1u<<24); DWT_CYCCNT = 0; DWT_CTRL |= 1u; }
static void delay_ms(uint32_t ms){ for (volatile uint32_t i=0;i<ms*2000u;i++) __asm__ volatile("nop"); }
static void uputc(char c){ while(!(USART2_SR&(1u<<7))){} USART2_DR=(uint8_t)c; }
static void uputs(const char*s){ while(*s) uputc(*s++); }
static void uhex2(uint8_t v){ const char*h="0123456789ABCDEF"; uputc('0');uputc('x');uputc(h[(v>>4)&0xF]);uputc(h[v&0xF]); }
static void udec(uint32_t v){ char b[10]; int n=0; if(!v){uputc('0');return;} while(v){b[n++]='0'+(v%10);v/=10;} while(n)uputc(b[--n]); }
static void emit_result(int obs,const char*d){ uputs("RESULT ");uputc(obs?'1':'0');uputc(' ');uputs(d);uputs("\r\n"); }
#define CS_LOW()  (BSRR(GPIOB)=(1u<<(6+16)))
#define CS_HIGH() (BSRR(GPIOB)=(1u<<6))
#define BTN_PRESSED() ((IDR(GPIOC)&(1u<<13))==0)

static uint8_t spi_xfer(uint8_t b){
    while(!(SPI1_SR&(1u<<1))){}  SPI1_DR8=b;  while(!(SPI1_SR&(1u<<0))){}  return SPI1_DR8;
}
static int wait_sr1(uint32_t bit, uint32_t*el){
    uint32_t t0=DWT_CYCCNT;
    for(;;){ uint32_t s=I2C1_SR1;
        if(s&bit){*el=DWT_CYCCNT-t0;return 0;}
        if(s&SR1_AF){*el=DWT_CYCCNT-t0;return 2;}
        if((DWT_CYCCNT-t0)>TIMEOUT_CYC){*el=DWT_CYCCNT-t0;return 1;} }
}

// ---- init (both peripherals) --------------------------------------------
static void init_all(void){
    RCC_AHB1ENR |= (1u<<0)|(1u<<1)|(1u<<2);      // GPIOA,B,C
    RCC_APB1ENR |= (1u<<17)|(1u<<21);            // USART2, I2C1
    RCC_APB2ENR |= (1u<<12);                     // SPI1

    // PA2,3 USART2(AF7); PA5,6,7 SPI1(AF5)
    uint32_t m=MODER(GPIOA);
    m&=~((3u<<4)|(3u<<6)|(3u<<10)|(3u<<12)|(3u<<14));
    m|= ((2u<<4)|(2u<<6)|(2u<<10)|(2u<<12)|(2u<<14));
    MODER(GPIOA)=m;
    uint32_t a=AFRL(GPIOA);
    a&=~((0xFu<<8)|(0xFu<<12)|(0xFu<<20)|(0xFu<<24)|(0xFu<<28));
    a|= ((7u<<8)|(7u<<12)|(5u<<20)|(5u<<24)|(5u<<28));
    AFRL(GPIOA)=a;
    OSPEEDR(GPIOA)|=(2u<<10)|(2u<<12)|(2u<<14);

    // PB6 CS output; PB8/9 I2C1(AF4) open-drain pull-up
    uint32_t bm=MODER(GPIOB);
    bm&=~((3u<<12)|(3u<<16)|(3u<<18));
    bm|= ((1u<<12)|(2u<<16)|(2u<<18));           // PB6 out, PB8/9 AF
    MODER(GPIOB)=bm;  CS_HIGH();
    OTYPER(GPIOB)|=(1u<<8)|(1u<<9);
    OSPEEDR(GPIOB)|=(2u<<16)|(2u<<18);
    uint32_t bp=PUPDR(GPIOB); bp&=~((3u<<16)|(3u<<18)); bp|=((1u<<16)|(1u<<18)); PUPDR(GPIOB)=bp;
    uint32_t ah=AFRH(GPIOB); ah&=~((0xFu<<0)|(0xFu<<4)); ah|=((4u<<0)|(4u<<4)); AFRH(GPIOB)=ah;

    // PC13 button pull-up
    MODER(GPIOC)&=~(3u<<26); PUPDR(GPIOC)&=~(3u<<26); PUPDR(GPIOC)|=(1u<<26);

    USART2_BRR=0x8B; USART2_CR1=(1u<<13)|(1u<<3)|(1u<<2);
    SPI1_CR1=(1u<<2)|(4u<<3)|(1u<<9)|(1u<<8); SPI1_CR1|=(1u<<6);
    I2C1_CR1=(1u<<15); I2C1_CR1=0; I2C1_CR2=16u; I2C1_CCR=80u; I2C1_TRISE=17u; I2C1_CR1=CR1_PE;
    dwt_init();
}

// ---- SPI campaign -------------------------------------------------------
#define NF 9
static void run_spi(void){
    uint8_t sent[NF], recv[NF]; int i, flips=0;
    for(i=0;i<NF;i++) sent[i]=(uint8_t)(0xA0+i);
    CS_LOW(); delay_ms(1);
    for(i=0;i<NF;i++) recv[i]=spi_xfer(sent[i]);
    CS_HIGH();
    uputs("\r\n[SPI] frame  sent  recv  expect  result\r\n");
    for(i=1;i<NF;i++){
        uint8_t exp=sent[i-1], diff=recv[i]^exp;
        uputs("  ");udec(i);uputs("    ");uhex2(sent[i]);uputs("  ");uhex2(recv[i]);uputs("   ");uhex2(exp);uputs("   ");
        if(diff==0) uputs("ok\r\n");
        else { int b; uputs("FLIP bit"); for(b=0;b<8;b++) if(diff&(1u<<b)){uputc(' ');udec(b);} uputs("\r\n"); flips++; }
    }
    uputs("RESULT ");uputc(flips?'1':'0');uputc(' ');
    if(flips){uputs("SPI flip on ");udec(flips);uputs(" frame(s)");} else uputs("SPI clean");
    uputs("\r\n");
}

// ---- I2C campaign -------------------------------------------------------
static void run_i2c(void){
    static const uint8_t data[4]={0xA0,0xA1,0xA2,0xA3};
    uint32_t el,bt0,byte_us[4]; int r,i,fault=0,byte_res[4],nbytes=0;
    uint32_t t0=DWT_CYCCNT;
    while(I2C1_SR2&SR2_BUSY){ if((DWT_CYCCNT-t0)>TIMEOUT_CYC){uputs("\r\n[I2C] bus busy\r\n");emit_result(0,"I2C bus stuck busy");return;} }
    I2C1_CR1|=(1u<<8);
    if(wait_sr1(SR1_SB,&el)){uputs("\r\n[I2C] START failed\r\n");emit_result(0,"I2C START failed");I2C1_CR1|=(1u<<9);return;}
    (void)I2C1_SR1; I2C1_DR=(0x42u<<1)|0u;
    r=wait_sr1(SR1_ADDR,&el);
    if(r==2){uputs("\r\n[I2C] address NACK\r\n");emit_result(0,"I2C address NACK");I2C1_CR1|=(1u<<9);return;}
    if(r==1){uputs("\r\n[I2C] address timeout\r\n");emit_result(0,"I2C address timeout");I2C1_CR1|=(1u<<9);return;}
    (void)I2C1_SR1;(void)I2C1_SR2;
    for(i=0;i<4;i++){ bt0=DWT_CYCCNT; I2C1_DR=data[i]; r=wait_sr1(SR1_BTF,&el);
        byte_us[i]=(DWT_CYCCNT-bt0)/CLK_MHZ; byte_res[i]=r; nbytes++; if(r)break; }
    I2C1_CR1|=(1u<<9);
    uputs("\r\n[I2C] dbyte  time(us)  result\r\n");
    for(i=0;i<nbytes;i++){ uputs("  ");udec(i);uputs("     ");udec(byte_us[i]);uputs("      ");
        if(byte_res[i]==1){uputs("TIMEOUT\r\n");fault=1;}
        else if(byte_res[i]==2){uputs("NACK\r\n");fault=1;}
        else if(byte_us[i]>150){uputs("SLOW - stretched\r\n");fault=1;}
        else uputs("ok\r\n"); }
    emit_result(fault, fault?"I2C stretch fault":"I2C clean");
}

int main(void){
    init_all();
    uputs("\r\n=== HardFuzz STM32 multi (SPI+I2C) master ===\r\n");
    uputs("Cmds over UART: 'S' select SPI, 'I' select I2C, 'R' run. Button runs current.\r\n");
    uputs("For multi_inject_top; arm the FPGA via host/arm.py or `hardfuzz run`.\r\n");
    char mode='S';
    for(;;){
        if(BTN_PRESSED()){ if(mode=='I')run_i2c(); else run_spi(); while(BTN_PRESSED()){} delay_ms(50); }
        if(USART2_SR&(1u<<5)){
            char c=(char)USART2_DR;
            if(c=='S')      mode='S';
            else if(c=='I') mode='I';
            else if(c=='R'){ if(mode=='I')run_i2c(); else run_spi(); }
        }
    }
}

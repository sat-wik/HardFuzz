// Minimal startup for STM32F446: vector table + reset handler. No CMSIS needed.
#include <stdint.h>

extern uint32_t _sidata, _sdata, _edata, _sbss, _ebss, _estack;
int main(void);

void Reset_Handler(void) {
    uint32_t *src = &_sidata, *dst = &_sdata;
    while (dst < &_edata) *dst++ = *src++;     // copy .data from flash to RAM
    for (dst = &_sbss; dst < &_ebss;) *dst++ = 0;  // zero .bss
    main();
    for (;;) {}
}

void Default_Handler(void) { for (;;) {} }

// Core exception vectors are enough — we use no peripheral interrupts.
__attribute__((section(".isr_vector"), used))
void (*const g_vectors[])(void) = {
    (void (*)(void))(&_estack),  // 0  initial stack pointer
    Reset_Handler,               // 1  reset
    Default_Handler,             // 2  NMI
    Default_Handler,             // 3  HardFault
    Default_Handler,             // 4  MemManage
    Default_Handler,             // 5  BusFault
    Default_Handler,             // 6  UsageFault
    0, 0, 0, 0,                  // 7-10 reserved
    Default_Handler,             // 11 SVCall
    Default_Handler,             // 12 Debug Monitor
    0,                           // 13 reserved
    Default_Handler,             // 14 PendSV
    Default_Handler,             // 15 SysTick
};

/*
 * Common test definitions for FreeRTOS on RISC-V
 */

#ifndef TESTCOMMON_RISCV_H
#define TESTCOMMON_RISCV_H

#include <stdint.h>

/* Console I/O via magic address */
#define CONSOLE_ADDR 0xFFFFFFF4
#define EXIT_ADDR    0xFFFFFFF0

/* Simple console output */
static inline void console_putc(char c) {
    volatile uint32_t *console = (volatile uint32_t *)CONSOLE_ADDR;
    *console = c;
}

static inline void console_puts(const char *s) {
    while (*s) {
        console_putc(*s++);
    }
}

/* Exit simulation */
static inline void exit_sim(int code) {
    volatile uint32_t *exit_reg = (volatile uint32_t *)EXIT_ADDR;
    *exit_reg = code;
    while(1);
}

#endif /* TESTCOMMON_RISCV_H */

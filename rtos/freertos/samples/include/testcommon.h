/*
 * Common test definitions for FreeRTOS on RISC-V
 */

#ifndef TESTCOMMON_RISCV_H
#define TESTCOMMON_RISCV_H

#include <stdint.h>
#include "kv_platform.h"

/* Console I/O and exit helpers - use SDK API from kv_platform.h */
static inline void console_putc(char c) {
    kv_magic_putc(c);
}

static inline void console_puts(const char *s) {
    while (*s) {
        console_putc(*s++);
    }
}

/* Exit simulation */
static inline void exit_sim(int code) {
    kv_magic_exit(code);
}

#endif /* TESTCOMMON_RISCV_H */

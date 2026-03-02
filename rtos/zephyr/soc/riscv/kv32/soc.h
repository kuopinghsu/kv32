/*
 * Copyright (c) 2026 kv32 Project
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef _SOC_RISCV_KV32_SOC_H_
#define _SOC_RISCV_KV32_SOC_H_

#include <zephyr/sys/util.h>

/* CPU core definitions */
#define RISCV_MTVEC_MODE_DIRECT    0
#define RISCV_MTVEC_MODE_VECTORED  1

/* Memory map */
#define RAM_BASE_ADDR      0x80000000
#define RAM_SIZE           (2 * 1024 * 1024)  /* 2MB */

#define UART_BASE_ADDR     0x20000000
#define CLINT_BASE_ADDR    0x02000000

/* UART registers */
#define UART_TX_DATA       (UART_BASE_ADDR + 0x00)
#define UART_TX_STATUS     (UART_BASE_ADDR + 0x04)
#define UART_BAUD_DIV      (UART_BASE_ADDR + 0x08)

/* CLINT registers */
#define CLINT_MSIP         (CLINT_BASE_ADDR + 0x0000)
#define CLINT_MTIMECMP_LO  (CLINT_BASE_ADDR + 0x4000)
#define CLINT_MTIMECMP_HI  (CLINT_BASE_ADDR + 0x4004)
#define CLINT_MTIME_LO     (CLINT_BASE_ADDR + 0xBFF8)
#define CLINT_MTIME_HI     (CLINT_BASE_ADDR + 0xBFFC)

/* System clock */
#define CPU_CLOCK_HZ       50000000  /* 50 MHz */

/* Interrupt numbers */
#define RISCV_IRQ_MSOFT    3   /* Machine software interrupt */
#define RISCV_IRQ_MTIMER   7   /* Machine timer interrupt */
#define RISCV_IRQ_MEXT     11  /* Machine external interrupt */

#ifndef _ASMLANGUAGE

/* Include generic RISC-V SoC definitions */
#include <zephyr/arch/riscv/arch.h>

/* SoC initialization */
static inline void soc_early_init_hook(void)
{
    /* Machine trap vector setup is handled by Zephyr RISC-V common code */
}

#endif /* !_ASMLANGUAGE */

#endif /* _SOC_RISCV_KV32_SOC_H_ */

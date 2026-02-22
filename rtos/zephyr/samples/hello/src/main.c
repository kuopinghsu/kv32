/*
 * Copyright (c) 2026 kcore Project
 * SPDX-License-Identifier: Apache-2.0
 *
 * Simple Hello World application for kcore board
 * Uses magic address console driver for fast simulation output
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <zephyr/version.h>

void sim_exit(int exit_code)
{
    /* Write to exit magic address */
    *((volatile uint32_t *)0xFFFFFFF0) = exit_code;
}

void main(void)
{
    printk("*** Booting Zephyr OS build %s ***\n", KERNEL_VERSION_STRING);
    printk("Hello World! kcore RISC-V Board\n");
    printk("Test completed successfully!\n");
    sim_exit(0);
}

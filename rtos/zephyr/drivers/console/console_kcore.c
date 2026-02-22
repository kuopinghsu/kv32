/*
 * Copyright (c) 2026 kcore Project
 * SPDX-License-Identifier: Apache-2.0
 *
 * Console driver for kcore using magic address
 * Writes characters to 0xFFFFFFF4 for simulation/testbench output
 */

#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/printk-hooks.h>
#include <zephyr/sys/libc-hooks.h>
#include <zephyr/device.h>
#include <zephyr/init.h>

/* Magic address for console output */
#define CONSOLE_MAGIC_ADDR  0xFFFFFFF4

#if defined(CONFIG_PRINTK) || defined(CONFIG_STDOUT_CONSOLE)
/**
 * @brief Output one character to console via magic address
 * @param c Character to output
 * @return The character passed as input
 */
static int console_out(int c)
{
    /* Write character to magic address */
    *((volatile uint32_t *)CONSOLE_MAGIC_ADDR) = (uint32_t)c;
    return c;
}
#endif

/**
 * @brief Initialize the console driver
 * @return 0 if successful
 */
static int console_kcore_init(void)
{
#if defined(CONFIG_STDOUT_CONSOLE)
    __stdout_hook_install(console_out);
#endif
#if defined(CONFIG_PRINTK)
    __printk_hook_install(console_out);
#endif
    return 0;
}

SYS_INIT(console_kcore_init,
     PRE_KERNEL_1,
     CONFIG_CONSOLE_INIT_PRIORITY);

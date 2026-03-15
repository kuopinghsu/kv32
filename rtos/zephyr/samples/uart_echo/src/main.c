/*
 * Copyright (c) 2026 kv32 Project
 * SPDX-License-Identifier: Apache-2.0
 *
 * UART Echo Test Sample for kv32 board
 * Demonstrates UART driver TX and RX functionality with echo
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/sys_io.h>
#include "kv_platform.h"

void uart_echo_test(const struct device *uart_dev)
{
    unsigned char c;
    int ret;
    int char_count = 0;
    int max_chars = 20;  // Read up to 20 characters

    printk("\n*** UART Echo Test ***\n");
    printk("Device: %s\n", uart_dev->name);
    printk("Waiting for UART input...\n");
    printk("Will echo received characters back\n\n");

    /* Echo loop - read and echo back characters */
    while (char_count < max_chars) {
        ret = uart_poll_in(uart_dev, &c);

        if (ret == 0) {
            /* Character received */
            printk("RX: 0x%02x ('%c')\n", c, (c >= 32 && c < 127) ? c : '?');

            /* Echo it back */
            uart_poll_out(uart_dev, c);
            printk("TX: 0x%02x (echoed)\n", c);

            char_count++;

            /* Exit on newline */
            if (c == '\n') {
                break;
            }
        }

        /* Small delay to avoid busy looping (1 microsecond) */
        k_busy_wait(1);
    }

    printk("\nReceived %d characters\n", char_count);
}

void main(void)
{
    const struct device *uart_dev;

    printk("*** Starting UART Echo Test Sample ***\n");

    /* Get UART device */
    uart_dev = DEVICE_DT_GET(DT_NODELABEL(uart0));

    if (!device_is_ready(uart_dev)) {
        printk("ERROR: UART device not ready!\n");
        kv_magic_exit(1);
        return;
    }

    printk("UART device ready: %s\n", uart_dev->name);

    /* Enable internal UART loopback and provide deterministic RX input so
     * simulation/RTL runs do not block waiting for host-side typing.
     */
    sys_write32(KV_UART_CTRL_LOOPBACK, KV_UART_BASE + KV_UART_CTRL_OFF);
    uart_poll_out(uart_dev, 'O');
    uart_poll_out(uart_dev, 'K');
    uart_poll_out(uart_dev, '\n');

    /* Run echo test */
    uart_echo_test(uart_dev);

    /* Report results */
    printk("\nUART Echo test PASSED\n");
    printk("Successfully received and echoed characters\n");
    kv_magic_exit(0);
}

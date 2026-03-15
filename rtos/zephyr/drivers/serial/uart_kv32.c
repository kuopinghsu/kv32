/*
 * Copyright (c) 2026 kv32 Project
 * SPDX-License-Identifier: Apache-2.0
 *
 * UART driver for kv32 custom UART peripheral
 */

#define DT_DRV_COMPAT kv32_uart

#include <zephyr/kernel.h>
#include <zephyr/arch/cpu.h>
#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/sys/sys_io.h>

/* UART register offsets */
#define UART_REG_TX_DATA    0x00
#define UART_REG_RX_DATA    0x00  /* Same register, write=TX, read=RX */
#define UART_REG_STATUS     0x04
#define UART_REG_BAUD_DIV   0x10  /* KV_UART_LEVEL_OFF */

/* Status register bits */
#define UART_STATUS_TX_BUSY      (1 << 0)
#define UART_STATUS_TX_FULL      (1 << 1)
#define UART_STATUS_RX_READY     (1 << 2)
#define UART_STATUS_RX_OVERRUN   (1 << 3)

struct uart_kv32_config {
    uint32_t base;
    uint32_t sys_clk_freq;
    uint32_t baud_rate;
};

struct uart_kv32_data {
    /* Runtime data if needed */
};

static inline uint32_t uart_kv32_read(const struct device *dev, uint32_t offset)
{
    const struct uart_kv32_config *config = dev->config;
    return sys_read32(config->base + offset);
}

static inline void uart_kv32_write(const struct device *dev, uint32_t offset, uint32_t val)
{
    const struct uart_kv32_config *config = dev->config;
    sys_write32(val, config->base + offset);
}

static int uart_kv32_poll_in(const struct device *dev, unsigned char *c)
{
    uint32_t status;

    /* Check if RX data is available */
    status = uart_kv32_read(dev, UART_REG_STATUS);
    if (!(status & UART_STATUS_RX_READY)) {
        return -1;  /* No data available */
    }

    /* Read character from RX data register */
    *c = (unsigned char)uart_kv32_read(dev, UART_REG_RX_DATA);

    return 0;
}

static void uart_kv32_poll_out(const struct device *dev, unsigned char c)
{
    uint32_t status;

    /* Wait until TX FIFO is not full */
    do {
        status = uart_kv32_read(dev, UART_REG_STATUS);
    } while (status & UART_STATUS_TX_FULL);

    /* Write character to TX data register */
    uart_kv32_write(dev, UART_REG_TX_DATA, (uint32_t)c);
}

static int uart_kv32_err_check(const struct device *dev)
{
    /* Simple UART - no error checking */
    return 0;
}

static int uart_kv32_init(const struct device *dev)
{
    const struct uart_kv32_config *config = dev->config;
    uint32_t divisor;

    /* Calculate baud rate divisor
     * divisor = sys_clk_freq / baud_rate
     * For 50 MHz clock and 115200 baud: 50000000 / 115200 = 434
     */
    divisor = config->sys_clk_freq / config->baud_rate;

    /* Set baud rate divisor */
    uart_kv32_write(dev, UART_REG_BAUD_DIV, divisor);

    return 0;
}

static const struct uart_driver_api uart_kv32_driver_api = {
    .poll_in = uart_kv32_poll_in,
    .poll_out = uart_kv32_poll_out,
    .err_check = uart_kv32_err_check,
};

/* Device instantiation macro */
#define UART_KV32_INIT(n)                                           \
    static const struct uart_kv32_config uart_kv32_cfg_##n = { \
        .base = DT_INST_REG_ADDR(n),                               \
        .sys_clk_freq = DT_INST_PROP(n, clock_frequency),         \
        .baud_rate = DT_INST_PROP(n, current_speed),              \
    };                                                                  \
                                                                        \
    static struct uart_kv32_data uart_kv32_data_##n;           \
                                                                        \
    DEVICE_DT_INST_DEFINE(n,                                           \
                uart_kv32_init,                            \
                NULL,                                          \
                &uart_kv32_data_##n,                       \
                &uart_kv32_cfg_##n,                        \
                PRE_KERNEL_1,                                  \
                CONFIG_SERIAL_INIT_PRIORITY,                   \
                &uart_kv32_driver_api);

/* Instantiate UART devices */
DT_INST_FOREACH_STATUS_OKAY(UART_KV32_INIT)

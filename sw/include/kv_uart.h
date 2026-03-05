/**
 * @file kv_uart.h
 * @brief UART driver — transmit/receive, polling and interrupt-driven modes.
 *
 * Header-only inline driver for the kv32 AXI UART peripheral at
 * ::KV_UART_BASE.  Pair with kv_plic.h for interrupt-driven use.
 * @see axi_uart.sv
 * @ingroup drivers
 */

#ifndef KV_UART_H
#define KV_UART_H

#include <stdint.h>
#include "kv_platform.h"

/** @defgroup drivers Peripheral Driver API
 * @{ */

/* ─── register accessors ──────────────────────────────────────────── */
#define KV_UART_DATA    KV_REG32(KV_UART_BASE, KV_UART_DATA_OFF)
#define KV_UART_STATUS  KV_REG32(KV_UART_BASE, KV_UART_STATUS_OFF)
#define KV_UART_IE      KV_REG32(KV_UART_BASE, KV_UART_IE_OFF)
#define KV_UART_IS      KV_REG32(KV_UART_BASE, KV_UART_IS_OFF)
#define KV_UART_LEVEL   KV_REG32(KV_UART_BASE, KV_UART_LEVEL_OFF)
#define KV_UART_CTRL    KV_REG32(KV_UART_BASE, KV_UART_CTRL_OFF)

/* ─── init ────────────────────────────────────────────────────────── */

/** @brief Set the baud-rate divisor and disable interrupts.
 * @param baud_div Pre-computed divisor: `sys_clk_hz / (baud_rate * 8) - 1`. */
static inline void kv_uart_init(uint32_t baud_div)
{
    KV_UART_LEVEL = baud_div;
    KV_UART_IE    = 0u;          /* interrupts off by default */
}

/* ─── status queries ──────────────────────────────────────────────── */

/** @brief Return non-zero if the TX FIFO is full (cannot write right now). */
static inline int kv_uart_tx_busy(void)
{
    return (KV_UART_STATUS & KV_UART_ST_TX_BUSY) != 0;
}

/** @brief Return non-zero if at least one byte is waiting in the RX FIFO. */
static inline int kv_uart_rx_ready(void)
{
    return (KV_UART_STATUS & KV_UART_ST_RX_READY) != 0;
}

/* ─── polling TX ──────────────────────────────────────────────────── */

/** @brief Block until the TX FIFO has room, then transmit one byte.
 * @param c Byte to transmit. */
static inline void kv_uart_putc(char c)
{
    while (kv_uart_tx_busy()) {}
    KV_UART_DATA = (uint32_t)(uint8_t)c;
}

/** @brief Transmit a NUL-terminated string.
 * @param s Pointer to the string. */
static inline void kv_uart_puts(const char *s)
{
    while (*s) kv_uart_putc(*s++);
}

/** @brief Transmit @p len bytes from @p buf.
 * @param buf Source buffer.
 * @param len Number of bytes to transmit. */
static inline void kv_uart_write(const uint8_t *buf, uint32_t len)
{
    for (uint32_t i = 0; i < len; i++)
        kv_uart_putc((char)buf[i]);
}

/* ─── polling RX ──────────────────────────────────────────────────── */

/** @brief Return the next byte from the RX FIFO, or -1 if empty.
 * @return Received byte (0–255) or -1 when the FIFO is empty. */
static inline int kv_uart_getc(void)
{
    if (!kv_uart_rx_ready()) return -1;
    return (int)(KV_UART_DATA & 0xFFu);
}

/** @brief Block until a byte is received, then return it.
 * @return Received byte (0–255). */
static inline uint8_t kv_uart_getc_blocking(void)
{
    while (!kv_uart_rx_ready()) {}
    return (uint8_t)(KV_UART_DATA & 0xFFu);
}

/* ─── interrupt control ───────────────────────────────────────────── */

/* Enable UART interrupt sources (KV_UART_IE_TX_EMPTY | KV_UART_IE_RX_READY). */
static inline void kv_uart_irq_enable(uint32_t mask)
{
    KV_UART_IE |= mask;
}

/* Disable UART interrupt sources. */
static inline void kv_uart_irq_disable(uint32_t mask)
{
    KV_UART_IE &= ~mask;
}

/* Read and clear the interrupt status register (W1C). */
static inline uint32_t kv_uart_irq_status(void)
{
    uint32_t s = KV_UART_IS;
    KV_UART_IS = s;   /* W1C clear */
    return s;
}

/* ─── loopback control ───────────────────────────────────────────── */

/* Enable internal TX→RX loopback (hardware test mode).
 * While enabled, every transmitted byte is fed back to the RX path
 * without leaving the chip; the external uart_rx pin is ignored. */
static inline void kv_uart_loopback_enable(void)
{
    KV_UART_CTRL |= KV_UART_CTRL_LOOPBACK;
}

/* Restore normal operation; RX reads from the external uart_rx pin. */
static inline void kv_uart_loopback_disable(void)
{
    KV_UART_CTRL &= ~KV_UART_CTRL_LOOPBACK;
}

/* ─── capability register ────────────────────────────────────────── */

#define KV_UART_CAP     KV_REG32(KV_UART_BASE, KV_UART_CAP_OFF)

/* Read capability register (hardware configuration) */
static inline uint32_t kv_uart_get_capability(void)
{
    return KV_UART_CAP;
}

/* Get TX FIFO depth from capability register */
static inline uint32_t kv_uart_get_tx_fifo_depth(void)
{
    return KV_UART_CAP & 0xFF;  // [7:0]
}

/* Get RX FIFO depth from capability register */
static inline uint32_t kv_uart_get_rx_fifo_depth(void)
{
    return (KV_UART_CAP >> 8) & 0xFF;  // [15:8]
}

/* Get UART version from capability register */
static inline uint32_t kv_uart_get_version(void)
{
    return (KV_UART_CAP >> 16) & 0xFFFF;  // [31:16]
}

/** @} */
#endif /* KV_UART_H */

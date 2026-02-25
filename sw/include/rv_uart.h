/*
 * rv_uart.h – UART driver (polling + interrupt-mode helpers)
 *
 * Hardware: axi_uart.sv at RV_UART_BASE
 *   Register map – see rv_platform.h (RV_UART_*)
 *
 * The driver is intentionally header-only (all inline) so that it adds
 * zero code when not called.  For interrupt-driven use, pair with
 * rv_plic.h (source RV_PLIC_SRC_UART).
 */
#ifndef RV_UART_H
#define RV_UART_H

#include <stdint.h>
#include "rv_platform.h"

/* ─── register accessors ──────────────────────────────────────────── */
#define RV_UART_DATA    RV_REG32(RV_UART_BASE, RV_UART_DATA_OFF)
#define RV_UART_STATUS  RV_REG32(RV_UART_BASE, RV_UART_STATUS_OFF)
#define RV_UART_IE      RV_REG32(RV_UART_BASE, RV_UART_IE_OFF)
#define RV_UART_IS      RV_REG32(RV_UART_BASE, RV_UART_IS_OFF)
#define RV_UART_LEVEL   RV_REG32(RV_UART_BASE, RV_UART_LEVEL_OFF)
#define RV_UART_CTRL    RV_REG32(RV_UART_BASE, RV_UART_CTRL_OFF)

/* ─── init ────────────────────────────────────────────────────────── */

/* Set the baud-rate divisor.
 * baud_div = sys_clk_hz / (baud_rate * 8) - 1  (hardware-specific formula) */
static inline void rv_uart_init(uint32_t baud_div)
{
    RV_UART_LEVEL = baud_div;
    RV_UART_IE    = 0u;          /* interrupts off by default */
}

/* ─── status queries ──────────────────────────────────────────────── */

/* Return non-zero if the TX FIFO is full (cannot write right now). */
static inline int rv_uart_tx_busy(void)
{
    return (RV_UART_STATUS & RV_UART_ST_TX_BUSY) != 0;
}

/* Return non-zero if at least one byte is waiting in the RX FIFO. */
static inline int rv_uart_rx_ready(void)
{
    return (RV_UART_STATUS & RV_UART_ST_RX_READY) != 0;
}

/* ─── polling TX ──────────────────────────────────────────────────── */

/* Block until the TX FIFO has room, then transmit one byte. */
static inline void rv_uart_putc(char c)
{
    while (rv_uart_tx_busy()) {}
    RV_UART_DATA = (uint32_t)(uint8_t)c;
}

/* Transmit a NUL-terminated string. */
static inline void rv_uart_puts(const char *s)
{
    while (*s) rv_uart_putc(*s++);
}

/* Transmit 'len' bytes from buf. */
static inline void rv_uart_write(const uint8_t *buf, uint32_t len)
{
    for (uint32_t i = 0; i < len; i++)
        rv_uart_putc((char)buf[i]);
}

/* ─── polling RX ──────────────────────────────────────────────────── */

/* Return the next byte from the RX FIFO, or -1 if empty. */
static inline int rv_uart_getc(void)
{
    if (!rv_uart_rx_ready()) return -1;
    return (int)(RV_UART_DATA & 0xFFu);
}

/* Block until a byte is received, then return it. */
static inline uint8_t rv_uart_getc_blocking(void)
{
    while (!rv_uart_rx_ready()) {}
    return (uint8_t)(RV_UART_DATA & 0xFFu);
}

/* ─── interrupt control ───────────────────────────────────────────── */

/* Enable UART interrupt sources (RV_UART_IE_TX_EMPTY | RV_UART_IE_RX_READY). */
static inline void rv_uart_irq_enable(uint32_t mask)
{
    RV_UART_IE |= mask;
}

/* Disable UART interrupt sources. */
static inline void rv_uart_irq_disable(uint32_t mask)
{
    RV_UART_IE &= ~mask;
}

/* Read and clear the interrupt status register (W1C). */
static inline uint32_t rv_uart_irq_status(void)
{
    uint32_t s = RV_UART_IS;
    RV_UART_IS = s;   /* W1C clear */
    return s;
}

/* ─── loopback control ───────────────────────────────────────────── */

/* Enable internal TX→RX loopback (hardware test mode).
 * While enabled, every transmitted byte is fed back to the RX path
 * without leaving the chip; the external uart_rx pin is ignored. */
static inline void rv_uart_loopback_enable(void)
{
    RV_UART_CTRL |= RV_UART_CTRL_LOOPBACK;
}

/* Restore normal operation; RX reads from the external uart_rx pin. */
static inline void rv_uart_loopback_disable(void)
{
    RV_UART_CTRL &= ~RV_UART_CTRL_LOOPBACK;
}

#endif /* RV_UART_H */

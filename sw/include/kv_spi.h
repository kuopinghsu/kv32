/*
 * kv_spi.h – SPI master driver (polling + interrupt-mode helpers)
 *
 * Hardware: axi_spi.sv at KV_SPI_BASE
 *   Register map – see kv_platform.h (KV_SPI_*)
 *
 * All functions are inlined.  For interrupt-driven use, pair with
 * kv_plic.h (source KV_PLIC_SRC_SPI).
 */
#ifndef KV_SPI_H
#define KV_SPI_H

#include <stdint.h>
#include "kv_platform.h"

/* ─── register accessors ──────────────────────────────────────────── */
#define KV_SPI_CTRL    KV_REG32(KV_SPI_BASE, KV_SPI_CTRL_OFF)
#define KV_SPI_DIV     KV_REG32(KV_SPI_BASE, KV_SPI_DIV_OFF)
#define KV_SPI_TX      KV_REG32(KV_SPI_BASE, KV_SPI_TX_OFF)
#define KV_SPI_RX      KV_REG32(KV_SPI_BASE, KV_SPI_RX_OFF)
#define KV_SPI_STATUS  KV_REG32(KV_SPI_BASE, KV_SPI_STATUS_OFF)
#define KV_SPI_IE      KV_REG32(KV_SPI_BASE, KV_SPI_IE_OFF)
#define KV_SPI_IS      KV_REG32(KV_SPI_BASE, KV_SPI_IS_OFF)

/* ─── init ────────────────────────────────────────────────────────── */

/* Initialise the SPI controller.
 *
 * clk_div: SCK frequency = sys_clk / (2 * (clk_div + 1))
 *   e.g. 1 MHz at 100 MHz system clock → clk_div = 49
 *
 * mode: KV_SPI_MODE0..MODE3 */
static inline void kv_spi_init(uint32_t clk_div, uint32_t mode)
{
    uint32_t ctrl = KV_SPI_CTRL_ENABLE | KV_SPI_CTRL_CS_ALL;  /* all CS idle */
    if (mode & 1u) ctrl |= KV_SPI_CTRL_CPHA;
    if (mode & 2u) ctrl |= KV_SPI_CTRL_CPOL;
    KV_SPI_DIV  = clk_div;
    KV_SPI_CTRL = ctrl;
    KV_SPI_IE   = 0u;
}

/* ─── status helpers ──────────────────────────────────────────────── */

static inline int kv_spi_busy(void)    { return (KV_SPI_STATUS & KV_SPI_ST_BUSY)     != 0; }
static inline int kv_spi_tx_ready(void){ return (KV_SPI_STATUS & KV_SPI_ST_TX_READY) != 0; }
static inline int kv_spi_rx_valid(void){ return (KV_SPI_STATUS & KV_SPI_ST_RX_VALID) != 0; }

static inline void kv_spi_wait_ready(void)  { while (kv_spi_busy()) {} }
static inline void kv_spi_wait_tx_ready(void){ while (!kv_spi_tx_ready()) {} }

/* ─── chip-select control ─────────────────────────────────────────── */

/* Assert CS line n (0-3, active-low in hardware). */
static inline void kv_spi_cs_select(uint32_t n)
{
    uint32_t ctrl = KV_SPI_CTRL;
    ctrl |= KV_SPI_CTRL_CS_ALL;          /* deassert all first */
    ctrl &= ~KV_SPI_CTRL_CS_BIT(n);      /* assert chosen CS   */
    KV_SPI_CTRL = ctrl;
}

/* Deassert all CS lines. */
static inline void kv_spi_cs_deselect(void)
{
    KV_SPI_CTRL |= KV_SPI_CTRL_CS_ALL;
}

/* ─── single-byte transfer ────────────────────────────────────────── */

/* Full-duplex transfer: send 'data', return received byte.
 * Waits for TX ready, sends, then waits for busy → idle cycle. */
static inline uint8_t kv_spi_transfer(uint8_t data)
{
    kv_spi_wait_ready();
    KV_SPI_TX = data;
    /* Wait until controller accepts the byte and goes busy */
    while (!kv_spi_busy()) {}
    /* Wait until transfer completes */
    while (kv_spi_busy()) {}
    return (uint8_t)(KV_SPI_RX & 0xFFu);
}

/* ─── burst helpers ───────────────────────────────────────────────── */

/* Transmit 'len' bytes from tx_buf; receive into rx_buf (may be NULL). */
static inline void kv_spi_transfer_buf(const uint8_t *tx_buf, uint8_t *rx_buf,
                                       uint32_t len)
{
    for (uint32_t i = 0; i < len; i++) {
        uint8_t rx = kv_spi_transfer(tx_buf ? tx_buf[i] : 0xFFu);
        if (rx_buf) rx_buf[i] = rx;
    }
}

/* Read 'len' bytes by clocking out 0xFF bytes (dummy TX). */
static inline void kv_spi_read_buf(uint8_t *rx_buf, uint32_t len)
{
    kv_spi_transfer_buf(0, rx_buf, len);
}

/* ─── interrupt control ───────────────────────────────────────────── */

static inline void kv_spi_irq_enable(uint32_t mask)  { KV_SPI_IE |=  mask; }
static inline void kv_spi_irq_disable(uint32_t mask) { KV_SPI_IE &= ~mask; }

static inline uint32_t kv_spi_irq_status(void)
{
    uint32_t s = KV_SPI_IS;
    KV_SPI_IS = s;   /* W1C */
    return s;
}

/* ─── loopback control ───────────────────────────────────────────── */

/* Enable internal MOSI→MISO loopback (hardware test mode).
 * Every bit shifted out on MOSI is immediately sampled back on MISO;
 * the external spi_miso pin is ignored. */
static inline void kv_spi_loopback_enable(void)
{
    KV_SPI_CTRL |= KV_SPI_CTRL_LOOPBACK;
}

/* Restore normal operation; MISO reads from the external spi_miso pin. */
static inline void kv_spi_loopback_disable(void)
{
    KV_SPI_CTRL &= ~KV_SPI_CTRL_LOOPBACK;
}

/* ─── capability register ────────────────────────────────────────── */

#define KV_SPI_CAP      KV_REG32(KV_SPI_BASE, KV_SPI_CAP_OFF)

/* Read capability register (hardware configuration) */
static inline uint32_t kv_spi_get_capability(void)
{
    return KV_SPI_CAP;
}

/* Get TX FIFO depth from capability register */
static inline uint32_t kv_spi_get_tx_fifo_depth(void)
{
    return KV_SPI_CAP & 0xFF;  // [7:0]
}

/* Get RX FIFO depth from capability register */
static inline uint32_t kv_spi_get_rx_fifo_depth(void)
{
    return (KV_SPI_CAP >> 8) & 0xFF;  // [15:8]
}

/* Get number of chip selects from capability register */
static inline uint32_t kv_spi_get_num_cs(void)
{
    return (KV_SPI_CAP >> 16) & 0xFF;  // [23:16]
}

/* Get SPI version from capability register */
static inline uint32_t kv_spi_get_version(void)
{
    return (KV_SPI_CAP >> 24) & 0xFF;  // [31:24]
}

#endif /* KV_SPI_H */

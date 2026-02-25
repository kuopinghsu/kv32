/*
 * rv_spi.h – SPI master driver (polling + interrupt-mode helpers)
 *
 * Hardware: axi_spi.sv at RV_SPI_BASE
 *   Register map – see rv_platform.h (RV_SPI_*)
 *
 * All functions are inlined.  For interrupt-driven use, pair with
 * rv_plic.h (source RV_PLIC_SRC_SPI).
 */
#ifndef RV_SPI_H
#define RV_SPI_H

#include <stdint.h>
#include "rv_platform.h"

/* ─── register accessors ──────────────────────────────────────────── */
#define RV_SPI_CTRL    RV_REG32(RV_SPI_BASE, RV_SPI_CTRL_OFF)
#define RV_SPI_DIV     RV_REG32(RV_SPI_BASE, RV_SPI_DIV_OFF)
#define RV_SPI_TX      RV_REG32(RV_SPI_BASE, RV_SPI_TX_OFF)
#define RV_SPI_RX      RV_REG32(RV_SPI_BASE, RV_SPI_RX_OFF)
#define RV_SPI_STATUS  RV_REG32(RV_SPI_BASE, RV_SPI_STATUS_OFF)
#define RV_SPI_IE      RV_REG32(RV_SPI_BASE, RV_SPI_IE_OFF)
#define RV_SPI_IS      RV_REG32(RV_SPI_BASE, RV_SPI_IS_OFF)

/* ─── init ────────────────────────────────────────────────────────── */

/* Initialise the SPI controller.
 *
 * clk_div: SCK frequency = sys_clk / (2 * (clk_div + 1))
 *   e.g. 1 MHz at 100 MHz system clock → clk_div = 49
 *
 * mode: RV_SPI_MODE0..MODE3 */
static inline void rv_spi_init(uint32_t clk_div, uint32_t mode)
{
    uint32_t ctrl = RV_SPI_CTRL_ENABLE | RV_SPI_CTRL_CS_ALL;  /* all CS idle */
    if (mode & 1u) ctrl |= RV_SPI_CTRL_CPHA;
    if (mode & 2u) ctrl |= RV_SPI_CTRL_CPOL;
    RV_SPI_DIV  = clk_div;
    RV_SPI_CTRL = ctrl;
    RV_SPI_IE   = 0u;
}

/* ─── status helpers ──────────────────────────────────────────────── */

static inline int rv_spi_busy(void)    { return (RV_SPI_STATUS & RV_SPI_ST_BUSY)     != 0; }
static inline int rv_spi_tx_ready(void){ return (RV_SPI_STATUS & RV_SPI_ST_TX_READY) != 0; }
static inline int rv_spi_rx_valid(void){ return (RV_SPI_STATUS & RV_SPI_ST_RX_VALID) != 0; }

static inline void rv_spi_wait_ready(void)  { while (rv_spi_busy()) {} }
static inline void rv_spi_wait_tx_ready(void){ while (!rv_spi_tx_ready()) {} }

/* ─── chip-select control ─────────────────────────────────────────── */

/* Assert CS line n (0-3, active-low in hardware). */
static inline void rv_spi_cs_select(uint32_t n)
{
    uint32_t ctrl = RV_SPI_CTRL;
    ctrl |= RV_SPI_CTRL_CS_ALL;          /* deassert all first */
    ctrl &= ~RV_SPI_CTRL_CS_BIT(n);      /* assert chosen CS   */
    RV_SPI_CTRL = ctrl;
}

/* Deassert all CS lines. */
static inline void rv_spi_cs_deselect(void)
{
    RV_SPI_CTRL |= RV_SPI_CTRL_CS_ALL;
}

/* ─── single-byte transfer ────────────────────────────────────────── */

/* Full-duplex transfer: send 'data', return received byte.
 * Waits for TX ready, sends, then waits for busy → idle cycle. */
static inline uint8_t rv_spi_transfer(uint8_t data)
{
    rv_spi_wait_ready();
    RV_SPI_TX = data;
    /* Wait until controller accepts the byte and goes busy */
    while (!rv_spi_busy()) {}
    /* Wait until transfer completes */
    while (rv_spi_busy()) {}
    return (uint8_t)(RV_SPI_RX & 0xFFu);
}

/* ─── burst helpers ───────────────────────────────────────────────── */

/* Transmit 'len' bytes from tx_buf; receive into rx_buf (may be NULL). */
static inline void rv_spi_transfer_buf(const uint8_t *tx_buf, uint8_t *rx_buf,
                                       uint32_t len)
{
    for (uint32_t i = 0; i < len; i++) {
        uint8_t rx = rv_spi_transfer(tx_buf ? tx_buf[i] : 0xFFu);
        if (rx_buf) rx_buf[i] = rx;
    }
}

/* Read 'len' bytes by clocking out 0xFF bytes (dummy TX). */
static inline void rv_spi_read_buf(uint8_t *rx_buf, uint32_t len)
{
    rv_spi_transfer_buf(0, rx_buf, len);
}

/* ─── interrupt control ───────────────────────────────────────────── */

static inline void rv_spi_irq_enable(uint32_t mask)  { RV_SPI_IE |=  mask; }
static inline void rv_spi_irq_disable(uint32_t mask) { RV_SPI_IE &= ~mask; }

static inline uint32_t rv_spi_irq_status(void)
{
    uint32_t s = RV_SPI_IS;
    RV_SPI_IS = s;   /* W1C */
    return s;
}

/* ─── loopback control ───────────────────────────────────────────── */

/* Enable internal MOSI→MISO loopback (hardware test mode).
 * Every bit shifted out on MOSI is immediately sampled back on MISO;
 * the external spi_miso pin is ignored. */
static inline void rv_spi_loopback_enable(void)
{
    RV_SPI_CTRL |= RV_SPI_CTRL_LOOPBACK;
}

/* Restore normal operation; MISO reads from the external spi_miso pin. */
static inline void rv_spi_loopback_disable(void)
{
    RV_SPI_CTRL &= ~RV_SPI_CTRL_LOOPBACK;
}

#endif /* RV_SPI_H */

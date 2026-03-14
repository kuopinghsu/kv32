/**
 * @file kv_cap.h
 * @brief Expected capability register values for all KV32 AXI peripherals.
 *
 * Constants mirror the RTL @c localparam @c CAPABILITY_REG definitions.
 * Test code compares these against actual register reads to verify that
 * the hardware matches the SDK version expectations.
 * @ingroup platform
 */

#ifndef KV_CAP_H
#define KV_CAP_H

#include <stdint.h>

/* ── UART capability (offset KV_UART_CAP_OFF = 0x18) ─────────────────────
 * RTL: UART_VERSION=0x0001, FIFO_DEPTH=16 (both TX and RX)
 * CAPABILITY_REG = {UART_VERSION, 8'(FIFO_DEPTH), 8'(FIFO_DEPTH)}
 */
#define KV_CAP_UART_VERSION        0x0001u
#define KV_CAP_UART_TX_FIFO_DEPTH  16u
#define KV_CAP_UART_RX_FIFO_DEPTH  16u
#define KV_CAP_UART_VALUE \
    ((uint32_t)(KV_CAP_UART_VERSION      << 16) | \
     (uint32_t)(KV_CAP_UART_RX_FIFO_DEPTH << 8) | \
     (uint32_t)(KV_CAP_UART_TX_FIFO_DEPTH))
/* Expected: 0x00011010 */

/* ── I2C capability (offset KV_I2C_CAP_OFF = 0x1C) ──────────────────────
 * RTL: I2C_VERSION=0x0001, FIFO_DEPTH=8 (both TX and RX)
 * CAPABILITY_REG = {I2C_VERSION, 8'(FIFO_DEPTH), 8'(FIFO_DEPTH)}
 */
#define KV_CAP_I2C_VERSION         0x0001u
#define KV_CAP_I2C_TX_FIFO_DEPTH   8u
#define KV_CAP_I2C_RX_FIFO_DEPTH   8u
#define KV_CAP_I2C_VALUE \
    ((uint32_t)(KV_CAP_I2C_VERSION       << 16) | \
     (uint32_t)(KV_CAP_I2C_RX_FIFO_DEPTH <<  8) | \
     (uint32_t)(KV_CAP_I2C_TX_FIFO_DEPTH))
/* Expected: 0x00010808 */

/* ── SPI capability (offset KV_SPI_CAP_OFF = 0x1C) ──────────────────────
 * RTL: SPI_VERSION=0x0001, 4 chip-selects, FIFO_DEPTH=8 (both TX and RX)
 * CAPABILITY_REG = {SPI_VERSION, 4'd4, 4'(FIFO_DEPTH), 8'(FIFO_DEPTH)}
 *   [31:16] = VERSION
 *   [23:20] = NUM_CS  (4 bits)
 *   [19:16] = RX_FIFO (4 bits, lower nibble of the packed byte)
 *   [7:0]   = TX_FIFO_DEPTH (full byte)
 */
#define KV_CAP_SPI_VERSION         0x0001u
#define KV_CAP_SPI_NUM_CS          4u
#define KV_CAP_SPI_TX_FIFO_DEPTH   8u
#define KV_CAP_SPI_RX_FIFO_DEPTH   8u
#define KV_CAP_SPI_VALUE \
    ((uint32_t)(KV_CAP_SPI_VERSION        << 16) | \
     (uint32_t)((KV_CAP_SPI_NUM_CS & 0xFu) << 20) | \
     (uint32_t)((KV_CAP_SPI_RX_FIFO_DEPTH & 0xFu) << 16) | \
     (uint32_t)(KV_CAP_SPI_TX_FIFO_DEPTH))
/* Expected: 0x00014808 */

/* ── DMA capability (offset KV_DMA_CAP_OFF = 0xF0C) ─────────────────────
 * RTL: DMA_VERSION=0x0001, NUM_CHANNELS=4, MAX_BURST_LEN=16
 * CAPABILITY_REG = {DMA_VERSION, 8'(NUM_CHANNELS), 8'(MAX_BURST_LEN)}
 */
#define KV_CAP_DMA_VERSION         0x0001u
#define KV_CAP_DMA_NUM_CHANNELS    4u
#define KV_CAP_DMA_MAX_BURST_LEN   16u
#define KV_CAP_DMA_VALUE \
    ((uint32_t)(KV_CAP_DMA_VERSION       << 16) | \
     (uint32_t)(KV_CAP_DMA_NUM_CHANNELS  <<  8) | \
     (uint32_t)(KV_CAP_DMA_MAX_BURST_LEN))
/* Expected: 0x00010410 */

/* ── GPIO capability (offset KV_GPIO_CAP_OFF = 0xA0) ────────────────────
 * RTL: GPIO_VERSION=0x0001, NUM_PINS=4, NUM_REG_BANKS=ceil(4/32)=1
 * CAPABILITY_REG = {GPIO_VERSION, 8'(NUM_REG_BANKS), 8'(NUM_PINS)}
 */
#define KV_CAP_GPIO_VERSION        0x0001u
#define KV_CAP_GPIO_NUM_PINS       4u
#define KV_CAP_GPIO_NUM_BANKS      1u
#define KV_CAP_GPIO_VALUE \
    ((uint32_t)(KV_CAP_GPIO_VERSION    << 16) | \
     (uint32_t)(KV_CAP_GPIO_NUM_BANKS  <<  8) | \
     (uint32_t)(KV_CAP_GPIO_NUM_PINS))
/* Expected: 0x00010104 */

/* ── Timer capability (offset KV_TIMER_CAP_OFF = 0x88) ──────────────────
 * RTL: TIMER_VERSION=0x0001, 4 channels, 32-bit counters
 * CAPABILITY_REG = {TIMER_VERSION, 8'd4, 8'd32}
 */
#define KV_CAP_TIMER_VERSION        0x0001u
#define KV_CAP_TIMER_NUM_CHANNELS   4u
#define KV_CAP_TIMER_COUNTER_WIDTH  32u
#define KV_CAP_TIMER_VALUE \
    ((uint32_t)(KV_CAP_TIMER_VERSION        << 16) | \
     (uint32_t)(KV_CAP_TIMER_NUM_CHANNELS   <<  8) | \
     (uint32_t)(KV_CAP_TIMER_COUNTER_WIDTH))
/* Expected: 0x00010420 */

/* ── Cache diagnostic capability CSRs (custom machine CSRs) ─────────────
 * Layout: [31:24]=WAYS [23:16]=NUM_SETS [15:8]=WORDS_PER_LINE [7:0]=TAG_BITS
 * Default SoC configuration (Makefile):
 *   I-cache: 2 ways, 64 sets, 8 words/line, 21-bit tag
 *   D-cache: 2 ways, 64 sets, 8 words/line, 21-bit tag
 */
#define KV_CAP_ICAP_VALUE  ((uint32_t)((2u << 24) | (64u << 16) | (8u << 8) | 21u))
#define KV_CAP_DCAP_VALUE  ((uint32_t)((2u << 24) | (64u << 16) | (8u << 8) | 21u))

#endif /* KV_CAP_H */

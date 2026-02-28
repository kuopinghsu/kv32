/*
 * kv_i2c.h – I2C master driver (polling + interrupt-mode helpers)
 *
 * Hardware: axi_i2c.sv at KV_I2C_BASE
 *   Register map – see kv_platform.h (KV_I2C_*)
 *
 * All functions are inlined.  For interrupt-driven use, pair with
 * kv_plic.h (source KV_PLIC_SRC_I2C).
 *
 * Return values:
 *   0   – success
 *  -1   – device did not ACK the address
 *  -2   – device did not ACK a data byte
 *  -3   – other error / NACK
 */
#ifndef KV_I2C_H
#define KV_I2C_H

#include <stdint.h>
#include "kv_platform.h"

/* Ensure a peripheral register write is visible before reading STATUS.
 * FENCE drains the store buffer in RTL; in the SW simulator it is a no-op. */
#define KV_I2C_FENCE() __asm__ volatile("fence" ::: "memory")

/* ─── register accessors ──────────────────────────────────────────── */
#define KV_I2C_CTRL    KV_REG32(KV_I2C_BASE, KV_I2C_CTRL_OFF)
#define KV_I2C_DIV     KV_REG32(KV_I2C_BASE, KV_I2C_DIV_OFF)
#define KV_I2C_TX      KV_REG32(KV_I2C_BASE, KV_I2C_TX_OFF)
#define KV_I2C_RX      KV_REG32(KV_I2C_BASE, KV_I2C_RX_OFF)
#define KV_I2C_STATUS  KV_REG32(KV_I2C_BASE, KV_I2C_STATUS_OFF)
#define KV_I2C_IE      KV_REG32(KV_I2C_BASE, KV_I2C_IE_OFF)
#define KV_I2C_IS      KV_REG32(KV_I2C_BASE, KV_I2C_IS_OFF)

/* ─── init ────────────────────────────────────────────────────────── */

/* Initialise the I2C controller.
 * clk_div: SCL period = sys_clk / (4 * (clk_div + 1))
 *   For 100 kHz at 100 MHz: clk_div = 249
 *   For 400 kHz at 100 MHz: clk_div =  62 */
static inline void kv_i2c_init(uint32_t clk_div)
{
    KV_I2C_DIV  = clk_div;
    KV_I2C_CTRL = KV_I2C_CTRL_ENABLE;
    KV_I2C_IE   = 0u;    /* interrupts off by default */
}

/* ─── status helpers ──────────────────────────────────────────────── */

static inline int kv_i2c_busy(void)
{
    return (KV_I2C_STATUS & KV_I2C_ST_BUSY) != 0;
}

static inline int kv_i2c_ack_received(void)
{
    return (KV_I2C_STATUS & KV_I2C_ST_ACK_RECV) != 0;
}

static inline int kv_i2c_rx_valid(void)
{
    return (KV_I2C_STATUS & KV_I2C_ST_RX_VALID) != 0;
}

/* Block until the controller is idle. */
static inline void kv_i2c_wait_ready(void)
{
    while (kv_i2c_busy()) {}
}

/* ─── bus operations ──────────────────────────────────────────────── */

/* Issue a START condition. */
static inline void kv_i2c_start(void)
{
    kv_i2c_wait_ready();
    KV_I2C_CTRL = KV_I2C_CTRL_ENABLE | KV_I2C_CTRL_START;
    KV_I2C_FENCE();
    kv_i2c_wait_ready();
}

/* Issue a STOP condition. */
static inline void kv_i2c_stop(void)
{
    kv_i2c_wait_ready();
    KV_I2C_CTRL = KV_I2C_CTRL_ENABLE | KV_I2C_CTRL_STOP;
    KV_I2C_FENCE();
    kv_i2c_wait_ready();
}

/* Write one byte and return 0 if ACKed, -1 if NACKed. */
static inline int kv_i2c_write_byte(uint8_t data)
{
    kv_i2c_wait_ready();
    KV_I2C_TX = data;
    KV_I2C_FENCE();
    kv_i2c_wait_ready();
    return kv_i2c_ack_received() ? 0 : -1;
}

/* Receive one byte.  send_ack=1 → send ACK; send_ack=0 → send NACK
 * (use NACK for the last byte of a read sequence). */
static inline uint8_t kv_i2c_read_byte(int send_ack)
{
    uint32_t ctrl = KV_I2C_CTRL_ENABLE | KV_I2C_CTRL_READ;
    if (!send_ack) ctrl |= KV_I2C_CTRL_NACK;
    kv_i2c_wait_ready();
    KV_I2C_CTRL = ctrl;
    KV_I2C_FENCE();
    kv_i2c_wait_ready();
    return (uint8_t)(KV_I2C_RX & 0xFFu);
}

/* ─── composite helpers ───────────────────────────────────────────── */

/* Write 'len' bytes to I2C device at 7-bit address 'addr'.
 * Issues START, address byte (W), data, STOP.
 * Returns 0 on success, negative on NACK or error. */
static inline int kv_i2c_master_write(uint8_t addr, const uint8_t *buf, uint32_t len)
{
    kv_i2c_start();
    if (kv_i2c_write_byte((uint8_t)((addr << 1) | 0u)) < 0) { kv_i2c_stop(); return -1; }
    for (uint32_t i = 0; i < len; i++) {
        if (kv_i2c_write_byte(buf[i]) < 0) { kv_i2c_stop(); return -2; }
    }
    kv_i2c_stop();
    return 0;
}

/* Read 'len' bytes from I2C device at 7-bit address 'addr' into buf.
 * Issues START, address byte (R), data bytes with ACK/NACK, STOP.
 * Returns 0 on success, negative on NACK or error. */
static inline int kv_i2c_master_read(uint8_t addr, uint8_t *buf, uint32_t len)
{
    kv_i2c_start();
    if (kv_i2c_write_byte((uint8_t)((addr << 1) | 1u)) < 0) { kv_i2c_stop(); return -1; }
    for (uint32_t i = 0; i < len; i++) {
        buf[i] = kv_i2c_read_byte(i < len - 1u ? 1 : 0);   /* NACK on last byte */
    }
    kv_i2c_stop();
    return 0;
}

/* ─── interrupt control ───────────────────────────────────────────── */

static inline void kv_i2c_irq_enable(uint32_t mask)  { KV_I2C_IE |=  mask; }
static inline void kv_i2c_irq_disable(uint32_t mask) { KV_I2C_IE &= ~mask; }

static inline uint32_t kv_i2c_irq_status(void)
{
    uint32_t s = KV_I2C_IS;
    KV_I2C_IS = s;   /* W1C */
    return s;
}

/* ─── capability register ────────────────────────────────────────── */

#define KV_I2C_CAP      KV_REG32(KV_I2C_BASE, KV_I2C_CAP_OFF)

/* Read capability register (hardware configuration) */
static inline uint32_t kv_i2c_get_capability(void)
{
    return KV_I2C_CAP;
}

/* Get TX FIFO depth from capability register */
static inline uint32_t kv_i2c_get_tx_fifo_depth(void)
{
    return KV_I2C_CAP & 0xFF;  // [7:0]
}

/* Get RX FIFO depth from capability register */
static inline uint32_t kv_i2c_get_rx_fifo_depth(void)
{
    return (KV_I2C_CAP >> 8) & 0xFF;  // [15:8]
}

/* Get I2C version from capability register */
static inline uint32_t kv_i2c_get_version(void)
{
    return (KV_I2C_CAP >> 16) & 0xFFFF;  // [31:16]
}

#endif /* KV_I2C_H */

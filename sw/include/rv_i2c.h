/*
 * rv_i2c.h – I2C master driver (polling + interrupt-mode helpers)
 *
 * Hardware: axi_i2c.sv at RV_I2C_BASE
 *   Register map – see rv_platform.h (RV_I2C_*)
 *
 * All functions are inlined.  For interrupt-driven use, pair with
 * rv_plic.h (source RV_PLIC_SRC_I2C).
 *
 * Return values:
 *   0   – success
 *  -1   – device did not ACK the address
 *  -2   – device did not ACK a data byte
 *  -3   – other error / NACK
 */
#ifndef RV_I2C_H
#define RV_I2C_H

#include <stdint.h>
#include "rv_platform.h"

/* Ensure a peripheral register write is visible before reading STATUS.
 * FENCE drains the store buffer in RTL; in the SW simulator it is a no-op. */
#define RV_I2C_FENCE() __asm__ volatile("fence" ::: "memory")

/* ─── register accessors ──────────────────────────────────────────── */
#define RV_I2C_CTRL    RV_REG32(RV_I2C_BASE, RV_I2C_CTRL_OFF)
#define RV_I2C_DIV     RV_REG32(RV_I2C_BASE, RV_I2C_DIV_OFF)
#define RV_I2C_TX      RV_REG32(RV_I2C_BASE, RV_I2C_TX_OFF)
#define RV_I2C_RX      RV_REG32(RV_I2C_BASE, RV_I2C_RX_OFF)
#define RV_I2C_STATUS  RV_REG32(RV_I2C_BASE, RV_I2C_STATUS_OFF)
#define RV_I2C_IE      RV_REG32(RV_I2C_BASE, RV_I2C_IE_OFF)
#define RV_I2C_IS      RV_REG32(RV_I2C_BASE, RV_I2C_IS_OFF)

/* ─── init ────────────────────────────────────────────────────────── */

/* Initialise the I2C controller.
 * clk_div: SCL period = sys_clk / (4 * (clk_div + 1))
 *   For 100 kHz at 100 MHz: clk_div = 249
 *   For 400 kHz at 100 MHz: clk_div =  62 */
static inline void rv_i2c_init(uint32_t clk_div)
{
    RV_I2C_DIV  = clk_div;
    RV_I2C_CTRL = RV_I2C_CTRL_ENABLE;
    RV_I2C_IE   = 0u;    /* interrupts off by default */
}

/* ─── status helpers ──────────────────────────────────────────────── */

static inline int rv_i2c_busy(void)
{
    return (RV_I2C_STATUS & RV_I2C_ST_BUSY) != 0;
}

static inline int rv_i2c_ack_received(void)
{
    return (RV_I2C_STATUS & RV_I2C_ST_ACK_RECV) != 0;
}

static inline int rv_i2c_rx_valid(void)
{
    return (RV_I2C_STATUS & RV_I2C_ST_RX_VALID) != 0;
}

/* Block until the controller is idle. */
static inline void rv_i2c_wait_ready(void)
{
    while (rv_i2c_busy()) {}
}

/* ─── bus operations ──────────────────────────────────────────────── */

/* Issue a START condition. */
static inline void rv_i2c_start(void)
{
    rv_i2c_wait_ready();
    RV_I2C_CTRL = RV_I2C_CTRL_ENABLE | RV_I2C_CTRL_START;
    RV_I2C_FENCE();
    rv_i2c_wait_ready();
}

/* Issue a STOP condition. */
static inline void rv_i2c_stop(void)
{
    rv_i2c_wait_ready();
    RV_I2C_CTRL = RV_I2C_CTRL_ENABLE | RV_I2C_CTRL_STOP;
    RV_I2C_FENCE();
    rv_i2c_wait_ready();
}

/* Write one byte and return 0 if ACKed, -1 if NACKed. */
static inline int rv_i2c_write_byte(uint8_t data)
{
    rv_i2c_wait_ready();
    RV_I2C_TX = data;
    RV_I2C_FENCE();
    rv_i2c_wait_ready();
    return rv_i2c_ack_received() ? 0 : -1;
}

/* Receive one byte.  send_ack=1 → send ACK; send_ack=0 → send NACK
 * (use NACK for the last byte of a read sequence). */
static inline uint8_t rv_i2c_read_byte(int send_ack)
{
    uint32_t ctrl = RV_I2C_CTRL_ENABLE | RV_I2C_CTRL_READ;
    if (!send_ack) ctrl |= RV_I2C_CTRL_NACK;
    rv_i2c_wait_ready();
    RV_I2C_CTRL = ctrl;
    RV_I2C_FENCE();
    rv_i2c_wait_ready();
    return (uint8_t)(RV_I2C_RX & 0xFFu);
}

/* ─── composite helpers ───────────────────────────────────────────── */

/* Write 'len' bytes to I2C device at 7-bit address 'addr'.
 * Issues START, address byte (W), data, STOP.
 * Returns 0 on success, negative on NACK or error. */
static inline int rv_i2c_master_write(uint8_t addr, const uint8_t *buf, uint32_t len)
{
    rv_i2c_start();
    if (rv_i2c_write_byte((uint8_t)((addr << 1) | 0u)) < 0) { rv_i2c_stop(); return -1; }
    for (uint32_t i = 0; i < len; i++) {
        if (rv_i2c_write_byte(buf[i]) < 0) { rv_i2c_stop(); return -2; }
    }
    rv_i2c_stop();
    return 0;
}

/* Read 'len' bytes from I2C device at 7-bit address 'addr' into buf.
 * Issues START, address byte (R), data bytes with ACK/NACK, STOP.
 * Returns 0 on success, negative on NACK or error. */
static inline int rv_i2c_master_read(uint8_t addr, uint8_t *buf, uint32_t len)
{
    rv_i2c_start();
    if (rv_i2c_write_byte((uint8_t)((addr << 1) | 1u)) < 0) { rv_i2c_stop(); return -1; }
    for (uint32_t i = 0; i < len; i++) {
        buf[i] = rv_i2c_read_byte(i < len - 1u ? 1 : 0);   /* NACK on last byte */
    }
    rv_i2c_stop();
    return 0;
}

/* ─── interrupt control ───────────────────────────────────────────── */

static inline void rv_i2c_irq_enable(uint32_t mask)  { RV_I2C_IE |=  mask; }
static inline void rv_i2c_irq_disable(uint32_t mask) { RV_I2C_IE &= ~mask; }

static inline uint32_t rv_i2c_irq_status(void)
{
    uint32_t s = RV_I2C_IS;
    RV_I2C_IS = s;   /* W1C */
    return s;
}

#endif /* RV_I2C_H */

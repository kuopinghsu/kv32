/**
 * @file kv_gpio.h
 * @brief GPIO driver — data/direction/interrupt configuration, loopback helpers.
 *
 * Header-only inline driver for the kv32 AXI GPIO peripheral at
 * ::KV_GPIO_BASE.  Pair with kv_plic.h for interrupt-driven use.
 * @see axi_gpio.sv
 * @ingroup drivers
 */

#ifndef KV_GPIO_H
#define KV_GPIO_H

#include <stdint.h>
#include "kv_platform.h"

/* ─── register accessors ──────────────────────────────────────────── */
#define KV_GPIO_DATA_OUT0   KV_REG32(KV_GPIO_BASE, KV_GPIO_DATA_OUT0_OFF)
#define KV_GPIO_DATA_OUT1   KV_REG32(KV_GPIO_BASE, KV_GPIO_DATA_OUT1_OFF)
#define KV_GPIO_DATA_OUT2   KV_REG32(KV_GPIO_BASE, KV_GPIO_DATA_OUT2_OFF)
#define KV_GPIO_DATA_OUT3   KV_REG32(KV_GPIO_BASE, KV_GPIO_DATA_OUT3_OFF)

#define KV_GPIO_SET0        KV_REG32(KV_GPIO_BASE, KV_GPIO_SET0_OFF)
#define KV_GPIO_SET1        KV_REG32(KV_GPIO_BASE, KV_GPIO_SET1_OFF)
#define KV_GPIO_SET2        KV_REG32(KV_GPIO_BASE, KV_GPIO_SET2_OFF)
#define KV_GPIO_SET3        KV_REG32(KV_GPIO_BASE, KV_GPIO_SET3_OFF)

#define KV_GPIO_CLEAR0      KV_REG32(KV_GPIO_BASE, KV_GPIO_CLEAR0_OFF)
#define KV_GPIO_CLEAR1      KV_REG32(KV_GPIO_BASE, KV_GPIO_CLEAR1_OFF)
#define KV_GPIO_CLEAR2      KV_REG32(KV_GPIO_BASE, KV_GPIO_CLEAR2_OFF)
#define KV_GPIO_CLEAR3      KV_REG32(KV_GPIO_BASE, KV_GPIO_CLEAR3_OFF)

#define KV_GPIO_DATA_IN0    KV_REG32(KV_GPIO_BASE, KV_GPIO_DATA_IN0_OFF)
#define KV_GPIO_DATA_IN1    KV_REG32(KV_GPIO_BASE, KV_GPIO_DATA_IN1_OFF)
#define KV_GPIO_DATA_IN2    KV_REG32(KV_GPIO_BASE, KV_GPIO_DATA_IN2_OFF)
#define KV_GPIO_DATA_IN3    KV_REG32(KV_GPIO_BASE, KV_GPIO_DATA_IN3_OFF)

#define KV_GPIO_DIR0        KV_REG32(KV_GPIO_BASE, KV_GPIO_DIR0_OFF)
#define KV_GPIO_DIR1        KV_REG32(KV_GPIO_BASE, KV_GPIO_DIR1_OFF)
#define KV_GPIO_DIR2        KV_REG32(KV_GPIO_BASE, KV_GPIO_DIR2_OFF)
#define KV_GPIO_DIR3        KV_REG32(KV_GPIO_BASE, KV_GPIO_DIR3_OFF)

#define KV_GPIO_IE0         KV_REG32(KV_GPIO_BASE, KV_GPIO_IE0_OFF)
#define KV_GPIO_IE1         KV_REG32(KV_GPIO_BASE, KV_GPIO_IE1_OFF)
#define KV_GPIO_IE2         KV_REG32(KV_GPIO_BASE, KV_GPIO_IE2_OFF)
#define KV_GPIO_IE3         KV_REG32(KV_GPIO_BASE, KV_GPIO_IE3_OFF)

#define KV_GPIO_TRIGGER0    KV_REG32(KV_GPIO_BASE, KV_GPIO_TRIGGER0_OFF)
#define KV_GPIO_TRIGGER1    KV_REG32(KV_GPIO_BASE, KV_GPIO_TRIGGER1_OFF)
#define KV_GPIO_TRIGGER2    KV_REG32(KV_GPIO_BASE, KV_GPIO_TRIGGER2_OFF)
#define KV_GPIO_TRIGGER3    KV_REG32(KV_GPIO_BASE, KV_GPIO_TRIGGER3_OFF)

#define KV_GPIO_POLARITY0   KV_REG32(KV_GPIO_BASE, KV_GPIO_POLARITY0_OFF)
#define KV_GPIO_POLARITY1   KV_REG32(KV_GPIO_BASE, KV_GPIO_POLARITY1_OFF)
#define KV_GPIO_POLARITY2   KV_REG32(KV_GPIO_BASE, KV_GPIO_POLARITY2_OFF)
#define KV_GPIO_POLARITY3   KV_REG32(KV_GPIO_BASE, KV_GPIO_POLARITY3_OFF)

#define KV_GPIO_IS0         KV_REG32(KV_GPIO_BASE, KV_GPIO_IS0_OFF)
#define KV_GPIO_IS1         KV_REG32(KV_GPIO_BASE, KV_GPIO_IS1_OFF)
#define KV_GPIO_IS2         KV_REG32(KV_GPIO_BASE, KV_GPIO_IS2_OFF)
#define KV_GPIO_IS3         KV_REG32(KV_GPIO_BASE, KV_GPIO_IS3_OFF)

#define KV_GPIO_LOOPBACK0   KV_REG32(KV_GPIO_BASE, KV_GPIO_LOOPBACK0_OFF)
#define KV_GPIO_LOOPBACK1   KV_REG32(KV_GPIO_BASE, KV_GPIO_LOOPBACK1_OFF)
#define KV_GPIO_LOOPBACK2   KV_REG32(KV_GPIO_BASE, KV_GPIO_LOOPBACK2_OFF)
#define KV_GPIO_LOOPBACK3   KV_REG32(KV_GPIO_BASE, KV_GPIO_LOOPBACK3_OFF)

#define KV_GPIO_CAP         KV_REG32(KV_GPIO_BASE, KV_GPIO_CAP_OFF)

/* ─── init ────────────────────────────────────────────────────────── */

/* Initialize GPIO: all pins as inputs, interrupts disabled */
static inline void kv_gpio_init(void)
{
    KV_GPIO_DIR0 = 0;
    KV_GPIO_DIR1 = 0;
    KV_GPIO_DIR2 = 0;
    KV_GPIO_DIR3 = 0;
    KV_GPIO_IE0 = 0;
    KV_GPIO_IE1 = 0;
    KV_GPIO_IE2 = 0;
    KV_GPIO_IE3 = 0;
    KV_GPIO_LOOPBACK0 = 0;
    KV_GPIO_LOOPBACK1 = 0;
    KV_GPIO_LOOPBACK2 = 0;
    KV_GPIO_LOOPBACK3 = 0;
}

/* ─── pin direction ───────────────────────────────────────────────── */

/* Set pin direction: 1=output, 0=input (bank 0: pins 0-31) */
static inline void kv_gpio_set_dir(uint32_t bank, uint32_t mask)
{
    switch (bank) {
        case 0: KV_GPIO_DIR0 = mask; break;
        case 1: KV_GPIO_DIR1 = mask; break;
        case 2: KV_GPIO_DIR2 = mask; break;
        case 3: KV_GPIO_DIR3 = mask; break;
    }
}

/* Get pin direction */
static inline uint32_t kv_gpio_get_dir(uint32_t bank)
{
    switch (bank) {
        case 0: return KV_GPIO_DIR0;
        case 1: return KV_GPIO_DIR1;
        case 2: return KV_GPIO_DIR2;
        case 3: return KV_GPIO_DIR3;
        default: return 0;
    }
}

/* Read direction register (alias for compatibility) */
static inline uint32_t kv_gpio_read_dir(uint32_t bank) {
    return kv_gpio_get_dir(bank);
}

/* ─── output operations ───────────────────────────────────────────── */

/* Write GPIO output data */
static inline void kv_gpio_write(uint32_t bank, uint32_t value)
{
    switch (bank) {
        case 0: KV_GPIO_DATA_OUT0 = value; break;
        case 1: KV_GPIO_DATA_OUT1 = value; break;
        case 2: KV_GPIO_DATA_OUT2 = value; break;
        case 3: KV_GPIO_DATA_OUT3 = value; break;
    }
}

/* Read output data register */
static inline uint32_t kv_gpio_read_out(uint32_t bank)
{
    switch (bank) {
        case 0: return KV_GPIO_DATA_OUT0;
        case 1: return KV_GPIO_DATA_OUT1;
        case 2: return KV_GPIO_DATA_OUT2;
        case 3: return KV_GPIO_DATA_OUT3;
        default: return 0;
    }
}

/* Atomic set bits (write-1-to-set) */
static inline void kv_gpio_set(uint32_t bank, uint32_t mask)
{
    switch (bank) {
        case 0: KV_GPIO_SET0 = mask; break;
        case 1: KV_GPIO_SET1 = mask; break;
        case 2: KV_GPIO_SET2 = mask; break;
        case 3: KV_GPIO_SET3 = mask; break;
    }
}

/* Atomic clear bits (write-1-to-clear) */
static inline void kv_gpio_clear(uint32_t bank, uint32_t mask)
{
    switch (bank) {
        case 0: KV_GPIO_CLEAR0 = mask; break;
        case 1: KV_GPIO_CLEAR1 = mask; break;
        case 2: KV_GPIO_CLEAR2 = mask; break;
        case 3: KV_GPIO_CLEAR3 = mask; break;
    }
}

/* Toggle bits */
static inline void kv_gpio_toggle(uint32_t bank, uint32_t mask)
{
    uint32_t curr = 0;
    switch (bank) {
        case 0: curr = KV_GPIO_DATA_OUT0; KV_GPIO_DATA_OUT0 = curr ^ mask; break;
        case 1: curr = KV_GPIO_DATA_OUT1; KV_GPIO_DATA_OUT1 = curr ^ mask; break;
        case 2: curr = KV_GPIO_DATA_OUT2; KV_GPIO_DATA_OUT2 = curr ^ mask; break;
        case 3: curr = KV_GPIO_DATA_OUT3; KV_GPIO_DATA_OUT3 = curr ^ mask; break;
    }
}

/* ─── input operations ────────────────────────────────────────────── */

/* Read GPIO input data */
static inline uint32_t kv_gpio_read(uint32_t bank)
{
    switch (bank) {
        case 0: return KV_GPIO_DATA_IN0;
        case 1: return KV_GPIO_DATA_IN1;
        case 2: return KV_GPIO_DATA_IN2;
        case 3: return KV_GPIO_DATA_IN3;
        default: return 0;
    }
}

/* ─── interrupt configuration ─────────────────────────────────────── */

/* Set interrupt enable mask */
static inline void kv_gpio_set_ie(uint32_t bank, uint32_t mask)
{
    switch (bank) {
        case 0: KV_GPIO_IE0 = mask; break;
        case 1: KV_GPIO_IE1 = mask; break;
        case 2: KV_GPIO_IE2 = mask; break;
        case 3: KV_GPIO_IE3 = mask; break;
    }
}

/* Read interrupt enable mask */
static inline uint32_t kv_gpio_read_ie(uint32_t bank)
{
    switch (bank) {
        case 0: return KV_GPIO_IE0;
        case 1: return KV_GPIO_IE1;
        case 2: return KV_GPIO_IE2;
        case 3: return KV_GPIO_IE3;
        default: return 0;
    }
}

/* Set trigger mode: 1=edge, 0=level */
static inline void kv_gpio_set_trigger(uint32_t bank, uint32_t mask)
{
    switch (bank) {
        case 0: KV_GPIO_TRIGGER0 = mask; break;
        case 1: KV_GPIO_TRIGGER1 = mask; break;
        case 2: KV_GPIO_TRIGGER2 = mask; break;
        case 3: KV_GPIO_TRIGGER3 = mask; break;
    }
}

/* Read trigger mode */
static inline uint32_t kv_gpio_read_trigger(uint32_t bank)
{
    switch (bank) {
        case 0: return KV_GPIO_TRIGGER0;
        case 1: return KV_GPIO_TRIGGER1;
        case 2: return KV_GPIO_TRIGGER2;
        case 3: return KV_GPIO_TRIGGER3;
        default: return 0;
    }
}

/* Set polarity: edge=(1=rising, 0=falling), level=(1=high, 0=low) */
static inline void kv_gpio_set_polarity(uint32_t bank, uint32_t mask)
{
    switch (bank) {
        case 0: KV_GPIO_POLARITY0 = mask; break;
        case 1: KV_GPIO_POLARITY1 = mask; break;
        case 2: KV_GPIO_POLARITY2 = mask; break;
        case 3: KV_GPIO_POLARITY3 = mask; break;
    }
}

/* Read polarity */
static inline uint32_t kv_gpio_read_polarity(uint32_t bank)
{
    switch (bank) {
        case 0: return KV_GPIO_POLARITY0;
        case 1: return KV_GPIO_POLARITY1;
        case 2: return KV_GPIO_POLARITY2;
        case 3: return KV_GPIO_POLARITY3;
        default: return 0;
    }
}

/* ─── interrupt status ────────────────────────────────────────────── */

/* Read interrupt status */
static inline uint32_t kv_gpio_get_is(uint32_t bank)
{
    switch (bank) {
        case 0: return KV_GPIO_IS0;
        case 1: return KV_GPIO_IS1;
        case 2: return KV_GPIO_IS2;
        case 3: return KV_GPIO_IS3;
        default: return 0;
    }
}

/* Clear interrupt status (write-1-to-clear) */
static inline void kv_gpio_clear_is(uint32_t bank, uint32_t mask)
{
    switch (bank) {
        case 0: KV_GPIO_IS0 = mask; break;
        case 1: KV_GPIO_IS1 = mask; break;
        case 2: KV_GPIO_IS2 = mask; break;
        case 3: KV_GPIO_IS3 = mask; break;
    }
}

/* ─── loopback mode (for testing) ─────────────────────────────────── */

/* Enable loopback: output data is routed back to input */
static inline void kv_gpio_set_loopback(uint32_t bank, uint32_t mask)
{
    switch (bank) {
        case 0: KV_GPIO_LOOPBACK0 = mask; break;
        case 1: KV_GPIO_LOOPBACK1 = mask; break;
        case 2: KV_GPIO_LOOPBACK2 = mask; break;
        case 3: KV_GPIO_LOOPBACK3 = mask; break;
    }
}

/* Read loopback mode */
static inline uint32_t kv_gpio_read_loopback(uint32_t bank)
{
    switch (bank) {
        case 0: return KV_GPIO_LOOPBACK0;
        case 1: return KV_GPIO_LOOPBACK1;
        case 2: return KV_GPIO_LOOPBACK2;
        case 3: return KV_GPIO_LOOPBACK3;
        default: return 0;
    }
}

/* ─── capability register ─────────────────────────────────────────── */

/* Read capability register (hardware configuration) */
static inline uint32_t kv_gpio_get_capability(void)
{
    return KV_GPIO_CAP;
}

/* Get number of GPIO pins from capability register */
static inline uint32_t kv_gpio_get_num_pins(void)
{
    return KV_GPIO_CAP & 0xFF;  // [7:0]
}

/* Get number of register banks from capability register */
static inline uint32_t kv_gpio_get_num_banks(void)
{
    return (KV_GPIO_CAP >> 8) & 0xFF;  // [15:8]
}

/* Get GPIO version from capability register */
static inline uint32_t kv_gpio_get_version(void)
{
    return (KV_GPIO_CAP >> 16) & 0xFFFF;  // [31:16]
}

#endif /* KV_GPIO_H */

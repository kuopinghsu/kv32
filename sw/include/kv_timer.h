/*
 * kv_timer.h – Timer/PWM driver (polling + interrupt-mode helpers)
 *
 * Hardware: axi_timer.sv at KV_TIMER_BASE
 *   Register map – see kv_platform.h (KV_TIMER_*)
 *
 * The driver is intentionally header-only (all inline) so that it adds
 * zero code when not called.  For interrupted-driven use, pair with
 * kv_plic.h (source KV_PLIC_SRC_TIMER).
 */
#ifndef KV_TIMER_H
#define KV_TIMER_H

#include <stdint.h>
#include "kv_platform.h"

/* ─── register accessors for timer N (0-3) ───────────────────────── */
#define KV_TIMER_COUNT(n)      KV_REG32(KV_TIMER_BASE, KV_TIMER_CH_STRIDE * (n) + KV_TIMER_COUNT_OFF)
#define KV_TIMER_COMPARE1(n)   KV_REG32(KV_TIMER_BASE, KV_TIMER_CH_STRIDE * (n) + KV_TIMER_COMPARE1_OFF)
#define KV_TIMER_COMPARE2(n)   KV_REG32(KV_TIMER_BASE, KV_TIMER_CH_STRIDE * (n) + KV_TIMER_COMPARE2_OFF)
#define KV_TIMER_CTRL(n)       KV_REG32(KV_TIMER_BASE, KV_TIMER_CH_STRIDE * (n) + KV_TIMER_CTRL_OFF)

/* ─── global interrupt registers ──────────────────────────────────── */
#define KV_TIMER_INT_STATUS    KV_REG32(KV_TIMER_BASE, KV_TIMER_INT_STATUS_OFF)
#define KV_TIMER_INT_ENABLE    KV_REG32(KV_TIMER_BASE, KV_TIMER_INT_ENABLE_OFF)

/* ─── control register bit masks ──────────────────────────────────── */
#define KV_TIMER_CTRL_EN       (1u << 0)   /* Timer enable */
#define KV_TIMER_CTRL_PWM_EN   (1u << 1)   /* PWM mode enable */
#define KV_TIMER_CTRL_INT_EN   (1u << 3)   /* Interrupt enable */
#define KV_TIMER_CTRL_PWM_POL  (1u << 4)   /* PWM polarity (1=active high) */
#define KV_TIMER_CTRL_PRESCALE(n)  (((n) & 0xFFFFu) << 16) /* Prescaler value */

/* ─── init ────────────────────────────────────────────────────────── */

/* Initialize all timer channels (disabled) */
static inline void kv_timer_init(void)
{
    for (int i = 0; i < 4; i++) {
        KV_TIMER_CTRL(i) = 0;
        KV_TIMER_COUNT(i) = 0;
        KV_TIMER_COMPARE1(i) = 0;
        KV_TIMER_COMPARE2(i) = 0xFFFFFFFFu;
    }
}

/* Initialize interrupt controller for timers */
static inline void kv_timer_init_irq(uint32_t timer_mask)
{
    KV_TIMER_INT_ENABLE = timer_mask & 0xFu;  /* Enable selected timers (bits 0-3) */
}

/* ─── timer mode operations ───────────────────────────────────────── */

/* Configure and start timer in simple mode (compare2 defines period) */
static inline void kv_timer_start(int timer_num, uint32_t period, uint16_t prescale)
{
    KV_TIMER_CTRL(timer_num) = 0;  /* Disable first */
    KV_TIMER_COUNT(timer_num) = 0;
    KV_TIMER_COMPARE1(timer_num) = 0;           /* Not used in simple timer mode */
    KV_TIMER_COMPARE2(timer_num) = period - 1;
    KV_TIMER_CTRL(timer_num) = KV_TIMER_CTRL_EN | 
                                KV_TIMER_CTRL_INT_EN |
                                KV_TIMER_CTRL_PRESCALE(prescale);
}

/* Configure timer with dual compare interrupts */
static inline void kv_timer_start_dual(int timer_num, uint32_t compare1, uint32_t period, uint16_t prescale, int int_en)
{
    uint32_t ctrl = KV_TIMER_CTRL_EN | KV_TIMER_CTRL_PRESCALE(prescale);
    if (int_en) {
        ctrl |= KV_TIMER_CTRL_INT_EN;
    }
    
    KV_TIMER_CTRL(timer_num) = 0;  /* Disable first */
    KV_TIMER_COUNT(timer_num) = 0;
    KV_TIMER_COMPARE1(timer_num) = compare1;    /* Mid-period interrupt */
    KV_TIMER_COMPARE2(timer_num) = period - 1;  /* Period end + reload */
    KV_TIMER_CTRL(timer_num) = ctrl;
}

/* Stop timer */
static inline void kv_timer_stop(int timer_num)
{
    KV_TIMER_CTRL(timer_num) = 0;
}

/* Read current counter value */
static inline uint32_t kv_timer_get_count(int timer_num)
{
    return KV_TIMER_COUNT(timer_num);
}

/* ─── PWM mode operations ─────────────────────────────────────────── */

/* Configure and start PWM output (standard mode: duty cycle control)
 * period = PWM period (counter resets at this value)
 * duty = time when PWM is high (0-100% of period)
 * PWM goes high at count=0, low at count=duty, resets at count=period
 */
static inline void kv_timer_pwm_start(int timer_num, uint32_t period, uint32_t duty, uint16_t prescale)
{
    uint32_t ctrl = KV_TIMER_CTRL_EN | 
                    KV_TIMER_CTRL_PWM_EN | 
                    KV_TIMER_CTRL_PWM_POL |  /* Active high */
                    KV_TIMER_CTRL_PRESCALE(prescale);
    
    KV_TIMER_CTRL(timer_num) = 0;  /* Disable first */
    KV_TIMER_COUNT(timer_num) = 0;
    KV_TIMER_COMPARE1(timer_num) = duty;      /* Falling edge (PWM goes low) */
    KV_TIMER_COMPARE2(timer_num) = period - 1;  /* Period (counter resets) */
    KV_TIMER_CTRL(timer_num) = ctrl;
}

/* Set PWM duty cycle
 * period = PWM period (must match the period from pwm_start)
 * duty = time when PWM is high (0-100% of period)
 */
static inline void kv_timer_pwm_set_duty(int timer_num, uint32_t period, uint32_t duty)
{
    KV_TIMER_COMPARE1(timer_num) = duty;        /* Falling edge */
    KV_TIMER_COMPARE2(timer_num) = period - 1;  /* Period */
}

/* Stop PWM output */
static inline void kv_timer_pwm_stop(int timer_num)
{
    KV_TIMER_CTRL(timer_num) = 0;
}

/* ─── interrupt operations ────────────────────────────────────────── */

/* Get global interrupt status (one bit per timer) */
static inline uint32_t kv_timer_get_int_status(void)
{
    return KV_TIMER_INT_STATUS;
}

/* Clear interrupt status (write-1-to-clear, pass mask) */
static inline void kv_timer_clear_int(uint32_t mask)
{
    KV_TIMER_INT_STATUS = mask;
}

/* Check if specific timer interrupt is pending */
static inline int kv_timer_is_int_pending(int timer_num)
{
    return (KV_TIMER_INT_STATUS & (1u << timer_num)) != 0;
}

/* ─── helper macros ───────────────────────────────────────────────── */

/* Calculate period for given frequency and prescaler
 * freq_hz = clock_hz / ((prescale + 1) * period)
 * period = clock_hz / ((prescale + 1) * freq_hz)
 */
#define KV_TIMER_PERIOD(clock_hz, prescale, freq_hz) \
    ((clock_hz) / (((prescale) + 1) * (freq_hz)))

/* Calculate prescaler for given frequency and desired period
 * prescale = (clock_hz / (period * freq_hz)) - 1
 */
#define KV_TIMER_PRESCALE(clock_hz, period, freq_hz) \
    (((clock_hz) / ((period) * (freq_hz))) - 1)

/* ─── capability register ────────────────────────────────────────── */

#define KV_TIMER_CAP    KV_REG32(KV_TIMER_BASE, KV_TIMER_CAP_OFF)

/* Read capability register (hardware configuration) */
static inline uint32_t kv_timer_get_capability(void)
{
    return KV_TIMER_CAP;
}

/* Get number of timer channels from capability register */
static inline uint32_t kv_timer_get_num_channels(void)
{
    return (KV_TIMER_CAP >> 8) & 0xFF;  // [15:8]
}

/* Get counter width from capability register */
static inline uint32_t kv_timer_get_counter_width(void)
{
    return KV_TIMER_CAP & 0xFF;  // [7:0]
}

/* Get Timer version from capability register */
static inline uint32_t kv_timer_get_version(void)
{
    return (KV_TIMER_CAP >> 16) & 0xFFFF;  // [31:16]
}

#endif /* KV_TIMER_H */

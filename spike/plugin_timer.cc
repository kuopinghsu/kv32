// ============================================================================
// File: plugin_timer.cc
// Project: KV32 RISC-V Processor
// Description: Spike MMIO plugin for the KV32 Timer/PWM peripheral
//
// Register Map (relative to KV_TIMER_BASE = 0x2004_0000):
//   Per-channel (4 channels, stride = 0x20):
//     ch*0x20 + 0x00  COUNT     - Counter value (R/W)
//     ch*0x20 + 0x04  COMPARE1  - Compare 1: interrupt trigger / PWM rise (R/W)
//     ch*0x20 + 0x08  COMPARE2  - Compare 2: PWM fall / auto-reload value (R/W)
//     ch*0x20 + 0x0C  CTRL      - [0]=en, [1]=pwm_en, [3]=int_en, [4]=pwm_pol,
//                                  [31:16]=prescaler (R/W)
//   Global:
//     0x80  INT_STATUS  - Per-channel interrupt status (W1C)
//     0x84  INT_ENABLE  - Global interrupt enable per channel (R/W)
//     0x88  CAP         - [7:0]=width(32), [15:8]=num_ch(4), [31:16]=version(1)
//   >0x8B  —            - Bus error
//
// Simulation behaviour:
//   tick() increments a nanosecond-resolution counter.  Each timer channel
//   whose CTRL[0]=1 (enable) increments COUNT every (prescaler+1) ticks.
//   When COUNT >= COMPARE1 and CTRL[3]=1 (int_en):
//     INT_STATUS[ch] is set and COUNT wraps to 0 (auto-reload).
//   Software clears INT_STATUS with W1C writes.
// ============================================================================

#include <riscv/abstract_device.h>

#ifdef SPIKE_INCLUDE
#include <riscv/sim.h>
#include <riscv/devices.h>
#endif

#include <cstring>
#include <string>
#include <vector>

#include "kv_platform.h"

static constexpr uint32_t TIMER_NUM_CH  = 4;
static constexpr uint32_t TIMER_CAP_VAL =
    (0x0001u << 16) | (TIMER_NUM_CH << 8) | 32u; // version=1, ch=4, width=32

// Last valid byte address within the peripheral window
static constexpr reg_t TIMER_ADDR_MAX = KV_TIMER_CAP_OFF + 3u;

class plugin_timer_t : public abstract_device_t {
public:
    explicit plugin_timer_t(sim_t *sim = nullptr) : sim_(sim)
    {
        memset(count_,    0, sizeof(count_));
        memset(compare1_, 0, sizeof(compare1_));
        memset(compare2_, 0, sizeof(compare2_));
        memset(ctrl_,     0, sizeof(ctrl_));
        memset(prescaler_cnt_, 0, sizeof(prescaler_cnt_));
        int_status_ = 0;
        int_enable_ = 0;
    }

    bool load(reg_t addr, size_t len, uint8_t *bytes) override
    {
        if (addr > TIMER_ADDR_MAX) return false;
        uint32_t val = reg_read(addr);
        memset(bytes, 0, len);
        if (len >= 4) memcpy(bytes, &val, 4);
        else           memcpy(bytes, &val, len);
        return true;
    }

    bool store(reg_t addr, size_t len, const uint8_t *bytes) override
    {
        if (addr > TIMER_ADDR_MAX) return false;
        uint32_t val = 0;
        if (len >= 4) memcpy(&val, bytes, 4);
        else           memcpy(&val, bytes, len);
        reg_write(addr, val);
        return true;
    }

    void tick(reg_t rtc_ticks) override
    {
        // rtc_ticks is the CLINT period: CPU cycles between each tick() call.
        // The KV32 timer counts CPU clock cycles (prescaler=0 → 1 count/cycle).
        // Advance count by (cycles / (prescaler+1)) to simulate correct speed.
        const uint32_t cycles = (uint32_t)(rtc_ticks > 0 ? rtc_ticks : 1);

        for (uint32_t ch = 0; ch < TIMER_NUM_CH; ++ch) {
            if (!(ctrl_[ch] & (1u << KV_TIMER_CTRL_EN_BIT))) continue;

            uint32_t prescaler = ctrl_[ch] >> 16; // [31:16]
            // prescaler_cnt_ accumulates leftover sub-period cycles.
            prescaler_cnt_[ch] += cycles;
            uint32_t ticks_now = prescaler_cnt_[ch] / (prescaler + 1);
            if (ticks_now == 0) continue;
            prescaler_cnt_[ch] %= (prescaler + 1);

            // Simulate each individual timer tick (CPU cycle) to preserve
            // compare-match granularity without resetting count to zero.
            // Using strict '>' for compare2 and subtracting compare2 (not +1)
            // keeps the overshoot so count never returns to exactly 0.
            bool irq_any = false;
            for (uint32_t i = 0; i < ticks_now; i++) {
                count_[ch]++;
                if (compare2_[ch] != 0 && count_[ch] > compare2_[ch]) {
                    // Period end: reload by subtracting compare2 (keep overshoot)
                    count_[ch] -= compare2_[ch];
                    if (ctrl_[ch] & (1u << KV_TIMER_CTRL_INT_EN_BIT))
                        irq_any = true;
                } else if (compare1_[ch] != 0 && count_[ch] >= compare1_[ch]) {
                    if (ctrl_[ch] & (1u << KV_TIMER_CTRL_INT_EN_BIT))
                        irq_any = true;
                }
            }
            if (irq_any) int_status_ |= (1u << ch);
        }
        update_meip();
    }

    reg_t size() override { return (reg_t)KV_TIMER_SIZE; }

private:
    void update_meip() const
    {
#ifdef SPIKE_INCLUDE
        if (!sim_) return;
        for (uint32_t ch = 0; ch < TIMER_NUM_CH; ++ch) {
            const bool pending = ((int_status_ >> ch) & 1u) && ((int_enable_ >> ch) & 1u);
            sim_->get_intctrl()->set_interrupt_level(
                (uint32_t)(KV_PLIC_SRC_TIMER0 + ch), pending ? 1 : 0);
        }
#endif
    }
    sim_t   *sim_;
    uint32_t count_[TIMER_NUM_CH];
    uint32_t compare1_[TIMER_NUM_CH];
    uint32_t compare2_[TIMER_NUM_CH];
    uint32_t ctrl_[TIMER_NUM_CH];
    uint32_t prescaler_cnt_[TIMER_NUM_CH];  // tick-divider accumulator
    uint32_t int_status_;
    uint32_t int_enable_;

    // Decode channel and word offset from address.
    static bool ch_addr(reg_t addr, uint32_t *ch_out, reg_t *off_out)
    {
        if (addr >= KV_TIMER_INT_STATUS_OFF) return false;
        *ch_out  = (uint32_t)(addr / KV_TIMER_CH_STRIDE);
        *off_out = addr % KV_TIMER_CH_STRIDE;
        return (*ch_out < TIMER_NUM_CH);
    }

    uint32_t reg_read(reg_t addr)
    {
        if (addr == KV_TIMER_INT_STATUS_OFF) return int_status_;
        if (addr == KV_TIMER_INT_ENABLE_OFF) return int_enable_;
        if (addr == KV_TIMER_CAP_OFF)        return TIMER_CAP_VAL;

        uint32_t ch; reg_t off;
        if (!ch_addr(addr, &ch, &off)) return 0u;
        switch (off) {
        case KV_TIMER_COUNT_OFF:    return count_[ch];
        case KV_TIMER_COMPARE1_OFF: return compare1_[ch];
        case KV_TIMER_COMPARE2_OFF: return compare2_[ch];
        case KV_TIMER_CTRL_OFF:     return ctrl_[ch];
        default:                    return 0u;
        }
    }

    void reg_write(reg_t addr, uint32_t val)
    {
        if (addr == KV_TIMER_INT_STATUS_OFF) { int_status_ &= ~val; update_meip(); return; } // W1C
        if (addr == KV_TIMER_INT_ENABLE_OFF) { int_enable_  = val;  update_meip(); return; }
        if (addr == KV_TIMER_CAP_OFF)        return; // read-only

        uint32_t ch; reg_t off;
        if (!ch_addr(addr, &ch, &off)) return;
        switch (off) {
        case KV_TIMER_COUNT_OFF:    count_[ch]    = val; break;
        case KV_TIMER_COMPARE1_OFF: compare1_[ch] = val; break;
        case KV_TIMER_COMPARE2_OFF: compare2_[ch] = val; break;
        case KV_TIMER_CTRL_OFF:     ctrl_[ch]     = val;
                                    prescaler_cnt_[ch] = 0; // reset divider on ctrl write
                                    break;
        default: break;
        }
    }
};

static plugin_timer_t *
plugin_timer_parse(const void *, const sim_t *sim, reg_t *base,
                   const std::vector<std::string> &sargs)
{
    if (!sargs.empty()) *base = strtoull(sargs[0].c_str(), nullptr, 0);
    return new plugin_timer_t(const_cast<sim_t *>(sim));
}

static std::string
plugin_timer_generate_dts(const sim_t *, const std::vector<std::string> &)
{ return ""; }

REGISTER_DEVICE(plugin_timer, plugin_timer_parse, plugin_timer_generate_dts)

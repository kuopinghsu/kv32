// ============================================================================
// File: plugin_wdt.cc
// Project: KV32 RISC-V Processor
// Description: Spike MMIO plugin for the KV32 Hardware Watchdog Timer (WDT)
//
// Register Map (relative to KV_WDT_BASE = 0x2006_0000):
//   0x00  CTRL    [0]=EN, [1]=INTR_EN (1=IRQ, 0=hardware reset)
//   0x04  LOAD    Reload value (write before enabling)
//   0x08  COUNT   Current countdown value (RO)
//   0x0C  KICK    WO: any write reloads COUNT from LOAD
//   0x10  STATUS  [0]=WDT_INT (W1C)
//   0x14  CAP     RO: 0x0001_0020 (version=1, width=32)
//  >0x17  —       Bus error
//
// Simulation behaviour:
//   tick(rtc_ticks) decrements COUNT by cpu-cycle-equivalent ticks when EN=1.
//   On reaching zero:
//     INTR_EN=1 → STATUS[0] set; PLIC interrupt level asserted via
//                 sim->get_intctrl()->set_interrupt_level()
//     INTR_EN=0 → sim->htif_exit(2) called (hardware reset equivalent)
//   COUNT latches at zero until KICK or rst (consistent with RTL latch).
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

// Last valid byte address within the WDT window
static constexpr reg_t WDT_ADDR_MAX = KV_WDT_CAP_OFF + 3u;

// Capability register value: version=1, counter width=32 bits
static constexpr uint32_t WDT_CAP_VAL = 0x00010020u;

class plugin_wdt_t : public abstract_device_t {
public:
    explicit plugin_wdt_t(sim_t *sim = nullptr) : sim_(sim)
    {
        ctrl_r        = 0;
        load_r        = 0xFFFFFFFFu;
        count_r       = 0xFFFFFFFFu;
        status_r      = 0;
        suppress_next_count_advance_ = false;
    }

    bool load(reg_t addr, size_t len, uint8_t *bytes) override
    {
        if (addr > WDT_ADDR_MAX) return false;
        if ((uint32_t)addr == KV_WDT_COUNT_OFF && suppress_next_count_advance_) {
            suppress_next_count_advance_ = false;
        } else {
            advance_count(1);
        }
        uint32_t val = reg_read((uint32_t)addr);
        memset(bytes, 0, len);
        if (len >= 4) memcpy(bytes, &val, 4);
        else           memcpy(bytes, &val, len);
        return true;
    }

    bool store(reg_t addr, size_t len, const uint8_t *bytes) override
    {
        if (addr > WDT_ADDR_MAX) return false;
        advance_count(1);
        uint32_t val = 0;
        if (len >= 4) memcpy(&val, bytes, 4);
        else           memcpy(&val, bytes, len);
        reg_write((uint32_t)addr, val);
        return true;
    }

    void tick(reg_t rtc_ticks) override
    {
        const uint32_t cycles = (uint32_t)(rtc_ticks > 0 ? rtc_ticks : 1);
        advance_count(cycles);
    }

    reg_t size() override { return (reg_t)KV_WDT_SIZE; }

private:
    void advance_count(uint32_t cycles)
    {
        if (!(ctrl_r & 1u)) return;  // EN=0: stopped
        if (count_r == 0)   return;  // Expired; latch held until KICK

        if (cycles >= count_r) {
            count_r = 0;
            if (ctrl_r & 2u) {
                // INTR_EN=1: set WDT_INT and assert PLIC interrupt
                status_r |= 1u;
                update_meip();
            } else {
                // INTR_EN=0: hardware reset equivalent, EN clears in reset mode
                ctrl_r &= ~1u;
#ifdef SPIKE_INCLUDE
                if (sim_) sim_->htif_exit(2);
#endif
            }
        } else {
            count_r -= cycles;
        }
    }

    void update_meip() const
    {
#ifdef SPIKE_INCLUDE
        if (!sim_) return;
        const bool pending = (status_r & 1u) && (ctrl_r & 2u);
        sim_->get_intctrl()->set_interrupt_level(
            (uint32_t)KV_PLIC_SRC_WDT, pending ? 1 : 0);
#endif
    }

    sim_t   *sim_;
    uint32_t ctrl_r;    // [0]=EN, [1]=INTR_EN
    uint32_t load_r;    // Reload value
    uint32_t count_r;   // Countdown counter
    uint32_t status_r;  // [0]=WDT_INT (W1C)
    bool     suppress_next_count_advance_;

    uint32_t reg_read(uint32_t addr)
    {
        switch (addr) {
        case KV_WDT_CTRL_OFF:   return ctrl_r;
        case KV_WDT_LOAD_OFF:   return load_r;
        case KV_WDT_COUNT_OFF:  return count_r;
        case KV_WDT_KICK_OFF:   return 0u;       // WO: reads return 0
        case KV_WDT_STATUS_OFF: return status_r;
        case KV_WDT_CAP_OFF:    return WDT_CAP_VAL;
        default:                return 0u;
        }
    }

    void reg_write(uint32_t addr, uint32_t val)
    {
        switch (addr) {
        case KV_WDT_CTRL_OFF:
            ctrl_r = val & 3u;
            update_meip();
            break;
        case KV_WDT_LOAD_OFF:
            load_r = val;
            break;
        case KV_WDT_COUNT_OFF:
            break;              // COUNT is RO
        case KV_WDT_KICK_OFF:
            count_r = load_r;  // Any write reloads COUNT from LOAD
            suppress_next_count_advance_ = (ctrl_r & 1u) != 0u;
            break;
        case KV_WDT_STATUS_OFF:
            status_r &= ~val;  // W1C
            update_meip();
            break;
        case KV_WDT_CAP_OFF:
            break;              // CAP is RO
        default:
            break;
        }
    }
};

static plugin_wdt_t *
plugin_wdt_parse(const void *, const sim_t *sim, reg_t *base,
                 const std::vector<std::string> &sargs)
{
    if (!sargs.empty()) *base = strtoull(sargs[0].c_str(), nullptr, 0);
    return new plugin_wdt_t(const_cast<sim_t *>(sim));
}

static std::string
plugin_wdt_generate_dts(const sim_t *, const std::vector<std::string> &)
{ return ""; }

REGISTER_DEVICE(plugin_wdt, plugin_wdt_parse, plugin_wdt_generate_dts)

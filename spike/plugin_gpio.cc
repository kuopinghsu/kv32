// ============================================================================
// File: plugin_gpio.cc
// Project: KV32 RISC-V Processor
// Description: Spike MMIO plugin for the KV32 GPIO peripheral
//              with edge/level interrupt detection and PLIC IRQ.
//
// Register Map (relative to KV_GPIO_BASE = 0x2005_0000):
//   0x00-0x0C  DATA_OUT[0-3]  - Output data (R/W)
//   0x10-0x1C  SET[0-3]       - Write-1-to-set output bits
//   0x20-0x2C  CLEAR[0-3]     - Write-1-to-clear output bits
//   0x30-0x3C  DATA_IN[0-3]   - Input data (RO): loopback? out : 0
//   0x40-0x4C  DIR[0-3]       - Direction: 1=output (R/W)
//   0x50-0x5C  IE[0-3]        - Interrupt enable (R/W)
//   0x60-0x6C  TRIGGER[0-3]   - Trigger type: 1=edge, 0=level (R/W)
//   0x70-0x7C  POLARITY[0-3]  - Polarity: 1=rising/high, 0=falling/low (R/W)
//   0x80-0x8C  IS[0-3]        - Interrupt status (W1C)
//   0x90-0x9C  LOOPBACK[0-3]  - Loopback enable (R/W)
//   0xA0       CAP            - [7:0]=NUM_PINS, [15:8]=NUM_BANKS, [31:16]=VERSION
//   >0xA0       —             - Bus error
//
// Simulation behaviour:
//   When LOOPBACK[bank] bit for a pin is set, DATA_IN[bank] reflects DATA_OUT[bank].
//   Edge-triggered (TRIGGER=1):
//     Rising  interrupt (POLARITY=1): IS set when output goes 0→1 on loopback pins.
//     Falling interrupt (POLARITY=0): IS set when output goes 1→0 on loopback pins.
//   Level-triggered (TRIGGER=0):
//     High-level (POLARITY=1): MEIP held while (out & loopback) & ie are set.
//     Low-level  (POLARITY=0): MEIP held while (~out & loopback) & ie are set.
//   PLIC source: KV_PLIC_SRC_GPIO.
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

static constexpr uint32_t GPIO_NUM_BANKS = 4;
// CAP: VERSION=1, NUM_BANKS=4, NUM_PINS=128
static constexpr uint32_t GPIO_CAP_VAL =
    (0x0001u << 16) | (GPIO_NUM_BANKS << 8) | (GPIO_NUM_BANKS * 32);
static constexpr reg_t GPIO_ADDR_MAX = KV_GPIO_CAP_OFF;

class plugin_gpio_t : public abstract_device_t {
public:
    explicit plugin_gpio_t(sim_t *sim = nullptr) : sim_(sim)
    {
        memset(out_,       0, sizeof(out_));
        memset(dir_,       0, sizeof(dir_));
        memset(ie_,        0, sizeof(ie_));
        memset(trigger_,   0, sizeof(trigger_));
        memset(polarity_,  0, sizeof(polarity_));
        memset(is_,        0, sizeof(is_));
        memset(loopback_,  0, sizeof(loopback_));
    }

    bool load(reg_t addr, size_t len, uint8_t *bytes) override
    {
        if (addr > GPIO_ADDR_MAX) return false;
        uint32_t val = reg_read(addr);
        memset(bytes, 0, len);
        if (len >= 4) memcpy(bytes, &val, 4);
        else           memcpy(bytes, &val, len);
        return true;
    }

    bool store(reg_t addr, size_t len, const uint8_t *bytes) override
    {
        if (addr > GPIO_ADDR_MAX) return false;
        uint32_t val = 0;
        if (len >= 4) memcpy(&val, bytes, 4);
        else           memcpy(&val, bytes, len);
        reg_write(addr, val);
        return true;
    }

    reg_t size() override { return (reg_t)KV_GPIO_SIZE; }

private:
    sim_t   *sim_;
    uint32_t out_[GPIO_NUM_BANKS];
    uint32_t dir_[GPIO_NUM_BANKS];
    uint32_t ie_[GPIO_NUM_BANKS];
    uint32_t trigger_[GPIO_NUM_BANKS];
    uint32_t polarity_[GPIO_NUM_BANKS];
    uint32_t is_[GPIO_NUM_BANKS];
    uint32_t loopback_[GPIO_NUM_BANKS];

    // Decode bank from address: banks are 4-byte aligned within each 0x10-byte group
    static uint32_t bank(reg_t addr) { return (uint32_t)((addr & 0xCu) >> 2u); }

    // ── PLIC IRQ ─────────────────────────────────────────────────────────────

    void update_meip() const
    {
#ifdef SPIKE_INCLUDE
        if (!sim_) return;
        bool pending = false;
        for (uint32_t b = 0; b < GPIO_NUM_BANKS && !pending; b++) {
            uint32_t input = out_[b] & loopback_[b];
            // Edge-triggered: IS bits that are enabled
            bool edge_pend  = (is_[b] & trigger_[b] & ie_[b]) != 0;
            // Level-triggered, high-active
            bool level_hi   = ((~trigger_[b]) & polarity_[b] & ie_[b] & input) != 0;
            // Level-triggered, low-active: fire when the bit is NOT driven high
            uint32_t lo_bits = (~trigger_[b]) & (~polarity_[b]) & ie_[b] & loopback_[b];
            bool level_lo   = (lo_bits & ~input) != 0;
            pending = edge_pend || level_hi || level_lo;
        }
        sim_->get_intctrl()->set_interrupt_level(
            (uint32_t)KV_PLIC_SRC_GPIO, pending ? 1 : 0);
#endif
    }

    // Called after every output change; detects edges and updates IS.
    void detect_edge(uint32_t b, uint32_t old_out, uint32_t new_out)
    {
        // Only loopback pins can see their own output as input.
        // Rising edge (0→1) fires if TRIGGER=1 and POLARITY=1 and IE=1.
        uint32_t rising  = (new_out & ~old_out) & loopback_[b] & trigger_[b] & polarity_[b] & ie_[b];
        // Falling edge (1→0) fires if TRIGGER=1 and POLARITY=0 and IE=1.
        uint32_t falling = (~new_out & old_out) & loopback_[b] & trigger_[b] & (~polarity_[b]) & ie_[b];
        is_[b] |= (rising | falling);
        update_meip();
    }

    // ── Register access ──────────────────────────────────────────────────────

    uint32_t reg_read(reg_t addr)
    {
        if (addr == GPIO_ADDR_MAX) return GPIO_CAP_VAL;
        uint32_t b = bank(addr);
        reg_t group = addr & ~(reg_t)0xFu;
        switch (group) {
        case KV_GPIO_DATA_OUT0_OFF & ~(reg_t)0xFu: return out_[b];
        case KV_GPIO_SET0_OFF      & ~(reg_t)0xFu: return out_[b];
        case KV_GPIO_CLEAR0_OFF    & ~(reg_t)0xFu: return out_[b];
        case KV_GPIO_DATA_IN0_OFF  & ~(reg_t)0xFu: return out_[b] & loopback_[b];
        case KV_GPIO_DIR0_OFF      & ~(reg_t)0xFu: return dir_[b];
        case KV_GPIO_IE0_OFF       & ~(reg_t)0xFu: return ie_[b];
        case KV_GPIO_TRIGGER0_OFF  & ~(reg_t)0xFu: return trigger_[b];
        case KV_GPIO_POLARITY0_OFF & ~(reg_t)0xFu: return polarity_[b];
        case KV_GPIO_IS0_OFF       & ~(reg_t)0xFu: return is_[b];
        case KV_GPIO_LOOPBACK0_OFF & ~(reg_t)0xFu: return loopback_[b];
        default: return 0u;
        }
    }

    void reg_write(reg_t addr, uint32_t val)
    {
        if (addr == GPIO_ADDR_MAX) return;
        uint32_t b = bank(addr);
        reg_t group = addr & ~(reg_t)0xFu;
        switch (group) {
        case KV_GPIO_DATA_OUT0_OFF & ~(reg_t)0xFu: {
            uint32_t old = out_[b]; out_[b] = val;
            detect_edge(b, old, out_[b]); break;
        }
        case KV_GPIO_SET0_OFF & ~(reg_t)0xFu: {
            uint32_t old = out_[b]; out_[b] |= val;
            detect_edge(b, old, out_[b]); break;
        }
        case KV_GPIO_CLEAR0_OFF & ~(reg_t)0xFu: {
            uint32_t old = out_[b]; out_[b] &= ~val;
            detect_edge(b, old, out_[b]); break;
        }
        case KV_GPIO_DATA_IN0_OFF  & ~(reg_t)0xFu: /* read-only */ break;
        case KV_GPIO_DIR0_OFF      & ~(reg_t)0xFu: dir_[b]      = val;   break;
        case KV_GPIO_IE0_OFF       & ~(reg_t)0xFu:
            ie_[b] = val; update_meip(); break;
        case KV_GPIO_TRIGGER0_OFF  & ~(reg_t)0xFu:
            trigger_[b] = val; update_meip(); break;
        case KV_GPIO_POLARITY0_OFF & ~(reg_t)0xFu:
            polarity_[b] = val; update_meip(); break;
        case KV_GPIO_IS0_OFF & ~(reg_t)0xFu:
            is_[b] &= ~val; update_meip(); break;   // W1C
        case KV_GPIO_LOOPBACK0_OFF & ~(reg_t)0xFu:
            loopback_[b] = val; update_meip(); break;
        default: break;
        }
    }
};

static plugin_gpio_t *
plugin_gpio_parse(const void *, const sim_t *sim, reg_t *base,
                  const std::vector<std::string> &sargs)
{
    if (!sargs.empty()) *base = strtoull(sargs[0].c_str(), nullptr, 0);
    return new plugin_gpio_t(const_cast<sim_t *>(sim));
}

static std::string
plugin_gpio_generate_dts(const sim_t *, const std::vector<std::string> &)
{ return ""; }

REGISTER_DEVICE(plugin_gpio, plugin_gpio_parse, plugin_gpio_generate_dts)

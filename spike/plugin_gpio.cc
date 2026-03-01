// ============================================================================
// File: plugin_gpio.cc
// Project: KV32 RISC-V Processor
// Description: Spike MMIO plugin for the KV32 GPIO peripheral
//
// Register Map (relative to KV_GPIO_BASE = 0x2004_0000):
//   0x00-0x0C  DATA_OUT[0-3]  - Output data (R/W)
//   0x10-0x1C  SET[0-3]       - Write-1-to-set output bits
//   0x20-0x2C  CLEAR[0-3]     - Write-1-to-clear output bits
//   0x30-0x3C  DATA_IN[0-3]   - Input data (RO): loopback? out : 0
//   0x40-0x4C  DIR[0-3]       - Direction: 1=output (R/W)
//   0x50-0x5C  IE[0-3]        - Interrupt enable (R/W)
//   0x60-0x6C  TRIGGER[0-3]   - Trigger type: 1=edge, 0=level (R/W)
//   0x70-0x7C  POLARITY[0-3]  - Polarity (R/W)
//   0x80-0x8C  IS[0-3]        - Interrupt status (W1C)
//   0x90-0x9C  LOOPBACK[0-3]  - Loopback enable (R/W)
//   0xA0       CAP            - [7:0]=NUM_PINS, [15:8]=NUM_BANKS, [31:16]=VERSION
//   >0xA0       —             - Bus error
//
// Simulation behaviour:
//   When LOOPBACK[bank] bit for a pin is set, DATA_IN[bank] reflects DATA_OUT[bank]
//   for that pin.  Otherwise pins read as 0.  Interrupt status is not raised
//   automatically (no real edge detection in simulation).
// ============================================================================

#include <riscv/abstract_device.h>

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
    plugin_gpio_t()
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
    uint32_t out_[GPIO_NUM_BANKS];
    uint32_t dir_[GPIO_NUM_BANKS];
    uint32_t ie_[GPIO_NUM_BANKS];
    uint32_t trigger_[GPIO_NUM_BANKS];
    uint32_t polarity_[GPIO_NUM_BANKS];
    uint32_t is_[GPIO_NUM_BANKS];
    uint32_t loopback_[GPIO_NUM_BANKS];

    // Decode bank from address (step 4 within each group of 4 regs × 4 bytes).
    // Each group of 4 registers = 0x10 bytes; bank = (addr & 0xF) / 4
    static uint32_t bank(reg_t addr) { return (uint32_t)((addr & 0xCu) >> 2u); }

    uint32_t reg_read(reg_t addr)
    {
        if (addr == GPIO_ADDR_MAX) return GPIO_CAP_VAL;
        uint32_t b = bank(addr);
        reg_t group = addr & ~(reg_t)0xFu; // strip bank bits
        switch (group) {
        case KV_GPIO_DATA_OUT0_OFF & ~(reg_t)0xFu: return out_[b];
        case KV_GPIO_SET0_OFF      & ~(reg_t)0xFu: return out_[b]; // reads back output
        case KV_GPIO_CLEAR0_OFF    & ~(reg_t)0xFu: return out_[b]; // reads back output
        case KV_GPIO_DATA_IN0_OFF  & ~(reg_t)0xFu:
            // Loopback: each bit follows out_ if loopback enabled for that bit
            return out_[b] & loopback_[b];
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
        if (addr == GPIO_ADDR_MAX) return; // CAP read-only
        uint32_t b = bank(addr);
        reg_t group = addr & ~(reg_t)0xFu;
        switch (group) {
        case KV_GPIO_DATA_OUT0_OFF & ~(reg_t)0xFu: out_[b]      = val;   break;
        case KV_GPIO_SET0_OFF      & ~(reg_t)0xFu: out_[b]     |= val;   break;
        case KV_GPIO_CLEAR0_OFF    & ~(reg_t)0xFu: out_[b]     &= ~val;  break;
        case KV_GPIO_DATA_IN0_OFF  & ~(reg_t)0xFu: /* read-only */        break;
        case KV_GPIO_DIR0_OFF      & ~(reg_t)0xFu: dir_[b]      = val;   break;
        case KV_GPIO_IE0_OFF       & ~(reg_t)0xFu: ie_[b]       = val;   break;
        case KV_GPIO_TRIGGER0_OFF  & ~(reg_t)0xFu: trigger_[b]  = val;   break;
        case KV_GPIO_POLARITY0_OFF & ~(reg_t)0xFu: polarity_[b] = val;   break;
        case KV_GPIO_IS0_OFF       & ~(reg_t)0xFu: is_[b]      &= ~val;  break; // W1C
        case KV_GPIO_LOOPBACK0_OFF & ~(reg_t)0xFu: loopback_[b] = val;   break;
        default: break;
        }
    }
};

static plugin_gpio_t *
plugin_gpio_parse(const void *, const sim_t *, reg_t *base,
                  const std::vector<std::string> &sargs)
{
    if (!sargs.empty()) *base = strtoull(sargs[0].c_str(), nullptr, 0);
    return new plugin_gpio_t();
}

static std::string
plugin_gpio_generate_dts(const sim_t *, const std::vector<std::string> &)
{ return ""; }

REGISTER_DEVICE(plugin_gpio, plugin_gpio_parse, plugin_gpio_generate_dts)

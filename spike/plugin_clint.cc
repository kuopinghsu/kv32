// ============================================================================
// File: plugin_clint.cc
// Project: KV32 RISC-V Processor
// Description: Spike MMIO plugin for the KV32 CLINT (Core-Local Interrupt)
//
// Register Map (relative to KV_CLINT_BASE = 0x0200_0000):
//   0x00000  MSIP         - Machine Software Interrupt Pending (R/W, [0] = msip)
//   0x04000  MTIMECMP_LO  - Timer Compare register, low 32 bits (R/W)
//   0x04004  MTIMECMP_HI  - Timer Compare register, high 32 bits (R/W)
//   0x0BFF8  MTIME_LO     - Current time, low 32 bits (R/W)
//   0x0BFFC  MTIME_HI     - Current time, high 32 bits (R/W)
//   other    —            * Bus error (load/store access-fault)
//
// Behaviour:
//   mtime increments by 1 on each tick() call (RTC @ 1 MHz → 1 µs per tick).
//   Spike reads mtime/mtimecmp from this plugin when running rv32 code that
//   accesses the CLINT MMIO window, so CSR emulation stays consistent.
// ============================================================================

#include <riscv/abstract_device.h>

#include <cstring>
#include <string>
#include <vector>

#include "kv_platform.h"

class plugin_clint_t : public abstract_device_t {
public:
    plugin_clint_t() : msip_(0), mtime_(0), mtimecmp_(UINT64_MAX) {}

    bool load(reg_t addr, size_t len, uint8_t *bytes) override
    {
        uint32_t val = 0;
        bool ok = reg_read32(addr, &val);
        if (!ok) return false;
        memset(bytes, 0, len);
        if (len >= 4) memcpy(bytes, &val, 4);
        else           memcpy(bytes, &val, len);
        return true;
    }

    bool store(reg_t addr, size_t len, const uint8_t *bytes) override
    {
        uint32_t val = 0;
        if (len >= 4) memcpy(&val, bytes, 4);
        else           memcpy(&val, bytes, len);
        return reg_write32(addr, val);
    }

    void tick(reg_t /*rtc_ticks*/) override { mtime_++; }

    reg_t size() override { return (reg_t)KV_CLINT_SIZE; }

private:
    uint32_t msip_;
    uint64_t mtime_;
    uint64_t mtimecmp_;

    bool reg_read32(reg_t addr, uint32_t *out)
    {
        switch (addr) {
        case KV_CLINT_MSIP_OFF:
            *out = msip_ & 1u;                      return true;
        case KV_CLINT_MTIMECMP_LO_OFF:
            *out = (uint32_t)(mtimecmp_ & 0xFFFFFFFFu); return true;
        case KV_CLINT_MTIMECMP_HI_OFF:
            *out = (uint32_t)(mtimecmp_ >> 32);      return true;
        case KV_CLINT_MTIME_LO_OFF:
            *out = (uint32_t)(mtime_ & 0xFFFFFFFFu); return true;
        case KV_CLINT_MTIME_HI_OFF:
            *out = (uint32_t)(mtime_ >> 32);         return true;
        default:
            return false;  // unmapped offset → bus error
        }
    }

    bool reg_write32(reg_t addr, uint32_t val)
    {
        switch (addr) {
        case KV_CLINT_MSIP_OFF:
            msip_ = val & 1u;                        return true;
        case KV_CLINT_MTIMECMP_LO_OFF:
            mtimecmp_ = (mtimecmp_ & 0xFFFFFFFF00000000ULL) | val; return true;
        case KV_CLINT_MTIMECMP_HI_OFF:
            mtimecmp_ = ((uint64_t)val << 32) | (mtimecmp_ & 0xFFFFFFFFULL); return true;
        case KV_CLINT_MTIME_LO_OFF:
            mtime_ = (mtime_ & 0xFFFFFFFF00000000ULL) | val;       return true;
        case KV_CLINT_MTIME_HI_OFF:
            mtime_ = ((uint64_t)val << 32) | (mtime_ & 0xFFFFFFFFULL); return true;
        default:
            return false;  // unmapped offset → bus error
        }
    }
};

static plugin_clint_t *
plugin_clint_parse(const void *, const sim_t *, reg_t *base,
                   const std::vector<std::string> &sargs)
{
    if (!sargs.empty()) *base = strtoull(sargs[0].c_str(), nullptr, 0);
    return new plugin_clint_t();
}

static std::string
plugin_clint_generate_dts(const sim_t *, const std::vector<std::string> &)
{ return ""; }

REGISTER_DEVICE(plugin_clint, plugin_clint_parse, plugin_clint_generate_dts)

// ============================================================================
// File: plugin_plic.cc
// Project: KV32 RISC-V Processor
// Description: Spike MMIO plugin for the KV32 PLIC
//
// Register Map (relative to KV_PLIC_BASE = 0x0C00_0000, size 64 MB):
//   0x000000 + n*4  Source priority[n] (R/W)
//   0x001000        Pending bits (RO)
//   0x002000        Enable bits, context 0 (R/W)
//   0x200000        Priority threshold, context 0 (R/W)
//   0x200004        Claim / complete, context 0 (R/W)
//   other           — Accepted (PLIC space is sparsely populated; all
//                     within-window accesses return 0 / silently drop,
//                     which matches real PLIC hardware behaviour for
//                     reserved offsets.)
//
// No real interrupt routing is implemented.  claim reads return 0
// (no pending interrupt) and complete writes are silently ignored.
// ============================================================================

#include <riscv/abstract_device.h>

#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

#include "kv_platform.h"

static constexpr size_t PLIC_NUM_SOURCES = 8;  // IRQ IDs 1-7 used by KV32

class plugin_plic_t : public abstract_device_t {
public:
    bool load(reg_t addr, size_t len, uint8_t *bytes) override
    {
        // All aligned 32-bit reads within the 64 MB window are permitted.
        if (addr + len > KV_PLIC_SIZE || (addr & 3u)) return false;
        uint32_t val = reg_read(addr);
        memset(bytes, 0, len);
        if (len >= 4) memcpy(bytes, &val, 4);
        else           memcpy(bytes, &val, len);
        return true;
    }

    bool store(reg_t addr, size_t len, const uint8_t *bytes) override
    {
        if (addr + len > KV_PLIC_SIZE || (addr & 3u)) return false;
        uint32_t val = 0;
        if (len >= 4) memcpy(&val, bytes, 4);
        else           memcpy(&val, bytes, len);
        reg_write(addr, val);
        return true;
    }

    reg_t size() override { return (reg_t)KV_PLIC_SIZE; }

private:
    // Sparse register storage for the registers software actually touches.
    std::unordered_map<uint32_t, uint32_t> regs_;

    uint32_t reg_read(reg_t addr)
    {
        // Claim register: always return 0 (no pending interrupt).
        if (addr == KV_PLIC_CLAIM_OFF) return 0;
        auto it = regs_.find((uint32_t)addr);
        return (it != regs_.end()) ? it->second : 0u;
    }

    void reg_write(reg_t addr, uint32_t val)
    {
        // Complete register: clear the source from pending (no-op in stub).
        if (addr == KV_PLIC_CLAIM_OFF) return;
        // Priority registers: clamp to 7 bits.
        if (addr >= KV_PLIC_PRIORITY_OFF &&
            addr <  KV_PLIC_PRIORITY_OFF + PLIC_NUM_SOURCES * 4)
            val &= 0x7u;
        regs_[(uint32_t)addr] = val;
    }
};

static plugin_plic_t *
plugin_plic_parse(const void *, const sim_t *, reg_t *base,
                  const std::vector<std::string> &sargs)
{
    if (!sargs.empty()) *base = strtoull(sargs[0].c_str(), nullptr, 0);
    return new plugin_plic_t();
}

static std::string
plugin_plic_generate_dts(const sim_t *, const std::vector<std::string> &)
{ return ""; }

REGISTER_DEVICE(plugin_plic, plugin_plic_parse, plugin_plic_generate_dts)

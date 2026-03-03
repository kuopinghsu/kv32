// ============================================================================
// File: plugin_plic.cc
// Project: KV32 RISC-V Processor
// Description: Spike MMIO plugin for the KV32 PLIC, with MEIP signal routing
//
// Register Map (relative to KV_PLIC_BASE = 0x0C00_0000, size 16 MB):
//   0x000000 + n*4  Source priority[n]    (R/W, n = 1..PLIC_NUM_SOURCES-1)
//   0x001000        Pending bits          (RO)
//   0x002000        Enable bits, ctx 0    (R/W)
//   0x200000        Priority threshold    (R/W)
//   0x200004        Claim / complete      (R/W)
//
// Interrupt routing (Spike simulation):
//   Peripheral plugins (UART, SPI, …) call mip.backdoor_write_with_mask()
//   directly to assert MIP.MEIP when their IRQ is active.  The PLIC plugin
//   arbitrates claim/complete as follows:
//
//   claim read:
//     - If MIP.MEIP is asserted, scan for the highest-priority enabled source
//       whose priority > threshold.
//     - Deassert MIP.MEIP immediately (prevents handler re-entry while the
//       source is "in service").  The peripheral plugin will re-assert on its
//       next tick() if the condition is still true.
//     - Return the found source ID (0 if none).
//
//   complete write:
//     - Clear the in-service flag.  MIP.MEIP is re-asserted by the peripheral
//       plugin on its next tick() if the IRQ condition is still active.
//
// Note: Spike's default memory map does NOT include a built-in PLIC (only a
// built-in CLINT at 0x2000000).  This plugin registers at 0x0C000000 without
// any address conflict.
// ============================================================================

#include <riscv/abstract_device.h>

#ifdef SPIKE_INCLUDE
#include <riscv/sim.h>
#include <riscv/processor.h>
#include <riscv/encoding.h>
#endif

#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

#include "kv_platform.h"

static constexpr size_t PLIC_NUM_SOURCES = 8;  // IRQ IDs 1-7 used by KV32

class plugin_plic_t : public abstract_device_t {
public:
    explicit plugin_plic_t(sim_t *sim)
        : sim_(sim), claimed_source_(0) {}

    bool load(reg_t addr, size_t len, uint8_t *bytes) override
    {
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
    sim_t   *sim_;
    uint32_t claimed_source_;  // source currently "in service" (0 = none)

    // Sparse register storage keyed by byte offset within the PLIC window.
    std::unordered_map<uint32_t, uint32_t> regs_;

    // ── MIP helpers ─────────────────────────────────────────────────────────

    bool meip_is_asserted() const
    {
#ifdef SPIKE_INCLUDE
        if (!sim_) return false;
        return (sim_->get_core(0)->get_state()->mip->read() & MIP_MEIP) != 0;
#else
        return false;
#endif
    }

    void deassert_meip() const
    {
#ifdef SPIKE_INCLUDE
        if (!sim_) return;
        sim_->get_core(0)->get_state()->mip
            ->backdoor_write_with_mask(MIP_MEIP, 0);
#endif
    }

    // ── PLIC arbitration ────────────────────────────────────────────────────

    // Return the highest-priority enabled source whose priority > threshold.
    // Returns 0 if no such source exists.
    uint32_t find_best_source() const
    {
        uint32_t threshold = 0, enable = 0;
        {
            auto it = regs_.find((uint32_t)KV_PLIC_THRESHOLD_OFF);
            if (it != regs_.end()) threshold = it->second;
        }
        {
            auto it = regs_.find((uint32_t)KV_PLIC_ENABLE_OFF);
            if (it != regs_.end()) enable = it->second;
        }
        uint32_t best_src = 0, best_pri = threshold;
        for (uint32_t src = 1; src < PLIC_NUM_SOURCES; ++src) {
            if (!(enable & (1u << src))) continue;
            uint32_t pri = 0;
            auto it = regs_.find((uint32_t)(KV_PLIC_PRIORITY_OFF + src * 4));
            if (it != regs_.end()) pri = it->second & 0x7u;
            if (pri > best_pri) { best_pri = pri; best_src = src; }
        }
        return best_src;
    }

    // ── register access ─────────────────────────────────────────────────────

    uint32_t reg_read(reg_t addr)
    {
        if (addr == KV_PLIC_CLAIM_OFF) {
            if (!meip_is_asserted()) return 0u;
            claimed_source_ = find_best_source();
            // Deassert MEIP immediately to prevent spurious re-entry while
            // the handler executes.  The peripheral plugin's next tick() will
            // re-assert MEIP if the IRQ condition is still true.
            deassert_meip();
            return claimed_source_;
        }
        auto it = regs_.find((uint32_t)addr);
        return (it != regs_.end()) ? it->second : 0u;
    }

    void reg_write(reg_t addr, uint32_t val)
    {
        if (addr == KV_PLIC_CLAIM_OFF) {
            // Complete: source is no longer in service.
            // MIP.MEIP will be re-asserted by the peripheral plugin's next
            // tick() if the IRQ condition is still active.
            if (val == claimed_source_) claimed_source_ = 0;
            return;
        }
        if (addr >= KV_PLIC_PRIORITY_OFF &&
            addr <  KV_PLIC_PRIORITY_OFF + (uint32_t)(PLIC_NUM_SOURCES * 4))
            val &= 0xFu;
        regs_[(uint32_t)addr] = val;
    }
};

static plugin_plic_t *
plugin_plic_parse(const void *, const sim_t *sim, reg_t *base,
                  const std::vector<std::string> &sargs)
{
    if (!sargs.empty()) *base = strtoull(sargs[0].c_str(), nullptr, 0);
    return new plugin_plic_t(const_cast<sim_t *>(sim));
}

static std::string
plugin_plic_generate_dts(const sim_t *, const std::vector<std::string> &)
{ return ""; }

REGISTER_DEVICE(plugin_plic, plugin_plic_parse, plugin_plic_generate_dts)

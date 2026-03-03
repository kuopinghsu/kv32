// ============================================================================
// File: plugin_magic.cc
// Project: KV32 RISC-V Processor
// Description: Spike MMIO plugin for the KV32 "Magic" simulation-control device
//
// Implements a Spike abstract_device_t that handles accesses to the Magic
// address window.  Only two offsets are functional; all other accesses return
// false, which Spike translates into a load/store access-fault exception on
// the hart (mirrors RTL AXI SLVERR behaviour).
//
// Register Map (offsets relative to KV_MAGIC_BASE = 0x4000_0000):
//   0x0000  KV_MAGIC_CONSOLE_OFF  - W  Console: low byte written to stdout
//   0x0004  KV_MAGIC_EXIT_OFF     - W  Exit: low 32-bit word = exit code
//   ...     —                     * *  Bus error (load/store access-fault)
//
// Bus Error Detection:
//   load()  – returns false for any offset != CONSOLE_OFF and != EXIT_OFF
//   store() – default case returns false for any unrecognised offset
//
// Usage:
//   spike --extlib=./plugin_magic.so \
//         --device="plugin_magic,0x40000000" ...
// ============================================================================

#include <riscv/abstract_device.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "kv_platform.h"

// --------------------------------------------------------------------------
// Device implementation
// --------------------------------------------------------------------------
class plugin_magic_t : public abstract_device_t {
public:
    // Loads to EXIT_OFF or CONSOLE_OFF return 0; any other offset is a bus
    // error (returns false → Spike raises load access-fault exception).
    bool load(reg_t addr, size_t len, uint8_t *bytes) override
    {
        if (addr != KV_MAGIC_EXIT_OFF && addr != KV_MAGIC_CONSOLE_OFF)
            return false;   // out-of-range: bus error
        memset(bytes, 0, len);
        return true;
    }

    bool store(reg_t addr, size_t len, const uint8_t *bytes) override
    {
        switch (addr) {
        case KV_MAGIC_CONSOLE_OFF: {
            // console output: print least-significant byte
            char ch = static_cast<char>(bytes[0]);
            fputc(ch, stdout);
            fflush(stdout);
            return true;
        }
        case KV_MAGIC_EXIT_OFF: {
            // Decode HTIF tohost encoding (matches kv32sim device.cpp and RTL):
            //   pass (code 0) → firmware writes 1
            //   fail (code N) → firmware writes (N << 1) | 1
            // Recover the original exit code as: (raw >> 1) & 0x7FFFFFFF
            uint32_t raw = 0;
            if (len >= 4)
                memcpy(&raw, bytes, 4);
            else if (len >= 1)
                raw = static_cast<uint32_t>(bytes[0]);
            int code = static_cast<int>((raw >> 1) & 0x7FFFFFFF);
            exit(code);
        }
        default:
            return false;   // out-of-range: bus error
        }
    }

    // Called by Spike once per RTC tick.
    // rtc_ticks is the cumulative RTC tick count since simulation start.
    void tick(reg_t rtc_ticks) override
    {
        (void)rtc_ticks;
        // Hook for periodic device logic (e.g. raising interrupts, updating
        // status registers).  Currently a no-op placeholder.
    }

    // KV_MAGIC_BASE(0x40000000) + KV_MAGIC_SIZE(0x10000) = 0x4001_0000.
    // reg_t is uint64_t, so no overflow occurs; Spike routes every rv32
    // address in [0x40000000, 0x4000ffff] to this device.  Offsets other than
    // CONSOLE_OFF and EXIT_OFF trigger a bus error.
    reg_t size() override { return (reg_t)KV_MAGIC_SIZE; }
};

// --------------------------------------------------------------------------
// Factory helpers required by REGISTER_DEVICE
// --------------------------------------------------------------------------
static plugin_magic_t *
plugin_magic_parse(const void * /*fdt*/, const sim_t * /*sim*/,
            reg_t *base, const std::vector<std::string> &sargs)
{
    // Spike passes the address from --device="plugin_magic,0x..." in sargs[0].
    if (!sargs.empty())
        *base = strtoull(sargs[0].c_str(), nullptr, 0);
    return new plugin_magic_t();
}

static std::string
plugin_magic_generate_dts(const sim_t * /*sim*/, const std::vector<std::string> & /*sargs*/)
{
    return "";
}

// --------------------------------------------------------------------------
// Registration — inserts "plugin_magic" into Spike's global mmio_device_map()
// via the factory's constructor (invoked when the .so is dlopen'd by Spike).
// --------------------------------------------------------------------------
REGISTER_DEVICE(plugin_magic, plugin_magic_parse, plugin_magic_generate_dts)

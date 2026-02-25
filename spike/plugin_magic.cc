/* ============================================================================
 * spike/plugin_magic.cc – Spike plugin for the RV32 "Magic" device
 *
 * Base address : RV_MAGIC_BASE  (0xFFFF_0000)
 * Window       : RV_MAGIC_SIZE  (64 KB)
 *
 * Register offsets (from rv_platform.h):
 *   RV_MAGIC_EXIT_OFF     (0xFFF0)  write exit-code encoding
 *   RV_MAGIC_CONSOLE_OFF  (0xFFF4)  write low byte → stdout
 *
 * Enables non-HTIF firmware binaries to produce console output and exit
 * cleanly when run under Spike with the rv32_soc plugin set.
 *
 * Load with:
 *   spike --extlib=build/spike_plugin_magic.so \
 *         --device=rv32_magic,0x$(printf '%X' RV_MAGIC_BASE) ...
 * =========================================================================*/
#include "mmio_plugin_api.h"
#include <stdio.h>
#include <stdlib.h>

static void* magic_alloc(const char* /*args*/) { return (void*)(uintptr_t)1; }
static void  magic_dealloc(void* /*dev*/)       { }

static bool magic_access(void* /*dev*/, reg_t addr,
                          size_t len, uint8_t* bytes, bool store)
{
    if (store) {
        uint32_t val = extract_val(bytes, len);
        if ((uint32_t)addr == RV_MAGIC_EXIT_OFF) {
            /* HTIF-compatible encoding: 1=pass, (N<<1)|1=fail(N) */
            int code = (val == 1u) ? 0 : (int)((val >> 1) & 0x7FFFFFFFu);
            fflush(stdout);
            exit(code);
        } else if ((uint32_t)addr == RV_MAGIC_CONSOLE_OFF) {
            fputc((int)(val & 0xFFu), stdout);
            fflush(stdout);
        }
    } else {
        fill_bytes(bytes, len, 0u);
    }
    return true;
}

static const mmio_plugin_t plugin = { magic_alloc, magic_dealloc, magic_access };

__attribute__((constructor))
static void plugin_init() {
    register_mmio_plugin("rv32_magic", &plugin);
}

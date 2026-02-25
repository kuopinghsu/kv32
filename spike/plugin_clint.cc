/* ============================================================================
 * spike/plugin_clint.cc – Spike MMIO plugin for the RV32 CLINT
 *
 * Base address : RV_CLINT_BASE  (0x0200_0000)
 * Window size  : RV_CLINT_SIZE  (64 KB)
 *
 * Register offsets (from rv_platform.h):
 *   RV_CLINT_MSIP_OFF         (0x00000)  machine software IRQ pending
 *   RV_CLINT_MTIMECMP_LO_OFF  (0x04000)  timer compare [31:0]
 *   RV_CLINT_MTIMECMP_HI_OFF  (0x04004)  timer compare [63:32]
 *   RV_CLINT_MTIME_LO_OFF     (0x0BFF8)  current time [31:0]  (RO)
 *   RV_CLINT_MTIME_HI_OFF     (0x0BFFC)  current time [63:32] (RO)
 *
 * mtime increments by 1 on every read so that firmware polling on mtime
 * always makes forward progress in simulation.
 * =========================================================================*/
#include "mmio_plugin_api.h"
#include <stdlib.h>

struct clint_t {
    uint32_t msip;
    uint64_t mtimecmp;
    uint64_t mtime;
};

static void* clint_alloc(const char* /*args*/) {
    clint_t* c = (clint_t*)calloc(1, sizeof(clint_t));
    c->mtimecmp = UINT64_MAX;   /* no timer interrupt at reset */
    return c;
}

static void clint_dealloc(void* dev) {
    free(dev);
}

static bool clint_access(void* dev, reg_t addr,
                          size_t len, uint8_t* bytes, bool store)
{
    clint_t* c   = (clint_t*)dev;
    uint32_t off = (uint32_t)addr;

    if (!store) {
        uint32_t val = 0;
        if      (off == (uint32_t)RV_CLINT_MSIP_OFF)
            val = c->msip & 1u;
        else if (off == (uint32_t)RV_CLINT_MTIMECMP_LO_OFF)
            val = (uint32_t)(c->mtimecmp);
        else if (off == (uint32_t)RV_CLINT_MTIMECMP_HI_OFF)
            val = (uint32_t)(c->mtimecmp >> 32);
        else if (off == (uint32_t)RV_CLINT_MTIME_LO_OFF) {
            c->mtime++;             /* advance so polling terminates */
            val = (uint32_t)(c->mtime);
        } else if (off == (uint32_t)RV_CLINT_MTIME_HI_OFF) {
            val = (uint32_t)(c->mtime >> 32);
        }
        fill_bytes(bytes, len, val);
    } else {
        uint32_t val = extract_val(bytes, len);
        if      (off == (uint32_t)RV_CLINT_MSIP_OFF)
            c->msip = val & 1u;
        else if (off == (uint32_t)RV_CLINT_MTIMECMP_LO_OFF)
            c->mtimecmp = (c->mtimecmp & 0xFFFFFFFF00000000ULL) | val;
        else if (off == (uint32_t)RV_CLINT_MTIMECMP_HI_OFF)
            c->mtimecmp = (c->mtimecmp & 0x00000000FFFFFFFFULL) |
                          ((uint64_t)val << 32);
        /* mtime registers are read-only from the CPU side */
    }
    return true;
}

static const mmio_plugin_t clint_plugin = {
    clint_alloc, clint_dealloc, clint_access
};

__attribute__((constructor))
static void plugin_init() {
    register_mmio_plugin("rv32_clint", &clint_plugin);
}

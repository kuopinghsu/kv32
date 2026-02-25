/* ============================================================================
 * spike/plugin_plic.cc – Spike plugin for the RV32 PLIC
 *
 * Base address : RV_PLIC_BASE  (0x0C00_0000)  from rv_platform.h
 * Window       : RV_PLIC_SIZE  (64 MB)
 *
 * Register offsets (all from rv_platform.h):
 *   RV_PLIC_PRIORITY_OFF  (0x000000 + src*4)  source priority registers
 *   RV_PLIC_PENDING_OFF   (0x001000)           pending bitmask (RO from CPU)
 *   RV_PLIC_ENABLE_OFF    (0x002000)           context-0 enable bitmask
 *   RV_PLIC_THRESHOLD_OFF (0x200000)           context-0 priority threshold
 *   RV_PLIC_CLAIM_OFF     (0x200004)           context-0 claim (R) / complete (W)
 *
 * IRQ source IDs from rv_platform.h:
 *   RV_PLIC_SRC_UART=1  RV_PLIC_SRC_SPI=2  RV_PLIC_SRC_I2C=3  RV_PLIC_SRC_DMA=4
 *
 * plic_set_pending(src, asserted) is exported as extern "C" so that
 * peripheral plugins can inject pending bits via plic_notify() from
 * mmio_plugin_api.h (resolved lazily with dlsym).
 * =========================================================================*/
#include "mmio_plugin_api.h"
#include <string.h>
#include <stdlib.h>

/* All register offsets come from rv_platform.h via mmio_plugin_api.h */
#define PLIC_NUM_SRC   16      /* max source ID supported (1..15)        */
#define PLIC_NUM_CTX    1      /* only context 0 (hart 0 M-mode)         */

/* Per-instance state */
struct plic_t {
    uint32_t priority[PLIC_NUM_SRC + 1]; /* [0] unused, [1..NUM_SRC]      */
    uint32_t pending;                    /* bitmask; bit 0 unused          */
    uint32_t enable;                     /* context 0 enable bitmask       */
    uint32_t threshold;                  /* context 0 threshold            */
    uint32_t in_service;                 /* bitmask of claimed sources      */
};

/* ── Global pending-bit interface: peripheral plugins call this ─────────── */
/* We keep a single global PLIC instance so other .so plugins loaded in the  */
/* same process can inject pending bits without needing a shared handle.     */
static plic_t* g_plic = nullptr;

extern "C" void plic_set_pending(int src, int asserted) {
    if (!g_plic || src < 1 || src > PLIC_NUM_SRC) return;
    if (asserted)
        g_plic->pending |=  (1u << src);
    else
        g_plic->pending &= ~(1u << src);
}
extern "C" int plic_is_pending(int src) {
    if (!g_plic || src < 1 || src > PLIC_NUM_SRC) return 0;
    return (g_plic->pending >> src) & 1u;
}

/* ── Scheduler: best pending+enabled source above threshold ─────────────── */
static int plic_claim(const plic_t* p) {
    int best_src = 0;
    uint32_t best_pri = p->threshold;
    uint32_t active = p->pending & p->enable & ~p->in_service;
    for (int s = 1; s <= PLIC_NUM_SRC; s++) {
        if (!((active >> s) & 1u)) continue;
        if (p->priority[s] > best_pri) {
            best_pri = p->priority[s];
            best_src = s;
        }
    }
    return best_src;
}

/* ── mmio_plugin_t callbacks ─────────────────────────────────────────────── */
static void* plic_alloc(const char* /*args*/) {
    plic_t* p = (plic_t*)calloc(1, sizeof(plic_t));
    /* Default: each source gets priority 1 so they can all be claimed */
    for (int i = 1; i <= PLIC_NUM_SRC; i++) p->priority[i] = 1;
    g_plic = p;
    return p;
}

static void plic_dealloc(void* dev) {
    if (g_plic == (plic_t*)dev) g_plic = nullptr;
    free(dev);
}

static bool plic_access(void* dev, reg_t addr,
                         size_t len, uint8_t* bytes, bool store)
{
    plic_t* p = (plic_t*)dev;
    uint32_t off = (uint32_t)addr;

    if (!store) {
        /* ── Load ──────────────────────────────────────────────────────── */
        uint32_t val = 0;

        if (off < (uint32_t)RV_PLIC_PENDING_OFF) {
            /* Priority: RV_PLIC_PRIORITY_OFF + src*4 */
            int src = (int)((off - (uint32_t)RV_PLIC_PRIORITY_OFF) >> 2);
            if (src >= 0 && src <= PLIC_NUM_SRC)
                val = p->priority[src];
        } else if (off == (uint32_t)RV_PLIC_PENDING_OFF) {
            val = p->pending;
        } else if (off == (uint32_t)RV_PLIC_ENABLE_OFF) {
            val = p->enable;
        } else if (off == (uint32_t)RV_PLIC_THRESHOLD_OFF) {
            val = p->threshold;
        } else if (off == (uint32_t)RV_PLIC_CLAIM_OFF) {
            /* Claim: return the highest-priority pending+enabled source */
            int src = plic_claim(p);
            if (src > 0) {
                p->in_service |= (1u << src);
                /* Clear pending upon successful claim */
                p->pending    &= ~(1u << src);
            }
            val = (uint32_t)src;
        }
        fill_bytes(bytes, len, val);
    } else {
        /* ── Store ─────────────────────────────────────────────────────── */
        uint32_t val = extract_val(bytes, len);

        if (off < (uint32_t)RV_PLIC_PENDING_OFF) {
            int src = (int)((off - (uint32_t)RV_PLIC_PRIORITY_OFF) >> 2);
            if (src >= 1 && src <= PLIC_NUM_SRC)
                p->priority[src] = val & 0x7u;
        } else if (off == (uint32_t)RV_PLIC_ENABLE_OFF) {
            p->enable = val & ~1u; /* bit 0 (source 0) always 0 */
        } else if (off == (uint32_t)RV_PLIC_THRESHOLD_OFF) {
            p->threshold = val & 0x7u;
        } else if (off == (uint32_t)RV_PLIC_CLAIM_OFF) {
            /* Complete: clear the in-service bit for this source */
            int src = (int)(val & 0x3Fu);
            if (src >= 1 && src <= PLIC_NUM_SRC)
                p->in_service &= ~(1u << src);
        }
        /* pending register is read-only (set by peripheral logic) */
    }
    return true;
}

static const mmio_plugin_t plugin = { plic_alloc, plic_dealloc, plic_access };

__attribute__((constructor))
static void plugin_init() {
    register_mmio_plugin("rv32_plic", &plugin);
}

/* ============================================================================
 * spike/plugin_dma.cc – Spike MMIO plugin for the RV32 DMA controller
 *
 * Base address : RV_DMA_BASE  (0x2003_0000)
 * Window size  : RV_DMA_SIZE  (4 KB)
 *
 * Register layout (from rv_platform.h):
 *   Per-channel regs   BASE + ch * RV_DMA_CH_STRIDE  (0x40)
 *     RV_DMA_CH_CTRL_OFF    0x00  Control
 *     RV_DMA_CH_STAT_OFF    0x04  Status (RO)
 *     RV_DMA_CH_SRC_OFF     0x08  Source address
 *     RV_DMA_CH_DST_OFF     0x0C  Destination address
 *     RV_DMA_CH_XFER_OFF    0x10  Transfer size (bytes)
 *   Global regs
 *     RV_DMA_IRQ_STAT_OFF   0xF00 IRQ status (W1C)
 *     RV_DMA_IRQ_EN_OFF     0xF04 IRQ enable
 *     RV_DMA_ID_OFF         0xF08 ID register (RO = 0xD4A00100)
 *     RV_DMA_PERF_CTRL_OFF  0xF10 Perf counter control
 *     RV_DMA_PERF_CYCLES_OFF 0xF14 Perf: cycles
 *     RV_DMA_PERF_RD_BYTES_OFF 0xF18 Perf: read bytes
 *     RV_DMA_PERF_WR_BYTES_OFF 0xF1C Perf: write bytes
 *
 * Memory access:
 *   The plugin performs actual memcpy if a flat RAM window has been
 *   registered via dma_register_memory(base_phys, host_ptr, size).
 *   Without that registration, transfers are silently completed (stat
 *   and IRQ updated) but data is not moved.
 *
 * Usage:
 *   Before running Spike, call dma_register_memory() from another
 *   plugin or via a constructor of a wrapper .so:
 *     extern "C" void dma_register_memory(uint32_t base, void* host_ptr, size_t sz);
 * =========================================================================*/
#include "mmio_plugin_api.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

enum { DMA_NUM_CH = 4 };

/* DMA memory mapping registered by the host environment */
static uint32_t g_mem_base = 0;
static uint8_t* g_mem_ptr  = nullptr;
static size_t   g_mem_size = 0;

extern "C" void dma_register_memory(uint32_t base_phys,
                                     void*    host_ptr,
                                     size_t   byte_size)
{
    g_mem_base = base_phys;
    g_mem_ptr  = (uint8_t*)host_ptr;
    g_mem_size = byte_size;
}

static inline uint8_t* phys_to_host(uint32_t phys) {
    if (!g_mem_ptr) return nullptr;
    if (phys < g_mem_base) return nullptr;
    size_t off = phys - g_mem_base;
    if (off >= g_mem_size) return nullptr;
    return g_mem_ptr + off;
}

struct dma_ch_t {
    uint32_t ctrl;
    uint32_t stat;
    uint32_t src;
    uint32_t dst;
    uint32_t xfer;
    /* 2-D / 3-D / SG regs stored but not functionally used */
    uint32_t sstride, dstride, rowcnt;
    uint32_t spstride, dpstride, planecnt;
    uint32_t sgaddr, sgcnt;
};

struct dma_t {
    dma_ch_t ch[DMA_NUM_CH];
    uint32_t irq_stat;
    uint32_t irq_en;
    uint32_t perf_ctrl;
    uint32_t perf_cycles;
    uint32_t perf_rd_bytes;
    uint32_t perf_wr_bytes;
    int      irq_state;
};

static void dma_do_transfer(dma_t* d, int ch_idx) {
    dma_ch_t* ch = &d->ch[ch_idx];
    uint32_t  sz = ch->xfer;
    uint8_t*  src_p = phys_to_host(ch->src);
    uint8_t*  dst_p = phys_to_host(ch->dst);

    if (src_p && dst_p && sz) {
        memcpy(dst_p, src_p, sz);
        if (d->perf_ctrl & 1u) {
            d->perf_rd_bytes += sz;
            d->perf_wr_bytes += sz;
            d->perf_cycles   += sz;    /* 1 cycle per byte approximation */
        }
    }

    ch->stat &= ~(uint32_t)RV_DMA_STAT_BUSY;
    d->irq_stat |= (1u << ch_idx);     /* mark channel done */
}

static void dma_update_irq(dma_t* d) {
    int pending = (d->irq_stat & d->irq_en) ? 1 : 0;
    if (pending != d->irq_state) {
        d->irq_state = pending;
        plic_notify(RV_PLIC_SRC_DMA, pending);
    }
}

static void* dma_alloc(const char* /*args*/) { return calloc(1, sizeof(dma_t)); }
static void  dma_dealloc(void* dev)          { free(dev); }

static bool dma_access(void* dev, reg_t addr,
                        size_t len, uint8_t* bytes, bool store)
{
    dma_t*   d   = (dma_t*)dev;
    uint32_t off = (uint32_t)addr;

    /* ----- global registers ----------------------------------------- */
    if (off >= (uint32_t)RV_DMA_IRQ_STAT_OFF) {
        if (!store) {
            uint32_t val = 0;
            if      (off == (uint32_t)RV_DMA_IRQ_STAT_OFF)      val = d->irq_stat;
            else if (off == (uint32_t)RV_DMA_IRQ_EN_OFF)         val = d->irq_en;
            else if (off == (uint32_t)RV_DMA_ID_OFF)             val = 0xD4A00100u;
            else if (off == (uint32_t)RV_DMA_PERF_CTRL_OFF)      val = d->perf_ctrl;
            else if (off == (uint32_t)RV_DMA_PERF_CYCLES_OFF)    val = d->perf_cycles;
            else if (off == (uint32_t)RV_DMA_PERF_RD_BYTES_OFF)  val = d->perf_rd_bytes;
            else if (off == (uint32_t)RV_DMA_PERF_WR_BYTES_OFF)  val = d->perf_wr_bytes;
            fill_bytes(bytes, len, val);
        } else {
            uint32_t val = extract_val(bytes, len);
            if      (off == (uint32_t)RV_DMA_IRQ_STAT_OFF) {
                d->irq_stat &= ~val;    /* W1C */
                dma_update_irq(d);
            } else if (off == (uint32_t)RV_DMA_IRQ_EN_OFF) {
                d->irq_en = val;
                dma_update_irq(d);
            } else if (off == (uint32_t)RV_DMA_PERF_CTRL_OFF) {
                if (val & 2u) {         /* reset bit */
                    d->perf_cycles    = 0;
                    d->perf_rd_bytes  = 0;
                    d->perf_wr_bytes  = 0;
                }
                d->perf_ctrl = val & 1u;
            }
        }
        return true;
    }

    /* ----- per-channel registers ------------------------------------ */
    int ch_idx = (int)(off / (uint32_t)RV_DMA_CH_STRIDE);
    if (ch_idx >= DMA_NUM_CH) return true;

    uint32_t  ch_off = off % (uint32_t)RV_DMA_CH_STRIDE;
    dma_ch_t* ch     = &d->ch[ch_idx];

    if (!store) {
        uint32_t val = 0;
        if      (ch_off == (uint32_t)RV_DMA_CH_CTRL_OFF)  val = ch->ctrl;
        else if (ch_off == (uint32_t)RV_DMA_CH_STAT_OFF)  val = ch->stat;
        else if (ch_off == (uint32_t)RV_DMA_CH_SRC_OFF)   val = ch->src;
        else if (ch_off == (uint32_t)RV_DMA_CH_DST_OFF)   val = ch->dst;
        else if (ch_off == (uint32_t)RV_DMA_CH_XFER_OFF)  val = ch->xfer;
        fill_bytes(bytes, len, val);
    } else {
        uint32_t val = extract_val(bytes, len);
        if (ch_off == (uint32_t)RV_DMA_CH_CTRL_OFF) {
            ch->ctrl = val;
            if ((val & (uint32_t)RV_DMA_CTRL_EN) &&
                (val & (uint32_t)RV_DMA_CTRL_START)) {
                /* Arm and start: execute transfer immediately */
                ch->stat |= (uint32_t)RV_DMA_STAT_BUSY;
                dma_do_transfer(d, ch_idx);
                dma_update_irq(d);
            } else if (val & (uint32_t)RV_DMA_CTRL_STOP) {
                ch->stat &= ~(uint32_t)RV_DMA_STAT_BUSY;
            }
        } else if (ch_off == (uint32_t)RV_DMA_CH_SRC_OFF)  { ch->src  = val; }
        else if (ch_off == (uint32_t)RV_DMA_CH_DST_OFF)    { ch->dst  = val; }
        else if (ch_off == (uint32_t)RV_DMA_CH_XFER_OFF)   { ch->xfer = val; }
        /* stride / scatter-gather regs silently stored */
    }
    return true;
}

static const mmio_plugin_t dma_plugin = { dma_alloc, dma_dealloc, dma_access };

__attribute__((constructor))
static void plugin_init() {
    register_mmio_plugin("rv32_dma", &dma_plugin);
}

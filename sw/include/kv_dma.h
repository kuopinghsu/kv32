/*
 * kv_dma.h – DMA controller driver (polling + interrupt-mode helpers)
 *
 * Hardware: axi_dma.sv at KV_DMA_BASE
 *   Register map – see kv_platform.h (KV_DMA_*)
 *
 * The driver is intentionally header-only (all inline) so that it adds
 * zero code when not called.  For interrupt-driven use, pair with
 * kv_plic.h (source KV_PLIC_SRC_DMA).
 */
#ifndef KV_DMA_H
#define KV_DMA_H

#include <stdint.h>
#include "kv_platform.h"

/* ─── channel helpers ─────────────────────────────────────────────── */

/* Disable channel and clear any stale done/err flags. */
static inline void kv_dma_ch_reset(int ch)
{
    KV_DMA_CH_REG(ch, KV_DMA_CH_CTRL_OFF) = 0;
    KV_DMA_CH_REG(ch, KV_DMA_CH_STAT_OFF) = KV_DMA_STAT_DONE | KV_DMA_STAT_ERR;
    __asm__ volatile ("fence" ::: "memory");
}

/* Start a DMA channel transfer */
static inline void kv_dma_ch_start(int ch)
{
    uint32_t ctrl = KV_DMA_CH_REG(ch, KV_DMA_CH_CTRL_OFF);
    ctrl |= KV_DMA_CTRL_START;
    KV_DMA_CH_REG(ch, KV_DMA_CH_CTRL_OFF) = ctrl;
}

/* Stop/abort a DMA channel transfer */
static inline void kv_dma_ch_stop(int ch)
{
    uint32_t ctrl = KV_DMA_CH_REG(ch, KV_DMA_CH_CTRL_OFF);
    ctrl |= KV_DMA_CTRL_STOP;
    KV_DMA_CH_REG(ch, KV_DMA_CH_CTRL_OFF) = ctrl;
}

/* Check if channel is busy */
static inline int kv_dma_ch_busy(int ch)
{
    return (KV_DMA_CH_REG(ch, KV_DMA_CH_STAT_OFF) & KV_DMA_STAT_BUSY) != 0;
}

/* Check if channel transfer is done */
static inline int kv_dma_ch_done(int ch)
{
    return (KV_DMA_CH_REG(ch, KV_DMA_CH_STAT_OFF) & KV_DMA_STAT_DONE) != 0;
}

/* Check if channel has error */
static inline int kv_dma_ch_error(int ch)
{
    return (KV_DMA_CH_REG(ch, KV_DMA_CH_STAT_OFF) & KV_DMA_STAT_ERR) != 0;
}

/* Poll until channel completes (or errors) */
static inline int kv_dma_ch_wait(int ch)
{
    while (kv_dma_ch_busy(ch)) {
        __asm__ volatile ("nop");
    }
    return kv_dma_ch_error(ch) ? -1 : 0;
}

/* ─── 1D transfer ─────────────────────────────────────────────────── */

/* Setup and execute 1-D flat copy (polling) */
static inline int kv_dma_1d_copy(int ch, uint32_t src, uint32_t dst, uint32_t bytes)
{
    kv_dma_ch_reset(ch);
    
    KV_DMA_CH_REG(ch, KV_DMA_CH_SRC_OFF)   = src;
    KV_DMA_CH_REG(ch, KV_DMA_CH_DST_OFF)   = dst;
    KV_DMA_CH_REG(ch, KV_DMA_CH_XFER_OFF)  = bytes;
    KV_DMA_CH_REG(ch, KV_DMA_CH_CTRL_OFF)  = KV_DMA_CTRL_EN | 
                                               KV_DMA_CTRL_MODE_1D | 
                                               KV_DMA_CTRL_SRC_INC | 
                                               KV_DMA_CTRL_DST_INC;
    
    kv_dma_ch_start(ch);
    return kv_dma_ch_wait(ch);
}

/* ─── 2D strided transfer ─────────────────────────────────────────── */

/* Setup and execute 2-D strided copy */
static inline int kv_dma_2d_copy(int ch, uint32_t src, uint32_t dst, 
                                  uint32_t row_bytes, uint32_t num_rows,
                                  uint32_t src_stride, uint32_t dst_stride)
{
    kv_dma_ch_reset(ch);
    
    KV_DMA_CH_REG(ch, KV_DMA_CH_SRC_OFF)      = src;
    KV_DMA_CH_REG(ch, KV_DMA_CH_DST_OFF)      = dst;
    KV_DMA_CH_REG(ch, KV_DMA_CH_XFER_OFF)     = row_bytes;
    KV_DMA_CH_REG(ch, KV_DMA_CH_SSTRIDE_OFF)  = src_stride;
    KV_DMA_CH_REG(ch, KV_DMA_CH_DSTRIDE_OFF)  = dst_stride;
    KV_DMA_CH_REG(ch, KV_DMA_CH_ROWCNT_OFF)   = num_rows;
    KV_DMA_CH_REG(ch, KV_DMA_CH_CTRL_OFF)     = KV_DMA_CTRL_EN | 
                                                 KV_DMA_CTRL_MODE_2D | 
                                                 KV_DMA_CTRL_SRC_INC | 
                                                 KV_DMA_CTRL_DST_INC;
    
    kv_dma_ch_start(ch);
    return kv_dma_ch_wait(ch);
}

/* ─── 3D planar transfer ──────────────────────────────────────────── */

/* Setup and execute 3-D planar copy */
static inline int kv_dma_3d_copy(int ch, uint32_t src, uint32_t dst,
                                  uint32_t row_bytes, uint32_t num_rows, uint32_t num_planes,
                                  uint32_t src_stride, uint32_t dst_stride,
                                  uint32_t src_pstride, uint32_t dst_pstride)
{
    kv_dma_ch_reset(ch);
    
    KV_DMA_CH_REG(ch, KV_DMA_CH_SRC_OFF)       = src;
    KV_DMA_CH_REG(ch, KV_DMA_CH_DST_OFF)       = dst;
    KV_DMA_CH_REG(ch, KV_DMA_CH_XFER_OFF)      = row_bytes;
    KV_DMA_CH_REG(ch, KV_DMA_CH_SSTRIDE_OFF)   = src_stride;
    KV_DMA_CH_REG(ch, KV_DMA_CH_DSTRIDE_OFF)   = dst_stride;
    KV_DMA_CH_REG(ch, KV_DMA_CH_ROWCNT_OFF)    = num_rows;
    KV_DMA_CH_REG(ch, KV_DMA_CH_SPSTRIDE_OFF)  = src_pstride;
    KV_DMA_CH_REG(ch, KV_DMA_CH_DPSTRIDE_OFF)  = dst_pstride;
    KV_DMA_CH_REG(ch, KV_DMA_CH_PLANECNT_OFF)  = num_planes;
    KV_DMA_CH_REG(ch, KV_DMA_CH_CTRL_OFF)      = KV_DMA_CTRL_EN | 
                                                  KV_DMA_CTRL_MODE_3D | 
                                                  KV_DMA_CTRL_SRC_INC | 
                                                  KV_DMA_CTRL_DST_INC;
    
    kv_dma_ch_start(ch);
    return kv_dma_ch_wait(ch);
}

/* ─── Scatter-Gather transfer ─────────────────────────────────────── */

/* Setup and execute scatter-gather transfer */
static inline int kv_dma_sg_copy(int ch, uint32_t sg_addr, uint32_t sg_count)
{
    kv_dma_ch_reset(ch);
    
    KV_DMA_CH_REG(ch, KV_DMA_CH_SGADDR_OFF) = sg_addr;
    KV_DMA_CH_REG(ch, KV_DMA_CH_SGCNT_OFF)  = sg_count;
    KV_DMA_CH_REG(ch, KV_DMA_CH_CTRL_OFF)   = KV_DMA_CTRL_EN | 
                                               KV_DMA_CTRL_MODE_SG;
    
    kv_dma_ch_start(ch);
    return kv_dma_ch_wait(ch);
}

/* ─── interrupt operations ────────────────────────────────────────── */

/* Enable interrupts for specific channel */
static inline void kv_dma_enable_irq(int ch)
{
    uint32_t ctrl = KV_DMA_CH_REG(ch, KV_DMA_CH_CTRL_OFF);
    ctrl |= KV_DMA_CTRL_IE;
    KV_DMA_CH_REG(ch, KV_DMA_CH_CTRL_OFF) = ctrl;
    
    uint32_t irq_en = KV_DMA_GLB_REG(KV_DMA_IRQ_EN_OFF);
    irq_en |= (1u << ch);
    KV_DMA_GLB_REG(KV_DMA_IRQ_EN_OFF) = irq_en;
}

/* Disable interrupts for specific channel */
static inline void kv_dma_disable_irq(int ch)
{
    uint32_t ctrl = KV_DMA_CH_REG(ch, KV_DMA_CH_CTRL_OFF);
    ctrl &= ~KV_DMA_CTRL_IE;
    KV_DMA_CH_REG(ch, KV_DMA_CH_CTRL_OFF) = ctrl;
    
    uint32_t irq_en = KV_DMA_GLB_REG(KV_DMA_IRQ_EN_OFF);
    irq_en &= ~(1u << ch);
    KV_DMA_GLB_REG(KV_DMA_IRQ_EN_OFF) = irq_en;
}

/* Get global interrupt status */
static inline uint32_t kv_dma_get_irq_status(void)
{
    return KV_DMA_GLB_REG(KV_DMA_IRQ_STAT_OFF);
}

/* Clear interrupt status for channel (write-1-to-clear) */
static inline void kv_dma_clear_irq(int ch)
{
    KV_DMA_GLB_REG(KV_DMA_IRQ_STAT_OFF) = (1u << ch);
}

/* ─── performance counters ────────────────────────────────────────── */

/* Enable performance counters */
static inline void kv_dma_perf_enable(void)
{
    KV_DMA_GLB_REG(KV_DMA_PERF_CTRL_OFF) = 1;
}

/* Disable performance counters */
static inline void kv_dma_perf_disable(void)
{
    KV_DMA_GLB_REG(KV_DMA_PERF_CTRL_OFF) = 0;
}

/* Reset performance counters */
static inline void kv_dma_perf_reset(void)
{
    KV_DMA_GLB_REG(KV_DMA_PERF_CTRL_OFF) = 2;  /* write bit[1]=1 to reset */
    KV_DMA_GLB_REG(KV_DMA_PERF_CTRL_OFF) = 1;  /* re-enable */
}

/* Read performance counter: cycles */
static inline uint32_t kv_dma_perf_get_cycles(void)
{
    return KV_DMA_GLB_REG(KV_DMA_PERF_CYCLES_OFF);
}

/* Read performance counter: read bytes */
static inline uint32_t kv_dma_perf_get_rd_bytes(void)
{
    return KV_DMA_GLB_REG(KV_DMA_PERF_RD_BYTES_OFF);
}

/* Read performance counter: write bytes */
static inline uint32_t kv_dma_perf_get_wr_bytes(void)
{
    return KV_DMA_GLB_REG(KV_DMA_PERF_WR_BYTES_OFF);
}

/* ─── utility functions ───────────────────────────────────────────── */

/* Read DMA ID register (should return 0xD4A00100) */
static inline uint32_t kv_dma_get_id(void)
{
    return KV_DMA_GLB_REG(KV_DMA_ID_OFF);
}

#endif /* KV_DMA_H */

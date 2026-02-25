/*
 * sw/dma/dma.c – AXI DMA controller test suite
 *
 * Tests:
 *  1. DMA_ID register sanity
 *  2. 1-D flat copy, 64 bytes, polling
 *  3. 1-D flat copy, 128 bytes, IRQ-driven (channel 1)
 *  4. 2-D strided copy (4 rows × 16 B, src_stride=32, dst_stride=16)
 *  5. 3-D planar copy (2 planes × 2 rows × 8 B, pstrides)
 *  6. Scatter-Gather, 3 descriptors
 *  7. Error IRQ (unmapped source address → DECERR → ch_err)
 *  8. Multi-channel: ch0 and ch1 started back-to-back, both verified
 */

#include <stdint.h>
#include <stdio.h>
#include "rv_platform.h"
#include "rv_plic.h"
#include "rv_irq.h"

/* ── helpers ─────────────────────────────────────────────────────────────── */

#define RV_DMA_FENCE()  __asm__ volatile ("fence" ::: "memory")

static int g_pass, g_fail;

#define TEST_PASS(n)        do { printf("[TEST %d] PASS\n", (n)); g_pass++; } while (0)
#define TEST_FAIL(n, msg)   do { printf("[TEST %d] FAIL: %s\n", (n), (msg)); g_fail++; } while (0)

/* ── Scatter-Gather descriptor (16 bytes, little-endian) ─────────────────── */
typedef struct {
    uint32_t src_addr;
    uint32_t dst_addr;
    uint32_t xfer_cnt;
    uint32_t mode_ctrl;  /* [1:0]=mode(0=1D), [2]=src_inc, [3]=dst_inc */
} sg_desc_t;

/* ── Statically-allocated buffers in DRAM ────────────────────────────────── */
static uint8_t   buf_src0[64]   __attribute__((aligned(4)));  /* test 2 */
static uint8_t   buf_dst0[64]   __attribute__((aligned(4)));
static uint8_t   buf_src1[128]  __attribute__((aligned(4)));  /* test 3 */
static uint8_t   buf_dst1[128]  __attribute__((aligned(4)));
static uint8_t   buf_src2[128]  __attribute__((aligned(4)));  /* test 4 */
static uint8_t   buf_dst2[64]   __attribute__((aligned(4)));
static uint8_t   buf_src3[128]  __attribute__((aligned(4)));  /* test 5 */
static uint8_t   buf_dst3[32]   __attribute__((aligned(4)));
static uint8_t   buf_sg_src[64] __attribute__((aligned(4)));  /* test 6 */
static uint8_t   buf_sg_dst[64] __attribute__((aligned(4)));
static sg_desc_t sg_descs[3]    __attribute__((aligned(16))); /* test 6 */
static uint8_t   buf_src4[64]   __attribute__((aligned(4)));  /* test 8 */
static uint8_t   buf_dst4[64]   __attribute__((aligned(4)));
static uint8_t   buf_src5[64]   __attribute__((aligned(4)));  /* test 8 */
static uint8_t   buf_dst5[64]   __attribute__((aligned(4)));

/* ── IRQ state (set by MEI handler) ─────────────────────────────────────── */
static volatile uint32_t g_irq_stat;           /* captured IRQ_STAT */
static volatile uint32_t g_ch_stat[4];         /* per-channel STAT snapshot */
static volatile int      g_irq_fired;

/* ── MEI handler ─────────────────────────────────────────────────────────── */
static void dma_mei_handler(uint32_t cause)
{
    (void)cause;
    uint32_t src = rv_plic_claim();
    if (src == (uint32_t)RV_PLIC_SRC_DMA) {
        uint32_t irq = RV_DMA_GLB_REG(RV_DMA_IRQ_STAT_OFF);
        g_irq_stat = irq;
        /* Capture channel-level status before W1C clearing ch_done/ch_err */
        for (int ch = 0; ch < 4; ch++) {
            if (irq & (1u << ch))
                g_ch_stat[ch] = RV_DMA_CH_REG(ch, RV_DMA_CH_STAT_OFF);
        }
        g_irq_fired = 1;
        /* W1C clear: clears ch_done[i] and ch_err[i] for each set bit */
        RV_DMA_GLB_REG(RV_DMA_IRQ_STAT_OFF) = irq;
    }
    rv_plic_complete(src);
}

/* ── one-time IRQ setup ──────────────────────────────────────────────────── */
static void dma_setup_irq(void)
{
    rv_irq_register(RV_CAUSE_MEI, dma_mei_handler);
    rv_plic_init_source(RV_PLIC_SRC_DMA, 1);
    rv_irq_enable();
}

/* ── channel helpers ─────────────────────────────────────────────────────── */

/* Disable channel and clear any stale done/err flags. */
static void dma_ch_reset(int ch)
{
    RV_DMA_CH_REG(ch, RV_DMA_CH_CTRL_OFF) = 0;
    RV_DMA_CH_REG(ch, RV_DMA_CH_STAT_OFF) = RV_DMA_STAT_DONE | RV_DMA_STAT_ERR;
    RV_DMA_FENCE();
}

/*
 * Configure and kick a 1-D transfer.
 * use_irq=1 → enable per-channel IE bit (caller must also set IRQ_EN).
 */
static void dma_start_1d(int ch, uint32_t src, uint32_t dst,
                         uint32_t len, int use_irq)
{
    uint32_t ctrl = RV_DMA_CTRL_EN | RV_DMA_CTRL_SRC_INC |
                    RV_DMA_CTRL_DST_INC | RV_DMA_CTRL_MODE_1D;
    if (use_irq) ctrl |= RV_DMA_CTRL_IE;

    RV_DMA_CH_REG(ch, RV_DMA_CH_SRC_OFF)  = src;
    RV_DMA_CH_REG(ch, RV_DMA_CH_DST_OFF)  = dst;
    RV_DMA_CH_REG(ch, RV_DMA_CH_XFER_OFF) = len;
    RV_DMA_FENCE();
    RV_DMA_CH_REG(ch, RV_DMA_CH_CTRL_OFF) = ctrl | RV_DMA_CTRL_START;
    RV_DMA_FENCE();
}

/*
 * Poll channel STAT until DONE or ERR; returns 1=done, -1=error, 0=timeout.
 */
static int dma_poll_done(int ch, uint32_t timeout)
{
    for (uint32_t i = 0; i < timeout; i++) {
        uint32_t stat = RV_DMA_CH_REG(ch, RV_DMA_CH_STAT_OFF);
        if (stat & RV_DMA_STAT_ERR)  return -1;
        if (stat & RV_DMA_STAT_DONE) return  1;
    }
    return 0; /* timeout */
}

/* Count byte mismatches; print the first few. */
static int dma_verify(const uint8_t *expected, const uint8_t *got,
                      uint32_t len, const char *tag)
{
    int errs = 0;
    for (uint32_t i = 0; i < len; i++) {
        if (expected[i] != got[i]) {
            if (errs < 4)
                printf("  %s @%lu: exp=0x%02x got=0x%02x\n",
                       tag, (unsigned long)i, expected[i], got[i]);
            errs++;
        }
    }
    return errs;
}

/* ========================================================================== */
/* TEST 1 – DMA_ID register                                                   */
/* ========================================================================== */
static void test1_id(void)
{
    uint32_t id = RV_DMA_GLB_REG(RV_DMA_ID_OFF);
    if (id == 0xD4A00100U) {
        TEST_PASS(1);
    } else {
        printf("  DMA_ID=0x%08lx (expected 0xD4A00100)\n", (unsigned long)id);
        TEST_FAIL(1, "DMA_ID mismatch");
    }
}

/* ========================================================================== */
/* TEST 2 – 1-D copy, 64 bytes, polling                                       */
/* ========================================================================== */
static void test2_1d_poll(void)
{
    volatile uint8_t *s = (volatile uint8_t *)buf_src0;
    volatile uint8_t *d = (volatile uint8_t *)buf_dst0;
    for (int i = 0; i < 64; i++) { s[i] = (uint8_t)(0xAA ^ i); d[i] = 0; }
    RV_DMA_FENCE();

    dma_ch_reset(0);
    dma_start_1d(0, (uint32_t)(uintptr_t)buf_src0,
                    (uint32_t)(uintptr_t)buf_dst0, 64, 0);

    int r = dma_poll_done(0, 1000000);
    if (r <= 0) {
        TEST_FAIL(2, r == 0 ? "timeout" : "AXI error");
        dma_ch_reset(0);
        return;
    }
    RV_DMA_CH_REG(0, RV_DMA_CH_STAT_OFF) = RV_DMA_STAT_DONE;
    RV_DMA_CH_REG(0, RV_DMA_CH_CTRL_OFF) = 0;
    RV_DMA_FENCE();

    int e = dma_verify(buf_src0, buf_dst0, 64, "1D-poll");
    if (e == 0) TEST_PASS(2); else TEST_FAIL(2, "data mismatch");
}

/* ========================================================================== */
/* TEST 3 – 1-D copy, 128 bytes, IRQ-driven (channel 1)                       */
/* ========================================================================== */
static void test3_1d_irq(void)
{
    volatile uint8_t *s = (volatile uint8_t *)buf_src1;
    volatile uint8_t *d = (volatile uint8_t *)buf_dst1;
    for (int i = 0; i < 128; i++) { s[i] = (uint8_t)(0x5A + i); d[i] = 0; }
    RV_DMA_FENCE();

    g_irq_fired = 0;
    g_irq_stat  = 0;
    g_ch_stat[1]= 0;

    /* Enable global IRQ for channel 1 */
    RV_DMA_GLB_REG(RV_DMA_IRQ_EN_OFF) |= (1u << 1);
    dma_ch_reset(1);
    dma_start_1d(1, (uint32_t)(uintptr_t)buf_src1,
                    (uint32_t)(uintptr_t)buf_dst1, 128, 1 /* IE */);

    uint32_t to = 2000000;
    while (!g_irq_fired && --to);

    if (!g_irq_fired) {
        TEST_FAIL(3, "IRQ never fired");
        dma_ch_reset(1);
        RV_DMA_GLB_REG(RV_DMA_IRQ_EN_OFF) &= ~(1u << 1);
        return;
    }
    if (!(g_irq_stat & (1u << 1))) {
        printf("  IRQ_STAT=0x%08lx, expected bit 1 set\n", (unsigned long)g_irq_stat);
        TEST_FAIL(3, "wrong IRQ_STAT");
        dma_ch_reset(1);
        RV_DMA_GLB_REG(RV_DMA_IRQ_EN_OFF) &= ~(1u << 1);
        return;
    }

    /* IRQ handler already W1C-cleared IRQ_STAT (and ch_done/ch_err).
     * Disable channel and clean up. */
    RV_DMA_CH_REG(1, RV_DMA_CH_CTRL_OFF) = 0;
    RV_DMA_GLB_REG(RV_DMA_IRQ_EN_OFF)   &= ~(1u << 1);
    RV_DMA_FENCE();

    int e = dma_verify(buf_src1, buf_dst1, 128, "1D-irq");
    if (e == 0) TEST_PASS(3); else TEST_FAIL(3, "data mismatch");
}

/* ========================================================================== */
/* TEST 4 – 2-D strided copy                                                  */
/*   Layout: 4 rows × 16 bytes/row                                            */
/*   src_stride = 32 (rows in src have 16-byte padding between them)          */
/*   dst_stride = 16 (rows in dst are packed tightly)                         */
/*                                                                             */
/*   src: row i starts at buf_src2 + i*32                                     */
/*   dst: row i starts at buf_dst2 + i*16                                     */
/* ========================================================================== */
static void test4_2d(void)
{
    volatile uint8_t *s = (volatile uint8_t *)buf_src2;
    volatile uint8_t *d = (volatile uint8_t *)buf_dst2;
    for (int i = 0; i < 128; i++) { s[i] = (uint8_t)(0x10 + i); }
    for (int i = 0; i < 64;  i++) { d[i] = 0; }
    RV_DMA_FENCE();

    dma_ch_reset(2);
    RV_DMA_CH_REG(2, RV_DMA_CH_SRC_OFF)     = (uint32_t)(uintptr_t)buf_src2;
    RV_DMA_CH_REG(2, RV_DMA_CH_DST_OFF)     = (uint32_t)(uintptr_t)buf_dst2;
    RV_DMA_CH_REG(2, RV_DMA_CH_XFER_OFF)    = 16;   /* bytes per row */
    RV_DMA_CH_REG(2, RV_DMA_CH_SSTRIDE_OFF) = 32;   /* src row stride */
    RV_DMA_CH_REG(2, RV_DMA_CH_DSTRIDE_OFF) = 16;   /* dst row stride (packed) */
    RV_DMA_CH_REG(2, RV_DMA_CH_ROWCNT_OFF)  = 4;    /* number of rows */
    RV_DMA_FENCE();
    RV_DMA_CH_REG(2, RV_DMA_CH_CTRL_OFF) =
        RV_DMA_CTRL_EN | RV_DMA_CTRL_SRC_INC | RV_DMA_CTRL_DST_INC |
        RV_DMA_CTRL_MODE_2D | RV_DMA_CTRL_START;
    RV_DMA_FENCE();

    int r = dma_poll_done(2, 1000000);
    if (r <= 0) {
        TEST_FAIL(4, r == 0 ? "timeout" : "AXI error");
        dma_ch_reset(2);
        return;
    }
    RV_DMA_CH_REG(2, RV_DMA_CH_STAT_OFF) = RV_DMA_STAT_DONE;
    RV_DMA_CH_REG(2, RV_DMA_CH_CTRL_OFF) = 0;
    RV_DMA_FENCE();

    int errs = 0;
    for (int row = 0; row < 4; row++) {
        for (int b = 0; b < 16; b++) {
            uint8_t exp = buf_src2[row * 32 + b];
            uint8_t got = buf_dst2[row * 16 + b];
            if (exp != got) {
                if (errs < 4)
                    printf("  2D row=%d b=%d exp=0x%02x got=0x%02x\n",
                           row, b, exp, got);
                errs++;
            }
        }
    }
    if (errs == 0) TEST_PASS(4); else TEST_FAIL(4, "data mismatch");
}

/* ========================================================================== */
/* TEST 5 – 3-D planar copy (channel 3)                                       */
/*   2 planes × 2 rows × 8 bytes/row                                          */
/*   src: plane 0 at buf_src3+0,  plane 1 at buf_src3+64  (pstride=64)        */
/*        row stride within each plane = 16                                   */
/*   dst: plane 0 at buf_dst3+0,  plane 1 at buf_dst3+16  (dpstride=16)       */
/*        row stride within each plane = 8 (tightly packed)                  */
/*                                                                             */
/*   Expected copies:                                                          */
/*     dst[ 0.. 7] = src[ 0.. 7]  (p0r0)                                      */
/*     dst[ 8..15] = src[16..23]  (p0r1)                                      */
/*     dst[16..23] = src[64..71]  (p1r0)                                      */
/*     dst[24..31] = src[80..87]  (p1r1)                                      */
/* ========================================================================== */
static void test5_3d(void)
{
    volatile uint8_t *s = (volatile uint8_t *)buf_src3;
    volatile uint8_t *d = (volatile uint8_t *)buf_dst3;
    for (int i = 0; i < 128; i++) { s[i] = (uint8_t)(0x20 + i); }
    for (int i = 0; i < 32;  i++) { d[i] = 0; }
    RV_DMA_FENCE();

    dma_ch_reset(3);
    RV_DMA_CH_REG(3, RV_DMA_CH_SRC_OFF)      = (uint32_t)(uintptr_t)buf_src3;
    RV_DMA_CH_REG(3, RV_DMA_CH_DST_OFF)      = (uint32_t)(uintptr_t)buf_dst3;
    RV_DMA_CH_REG(3, RV_DMA_CH_XFER_OFF)     = 8;   /* bytes per row */
    RV_DMA_CH_REG(3, RV_DMA_CH_SSTRIDE_OFF)  = 16;  /* src row stride */
    RV_DMA_CH_REG(3, RV_DMA_CH_DSTRIDE_OFF)  = 8;   /* dst row stride (packed) */
    RV_DMA_CH_REG(3, RV_DMA_CH_ROWCNT_OFF)   = 2;   /* rows per plane */
    RV_DMA_CH_REG(3, RV_DMA_CH_SPSTRIDE_OFF) = 64;  /* src plane stride */
    RV_DMA_CH_REG(3, RV_DMA_CH_DPSTRIDE_OFF) = 16;  /* dst plane stride (packed) */
    RV_DMA_CH_REG(3, RV_DMA_CH_PLANECNT_OFF) = 2;   /* number of planes */
    RV_DMA_FENCE();
    RV_DMA_CH_REG(3, RV_DMA_CH_CTRL_OFF) =
        RV_DMA_CTRL_EN | RV_DMA_CTRL_SRC_INC | RV_DMA_CTRL_DST_INC |
        RV_DMA_CTRL_MODE_3D | RV_DMA_CTRL_START;
    RV_DMA_FENCE();

    int r = dma_poll_done(3, 1000000);
    if (r <= 0) {
        TEST_FAIL(5, r == 0 ? "timeout" : "AXI error");
        dma_ch_reset(3);
        return;
    }
    RV_DMA_CH_REG(3, RV_DMA_CH_STAT_OFF) = RV_DMA_STAT_DONE;
    RV_DMA_CH_REG(3, RV_DMA_CH_CTRL_OFF) = 0;
    RV_DMA_FENCE();

    struct { int src_off; int dst_off; int len; const char *lab; } spans[] = {
        {  0,  0, 8, "p0r0" },
        { 16,  8, 8, "p0r1" },
        { 64, 16, 8, "p1r0" },
        { 80, 24, 8, "p1r1" },
    };
    int errs = 0;
    for (int k = 0; k < 4; k++) {
        for (int b = 0; b < spans[k].len; b++) {
            uint8_t exp = buf_src3[spans[k].src_off + b];
            uint8_t got = buf_dst3[spans[k].dst_off + b];
            if (exp != got) {
                if (errs < 4)
                    printf("  3D %s[%d] exp=0x%02x got=0x%02x\n",
                           spans[k].lab, b, exp, got);
                errs++;
            }
        }
    }
    if (errs == 0) TEST_PASS(5); else TEST_FAIL(5, "data mismatch");
}

/* ========================================================================== */
/* TEST 6 – Scatter-Gather, 3 descriptors                                     */
/*   desc[0]: src+0  → dst+0,  16 bytes                                       */
/*   desc[1]: src+16 → dst+16, 32 bytes                                       */
/*   desc[2]: src+48 → dst+48, 16 bytes                                       */
/*   Total: 64 bytes; expected dst == src                                     */
/* ========================================================================== */
static void test6_sg(void)
{
    volatile uint8_t *s = (volatile uint8_t *)buf_sg_src;
    volatile uint8_t *d = (volatile uint8_t *)buf_sg_dst;
    for (int i = 0; i < 64; i++) { s[i] = (uint8_t)(0x30 + i); d[i] = 0; }
    RV_DMA_FENCE();

    /* mode_ctrl: src_inc[2]=1, dst_inc[3]=1, mode[1:0]=00 → 0x0C */
    sg_descs[0].src_addr  = (uint32_t)(uintptr_t)(buf_sg_src +  0);
    sg_descs[0].dst_addr  = (uint32_t)(uintptr_t)(buf_sg_dst +  0);
    sg_descs[0].xfer_cnt  = 16;
    sg_descs[0].mode_ctrl = 0x0Cu;

    sg_descs[1].src_addr  = (uint32_t)(uintptr_t)(buf_sg_src + 16);
    sg_descs[1].dst_addr  = (uint32_t)(uintptr_t)(buf_sg_dst + 16);
    sg_descs[1].xfer_cnt  = 32;
    sg_descs[1].mode_ctrl = 0x0Cu;

    sg_descs[2].src_addr  = (uint32_t)(uintptr_t)(buf_sg_src + 48);
    sg_descs[2].dst_addr  = (uint32_t)(uintptr_t)(buf_sg_dst + 48);
    sg_descs[2].xfer_cnt  = 16;
    sg_descs[2].mode_ctrl = 0x0Cu;
    RV_DMA_FENCE();

    dma_ch_reset(0);
    RV_DMA_CH_REG(0, RV_DMA_CH_SGADDR_OFF) = (uint32_t)(uintptr_t)sg_descs;
    RV_DMA_CH_REG(0, RV_DMA_CH_SGCNT_OFF)  = 3;
    RV_DMA_FENCE();
    RV_DMA_CH_REG(0, RV_DMA_CH_CTRL_OFF) =
        RV_DMA_CTRL_EN | RV_DMA_CTRL_MODE_SG | RV_DMA_CTRL_START;
    RV_DMA_FENCE();

    int r = dma_poll_done(0, 2000000);
    if (r <= 0) {
        TEST_FAIL(6, r == 0 ? "timeout" : "AXI error");
        dma_ch_reset(0);
        return;
    }
    RV_DMA_CH_REG(0, RV_DMA_CH_STAT_OFF) = RV_DMA_STAT_DONE;
    RV_DMA_CH_REG(0, RV_DMA_CH_CTRL_OFF) = 0;
    RV_DMA_FENCE();

    int e = dma_verify(buf_sg_src, buf_sg_dst, 64, "SG");
    if (e == 0) TEST_PASS(6); else TEST_FAIL(6, "data mismatch");
}

/* ========================================================================== */
/* TEST 7 – Error IRQ: channel 0, source at unmapped address 0x00000000       */
/*          The xbar returns DECERR on the read → DMA transitions to S_ERROR  */
/*          → ch_err[0]=1 → IRQ fires (IE+IRQ_EN set)                        */
/* ========================================================================== */
static void test7_irq_err(void)
{
    g_irq_fired  = 0;
    g_irq_stat   = 0;
    g_ch_stat[0] = 0;

    /* Enable global IRQ for channel 0 */
    RV_DMA_GLB_REG(RV_DMA_IRQ_EN_OFF) |= (1u << 0);
    dma_ch_reset(0);

    RV_DMA_CH_REG(0, RV_DMA_CH_SRC_OFF)  = 0x00000000UL;  /* unmapped → DECERR */
    RV_DMA_CH_REG(0, RV_DMA_CH_DST_OFF)  = (uint32_t)(uintptr_t)buf_dst0;
    RV_DMA_CH_REG(0, RV_DMA_CH_XFER_OFF) = 4;             /* minimum transfer  */
    RV_DMA_FENCE();
    RV_DMA_CH_REG(0, RV_DMA_CH_CTRL_OFF) =
        RV_DMA_CTRL_EN | RV_DMA_CTRL_SRC_INC | RV_DMA_CTRL_DST_INC |
        RV_DMA_CTRL_MODE_1D | RV_DMA_CTRL_IE | RV_DMA_CTRL_START;
    RV_DMA_FENCE();

    uint32_t to = 2000000;
    while (!g_irq_fired && --to);

    RV_DMA_GLB_REG(RV_DMA_IRQ_EN_OFF) &= ~(1u << 0);
    RV_DMA_CH_REG(0, RV_DMA_CH_CTRL_OFF) = 0;
    RV_DMA_FENCE();

    if (!g_irq_fired) {
        TEST_FAIL(7, "error IRQ never fired");
        return;
    }
    /*
     * g_irq_stat bit 0 = ch_done[0] | ch_err[0].
     * g_ch_stat[0] was captured before W1C in the handler, so STAT[2]=ERR
     * should be visible there.
     */
    int ok = (g_irq_stat   & (1u << 0)) &&     /* IRQ_STAT bit 0 set */
             (g_ch_stat[0] & RV_DMA_STAT_ERR) && /* ch_err was set    */
             !(g_ch_stat[0] & RV_DMA_STAT_DONE);  /* ch_done NOT set  */
    if (ok) {
        TEST_PASS(7);
    } else {
        printf("  IRQ_STAT=0x%08lx ch0_STAT=0x%08lx\n",
               (unsigned long)g_irq_stat, (unsigned long)g_ch_stat[0]);
        TEST_FAIL(7, "IRQ_STAT or CH_STAT mismatch");
    }
}

/* ========================================================================== */
/* TEST 8 – Multi-channel: ch0 and ch1 started back-to-back                  */
/*          The single-engine DMA runs them in round-robin order.             */
/* ========================================================================== */
static void test8_multi_ch(void)
{
    volatile uint8_t *s0 = (volatile uint8_t *)buf_src4;
    volatile uint8_t *d0 = (volatile uint8_t *)buf_dst4;
    volatile uint8_t *s1 = (volatile uint8_t *)buf_src5;
    volatile uint8_t *d1 = (volatile uint8_t *)buf_dst5;

    for (int i = 0; i < 64; i++) { s0[i] = (uint8_t)(0xC0 + i); d0[i] = 0; }
    for (int i = 0; i < 64; i++) { s1[i] = (uint8_t)(0x80 + i); d1[i] = 0; }
    RV_DMA_FENCE();

    dma_ch_reset(0);
    dma_ch_reset(1);

    /* Load channel configs */
    RV_DMA_CH_REG(0, RV_DMA_CH_SRC_OFF)  = (uint32_t)(uintptr_t)buf_src4;
    RV_DMA_CH_REG(0, RV_DMA_CH_DST_OFF)  = (uint32_t)(uintptr_t)buf_dst4;
    RV_DMA_CH_REG(0, RV_DMA_CH_XFER_OFF) = 64;
    RV_DMA_CH_REG(1, RV_DMA_CH_SRC_OFF)  = (uint32_t)(uintptr_t)buf_src5;
    RV_DMA_CH_REG(1, RV_DMA_CH_DST_OFF)  = (uint32_t)(uintptr_t)buf_dst5;
    RV_DMA_CH_REG(1, RV_DMA_CH_XFER_OFF) = 64;
    RV_DMA_FENCE();

    /* Start both channels – engine will service them in round-robin */
    uint32_t cfg = RV_DMA_CTRL_EN | RV_DMA_CTRL_SRC_INC |
                   RV_DMA_CTRL_DST_INC | RV_DMA_CTRL_MODE_1D | RV_DMA_CTRL_START;
    RV_DMA_CH_REG(0, RV_DMA_CH_CTRL_OFF) = cfg;
    RV_DMA_CH_REG(1, RV_DMA_CH_CTRL_OFF) = cfg;
    RV_DMA_FENCE();

    int r0 = dma_poll_done(0, 2000000);
    int r1 = dma_poll_done(1, 2000000);

    RV_DMA_CH_REG(0, RV_DMA_CH_STAT_OFF) = RV_DMA_STAT_DONE;
    RV_DMA_CH_REG(0, RV_DMA_CH_CTRL_OFF) = 0;
    RV_DMA_CH_REG(1, RV_DMA_CH_STAT_OFF) = RV_DMA_STAT_DONE;
    RV_DMA_CH_REG(1, RV_DMA_CH_CTRL_OFF) = 0;
    RV_DMA_FENCE();

    if (r0 <= 0 || r1 <= 0) {
        printf("  ch0_result=%d ch1_result=%d\n", r0, r1);
        TEST_FAIL(8, "transfer failed or timed out");
        return;
    }
    int e0 = dma_verify(buf_src4, buf_dst4, 64, "MCH0");
    int e1 = dma_verify(buf_src5, buf_dst5, 64, "MCH1");
    if (e0 == 0 && e1 == 0) TEST_PASS(8); else TEST_FAIL(8, "data mismatch");
}

/* ========================================================================== */
/* main                                                                       */
/* ========================================================================== */
int main(void)
{
    printf("=== DMA Test Suite ===\n");

    /* Arm IRQ path once (shared by tests 3 and 7) */
    dma_setup_irq();

    test1_id();
    test2_1d_poll();
    test3_1d_irq();
    test4_2d();
    test5_3d();
    test6_sg();
    test7_irq_err();
    test8_multi_ch();

    printf("\n=== Results: %d PASS, %d FAIL ===\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}

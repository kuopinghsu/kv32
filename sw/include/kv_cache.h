/**
 * @file kv_cache.h
 * @brief Cache management API for KV32 — FENCE, CMO (Zicbom/Zifencei) helpers.
 *
 * Provides portable inline wrappers for:
 *  - Instruction-stream serialisation (FENCE.I / Zifencei)
 *  - Data memory ordering (FENCE rw,rw)
 *  - Cache Block Operations (cbo.inval, cbo.clean, cbo.flush / Zicbom)
 *  - Range-based flush/invalidate helpers for D-Cache coherency
 *
 * All CMO operations are encoded via GAS `.insn` so no special -march flag
 * is required beyond the base RV32I toolchain.
 *
 * Zicbom instruction encoding (MISC-MEM opcode 0x0F, funct3=2):
 *   cbo.inval  rs1  →  imm = 0   (invalidate, discard dirty data)
 *   cbo.clean  rs1  →  imm = 1   (writeback, keep valid in cache)
 *   cbo.flush  rs1  →  imm = 2   (writeback + invalidate)
 *
 * The range helpers compile to no-ops when the corresponding cache is
 * absent (DCACHE_EN=0 / ICACHE_EN=0), so callers need not #ifdef them.
 *
 * @see docs/kv32_soc_datasheet.adoc
 * @ingroup platform
 * @{
 */

#ifndef KV_CACHE_H
#define KV_CACHE_H

#include <stdint.h>
#include <stddef.h>

/** @cond – line size used by range helpers; override before including if needed */
#ifndef KV_DCACHE_LINE_SIZE
#define KV_DCACHE_LINE_SIZE  32U   /**< Bytes per D-Cache line (default 32) */
#endif
#ifndef KV_ICACHE_LINE_SIZE
#define KV_ICACHE_LINE_SIZE  32U   /**< Bytes per I-Cache line (default 32) */
#endif
/** @endcond */

/* ═══════════════════════════════════════════════════════════════════
 * Fence instructions
 * ══════════════════════════════════════════════════════════════════ */

/**
 * @brief FENCE.I — flush the instruction pipeline and I-Cache.
 *
 * Serialises all prior instruction-stream modifications.  On kv32 this also
 * triggers a full D-Cache write-back so that self-modifying code stored via
 * CPU stores becomes visible to subsequent instruction fetches.
 * Encoding: opcode=0x0F funct3=1 rs1=0 rd=0 imm=0 → 0x0000_100F
 */
static inline void kv_fence_i(void)
{
    __asm__ volatile (".word 0x0000100f" ::: "memory");
}

/**
 * @brief FENCE rw,rw — full data memory ordering barrier.
 *
 * Ensures all loads and stores preceding this instruction are globally
 * visible before any load or store that follows it.
 * Encoding: pred=rw succ=rw → 0x0330_000F
 */
static inline void kv_fence_rw(void)
{
    __asm__ volatile (".word 0x0330000f" ::: "memory");
}

/* ═══════════════════════════════════════════════════════════════════
 * Cache Block Operations (Zicbom)
 * ══════════════════════════════════════════════════════════════════ */

/**
 * @brief cbo.inval — invalidate the cache line that contains @p addr.
 *
 * Discards the cache line without writing back dirty data.  Any
 * subsequent access to the line reloads from backing memory.
 * Use before a DMA write completes so the CPU sees the new memory contents.
 */
static inline void kv_cbo_inval(void *addr)
{
    __asm__ volatile (".insn i 0xf, 2, x0, 0(%0)"
                      : : "r"(addr) : "memory");
}

/**
 * @brief cbo.clean — write back the cache line that contains @p addr.
 *
 * If the line is dirty it is written to backing memory; the line remains
 * valid in the cache afterwards (unlike cbo.flush).
 */
static inline void kv_cbo_clean(void *addr)
{
    __asm__ volatile (".insn i 0xf, 2, x0, 1(%0)"
                      : : "r"(addr) : "memory");
}

/**
 * @brief cbo.flush — write back and invalidate the cache line at @p addr.
 *
 * Writes dirty data to backing memory and then removes the line from the
 * cache.  Use before starting a DMA read so the DMA sees the latest data.
 */
static inline void kv_cbo_flush(void *addr)
{
    __asm__ volatile (".insn i 0xf, 2, x0, 2(%0)"
                      : : "r"(addr) : "memory");
}

/* ═══════════════════════════════════════════════════════════════════
 * Range helpers
 * ══════════════════════════════════════════════════════════════════ */

/**
 * @brief Flush (write-back + invalidate) every D-Cache line in [p, p+len).
 *
 * Equivalent to calling kv_cbo_flush() on every cache line that overlaps
 * the region.  The start address is rounded down to the nearest line.
 *
 * Compiles to a no-op when DCACHE_EN=0.
 */
static inline void kv_dcache_flush_range(void *p, size_t len)
{
#if defined(DCACHE_EN) && DCACHE_EN != 0
    uintptr_t base = (uintptr_t)p & ~(uintptr_t)(KV_DCACHE_LINE_SIZE - 1U);
    uintptr_t end  = (uintptr_t)p + len;
    for (; base < end; base += KV_DCACHE_LINE_SIZE)
        kv_cbo_flush((void *)base);
#else
    (void)p; (void)len;
#endif
}

/**
 * @brief Invalidate every D-Cache line in [p, p+len).
 *
 * Discards all lines (dirty or clean) that overlap the region without
 * writing back.  Suitable for a destination buffer that the DMA has just
 * filled so the CPU fetches fresh data from memory.
 *
 * Compiles to a no-op when DCACHE_EN=0.
 */
static inline void kv_dcache_inval_range(void *p, size_t len)
{
#if defined(DCACHE_EN) && DCACHE_EN != 0
    uintptr_t base = (uintptr_t)p & ~(uintptr_t)(KV_DCACHE_LINE_SIZE - 1U);
    uintptr_t end  = (uintptr_t)p + len;
    for (; base < end; base += KV_DCACHE_LINE_SIZE)
        kv_cbo_inval((void *)base);
#else
    (void)p; (void)len;
#endif
}

/**
 * @brief Invalidate every I-Cache line in [p, p+len).
 *
 * Used after writing new instructions to memory (self-modifying code or
 * dynamic code generation) so that subsequent instruction fetches see the
 * new content.  Prefer kv_fence_i() for a full pipeline flush.
 *
 * Compiles to a no-op when ICACHE_EN=0.
 */
static inline void kv_icache_inval_range(void *p, size_t len)
{
#if defined(ICACHE_EN) && ICACHE_EN != 0
    uintptr_t base = (uintptr_t)p & ~(uintptr_t)(KV_ICACHE_LINE_SIZE - 1U);
    uintptr_t end  = (uintptr_t)p + len;
    for (; base < end; base += KV_ICACHE_LINE_SIZE)
        kv_cbo_inval((void *)base);
#else
    (void)p; (void)len;
#endif
}

/* ═══════════════════════════════════════════════════════════════════
 * Cache Diagnostic CSRs (custom KV32)
 * ══════════════════════════════════════════════════════════════════ */

#define KV_CSR_ICAP         0x7D0
#define KV_CSR_DCAP         0x7D1
#define KV_CSR_CDIAG_CMD    0x7D2
#define KV_CSR_CDIAG_TAG    0x7D3
#define KV_CSR_CDIAG_DATA   0x7D4

#define KV_CAP_WAYS(cap)    (((cap) >> 24) & 0xFFu)
#define KV_CAP_SETS(cap)    (((cap) >> 16) & 0xFFu)
#define KV_CAP_WPL(cap)     (((cap) >>  8) & 0xFFu)
#define KV_CAP_TAGBITS(cap) (((cap)      ) & 0xFFu)

#define KV_CDIAG_CMD_ICACHE  0u
#define KV_CDIAG_CMD_DCACHE  (1u << 31)
#define KV_CDIAG_CMD(sel, way, set, word) \
    ((uint32_t)(sel) | ((uint32_t)(way) << 24) | ((uint32_t)(set) << 16) | ((uint32_t)(word) << 8))

#define KV_CDIAG_DIRTY(t)   (((t) >> 31) & 1u)
#define KV_CDIAG_VALID(t)   (((t) >> 30) & 1u)
#define KV_CDIAG_TAG(t)     ((t) & 0x1FFFFFu)

// Two NOPs are required between CSR_CDIAG_CMD write and TAG/DATA reads.
static inline uint32_t kv_cdiag_tag(uint32_t cmd)
{
    uint32_t r;
    __asm__ volatile (
        "csrw 0x7D2, %[c]\n"
        "nop\n"
        "nop\n"
        "csrr %[r], 0x7D3\n"
        : [r] "=r" (r)
        : [c] "r" (cmd)
        : "memory");
    return r;
}

static inline uint32_t kv_cdiag_data(uint32_t cmd)
{
    uint32_t r;
    __asm__ volatile (
        "csrw 0x7D2, %[c]\n"
        "nop\n"
        "nop\n"
        "csrr %[r], 0x7D4\n"
        : [r] "=r" (r)
        : [c] "r" (cmd)
        : "memory");
    return r;
}

void kv_icache_dump(void);
void kv_dcache_dump(void);
void kv_cache_dump(void);

/** @} */
#endif /* KV_CACHE_H */

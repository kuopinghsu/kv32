/**
 * @file kv_pma.h
 * @brief Physical Memory Attributes (PMA) runtime configuration API for KV32.
 *
 * KV32 implements 8 runtime-configurable PMA regions via custom M-mode CSRs
 * (pmacfg0/pmacfg1 at 0x7C0–0x7C1, pmaaddr0–7 at 0x7C4–0x7CB).  The design
 * follows the same NAPOT/TOR/NA4 address encoding used by RISC-V PMP so that
 * existing tooling and familiarity carry over.
 *
 * CSR layout:
 *   pmacfg0  (0x7C0): packed 8-bit cfg bytes for regions 0–3 (bits [7:0]=r0, …)
 *   pmacfg1  (0x7C1): packed 8-bit cfg bytes for regions 4–7
 *   pmaaddr0 (0x7C4): physaddr[31:2] for region 0  (NAPOT-encoded for NAPOT mode)
 *   …
 *   pmaaddr7 (0x7CB): physaddr[31:2] for region 7
 *
 * cfg byte format (8 bits per region):
 *   [7]   L  — Lock: prevent further writes to this region's cfg+addr until reset
 *   [6:5]    — reserved (write 0)
 *   [4:3] A  — Address match mode:
 *               00 = OFF   (region disabled)
 *               01 = TOR   (top-of-range: pmaaddr[i-1]*4 ≤ addr < pmaaddr[i]*4)
 *               10 = NA4   (naturally-aligned 4-byte region)
 *               11 = NAPOT (naturally-aligned power-of-two, size ≥ 8 bytes)
 *   [2]   X  — I-Cacheable:  instruction fetches to matching addresses are cached
 *   [1]   C  — D-Cacheable:  data accesses to matching addresses are cached
 *   [0]   B  — Bufferable:   writes may be buffered (write-buffer allowed)
 *
 * Priority: region 0 has the highest priority; region 7 the lowest.
 * Fallback: when no region matches, the legacy bit[31]=1 rule is used
 *           (addr ≥ 0x8000_0000 → cacheable).
 *
 * Reset state: all regions disabled (A=00), so only the fallback rule applies.
 *
 * Typical usage — mark SRAM as fully cacheable + bufferable:
 * @code
 *   // Configure RAM region: 0x8000_0000, 128 KB, I+D cacheable + bufferable
 *   kv_pma_set_napot(0, 0x80000000U, 128*1024U,
 *                    KV_PMA_ICACHEABLE | KV_PMA_DCACHEABLE | KV_PMA_BUFFERABLE);
 * @endcode
 *
 * @see docs/kv32_soc_datasheet.adoc, rtl/core/kv32_csr.sv
 * @ingroup platform
 * @{
 */

#ifndef KV_PMA_H
#define KV_PMA_H

#include <stdint.h>

/* ═══════════════════════════════════════════════════════════════════
 * PMA CSR addresses  (custom M-mode, 0x7Cx range)
 * ══════════════════════════════════════════════════════════════════ */

#define KV_PMA_CSR_PMACFG0   0x7C0  /**< Packed cfg bytes for regions 0–3 */
#define KV_PMA_CSR_PMACFG1   0x7C1  /**< Packed cfg bytes for regions 4–7 */
#define KV_PMA_CSR_PMAADDR0  0x7C4  /**< physaddr>>2 for region 0 */
#define KV_PMA_CSR_PMAADDR1  0x7C5  /**< physaddr>>2 for region 1 */
#define KV_PMA_CSR_PMAADDR2  0x7C6  /**< physaddr>>2 for region 2 */
#define KV_PMA_CSR_PMAADDR3  0x7C7  /**< physaddr>>2 for region 3 */
#define KV_PMA_CSR_PMAADDR4  0x7C8  /**< physaddr>>2 for region 4 */
#define KV_PMA_CSR_PMAADDR5  0x7C9  /**< physaddr>>2 for region 5 */
#define KV_PMA_CSR_PMAADDR6  0x7CA  /**< physaddr>>2 for region 6 */
#define KV_PMA_CSR_PMAADDR7  0x7CB  /**< physaddr>>2 for region 7 */

/* ═══════════════════════════════════════════════════════════════════
 * cfg byte bit-field masks
 * ══════════════════════════════════════════════════════════════════ */

#define KV_PMA_LOCK         (1u << 7)  /**< Lock region (write-protect until reset) */
#define KV_PMA_MODE_OFF     (0u << 3)  /**< Address match: disabled */
#define KV_PMA_MODE_TOR     (1u << 3)  /**< Address match: Top-Of-Range */
#define KV_PMA_MODE_NA4     (2u << 3)  /**< Address match: Naturally-Aligned 4-byte */
#define KV_PMA_MODE_NAPOT   (3u << 3)  /**< Address match: Naturally-Aligned Power-Of-Two */
#define KV_PMA_ICACHEABLE   (1u << 2)  /**< Instruction fetches cached */
#define KV_PMA_DCACHEABLE   (1u << 1)  /**< Data accesses cached */
#define KV_PMA_BUFFERABLE   (1u << 0)  /**< Writes may be buffered */

/** Number of PMA regions */
#define KV_PMA_NUM_REGIONS  8u

/* ═══════════════════════════════════════════════════════════════════
 * Low-level CSR helpers (inline assembly)
 * ══════════════════════════════════════════════════════════════════ */

/** @cond */
/* Generic CSR read/write using immediate-encoded csrr/csrw.
 * The csrnum MUST be a compile-time constant for the inline asm constraint. */
#define _KV_PMA_READ_CSR(csrnum)  ({ uint32_t _v; \
    __asm__ volatile ("csrr %0, " #csrnum : "=r"(_v)); _v; })
#define _KV_PMA_WRITE_CSR(csrnum, val) \
    __asm__ volatile ("csrw " #csrnum ", %0" :: "r"((uint32_t)(val)))
/** @endcond */

/* ═══════════════════════════════════════════════════════════════════
 * Region read helpers
 * ══════════════════════════════════════════════════════════════════ */

/**
 * @brief Read the 8-bit cfg byte for region @p n.
 * @param n Region index (0–7).
 * @return 8-bit cfg value, or 0 if @p n is out of range.
 */
static inline uint8_t kv_pma_read_cfg(unsigned int n)
{
    uint32_t word;
    if (n < 4) {
        word = _KV_PMA_READ_CSR(0x7C0);
        return (uint8_t)((word >> (n * 8)) & 0xFFu);
    } else if (n < 8) {
        word = _KV_PMA_READ_CSR(0x7C1);
        return (uint8_t)((word >> ((n - 4) * 8)) & 0xFFu);
    }
    return 0;
}

/**
 * @brief Read the pmaaddr value (physaddr>>2, NAPOT-encoded) for region @p n.
 * @param n Region index (0–7).
 * @return Raw pmaaddr value, or 0 if @p n is out of range.
 */
static inline uint32_t kv_pma_read_addr(unsigned int n)
{
    switch (n) {
    case 0: return _KV_PMA_READ_CSR(0x7C4);
    case 1: return _KV_PMA_READ_CSR(0x7C5);
    case 2: return _KV_PMA_READ_CSR(0x7C6);
    case 3: return _KV_PMA_READ_CSR(0x7C7);
    case 4: return _KV_PMA_READ_CSR(0x7C8);
    case 5: return _KV_PMA_READ_CSR(0x7C9);
    case 6: return _KV_PMA_READ_CSR(0x7CA);
    case 7: return _KV_PMA_READ_CSR(0x7CB);
    default: return 0;
    }
}

/* ═══════════════════════════════════════════════════════════════════
 * NAPOT address encoding helper
 * ══════════════════════════════════════════════════════════════════ */

/**
 * @brief Compute the NAPOT-encoded pmaaddr value for a region.
 *
 * Uses the same PMP encoding: pmaaddr = (base >> 2) | (size/8 - 1).
 * Constraints (not checked for performance): base must be naturally aligned
 * to @p size, and size must be a power of two ≥ 8 bytes.
 *
 * Examples:
 *   kv_pma_napot_encode(0x80000000, 32768) → 0x20000FFF  (32 KB at 0x8000_0000)
 *   kv_pma_napot_encode(0x80000000, 65536) → 0x20001FFF  (64 KB at 0x8000_0000)
 *
 * @param base  Region base address (must be size-aligned).
 * @param size  Region size in bytes (must be power of two, ≥ 8).
 * @return      NAPOT-encoded pmaaddr to write to the pmaaddr CSR.
 */
static inline uint32_t kv_pma_napot_encode(uint32_t base, uint32_t size)
{
    return (base >> 2) | (size / 8u - 1u);
}

/* ═══════════════════════════════════════════════════════════════════
 * Region programming helpers
 * ══════════════════════════════════════════════════════════════════ */

/**
 * @brief Write the pmaaddr CSR for region @p n.
 * @note Has no effect if the region's lock bit is set.
 */
static inline void _kv_pma_write_addr(unsigned int n, uint32_t addr)
{
    switch (n) {
    case 0: _KV_PMA_WRITE_CSR(0x7C4, addr); break;
    case 1: _KV_PMA_WRITE_CSR(0x7C5, addr); break;
    case 2: _KV_PMA_WRITE_CSR(0x7C6, addr); break;
    case 3: _KV_PMA_WRITE_CSR(0x7C7, addr); break;
    case 4: _KV_PMA_WRITE_CSR(0x7C8, addr); break;
    case 5: _KV_PMA_WRITE_CSR(0x7C9, addr); break;
    case 6: _KV_PMA_WRITE_CSR(0x7CA, addr); break;
    case 7: _KV_PMA_WRITE_CSR(0x7CB, addr); break;
    default: break;
    }
}

/**
 * @brief Write a single region's cfg byte into the appropriate pmacfg CSR.
 *
 * Performs a read–modify–write on the 32-bit pmacfg word so only the
 * target region's byte is changed.  Lock bits in other bytes are preserved.
 * @note Has no effect on the target byte if its own lock bit is set.
 */
static inline void _kv_pma_write_cfg(unsigned int n, uint8_t cfg_byte)
{
    uint32_t word, mask, shifted;
    unsigned int shift;
    if (n < 4) {
        shift   = n * 8u;
        mask    = ~(0xFFu << shift);
        shifted = (uint32_t)cfg_byte << shift;
        word    = _KV_PMA_READ_CSR(0x7C0);
        word    = (word & mask) | shifted;
        _KV_PMA_WRITE_CSR(0x7C0, word);
    } else if (n < 8) {
        shift   = (n - 4u) * 8u;
        mask    = ~(0xFFu << shift);
        shifted = (uint32_t)cfg_byte << shift;
        word    = _KV_PMA_READ_CSR(0x7C1);
        word    = (word & mask) | shifted;
        _KV_PMA_WRITE_CSR(0x7C1, word);
    }
}

/**
 * @brief Disable region @p n (set address-match mode to OFF).
 *
 * Clears the A[1:0] field while preserving any lock bit.  If the region
 * is locked this call has no effect.
 *
 * @param n Region index (0–7).
 */
static inline void kv_pma_clear_region(unsigned int n)
{
    uint8_t cfg = kv_pma_read_cfg(n);
    if (cfg & KV_PMA_LOCK)
        return;  /* locked – ignore */
    cfg &= ~(KV_PMA_MODE_NAPOT);  /* clear A[1:0] */
    _kv_pma_write_cfg(n, cfg);
}

/**
 * @brief Configure region @p n in NAPOT mode.
 *
 * Sets pmaaddr to the NAPOT encoding of [@p base, @p base + @p size) and
 * programs the cfg byte with mode=NAPOT and the supplied attribute bits.
 *
 * @param n     Region index (0–7).
 * @param base  Region base address (must be naturally aligned to @p size).
 * @param size  Region size in bytes (power of two, ≥ 8).
 * @param attrs Attribute bits: any combination of
 *              ::KV_PMA_ICACHEABLE, ::KV_PMA_DCACHEABLE, ::KV_PMA_BUFFERABLE.
 *              The ::KV_PMA_LOCK bit may also be included to lock after write.
 */
static inline void kv_pma_set_napot(unsigned int n, uint32_t base,
                                    uint32_t size, uint8_t attrs)
{
    uint8_t cfg = KV_PMA_MODE_NAPOT | (attrs & (KV_PMA_LOCK | KV_PMA_ICACHEABLE |
                                                 KV_PMA_DCACHEABLE | KV_PMA_BUFFERABLE));
    _kv_pma_write_addr(n, kv_pma_napot_encode(base, size));
    _kv_pma_write_cfg(n, cfg);
}

/**
 * @brief Configure region @p n in TOR (Top-Of-Range) mode.
 *
 * Region @p n matches addresses in [pmaaddr[n-1]*4, @p top_addr).
 * For region 0 the lower bound is always 0x0000_0000.
 *
 * @param n         Region index (0–7).
 * @param top_addr  Exclusive upper bound of the region (must be 4-byte aligned).
 * @param attrs     Attribute bits (same as ::kv_pma_set_napot).
 */
static inline void kv_pma_set_tor(unsigned int n, uint32_t top_addr,
                                   uint8_t attrs)
{
    uint8_t cfg = KV_PMA_MODE_TOR | (attrs & (KV_PMA_LOCK | KV_PMA_ICACHEABLE |
                                               KV_PMA_DCACHEABLE | KV_PMA_BUFFERABLE));
    _kv_pma_write_addr(n, top_addr >> 2);
    _kv_pma_write_cfg(n, cfg);
}

/** @} */
#endif /* KV_PMA_H */

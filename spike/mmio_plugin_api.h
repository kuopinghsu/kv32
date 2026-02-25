/* ============================================================================
 * spike/mmio_plugin_api.h – Spike mmio_plugin interface + RV32 address map
 *
 * All plugins include ONLY this header.  It provides:
 *
 *   1. The Spike mmio_plugin_t callback struct and register_mmio_plugin().
 *      If SPIKE_INCLUDE is on the compiler search path the real Spike header
 *      is used; otherwise a portable self-contained shim is provided.
 *
 *   2. Every peripheral base address, register offset, and bit-field constant
 *      for the RV32 SoC – sourced directly from the SDK header
 *      ../sw/include/rv_platform.h so that plugins and firmware always agree.
 *
 * Build flags added by spike/Makefile:
 *   -DRV_PLATFORM_NO_INLINE_HELPERS   suppresses firmware-only MMIO helpers
 *   -I../sw/include                   makes rv_platform.h findable
 *   -I$(SPIKE_INCLUDE)                optional; activates real Spike types
 * =========================================================================*/
#pragma once

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <dlfcn.h>

/* ── Tell rv_platform.h we are building host code ───────────────────────── */
/* Suppresses the two inline helpers (rv_magic_putc / rv_magic_exit) that    *
 * dereference volatile MMIO pointers – meaningless and unsafe on the host.  */
#ifndef RV_PLATFORM_NO_INLINE_HELPERS
#  define RV_PLATFORM_NO_INLINE_HELPERS
#endif

/* ── SDK peripheral register map (single source of truth) ───────────────── */
#include "rv_platform.h"     /* resolved via -I../sw/include in spike/Makefile */

/* After the include, make any accidental RV_REG32 call a visible no-op so  *
 * nothing writes to random host-process memory.                             */
#undef  RV_REG32
#define RV_REG32(base, off)  ((void)((base)+(off)))

/* ── Spike mmio_plugin_t ─────────────────────────────────────────────────── */
/* reg_t: Spike uses uint64_t even in RV32 mode.                              */
typedef uint64_t reg_t;

#ifdef SPIKE_INCLUDE
/* Real Spike headers available. */
#  include <riscv/mmio_plugin.h>
#else
/* Portable shim – matches riscv/mmio_plugin.h from Spike. */
#include <stdbool.h>
typedef struct {
    void* (*alloc)(const char* args);
    void  (*dealloc)(void* dev);
    bool  (*access)(void* dev, reg_t addr, size_t len,
                    uint8_t* bytes, bool store);
} mmio_plugin_t;

#ifdef __cplusplus
extern "C"
#endif
/* Symbol provided by Spike binary when loaded with RTLD_GLOBAL. */
void register_mmio_plugin(const char* name, const mmio_plugin_t* plugin);
#endif /* SPIKE_INCLUDE */

/* ── Little-endian buffer helpers ───────────────────────────────────────── */
static inline uint32_t le32_load(const uint8_t* p) {
    return (uint32_t)p[0]         | ((uint32_t)p[1] <<  8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static inline void le32_store(uint8_t* p, uint32_t v) {
    p[0]=(uint8_t)(v);      p[1]=(uint8_t)(v>> 8);
    p[2]=(uint8_t)(v>>16);  p[3]=(uint8_t)(v>>24);
}
/* Fill an access buffer with a register value (handles 1, 2, or 4 bytes). */
static inline void fill_bytes(uint8_t* bytes, size_t len, uint32_t v) {
    uint8_t tmp[8]; le32_store(tmp, v); le32_store(tmp+4, 0);
    if (len > 8) len = 8;
    memcpy(bytes, tmp, len);
}
/* Extract a 32-bit value from a store access buffer (handles 1, 2, or 4 bytes). */
static inline uint32_t extract_val(const uint8_t* bytes, size_t len) {
    uint8_t tmp[4] = {0,0,0,0};
    memcpy(tmp, bytes, len < 4 ? len : 4);
    return le32_load(tmp);
}

/* ── Inter-plugin PLIC interface ─────────────────────────────────────────── */
/* Peripheral plugins call plic_notify() to assert/deassert an IRQ source.   *
 * The symbol plic_set_pending is exported by plugin_plic.so (loaded with    *
 * RTLD_GLOBAL by Spike) and located lazily via dlsym so loading order does  *
 * not matter.  If plic_set_pending is not found the call is silently ignored.*
 * Use the RV_PLIC_SRC_* constants from rv_platform.h for the src argument.  */
static inline void plic_notify(int src, int asserted) {
    typedef void (*fn_t)(int, int);
    static fn_t fn = (fn_t)(uintptr_t)-1;  /* sentinel: not yet resolved */
    if (fn == (fn_t)(uintptr_t)-1)
        fn = (fn_t)dlsym(RTLD_DEFAULT, "plic_set_pending");
    if (fn) fn(src, asserted);
}

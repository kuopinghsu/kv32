#include <stdint.h>
#include <csr.h>

extern void putc(char c);

static void puts_s(const char *s) {
    while (*s) putc(*s++);
}

static void put_dec(uint32_t v) {
    char buf[12];
    int i = 0;
    if (v == 0) {
        putc('0');
        return;
    }
    while (v > 0) {
        buf[i++] = (char)('0' + (v % 10));
        v /= 10;
    }
    while (i > 0) putc(buf[--i]);
}

static __attribute__((noinline)) uint32_t chain_b(uint32_t depth, uint32_t x);

static __attribute__((noinline)) uint32_t chain_a(uint32_t depth, uint32_t x) {
    if (depth == 0u) return x + 1u;
    if ((depth & 1u) != 0u) {
        return chain_b(depth - 1u, x + 3u) + 1u;
    }
    return chain_a(depth - 1u, x ^ 0x5Au) + 2u;
}

static __attribute__((noinline)) uint32_t chain_b(uint32_t depth, uint32_t x) {
    if (depth == 0u) return x + 7u;
    if ((depth & 1u) != 0u) {
        return chain_a(depth - 1u, x + 11u) + 3u;
    }
    return chain_b(depth - 1u, x ^ 0xA5u) + 4u;
}

#ifndef RASBENCH_DEPTH
#define RASBENCH_DEPTH 24
#endif

#ifndef RASBENCH_ITERS
#define RASBENCH_ITERS 5000
#endif

int main(void) {
    volatile uint32_t acc = 0x12345678u;

    uint32_t t0 = read_csr_mcycle();
    for (uint32_t i = 0; i < (uint32_t)RASBENCH_ITERS; i++) {
        acc ^= chain_a((uint32_t)RASBENCH_DEPTH, acc + i);
        acc += chain_b((uint32_t)RASBENCH_DEPTH, acc ^ (i << 1));
    }
    uint32_t t1 = read_csr_mcycle();

    puts_s("RASBENCH: cycles=");
    put_dec(t1 - t0);
    puts_s(" depth=");
    put_dec((uint32_t)RASBENCH_DEPTH);
    puts_s(" iters=");
    put_dec((uint32_t)RASBENCH_ITERS);
    puts_s(" acc=");
    put_dec((uint32_t)(acc & 0xFFFFu));
    puts_s("\n");

    return (acc == 0u) ? 1 : 0;
}

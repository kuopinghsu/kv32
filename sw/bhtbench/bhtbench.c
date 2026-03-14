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

#define DEF_PATTERN_SITE(N) \
static __attribute__((noinline)) uint32_t psite_##N(uint32_t phase, uint32_t x) { \
    uint32_t period = (uint32_t)((N % 7) + 2); \
    uint32_t taken = ((phase + (uint32_t)N) % period) != 0u; \
    if (taken) { \
        return x + (uint32_t)(N + 1); \
    } \
    return x ^ (uint32_t)(N * 3 + 5); \
}

DEF_PATTERN_SITE(0)   DEF_PATTERN_SITE(1)   DEF_PATTERN_SITE(2)   DEF_PATTERN_SITE(3)
DEF_PATTERN_SITE(4)   DEF_PATTERN_SITE(5)   DEF_PATTERN_SITE(6)   DEF_PATTERN_SITE(7)
DEF_PATTERN_SITE(8)   DEF_PATTERN_SITE(9)   DEF_PATTERN_SITE(10)  DEF_PATTERN_SITE(11)
DEF_PATTERN_SITE(12)  DEF_PATTERN_SITE(13)  DEF_PATTERN_SITE(14)  DEF_PATTERN_SITE(15)
DEF_PATTERN_SITE(16)  DEF_PATTERN_SITE(17)  DEF_PATTERN_SITE(18)  DEF_PATTERN_SITE(19)
DEF_PATTERN_SITE(20)  DEF_PATTERN_SITE(21)  DEF_PATTERN_SITE(22)  DEF_PATTERN_SITE(23)
DEF_PATTERN_SITE(24)  DEF_PATTERN_SITE(25)  DEF_PATTERN_SITE(26)  DEF_PATTERN_SITE(27)
DEF_PATTERN_SITE(28)  DEF_PATTERN_SITE(29)  DEF_PATTERN_SITE(30)  DEF_PATTERN_SITE(31)
DEF_PATTERN_SITE(32)  DEF_PATTERN_SITE(33)  DEF_PATTERN_SITE(34)  DEF_PATTERN_SITE(35)
DEF_PATTERN_SITE(36)  DEF_PATTERN_SITE(37)  DEF_PATTERN_SITE(38)  DEF_PATTERN_SITE(39)
DEF_PATTERN_SITE(40)  DEF_PATTERN_SITE(41)  DEF_PATTERN_SITE(42)  DEF_PATTERN_SITE(43)
DEF_PATTERN_SITE(44)  DEF_PATTERN_SITE(45)  DEF_PATTERN_SITE(46)  DEF_PATTERN_SITE(47)
DEF_PATTERN_SITE(48)  DEF_PATTERN_SITE(49)  DEF_PATTERN_SITE(50)  DEF_PATTERN_SITE(51)
DEF_PATTERN_SITE(52)  DEF_PATTERN_SITE(53)  DEF_PATTERN_SITE(54)  DEF_PATTERN_SITE(55)
DEF_PATTERN_SITE(56)  DEF_PATTERN_SITE(57)  DEF_PATTERN_SITE(58)  DEF_PATTERN_SITE(59)
DEF_PATTERN_SITE(60)  DEF_PATTERN_SITE(61)  DEF_PATTERN_SITE(62)  DEF_PATTERN_SITE(63)

typedef uint32_t (*psite_fn_t)(uint32_t, uint32_t);

static psite_fn_t sites[64] = {
    psite_0,  psite_1,  psite_2,  psite_3,  psite_4,  psite_5,  psite_6,  psite_7,
    psite_8,  psite_9,  psite_10, psite_11, psite_12, psite_13, psite_14, psite_15,
    psite_16, psite_17, psite_18, psite_19, psite_20, psite_21, psite_22, psite_23,
    psite_24, psite_25, psite_26, psite_27, psite_28, psite_29, psite_30, psite_31,
    psite_32, psite_33, psite_34, psite_35, psite_36, psite_37, psite_38, psite_39,
    psite_40, psite_41, psite_42, psite_43, psite_44, psite_45, psite_46, psite_47,
    psite_48, psite_49, psite_50, psite_51, psite_52, psite_53, psite_54, psite_55,
    psite_56, psite_57, psite_58, psite_59, psite_60, psite_61, psite_62, psite_63
};

#ifndef BHTBENCH_WORKSET
#define BHTBENCH_WORKSET 64
#endif

#ifndef BHTBENCH_PHASES
#define BHTBENCH_PHASES 5000
#endif

int main(void) {
    volatile uint32_t acc = 0x2468ACE1u;
    uint32_t ws = (uint32_t)BHTBENCH_WORKSET;
    if (ws == 0 || ws > 64u) ws = 64u;

    uint32_t t0 = read_csr_mcycle();
    for (uint32_t phase = 0; phase < (uint32_t)BHTBENCH_PHASES; phase++) {
        for (uint32_t i = 0; i < ws; i++) {
            acc = sites[i](phase, acc + i * 11u + 3u);
        }
    }
    uint32_t t1 = read_csr_mcycle();

    puts_s("BHTBENCH: cycles=");
    put_dec(t1 - t0);
    puts_s(" workset=");
    put_dec(ws);
    puts_s(" phases=");
    put_dec((uint32_t)BHTBENCH_PHASES);
    puts_s(" acc=");
    put_dec((uint32_t)(acc & 0xFFFFu));
    puts_s("\n");

    return (acc == 0u) ? 1 : 0;
}

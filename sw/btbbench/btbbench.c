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

#define DEF_SITE(N) \
static __attribute__((noinline)) uint32_t site_##N(uint32_t x) { \
    uint32_t bias = (uint32_t)((N % 13) + 1); \
    if ((x & bias) != 0u) { \
        return x + (uint32_t)(N + 3); \
    } \
    return x ^ (uint32_t)(N + 7); \
}

DEF_SITE(0)   DEF_SITE(1)   DEF_SITE(2)   DEF_SITE(3)
DEF_SITE(4)   DEF_SITE(5)   DEF_SITE(6)   DEF_SITE(7)
DEF_SITE(8)   DEF_SITE(9)   DEF_SITE(10)  DEF_SITE(11)
DEF_SITE(12)  DEF_SITE(13)  DEF_SITE(14)  DEF_SITE(15)
DEF_SITE(16)  DEF_SITE(17)  DEF_SITE(18)  DEF_SITE(19)
DEF_SITE(20)  DEF_SITE(21)  DEF_SITE(22)  DEF_SITE(23)
DEF_SITE(24)  DEF_SITE(25)  DEF_SITE(26)  DEF_SITE(27)
DEF_SITE(28)  DEF_SITE(29)  DEF_SITE(30)  DEF_SITE(31)
DEF_SITE(32)  DEF_SITE(33)  DEF_SITE(34)  DEF_SITE(35)
DEF_SITE(36)  DEF_SITE(37)  DEF_SITE(38)  DEF_SITE(39)
DEF_SITE(40)  DEF_SITE(41)  DEF_SITE(42)  DEF_SITE(43)
DEF_SITE(44)  DEF_SITE(45)  DEF_SITE(46)  DEF_SITE(47)
DEF_SITE(48)  DEF_SITE(49)  DEF_SITE(50)  DEF_SITE(51)
DEF_SITE(52)  DEF_SITE(53)  DEF_SITE(54)  DEF_SITE(55)
DEF_SITE(56)  DEF_SITE(57)  DEF_SITE(58)  DEF_SITE(59)
DEF_SITE(60)  DEF_SITE(61)  DEF_SITE(62)  DEF_SITE(63)

typedef uint32_t (*site_fn_t)(uint32_t);

static site_fn_t sites[64] = {
    site_0,  site_1,  site_2,  site_3,  site_4,  site_5,  site_6,  site_7,
    site_8,  site_9,  site_10, site_11, site_12, site_13, site_14, site_15,
    site_16, site_17, site_18, site_19, site_20, site_21, site_22, site_23,
    site_24, site_25, site_26, site_27, site_28, site_29, site_30, site_31,
    site_32, site_33, site_34, site_35, site_36, site_37, site_38, site_39,
    site_40, site_41, site_42, site_43, site_44, site_45, site_46, site_47,
    site_48, site_49, site_50, site_51, site_52, site_53, site_54, site_55,
    site_56, site_57, site_58, site_59, site_60, site_61, site_62, site_63
};

#ifndef BTBBENCH_WORKSET
#define BTBBENCH_WORKSET 64
#endif

#ifndef BTBBENCH_ITERS
#define BTBBENCH_ITERS 3500
#endif

int main(void) {
    volatile uint32_t acc = 0x13579BDFu;
    uint32_t ws = (uint32_t)BTBBENCH_WORKSET;
    if (ws == 0 || ws > 64u) ws = 64u;

    uint32_t t0 = read_csr_mcycle();
    for (uint32_t r = 0; r < (uint32_t)BTBBENCH_ITERS; r++) {
        for (uint32_t i = 0; i < ws; i++) {
            uint32_t seed = (acc + (r << 1) + i) ^ (0x9E3779B9u + i * 17u);
            acc = sites[i](seed);
        }
    }
    uint32_t t1 = read_csr_mcycle();

    puts_s("BTBBENCH: cycles=");
    put_dec(t1 - t0);
    puts_s(" workset=");
    put_dec(ws);
    puts_s(" iters=");
    put_dec((uint32_t)BTBBENCH_ITERS);
    puts_s(" acc=");
    put_dec((uint32_t)(acc & 0xFFFFu));
    puts_s("\n");

    return (acc == 0u) ? 1 : 0;
}

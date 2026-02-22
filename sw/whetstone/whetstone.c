/*
 * Whetstone Benchmark - Integer-Only Baremetal RISC-V Version
 *
 * Adapted from the original Whetstone benchmark (1972)
 *
 * NOTE: This is NOT a floating-point benchmark!
 * This version uses fixed-point arithmetic (scaled by 1000)
 * since the RISC-V core does not have FPU support.
 *
 * For true Whetstone scores, a processor with F/D extensions is required.
 */

#include <stdint.h>
#include <csr.h>

/* Magic console output */
#define CONSOLE_ADDR 0xFFFFFFF4
#define console_putc(c) (*(volatile uint32_t*)CONSOLE_ADDR = (c))

/* Fixed-point scaling */
#define SCALE 1000
#define PI_SCALED (3142)  /* PI * 1000 */

/* Configuration */
#define ITERATIONS 10  /* Reduced for simulation */

/* Simple output functions */
static void puts(const char *s) {
    while (*s) console_putc(*s++);
}

static void print_uint_recursive(uint32_t val) {
    if (val >= 10) print_uint_recursive(val / 10);
    console_putc('0' + (val % 10));
}

static void print_uint(uint32_t val) {
    print_uint_recursive(val);
}

static void print_uint64(uint64_t val) {
    if (val >= 10) print_uint64(val / 10);
    console_putc('0' + (val % 10));
}

/* Fixed-point math functions (scaled by 1000) */

static int32_t fp_mul(int32_t a, int32_t b) {
    return (int32_t)(((int64_t)a * (int64_t)b) / SCALE);
}

static int32_t fp_div(int32_t a, int32_t b) {
    if (b == 0) return 0;
    return (int32_t)(((int64_t)a * SCALE) / (int64_t)b);
}

static int32_t fp_sqrt(int32_t x) __attribute__((unused));
static int32_t fp_sqrt(int32_t x) {
    /* Newton-Raphson method */
    if (x <= 0) return 0;

    int32_t guess = x / 2;
    int i;

    for (i = 0; i < 10; i++) {
        if (guess == 0) break;
        guess = (guess + fp_div(x, guess)) / 2;
    }

    return guess;
}

static int32_t fp_sin(int32_t x) {
    /* Taylor series approximation: sin(x) ≈ x - x³/6 + x⁵/120 */
    /* Input x is in scaled radians (x * 1000) */

    /* Normalize to 0-2PI range */
    while (x > 2 * PI_SCALED) x -= 2 * PI_SCALED;
    while (x < 0) x += 2 * PI_SCALED;

    int32_t x2 = fp_mul(x, x);
    int32_t x3 = fp_mul(x2, x);
    int32_t x5 = fp_mul(x3, x2);

    int32_t term1 = x;
    int32_t term2 = x3 / 6;
    int32_t term3 = x5 / 120;

    return term1 - term2 + term3;
}

static int32_t fp_cos(int32_t x) {
    /* cos(x) = sin(x + PI/2) */
    return fp_sin(x + (PI_SCALED / 2));
}

static int32_t fp_exp(int32_t x) {
    /* Simplified exponential: e^x ≈ 1 + x + x²/2 + x³/6 */
    if (x > 10 * SCALE) return 0x7FFFFFFF;  /* Overflow */
    if (x < -10 * SCALE) return 0;

    int32_t x2 = fp_mul(x, x);
    int32_t x3 = fp_mul(x2, x);

    return SCALE + x + x2/2 + x3/6;
}

static int32_t fp_atan(int32_t x) {
    /* Simplified arctangent approximation */
    /* atan(x) ≈ x / (1 + 0.28*x²) for small x */
    int32_t x2 = fp_mul(x, x);
    int32_t denom = SCALE + (x2 * 28) / 100;
    if (denom == 0) return 0;
    return fp_div(x, denom);
}

/* Whetstone modules */

static void module1(int32_t *e1, int32_t t, int32_t t1, int32_t t2) {
    int32_t j;
    int32_t x1, x2, x3, x4;

    j = 0;
    x1 = 1 * SCALE;
    x2 = -1 * SCALE;
    x3 = -1 * SCALE;
    x4 = -1 * SCALE;

    for (j = 0; j < 6; j++) {
        x1 = (x1 + x2 + x3 - x4) * t;
        x2 = (x1 + x2 - x3 + x4) * t;
        x3 = (x1 - x2 + x3 + x4) * t;
        x4 = (-x1 + x2 + x3 + x4) / t2;
    }

    *e1 = (x1 + x2 + x3 + x4) / SCALE;
}

static void module2(int32_t *e1, int32_t t) {
    int32_t i, j;
    int32_t x, y, z;

    x = 1 * SCALE;
    y = 1 * SCALE;
    z = 1 * SCALE;

    for (i = 0; i < 6; i++) {
        for (j = 0; j < 6; j++) {
            x = fp_mul(t, (x + y));
            y = fp_mul(t, (x + y));
            z = (x + y) / t;
        }
    }

    *e1 = z / SCALE;
}

static void module3(int32_t *e1, int32_t t) {
    int32_t j;
    int32_t x, y;

    x = 5 * SCALE;
    y = 5 * SCALE;

    for (j = 0; j < 6; j++) {
        x = fp_mul(t, fp_atan(x));
        y = fp_mul(t, fp_sin(y));
        x = fp_mul(t, fp_cos(x));
        y = fp_mul(t, fp_exp(y / SCALE));
    }

    *e1 = (x + y) / SCALE;
}

static void module4(void) {
    int32_t j;

    for (j = 0; j < 6; j++) {
        /* Empty loop - tests loop overhead */
    }
}

static void module5(void) {
    int32_t j, k;

    j = 1;
    k = 2;

    for (j = 1; j <= 6; j++) {
        k = k + j;
        k = k * 2;
        k = k - 1;
        if (k > 10) k = k - 1;
    }
}

static void module6(int32_t array[], int32_t size) {
    int32_t i, j;
    int32_t sum = 0;

    for (i = 0; i < size; i++) {
        array[i] = i * SCALE;
    }

    for (j = 0; j < 6; j++) {
        for (i = 0; i < size; i++) {
            sum += array[i];
            array[i] = array[i] + 1 * SCALE;
        }
    }
}

int main(void) {
    uint64_t start_cycles, end_cycles, total_cycles;
    int32_t n;
    int32_t e1;
    int32_t t = 500;  /* 0.5 scaled */
    int32_t t1 = 50;  /* 0.05 scaled */
    int32_t t2 = 2000; /* 2.0 scaled */
    int32_t array[10];

    puts("Whetstone Benchmark (Integer-Only Version)\n");
    puts("===========================================\n\n");

    puts("WARNING: This is NOT a floating-point benchmark!\n");
    puts("Using fixed-point arithmetic (scaled by 1000)\n");
    puts("Not representative of true Whetstone performance.\n\n");

    puts("Configuration:\n");
    puts("  Iterations: "); print_uint(ITERATIONS); puts("\n");
    puts("  Scale factor: "); print_uint(SCALE); puts("\n\n");

    /* Read start time */
    start_cycles = read_csr_cycle64();

    /* Run Whetstone iterations */
    for (n = 0; n < ITERATIONS; n++) {
        /* Module 1: Simple arithmetic */
        module1(&e1, t, t1, t2);

        /* Module 2: Array operations */
        module2(&e1, t);

        /* Module 3: Math functions */
        module3(&e1, t);

        /* Module 4: Empty loop */
        module4();

        /* Module 5: Conditional branches */
        module5();

        /* Module 6: Array processing */
        module6(array, 10);
    }

    /* Read end time */
    end_cycles = read_csr_cycle64();
    total_cycles = end_cycles - start_cycles;

    /* Report results */
    puts("Results:\n");
    puts("--------\n");
    puts("Total cycles:  "); print_uint64(total_cycles); puts("\n");
    puts("Iterations:    "); print_uint(ITERATIONS); puts("\n");
    puts("Cycles/iter:   "); print_uint64(total_cycles / ITERATIONS); puts("\n\n");

    puts("NOTE: Cannot calculate MWIPS (Million Whetstone Instructions Per Second)\n");
    puts("      due to integer-only implementation.\n\n");

    puts("Performance:\n");
    puts("  Cycles/iteration: "); print_uint64(total_cycles / ITERATIONS); puts("\n");

    puts("\nWhetstone benchmark complete.\n");

    return 0;
}

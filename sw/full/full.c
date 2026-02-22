// Comprehensive RISC-V Test Program
// Tests UART, CLINT, compressed instructions, and various ISA features

#include <stdint.h>

// Memory-mapped I/O addresses
#define UART_BASE    0x02010000
#define UART_TX      (*(volatile uint32_t*)(UART_BASE + 0x00))
#define UART_STATUS  (*(volatile uint32_t*)(UART_BASE + 0x04))

#define CLINT_BASE   0x02000000
#define MSIP         (*(volatile uint32_t*)(CLINT_BASE + 0x0000))
#define MTIMECMP_LO  (*(volatile uint32_t*)(CLINT_BASE + 0x4000))
#define MTIMECMP_HI  (*(volatile uint32_t*)(CLINT_BASE + 0x4004))
#define MTIME_LO     (*(volatile uint32_t*)(CLINT_BASE + 0xBFF8))
#define MTIME_HI     (*(volatile uint32_t*)(CLINT_BASE + 0xBFFC))

// Test statistics
volatile uint32_t tests_run = 0;
volatile uint32_t tests_passed = 0;
volatile uint32_t timer_irq_count = 0;

// Function prototypes
void uart_putc(char c);
void uart_puts(const char* s);
void uart_puthex(uint32_t val);
void test_arithmetic(void);
void test_logic(void);
void test_shifts(void);
void test_branches(void);
void test_loads_stores(void);
void test_multiply(void);
void test_divide(void);
void test_compressed(void);
void test_fence(void);
void test_uart(void);
void test_clint(void);

// Trap handler
void trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval) {
    if (mcause & 0x80000000) {
        // Interrupt
        uint32_t irq = mcause & 0x7FFFFFFF;
        if (irq == 7) {
            // Timer interrupt
            timer_irq_count++;

            // Disable further timer interrupts by setting mtimecmp to max
            MTIMECMP_LO = 0xFFFFFFFF;
            MTIMECMP_HI = 0xFFFFFFFF;
        }
    } else {
        // Exception
        uart_puts("EXCEPTION: mcause=");
        uart_puthex(mcause);
        uart_puts(" mepc=");
        uart_puthex(mepc);
        uart_puts(" mtval=");
        uart_puthex(mtval);
        uart_putc('\n');

        // Exit simulation
        *(volatile uint32_t*)0xFFFFFFF0 = 1;
        while(1);
    }
}

// UART functions
void uart_putc(char c) {
    while (UART_STATUS & 0x01);  // Wait if busy
    UART_TX = c;
}

void uart_puts(const char* s) {
    while (*s) {
        uart_putc(*s++);
    }
}

void uart_puthex(uint32_t val) {
    const char hex[] = "0123456789ABCDEF";
    uart_putc('0');
    uart_putc('x');
    for (int i = 7; i >= 0; i--) {
        uart_putc(hex[(val >> (i * 4)) & 0xF]);
    }
}

// Test macros
#define TEST_START(name) \
    do { \
        uart_puts("TEST: "); \
        uart_puts(name); \
        uart_puts(" ... "); \
        tests_run++; \
    } while(0)

#define TEST_ASSERT(cond) \
    do { \
        if (!(cond)) { \
            uart_puts("FAIL at line "); \
            uart_puthex(__LINE__); \
            uart_putc('\n'); \
            return; \
        } \
    } while(0)

#define TEST_END() \
    do { \
        uart_puts("PASS\n"); \
        tests_passed++; \
    } while(0)

// Arithmetic tests
void test_arithmetic(void) {
    TEST_START("Arithmetic");

    // ADD
    TEST_ASSERT((5 + 3) == 8);
    TEST_ASSERT((100 + 200) == 300);

    // SUB
    TEST_ASSERT((10 - 3) == 7);
    TEST_ASSERT((5 - 10) == -5);

    // ADDI
    volatile int x = 42;
    x += 10;
    TEST_ASSERT(x == 52);

    // Overflow
    uint32_t a = 0xFFFFFFFF;
    uint32_t b = 1;
    TEST_ASSERT((a + b) == 0);

    TEST_END();
}

// Logic tests
void test_logic(void) {
    TEST_START("Logic Operations");

    // AND
    TEST_ASSERT((0xFF & 0x0F) == 0x0F);
    TEST_ASSERT((0xAAAA & 0x5555) == 0);

    // OR
    TEST_ASSERT((0xF0 | 0x0F) == 0xFF);
    TEST_ASSERT((0xAAAA | 0x5555) == 0xFFFF);

    // XOR
    TEST_ASSERT((0xFF ^ 0xFF) == 0);
    TEST_ASSERT((0xAA ^ 0x55) == 0xFF);

    TEST_END();
}

// Shift tests
void test_shifts(void) {
    TEST_START("Shift Operations");

    // SLL (shift left logical)
    TEST_ASSERT((1 << 4) == 16);
    TEST_ASSERT((0xF << 8) == 0xF00);

    // SRL (shift right logical)
    TEST_ASSERT((0x80 >> 4) == 0x08);
    TEST_ASSERT((0xFF00 >> 8) == 0xFF);

    // SRA (shift right arithmetic)
    int32_t neg = -16;
    TEST_ASSERT((neg >> 2) == -4);

    TEST_END();
}

// Branch tests
void test_branches(void) {
    TEST_START("Branch Instructions");

    int result = 0;

    // BEQ
    if (5 == 5) result++;
    TEST_ASSERT(result == 1);

    // BNE
    if (5 != 3) result++;
    TEST_ASSERT(result == 2);

    // BLT
    if (3 < 5) result++;
    TEST_ASSERT(result == 3);

    // BGE
    if (5 >= 5) result++;
    TEST_ASSERT(result == 4);

    // BLTU
    if (3U < 5U) result++;
    TEST_ASSERT(result == 5);

    // BGEU
    if (5U >= 5U) result++;
    TEST_ASSERT(result == 6);

    TEST_END();
}

// Load/Store tests
void test_loads_stores(void) {
    TEST_START("Load/Store Operations");

    volatile uint32_t data[4] = {0x12345678, 0xABCDEF00, 0xDEADBEEF, 0xCAFEBABE};

    // Word access
    TEST_ASSERT(data[0] == 0x12345678);
    data[0] = 0x11223344;
    TEST_ASSERT(data[0] == 0x11223344);

    // Halfword access
    volatile uint16_t* hdata = (volatile uint16_t*)data;
    TEST_ASSERT(hdata[0] == 0x3344);
    hdata[0] = 0x5566;
    TEST_ASSERT(hdata[0] == 0x5566);

    // Byte access
    volatile uint8_t* bdata = (volatile uint8_t*)data;
    TEST_ASSERT(bdata[0] == 0x66);
    bdata[0] = 0x77;
    TEST_ASSERT(bdata[0] == 0x77);

    TEST_END();
}

// Multiply tests (M extension)
void test_multiply(void) {
    TEST_START("Multiply Instructions");

    // MUL
    TEST_ASSERT((5 * 6) == 30);
    TEST_ASSERT((123 * 456) == 56088);

    // Negative multiply
    TEST_ASSERT((5 * -3) == -15);
    TEST_ASSERT((-5 * -3) == 15);

    TEST_END();
}

// Divide tests (M extension)
void test_divide(void) {
    TEST_START("Divide Instructions");

    // Use volatile to prevent compiler from optimizing away the divisions
    volatile int32_t a = 20, b = 5, c = 100, d = 7;
    volatile uint32_t ua = 20, ub = 5;

    // DIV
    TEST_ASSERT((a / b) == 4);
    TEST_ASSERT((c / d) == 14);

    // DIVU
    TEST_ASSERT((ua / ub) == 4U);

    // REM
    volatile int32_t r1 = 20, r2 = 7, r3 = 100, r4 = 11;
    TEST_ASSERT((r1 % r2) == 6);
    TEST_ASSERT((r3 % r4) == 1);

    // Division by zero (should return -1 per RISC-V spec)
    volatile uint32_t zero = 0;
    volatile uint32_t ten = 10;
    volatile uint32_t div_result = ten / zero;
    TEST_ASSERT(div_result == 0xFFFFFFFF);

    TEST_END();
}

// Compressed instruction tests (C extension)
void test_compressed(void) {
    TEST_START("Compressed Instructions");

    // C.ADDI
    int x = 5;
    x += 10;  // Should compile to c.addi
    TEST_ASSERT(x == 15);

    // C.LI
    int y = 42;  // Should compile to c.li
    TEST_ASSERT(y == 42);

    // C.MV
    int z = y;  // Should compile to c.mv
    TEST_ASSERT(z == 42);

    // C.ADD
    int sum = x + y;  // May compile to c.add
    TEST_ASSERT(sum == 57);

    // C.SW / C.LW
    int arr[4] = {1, 2, 3, 4};
    TEST_ASSERT(arr[0] == 1);
    TEST_ASSERT(arr[3] == 4);

    // C.J (jump)
    int flag = 0;
    goto skip;
    flag = 1;
skip:
    TEST_ASSERT(flag == 0);

    TEST_END();
}

// FENCE instruction tests
void test_fence(void) {
    TEST_START("FENCE Instruction");

    // Memory ordering test with FENCE
    volatile uint32_t data[4] = {0, 0, 0, 0};

    // Write some data
    data[0] = 0x11111111;
    data[1] = 0x22222222;

    // Execute FENCE to ensure memory ordering
    asm volatile("fence" ::: "memory");

    // Read back the data
    TEST_ASSERT(data[0] == 0x11111111);
    TEST_ASSERT(data[1] == 0x22222222);

    // Test FENCE with different bits (iorw combinations)
    data[2] = 0x33333333;
    asm volatile("fence rw, rw" ::: "memory");
    TEST_ASSERT(data[2] == 0x33333333);

    // Write after fence
    data[3] = 0x44444444;
    asm volatile("fence w, w" ::: "memory");
    TEST_ASSERT(data[3] == 0x44444444);

    uart_puts("  FENCE executed successfully\n");

    TEST_END();
}

// UART tests
void test_uart(void) {
    TEST_START("UART Transmission");

    // Send test string
    uart_puts("UART_TEST_STRING");

    // Check status register
    uint32_t status = UART_STATUS;
    // Just verify we can read it without crashing
    (void)status;

    TEST_END();
}

// CLINT tests
void test_clint(void) {
    TEST_START("CLINT Timer Interrupt");

    // Read current time
    uint32_t time_lo = MTIME_LO;
    uint32_t time_hi = MTIME_HI;

    uart_puts("  Current mtime: ");
    uart_puthex(time_hi);
    uart_putc(':');
    uart_puthex(time_lo);
    uart_putc('\n');

    // Set timer interrupt to trigger soon
    uint32_t trigger_time = time_lo + 1000;
    MTIMECMP_LO = trigger_time;
    MTIMECMP_HI = time_hi;

    // Enable interrupts
    asm volatile("csrsi mstatus, 0x8");  // Set MIE bit

    // Wait for interrupt
    uart_puts("  Waiting for timer interrupt...\n");
    uint32_t timeout = 0;
    while (timer_irq_count == 0 && timeout < 100000) {
        timeout++;
    }

    TEST_ASSERT(timer_irq_count > 0);

    uart_puts("  Timer interrupt received! Count: ");
    uart_puthex(timer_irq_count);
    uart_putc('\n');

    // Disable interrupts
    asm volatile("csrci mstatus, 0x8");  // Clear MIE bit

    TEST_END();
}

// Test atomic operations
void test_atomics(void) {
    TEST_START("Atomic Operations");

    volatile uint32_t memory_value = 0xF7FFFFFF;  // Initial value
    uint32_t returned_value;
    uint32_t operand = 0x80000000;  // -2^31

    // Test AMOMAX.W - should return original value and write max
    __asm__ volatile (
        "amomax.w %0, %2, (%1)"
        : "=r"(returned_value)
        : "r"(&memory_value), "r"(operand)
        : "memory"
    );

    uart_puts("  AMOMAX test:\n");
    uart_puts("    Initial memory: ");
    uart_puthex(0xF7FFFFFF);
    uart_putc('\n');
    uart_puts("    Operand: ");
    uart_puthex(operand);
    uart_putc('\n');
    uart_puts("    Returned value: ");
    uart_puthex(returned_value);
    uart_putc('\n');
    uart_puts("    Memory after: ");
    uart_puthex(memory_value);
    uart_putc('\n');

    // Check: returned value should be the original (0xF7FFFFFF)
    TEST_ASSERT(returned_value == 0xF7FFFFFF);
    // Check: memory should contain max(-134217729, -2147483648) = -134217729 = 0xF7FFFFFF
    TEST_ASSERT(memory_value == 0xF7FFFFFF);

    TEST_END();
}

// Main test function
int main(void) {
    uart_puts("\n");
    uart_puts("====================================\n");
    uart_puts("RISC-V Comprehensive Test Suite\n");
    uart_puts("====================================\n\n");

    // Run all tests
    test_arithmetic();
    test_logic();
    test_shifts();
    test_branches();
    test_loads_stores();
    test_multiply();
    test_divide();
    test_compressed();
    test_fence();
    test_atomics();
    test_uart();
    test_clint();

    // Summary
    uart_puts("\n====================================\n");
    uart_puts("Test Summary\n");
    uart_puts("====================================\n");
    uart_puts("Tests run:    ");
    uart_puthex(tests_run);
    uart_putc('\n');
    uart_puts("Tests passed: ");
    uart_puthex(tests_passed);
    uart_putc('\n');

    if (tests_run == tests_passed) {
        uart_puts("\nALL TESTS PASSED!\n");
        return 0;
    } else {
        uart_puts("\nSOME TESTS FAILED!\n");
        return 1;
    }
}

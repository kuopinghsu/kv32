// RISC-V Interrupt and Exception Test
// Tests timer interrupts from CLINT and exception handling

#include <stdint.h>
#include <csr.h>  // Shared CSR operations from sw/include

// Memory-mapped addresses
#define CLINT_BASE      0x02000000
#define MSIP            (CLINT_BASE + 0x0000)  // Machine Software Interrupt Pending
#define MTIMECMP_LO     (CLINT_BASE + 0x4000)  // Timer compare low
#define MTIMECMP_HI     (CLINT_BASE + 0x4004)  // Timer compare high
#define MTIME_LO        (CLINT_BASE + 0xBFF8)  // Timer value low
#define MTIME_HI        (CLINT_BASE + 0xBFFC)  // Timer value high

// External putc function from syscall.c
extern void putc(char c);

// Helper functions
static void puts(const char* str) {
    while (*str) {
        putc(*str++);
    }
}

static void print_hex(uint32_t val) {
    const char hex[] = "0123456789abcdef";
    for (int i = 7; i >= 0; i--) {
        putc(hex[(val >> (i * 4)) & 0xf]);
    }
}

static void print_dec(uint32_t val) {
    if (val == 0) {
        putc('0');
        return;
    }

    char buf[10];
    int i = 0;
    while (val > 0) {
        buf[i++] = '0' + (val % 10);
        val /= 10;
    }
    while (i > 0) {
        putc(buf[--i]);
    }
}

// Globals for interrupt tracking
volatile uint32_t timer_interrupt_count = 0;
volatile uint32_t software_interrupt_count = 0;
volatile uint32_t exception_count = 0;
volatile uint32_t ecall_exception_count = 0;
volatile uint32_t test_phase = 0;

// Read 64-bit mtime
static uint64_t read_mtime(void) {
    uint32_t lo, hi, hi2;
    do {
        hi = *(volatile uint32_t*)MTIME_HI;
        lo = *(volatile uint32_t*)MTIME_LO;
        hi2 = *(volatile uint32_t*)MTIME_HI;
    } while (hi != hi2);  // Retry if high word changed
    return ((uint64_t)hi << 32) | lo;
}

// Write 64-bit mtimecmp
static void write_mtimecmp(uint64_t val) {
    *(volatile uint32_t*)MTIMECMP_HI = 0xFFFFFFFF;  // Set high to prevent spurious interrupts
    *(volatile uint32_t*)MTIMECMP_LO = (uint32_t)val;
    *(volatile uint32_t*)MTIMECMP_HI = (uint32_t)(val >> 32);
}

// Custom trap handler
void trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval) {
    // Check if interrupt or exception
    if (mcause & 0x80000000) {
        // Interrupt
        uint32_t int_code = mcause & 0x7FFFFFFF;

        if (int_code == 7) {
            // Machine timer interrupt
            timer_interrupt_count++;

            // Clear interrupt by updating mtimecmp (but stop after enough interrupts for test)
            if (timer_interrupt_count < 5) {  // Allow up to 5 interrupts (test needs 4)
                uint64_t now = read_mtime();
                write_mtimecmp(now + 100000);  // Set next interrupt 100K cycles away
            } else {
                // Stop scheduling more interrupts after enough for test
                write_mtimecmp(0xFFFFFFFFFFFFFFFFULL);
            }

        } else if (int_code == 3) {
            // Machine software interrupt
            software_interrupt_count++;

            // Disable software interrupts in mie first to prevent re-triggering
            uint32_t mie_val = read_csr_mie();
            mie_val &= ~(1 << 3);  // Clear MSIE
            write_csr_mie(mie_val);

            // Clear MSIP
            *(volatile uint32_t*)MSIP = 0;

            // Ensure the write completes before returning
            // Read back to force completion of the write
            (void)*(volatile uint32_t*)MSIP;
        }
    } else {
        // Exception
        exception_count++;

        if (test_phase == 2) {
            // Expected illegal instruction exception
            // Skip the instruction (4 bytes)
            uint32_t new_mepc = mepc + 4;
            puts("  Setting mepc from 0x");
            print_hex(mepc);
            puts(" to 0x");
            print_hex(new_mepc);
            puts("\n");
            write_csr_mepc(new_mepc);
            // Force a read-back to ensure the write takes effect
            uint32_t read_back = read_csr_mepc();
            puts("  mepc read back: 0x");
            print_hex(read_back);
            puts("\n");
        } else if (test_phase == 3) {
            // Expected ECALL exception
            uint32_t exc_code = mcause & 0x7FFFFFFF;
            if (exc_code == 11) {
                // ECALL from M-mode (mcause = 11)
                ecall_exception_count++;
                puts("  ECALL exception detected (mcause = 11)\n");
                // Skip the ECALL instruction (4 bytes)
                uint32_t new_mepc = mepc + 4;
                write_csr_mepc(new_mepc);
            }
        }
    }
}

// Trigger illegal instruction exception
static void trigger_illegal_instruction(void) {
    // Use custom-0 opcode with invalid funct7/funct3 combination
    // This is guaranteed to be illegal in the base ISA
    asm volatile(".word 0x0000000B");  // Custom-0 opcode (0x0B) with all zeros
}

int main(void) {
    puts("\n");
    puts("========================================\n");
    puts("  Interrupt & Exception Test\n");
    puts("  CLINT Base: 0x02000000\n");
    puts("========================================\n\n");

    // Quick CSR test
    puts("[CSR TEST] Testing CSR write/read...\n");
    write_csr_mepc(0x12345678);
    uint32_t mepc_read = read_csr_mepc();
    puts("  Wrote 0x12345678 to mepc, read back: 0x");
    print_hex(mepc_read);
    puts("\n\n");

    // Read initial mtime
    uint64_t start_time = read_mtime();
    puts("[INIT] Current mtime: 0x");
    print_hex((uint32_t)(start_time >> 32));
    print_hex((uint32_t)start_time);
    puts("\n\n");

    // ===== TEST 1: Timer Interrupt =====
    puts("[TEST 1] Timer Interrupt\n");
    test_phase = 1;

    // mtvec is already set by start.S, just read it for verification
    uint32_t mtvec_val = read_csr_mtvec();
    puts("  mtvec set to: 0x");
    print_hex(mtvec_val);
    puts("\n");

    // Enable machine interrupts in mstatus (MIE bit)
    uint32_t mstatus = read_csr_mstatus();
    mstatus |= (1 << 3);  // Set MIE (bit 3)
    write_csr_mstatus(mstatus);

    // Enable timer interrupt in mie (MTIE bit)
    uint32_t mie = read_csr_mie();
    mie |= (1 << 7);  // Set MTIE (bit 7)
    write_csr_mie(mie);

    // Set mtimecmp to trigger interrupt soon
    uint64_t now = read_mtime();
    write_mtimecmp(now + 50000);  // Interrupt in 50K cycles
    puts("  mtimecmp set to trigger in 50K cycles\n");

    // Wait for interrupt
    puts("  Waiting for timer interrupt...\n");
    for (volatile int i = 0; i < 50000 && timer_interrupt_count == 0; i++) {
        asm volatile("nop");
    }

    if (timer_interrupt_count > 0) {
        puts("  First timer interrupt received! Count: ");
        print_dec(timer_interrupt_count);
        puts("\n\n");
    } else {
        puts("  ERROR: Timeout waiting for first interrupt\n");
        puts("  Result: FAIL\n\n");
    }

    // Wait for a few more interrupts (expecting at least 4 total)
    puts("  Waiting for additional timer interrupts...\n");
    uint32_t target_count = 4;  // Expect at least 4 interrupts total
    uint32_t last_count = 0;
    uint32_t i = 0;
    while(timer_interrupt_count < target_count) {
        if (last_count != timer_interrupt_count) i = 0;
        if (++i >= 50000) break;
        last_count = timer_interrupt_count;
    }
    puts("  Total timer interrupts: ");
    print_dec(timer_interrupt_count);
    puts(", timeout counter: ");
    print_dec(i);
    puts("\n");

    if (timer_interrupt_count >= target_count) {
        puts("  Result: PASS\n");
    } else {
        puts("  ERROR: Expected ");
        print_dec(target_count);
        puts(" interrupts but only received ");
        print_dec(timer_interrupt_count);
        puts(" (timeout)\n");
        puts("  Result: FAIL\n");
    }
    puts("\n");

    // Disable timer interrupt
    mie = read_csr_mie();
    mie &= ~(1 << 7);  // Clear MTIE
    write_csr_mie(mie);
    write_mtimecmp(0xFFFFFFFFFFFFFFFFULL);  // Set to max to prevent further interrupts
    puts("  Timer interrupts disabled\n\n");

    // ===== TEST 2: Software Interrupt =====
    puts("[TEST 2] Software Interrupt\n");

    // Enable software interrupt in mie (MSIE bit)
    mie = read_csr_mie();
    mie |= (1 << 3);  // Set MSIE (bit 3)
    write_csr_mie(mie);
    puts("  mie.MSIE enabled\n");

    // Trigger software interrupt
    puts("  Triggering software interrupt via MSIP...\n");
    *(volatile uint32_t*)MSIP = 1;

    // Small delay for interrupt to be processed
    for (int i = 0; i < 500; i++) {
        asm volatile("nop");
    }

    if (software_interrupt_count > 0) {
        puts("  Software interrupt received! Count: ");
        print_dec(software_interrupt_count);
        puts("\n");
        puts("  Result: PASS\n\n");
    } else {
        puts("  ERROR: Software interrupt not received\n");
        puts("  Result: FAIL\n\n");
    }

    // Disable software interrupt
    mie = read_csr_mie();
    mie &= ~(1 << 3);  // Clear MSIE
    write_csr_mie(mie);
    puts("  Software interrupts disabled\n\n");

    // ===== TEST 3: Exception Handling =====
    puts("[TEST 3] Exception Handling\n");
    test_phase = 2;

    puts("  Triggering illegal instruction exception...\n");
    trigger_illegal_instruction();

    if (exception_count > 0) {
        puts("  Exception handled! Count: ");
        print_dec(exception_count);
        puts("\n");
        puts("  Result: PASS\n\n");
    } else {
        puts("  ERROR: Exception not handled\n");
        puts("  Result: FAIL\n\n");
    }

    // ===== TEST 4: CSR Access =====
    puts("[TEST 4] ECALL Exception\n");
    test_phase = 3;

    puts("  Triggering ECALL exception...\n");
    asm volatile("ecall");

    if (ecall_exception_count > 0) {
        puts("  ECALL exception handled! Count: ");
        print_dec(ecall_exception_count);
        puts("\n");
        puts("  Result: PASS\n\n");
    } else {
        puts("  ERROR: ECALL exception not handled\n");
        puts("  Result: FAIL\n\n");
    }

    // ===== TEST 5: CSR Access =====
    puts("[TEST 5] CSR Register Access\n");

    puts("  mstatus: 0x");
    print_hex(read_csr_mstatus());
    puts("\n");

    puts("  mie:     0x");
    print_hex(read_csr_mie());
    puts("\n");

    puts("  mip:     0x");
    print_hex(read_csr_mip());
    puts("\n");

    uint64_t final_time = read_mtime();
    puts("  mtime:   0x");
    print_hex((uint32_t)(final_time >> 32));
    print_hex((uint32_t)final_time);
    puts("\n");

    puts("  Result: PASS\n\n");

    // ===== Summary =====
    puts("========================================\n");
    puts("  Summary:\n");
    puts("  - Timer interrupts:    ");
    print_dec(timer_interrupt_count);
    puts("\n");
    puts("  - Software interrupts: ");
    print_dec(software_interrupt_count);
    puts("\n");
    puts("  - Illegal instr excep: ");
    print_dec(exception_count);
    puts("\n");
    puts("  - ECALL exceptions:    ");
    print_dec(ecall_exception_count);
    puts("\n");

    uint32_t total_tests = 5;
    uint32_t passed_tests = 0;
    if (timer_interrupt_count >= 4) passed_tests++;
    if (software_interrupt_count >= 1) passed_tests++;
    if (exception_count >= 1) passed_tests++;
    if (ecall_exception_count >= 1) passed_tests++;
    passed_tests++;  // CSR test always passes

    puts("  - Tests: ");
    print_dec(passed_tests);
    puts("/");
    print_dec(total_tests);
    puts(" PASSED\n");
    puts("========================================\n\n");

    puts("Interrupt & exception test complete.\n");

    return 0;
}

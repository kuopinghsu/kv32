// Default trap handler for RISC-V exceptions and interrupts
// This is a weak function that can be overridden by user code

#ifdef __cplusplus
extern "C" {
#endif

// External putc function from syscall.c
extern void console_putchar(char c);

static void trap_puts(const char* str) {
    while (*str) {
        console_putchar(*str++);
    }
}

static void trap_print_hex(unsigned int val) {
    const char hex[] = "0123456789abcdef";
    trap_puts("0x");
    for (int i = 7; i >= 0; i--) {
        console_putchar(hex[(val >> (i * 4)) & 0xf]);
    }
}

// Default trap handler (weak function - can be overridden)
__attribute__((weak)) void trap_handler(unsigned int mcause, unsigned int mepc, unsigned int mtval) {
    trap_puts("\n=== TRAP ===\n");
    trap_puts("mcause: ");
    trap_print_hex(mcause);
    trap_puts("\n");
    trap_puts("mepc:   ");
    trap_print_hex(mepc);
    trap_puts("\n");
    trap_puts("mtval:  ");
    trap_print_hex(mtval);
    trap_puts("\n");

    // Check if it's an interrupt (MSB set) or exception
    if (mcause & 0x80000000) {
        trap_puts("Type:   Interrupt\n");
        unsigned int int_code = mcause & 0x7FFFFFFF;
        switch (int_code) {
            case 3:  trap_puts("Source: Machine software interrupt\n"); break;
            case 7:  trap_puts("Source: Machine timer interrupt\n"); break;
            case 11: trap_puts("Source: Machine external interrupt\n"); break;
            default: trap_puts("Source: Unknown interrupt\n"); break;
        }
    } else {
        trap_puts("Type:   Exception\n");
        switch (mcause) {
            case 0:  trap_puts("Cause:  Instruction address misaligned\n"); break;
            case 1:  trap_puts("Cause:  Instruction access fault\n"); break;
            case 2:  trap_puts("Cause:  Illegal instruction\n"); break;
            case 3:  trap_puts("Cause:  Breakpoint\n"); break;
            case 4:  trap_puts("Cause:  Load address misaligned\n"); break;
            case 5:  trap_puts("Cause:  Load access fault\n"); break;
            case 6:  trap_puts("Cause:  Store address misaligned\n"); break;
            case 7:  trap_puts("Cause:  Store access fault\n"); break;
            case 8:  trap_puts("Cause:  Environment call from U-mode\n"); break;
            case 11: trap_puts("Cause:  Environment call from M-mode\n"); break;
            default: trap_puts("Cause:  Unknown exception\n"); break;
        }
    }

    trap_puts("============\n\n");

    // Hang on exceptions (infinite loop)
    if (!(mcause & 0x80000000)) {
        trap_puts("Hanging on exception...\n");
        while (1);
    }
}
#ifdef __cplusplus
}
#endif

// Simple test program - executes NOP and returns
// Used for basic smoke testing of the CPU core
//
// This program:
// 1. Executes a NOP instruction in main()
// 2. Returns from main
// 3. start.S writes to exit address (0xFFFFFFF0)
// 4. Enters infinite hang loop
//
// Expected behavior: Simulation detects stuck PC after ~20 cycles
// and terminates with timeout (this is normal operation)

#include <stdint.h>

// Minimal trap handler (required by start.S)
void trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval) {
    // Do nothing - just return
    (void)mcause;
    (void)mepc;
    (void)mtval;
}

// Main function - executes a NOP instruction and returns
int main(void) {
    // memory read/write test
    volatile int n1 = 3;
    volatile short n2 = 4;
    volatile char n3 = 5;

    n1++; n2++; n3++;

    // Execute a NOP instruction
    __asm__ volatile ("nop");

    // Return 0 to signal success
    return 0;
}

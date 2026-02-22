# Software Include Directory

This directory contains shared header files used by all test programs.

## Headers

### csr.h
Control and Status Register (CSR) operations for RISC-V.

**Includes:**
- Read/write functions for all standard machine-mode CSRs
- Helper functions for 64-bit counter access (with wraparound handling)
- CSR bit manipulation operations (set/clear)
- Bit definitions and constants for mstatus, mie, mip, mcause

**Usage:**
```c
#include <csr.h>

// Read/write CSRs
uint32_t status = read_csr_mstatus();
write_csr_mstatus(status | MSTATUS_MIE);

// Bit manipulation
csr_set_mie(MIE_MTIE | MIE_MSIE);    // Enable interrupts
csr_clear_mie(MIE_MEIE);             // Disable interrupt

// 64-bit counters (with wraparound handling)
uint64_t cycles = read_csr_cycle64();
uint64_t instret = read_csr_instret64();

// Check interrupt cause
uint32_t cause = read_csr_mcause();
if (cause & MCAUSE_INTERRUPT) {
    uint32_t code = cause & MCAUSE_CODE_MASK;
    if (code == INTERRUPT_TIMER) {
        // Handle timer interrupt
    }
}
```

## Adding New Headers

When adding new shared headers:
1. Place the header file in `sw/include/`
2. Use `#include <header.h>` in test programs
3. The Makefile automatically adds `-Isw/include` to compilation flags
4. Document the header in this README

## Build System Integration

The include path is automatically added by the Makefile:
```makefile
CFLAGS += -I$(SW_DIR)/include
```

All test programs can include headers with:
```c
#include <csr.h>      // Shared headers from sw/include/
#include "../common/file.h"  // Common files (if needed)
```

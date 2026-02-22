# Software Tests

This directory contains test programs for the RISC-V processor.

> **Verification**: Tests can be verified at both instruction-level (Spike trace comparison) and memory transaction-level. For memory transaction verification, see [../docs/memory_trace_analysis.md](../docs/memory_trace_analysis.md).

## Directory Structure

```
sw/
├── common/           # Shared startup code and linker scripts
│   ├── start.S       # Assembly startup and reset vector
│   ├── trap.c        # Default trap handler (overridable)
│   ├── syscall.c     # System call implementations (_write, _sbrk, etc.)
│   ├── printf.c      # Full printf/sprintf/snprintf implementation
│   ├── putc.c        # Character output (putc, putchar, fputc)
│   ├── puts.c        # String output (puts, fputs)
│   └── link.ld       # Linker script
├── include/          # Shared headers (CSR operations)
├── simple/           # Simple smoke test (476B)
├── hello/            # Console output test (68KB, printf)
├── uart/             # UART TX/RX hardware test (6KB)
├── interrupt/        # Timer interrupt test (4.2KB)
├── full/             # Comprehensive test suite (4.1KB)
├── printf/           # Printf test suite (~50 test cases)
├── cpp/              # C++ integration test
├── algo/             # Algorithm test (QuickSort, FFT, Matrix ops)
├── dhry/             # Dhrystone benchmark (8KB)
├── coremark/         # CoreMark benchmark
├── embench/          # Embench IoT suite
├── mibench/          # MiBench suite
└── whetstone/        # Whetstone benchmark
```

## RTOS Integration

### FreeRTOS Tests

**Location**: `../rtos/freertos/samples/`

The project includes FreeRTOS V11.2.0 integration with RISC-V support. FreeRTOS tests are located in the `rtos/freertos/samples/` directory, separate from the standard software tests.

### Zephyr RTOS Port

**Location**: `../rtos/zephyr/`

Complete Zephyr RTOS port with:
- Out-of-tree SoC definition (RV32IM)
- Board support (kcore_board)
- Two console drivers:
  - Magic address (0xFFFFFFF4) - Fast simulation
  - UART (0x10000000) - Hardware accurate
- Sample application: Hello World with k_msleep()

See [../rtos/zephyr/README.md](../rtos/zephyr/README.md) for build instructions.

### FreeRTOS Configuration
- **Tick Rate**: 1 kHz (1 ms period)
- **CPU Clock**: 50 MHz
- **Heap**: 64KB using heap_3 (malloc/free)
- **Memory**: 2MB RAM (8KB main stack, 2KB IRQ stack)
- **Timer**: CLINT hardware timer (mtime/mtimecmp @ 0x02000000)

### Available FreeRTOS Tests

**Simple Test** (`../rtos/freertos/samples/simple.c`):
- Two tasks with priority 1
- Cooperative scheduling using `taskYIELD()`
- Busy-wait loops (500K cycles) instead of `vTaskDelay()`
- Demonstrates basic task creation and context switching
- **Status**: ✅ PASSING (after ecall implementation)

**Performance Test** (`../rtos/freertos/samples/perf_test.c`):
- Performance validation test
- Task switching overhead measurement
- System stability verification

### Building FreeRTOS Tests
```bash
# Build FreeRTOS test
make freertos-simple              # Build simple test

# Run on RTL simulation
make freertos-rtl-simple          # Run without waveform
make freertos-rtl-simple WAVE=fst # Run with FST waveform
make freertos-rtl-simple TRACE=1  # Run with instruction trace

# Debug options
make freertos-rtl-simple MEMTRACE=1    # Enable memory trace
make freertos-rtl-simple MAX_CYCLES=0  # Unlimited cycles
```

### Status & Known Limitations
✅ **Simple Example Working**: The FreeRTOS simple example now passes successfully after proper ecall/exception handling implementation.

⚠️ **Timer Interrupt Issue**: `vTaskDelay()` and `vTaskDelayUntil()` cause exceptions. Current tests use busy-wait loops + `taskYIELD()` for cooperative scheduling.

⚠️ **Spike Incompatibility**: FreeRTOS tests require CLINT timer peripheral, not available in Spike simulator. Only RTL simulation supported.

### FreeRTOS API Samples
```c
// Task creation (dynamic allocation)
xTaskCreate(vTask1, "Task1", 256, NULL, 1, NULL);

// Cooperative yield
taskYIELD();

// Idle hook (called when no tasks ready)
void vApplicationIdleHook(void) {
    // User code here
}

// Tick hook (called every 1ms tick)
void vApplicationTickHook(void) {
    // User code here
}
```

For detailed FreeRTOS configuration and technical details, see [../PROJECT_STATUS.md - FreeRTOS Integration](../PROJECT_STATUS.md#freertos-integration-january-1-2026).

## Common Files

### `common/start.S`
Assembly startup code providing:
- Reset vector and initialization
- Stack pointer setup
- BSS section clearing
- Trap entry point for exceptions/interrupts
- Exit mechanism via `tohost` and magic address (0xFFFF_FFF0)
- Global pointer (gp) initialization

### `common/trap.c`
Default trap handler providing:
- **Weak function** - can be overridden by user-defined trap_handler
- Detailed trap information output via UART
- Exception type identification (illegal instruction, misaligned access, etc.)
- Interrupt type identification (timer, software, external)
- Automatic hang on exceptions (infinite loop)
- Returns on interrupts (allows interrupt handling to continue)

**Usage**: Simply define your own `trap_handler()` function in your test code to override the default behavior.

### `common/syscall.c`
System call implementations providing:
- `_write()`: Output to magic address (0xFFFFFFF4)
- `_sbrk()`: Heap management (malloc support)
- `_exit()`: Program termination via magic address (0xFFFFFFF0)
- `_fflush()`: No-op (wrapped by linker)
- Other newlib stubs

### `common/printf.c`
Full printf implementation (~632 lines):
- **Functions**: printf(), vprintf(), sprintf(), snprintf(), vsprintf()
- **Format specifiers**: %c, %s, %d, %i, %u, %x, %X, %o, %p, %f
- **Length modifiers**: hh, h, l, ll, z, t
- **Flags**: -, +, 0, space, #
- **Width and precision**: %10.2f
- **Compile option**: `-DPRINTF_DISABLE_FLOAT` (saves ~6% code)
- **C++ compatible**: extern "C" guards

### `common/putc.c`
Character output functions:
- `putc(int c, FILE *stream)`: Output character
- `putchar(int c)`: Output to stdout
- `fputc(int c, FILE *stream)`: Same as putc
- All call `_write(1, &ch, 1)` internally

### `common/puts.c`
String output functions:
- `puts(const char *s)`: Output string with newline
- `fputs(const char *s, FILE *stream)`: Output string without newline
- Uses `_write()` for efficient output

**Usage Example**:
```c
#include <stdio.h>

int main(void) {
    printf("Hello, %s!\n", "World");
    puts("Second line");
    putchar('A');
    return 0;
}
```

### `common/link.ld`
Linker script defining:
- Memory regions: RAM at 0x8000_0000 (2MB)
- Section layout: .text, .rodata, .data, .bss
- Stack location: Top of RAM (0x8004_0000)
- `tohost`/`fromhost` symbols for RISC-V test compliance
- Heap support for C++ (if needed)

## Test Programs

### Simple Test (`simple/`)

**File**: `simple.c`

**Purpose**: Minimal smoke test for quick validation

**Test Coverage**:
- Basic instruction execution
- Memory load/store operations (byte, halfword, word)
- Register operations
- Function call/return
- Program exit via `tohost`

**Expected Results**:
- Exit code: 0 (success)
- Instructions executed: ~40
- Execution cycles: ~350-400
- CPI: ~8-9

**Usage**:
```bash
make verify-simple    # Full verification
make rtl-simple       # RTL simulation only
make sim-simple       # Spike simulation only
make sw-simple        # Compile only
```

### Hello Test (`hello/`)

**File**: `hello.c`

**Purpose**: Console output test using magic address

**Test Coverage**:
- Magic console address (0xFFFFFFF4) writes
- String output functionality
- Character transmission
- Simple console I/O without UART setup

**Features**:
- Uses magic console address for fast, direct output
- No UART register setup or polling required
- Demonstrates simplest way to output debug messages
- Good example for trap handlers and minimal test code

**Expected Results**:
- Exit code: 0 (success)
- Console output: "Hello, World!"
- Console output: "UART console output test successful."
- Instructions executed: ~100-150
- Execution cycles: ~500-700

**Usage**:
```bash
make verify-hello     # Full verification
make rtl-hello        # RTL simulation only
make sim-hello        # Spike simulation only
make sw-hello         # Compile only
```

**Features**:
- Demonstrates UART communication
- Tests memory-mapped I/O
- Validates console output functionality
- Simple example for peripheral access

### UART Hardware Test (`uart/`)

**File**: `uart.c`

**Purpose**: Full-duplex UART peripheral validation with TX and RX

**Test Coverage** (7 tests total):

1. **Status Register**: Read and verify all status bits
   - TX BUSY, TX FULL, RX READY, RX OVERRUN flags

2. **Character Transmission**: Send alphabet A-Z

3. **Numeric Output**: Send digits 0-9

4. **Special Characters**: Send symbols !@#$%^&*()

5. **Multi-line Output**: Test newline handling

6. **RX Echo Test**: Bidirectional UART communication
   - Waits for input from testbench
   - Receives characters (testbench sends "ABC\n")
   - Echoes each character back
   - Validates RX FIFO and status flags

7. **Status Monitoring**: Report TX/RX statistics
   - Status check count, busy waits
   - TX and RX character counts

**Hardware Configuration**:
- Base Address: 0x10000000
- Baud Rate: 12.5 Mbaud (BAUD_DIV=4, 50MHz / 4 = 12.5Mbps)
- FIFO Depth: 16 entries (TX and RX)
- Status Register: bit[0]=TX busy, bit[1]=TX full, bit[2]=RX ready, bit[3]=RX overrun

**Expected Results**:
- Exit code: 1 (normal termination)
- All 7 tests pass
- 4 characters received and echoed (A, B, C, newline)
- Instructions executed: ~18,000-20,000
- Execution cycles: ~140,000

**Usage**:
```bash
make verify-uart     # Full verification
make rtl-uart        # RTL simulation only
make sw-uart         # Compile only
```

**Features**:
- Direct UART hardware register access
- Full-duplex TX/RX demonstration
- FIFO status monitoring
- Echo test with testbench stimulus
- Validates bidirectional UART communication

### Printf Test Suite (`printf/`)

**File**: `printf.c`

**Purpose**: Comprehensive printf/sprintf/snprintf implementation test

**Test Coverage** (~50 test cases):

1. **Basic Format Specifiers**
   - Characters: %c
   - Strings: %s
   - Signed integers: %d, %i
   - Unsigned integers: %u
   - Hexadecimal: %x, %X (lowercase/uppercase)
   - Octal: %o
   - Pointers: %p

2. **Length Modifiers**
   - char: %hhd, %hhu
   - short: %hd, %hu
   - long: %ld, %lu
   - long long: %lld, %llu

3. **Floating Point** (if PRINTF_DISABLE_FLOAT not defined)
   - %f: Fixed-point notation
   - Precision control
   - Special values: infinity, NaN

4. **Format Flags**
   - Left justify: %-
   - Force sign: %+
   - Space for sign: %
   - Zero padding: %0
   - Alternate form: %#

5. **Width and Precision**
   - Minimum width: %10d
   - Precision: %.5f
   - Combined: %10.2f

6. **Edge Cases**
   - NULL pointers
   - Empty strings
   - Zero values
   - Negative values
   - Buffer truncation (snprintf)

**Features**:
- Full printf/sprintf/snprintf implementation in `common/printf.c`
- Compile option: `-DPRINTF_DISABLE_FLOAT` (saves ~6% code size)
- Uses `_write()` for output (magic address 0xFFFFFFF4)
- C++ compatible (extern "C" guards)

**Expected Results**:
- Exit code: 0 (all tests pass)
- ~50 lines of formatted output
- Instructions executed: ~50,000-80,000

**Usage**:
```bash
make rtl-printf              # Run with float support
make rtl-printf CFLAGS=-DPRINTF_DISABLE_FLOAT  # Integer-only
make sw-printf               # Compile only
```

### C++ Integration Test (`cpp/`)

**File**: `cpp_test.cpp`

**Purpose**: Validate C++ support and C/C++ interoperability

**Test Coverage**:

1. **C++ Language Features**
   - Classes with constructors/destructors
   - Member functions (public/private)
   - Static member variables
   - Operator overloading
   - Global constructors (called before main)
   - Static local objects with lazy initialization

2. **C Library Integration**
   - printf() with C++ strings
   - puts() output
   - putchar() character output
   - Demonstrates extern "C" linkage

3. **Object Lifecycle**
   - Constructor execution order tracking
   - Destructor execution (on exit)
   - Static initialization tracking

**Features**:
- Demonstrates C++ on bare metal RISC-V
- Tests GCC C++ runtime (_cxa_atexit, etc.)
- Validates newlib C++ support
- Shows how to use printf/puts/putc from C++

**Expected Results**:
- Exit code: 0 (success)
- Global constructor output
- Class construction/destruction messages
- Instructions executed: ~20,000-30,000

**Usage**:
```bash
make rtl-cpp                 # RTL simulation
make sw-cpp                  # Compile only
```

**Important**: C library functions (printf, puts, putc) are declared with extern "C" in their implementations (`common/*.c`), enabling seamless C/C++ interoperability.

### Algorithm Test Suite (`algo/`)

**File**: `algo.c`

**Purpose**: Complex algorithm demonstration across all data types

**Test Coverage**:

1. **QuickSort Algorithm**
   - Integer array sorting (100 elements)
   - Float array sorting (50 elements)
   - Partition/swap operations
   - Validation with checksums

2. **FFT (Fast Fourier Transform)**
   - Radix-2 decimation-in-time algorithm
   - Complex number arithmetic (double precision)
   - 16-point FFT computation
   - Bit reversal permutation
   - Magnitude calculation

3. **Matrix Operations**
   - 4x4 double precision matrices
   - Matrix multiplication
   - Matrix transpose
   - Result validation

4. **Statistical Functions**
   - Mean calculation
   - Variance and standard deviation
   - 100-element dataset

5. **Data Type Operations**
   - char, short, int, long long
   - float, double precision
   - Type conversions
   - Overflow handling

**Features**:
- Comprehensive use of math library (-lm)
- Uses sqrt(), cos(), sin() functions
- Complex number struct implementation
- Factorial calculation (long long)
- Demonstrates all RISC-V data types

**Expected Results**:
- Exit code: 0 (all tests pass)
- ~1.8M cycles
- ~342K instructions retired
- CPI ~5.3

**Usage**:
```bash
make rtl-algo                # RTL simulation
make sim-algo                # Software simulator
make sw-algo                 # Compile only
```

**Note**: Requires math library (-lm) for sqrt, cos, sin functions.

### Full Test Suite (`full/`)

**File**: `full.c`

**Purpose**: Comprehensive ISA and peripheral validation

**Test Coverage** (11 tests total):

1. **RV32I Base Instructions**
   - Arithmetic: ADD, SUB, ADDI (with overflow)
   - Logic: AND, OR, XOR, ANDI, ORI, XORI
   - Shifts: SLL, SRL, SRA, SLLI, SRLI, SRAI
   - Comparisons: SLT, SLTU, SLTI, SLTIU

2. **Control Flow**
   - Branches: BEQ, BNE, BLT, BGE, BLTU, BGEU
   - Jumps: JAL, JALR
   - Function calls and returns

3. **Memory Operations**
   - Load: LB, LH, LW, LBU, LHU
   - Store: SB, SH, SW
   - Aligned and unaligned access tests
   - Byte order verification

4. **RV32M Extension**
   - Multiply: MUL, MULH, MULHSU, MULHU
   - Divide: DIV, DIVU
   - Remainder: REM, REMU
   - Edge cases: division by zero, overflow

5. **Memory Ordering**
   - FENCE: Memory ordering instruction
   - FENCE variants: fence, fence rw,rw, fence w,w
   - Memory consistency validation

6. **Peripherals**
   - UART: Character transmission
   - CLINT: Timer interrupt generation and handling

7. **System Features**
   - CSR operations: CSRRW, CSRRS, CSRRC
   - Exception handling
   - Interrupt handling (timer)

**Expected Results**:
- Exit code: 0 (all tests pass)
- Instructions executed: ~5000-10000
- Multiple UART outputs during execution
- Timer interrupt triggers

**Usage**:
```bash
make verify-full      # Full verification
make rtl-full         # RTL simulation only
make sim-full         # Spike simulation only
make sw-full          # Compile only
```

### CoreMark Benchmark (`coremark/`)

**File**: `coremark.c`

**Purpose**: Industry-standard embedded performance benchmark

**Test Coverage**:
- List processing (find and sort)
- Matrix manipulation
- State machine validation
- CRC calculation

**Features**:
- Simplified baremetal adaptation
- No dynamic memory allocation
- Statically allocated data structures
- Reduced iterations for simulation
- CSR-based timing

**Expected Results**:
- Iterations: 10
- Cycles per iteration: ~50,000-100,000
- Checksums for validation
- Performance estimates

**Usage**:
```bash
make rtl-coremark MAX_CYCLES=0    # Run benchmark (unlimited cycles)
make sw-coremark                  # Compile only
```

**Note**: This is a simplified version for testing. Official CoreMark scores require full EEMBC validation suite.

### Embench IoT Suite (`embench/`)

**File**: `embench.c`

**Purpose**: Modern embedded benchmark suite replacing Dhrystone

**Included Benchmarks**:
- **crc32**: CRC-32 calculation
- **cubic**: Cubic equation solver
- **matmult**: Integer matrix multiplication
- **neural**: Neural network forward pass

**Features**:
- Realistic embedded workloads
- No file I/O or dynamic allocation
- Individual test timing
- Checksum validation

**Expected Results**:
- Per-test cycle counts
- Validation checksums
- Performance relative to baseline

**Usage**:
```bash
make rtl-embench MAX_CYCLES=0     # Run suite (unlimited cycles)
make sw-embench                   # Compile only
```

### MiBench Suite (`mibench/`)

**File**: `mibench.c`

**Purpose**: Commercially representative embedded benchmarks

**Included Benchmarks**:
- **qsort**: Quicksort algorithm (100 elements)
- **dijkstra**: Shortest path algorithm (16 nodes)
- **blowfish**: Encryption (64 bytes)
- **fft**: Fast Fourier Transform (32-point, integer)

**Features**:
- Representative of real embedded applications
- Multiple algorithm categories
- Validation via checksums
- Per-test performance metrics

**Expected Results**:
- Per-benchmark cycle counts
- Validation checksums
- Combined performance metrics

**Usage**:
```bash
make rtl-mibench MAX_CYCLES=0     # Run suite (unlimited cycles)
make sw-mibench                   # Compile only
```

### Whetstone Benchmark (`whetstone/`)

**File**: `whetstone.c`

**Purpose**: Classic synthetic benchmark (integer-only adaptation)

**Test Coverage**:
- Fixed-point arithmetic operations
- Array processing
- Mathematical functions (sin, cos, exp, atan)
- Conditional branches
- Loop overhead

**Features**:
- **Integer-only**: Uses fixed-point (scaled by 1000) instead of floating-point
- Simplified math function approximations
- Not representative of true floating-point performance
- Reduced iterations for simulation

**Expected Results**:
- Iterations: 10
- Cycles per iteration: ~20,000-40,000
- Performance metrics

**Usage**:
```bash
make rtl-whetstone MAX_CYCLES=0   # Run benchmark (unlimited cycles)
make sw-whetstone                 # Compile only
```

**Important**: This is NOT a true Whetstone benchmark due to integer-only implementation. For true floating-point benchmarking, F/D extensions are required.

## Adding New Tests

### Single-File Test

Create `sw/mytest.c`:
```c
#include <stdint.h>

int main(void) {
    // Your test code here
    return 0;  // Exit code
}
```

Run with:
```bash
make verify-mytest
```

### Multi-File Test

Create `sw/mytest/` directory:
```
sw/mytest/
├── mytest.c      # Main test file
├── helper.c      # Additional source files
└── helper.h      # Header files
```

Run with:
```bash
make verify-mytest
```

The build system automatically:
- Includes all `.c` files in the test directory
- Links with `common/start.S`
- Uses `common/link.ld` for memory layout
- Generates `.elf`, `.dump`, `.dis`, and `.map` files

## Build Artifacts

When you build a test, the following files are generated in `build/`:

- `test.elf` - ELF executable with debug symbols
- `test.dump` - Full disassembly listing
- `test.dis` - Disassembly with source code interleaved

## Memory Map

```
0x8000_0000 - 0x801F_FFFF : RAM (2MB)
  0x8000_0000 - 0x8000_XXXX : .text (code)
  0x8000_XXXX - 0x8000_YYYY : .rodata (constants)
  0x8000_YYYY - 0x8000_ZZZZ : .data (initialized data)
  0x8000_ZZZZ - 0x8003_FFFC : .bss (uninitialized data)
  0x8003_FFFC - 0x8004_0000 : Stack (grows down)

0x0200_0000 - 0x0200_FFFF : CLINT (timer)
0x1000_0000 - 0x1000_0FFF : UART
0xFFFF_FFF0               : Magic exit address
```

## Programming Guidelines

### Exit Codes

Use standard return values from `main()`:
```c
int main(void) {
    // Test code...
    return 0;  // Success
    // return 1;  // Failure
}
```

The startup code (`start.S`) converts this to proper `tohost` format.

### UART Output and Input

The UART peripheral supports full-duplex communication at 12.5 Mbaud with 16-entry FIFOs.

> **⚠️ Baud Rate Limitation**: Maximum baud rate is CLK_FREQ / 4 due to RX path requirements.
> At 50 MHz clock, maximum is 12.5 Mbaud (BAUD_DIV=4). Lower BAUD_DIV causes RX corruption.

**TX (Transmit)**:
```c
#define UART_BASE    0x10000000
#define UART_TX      (*(volatile uint32_t*)(UART_BASE + 0x00))
#define UART_STATUS  (*(volatile uint32_t*)(UART_BASE + 0x04))

// Simple output (without status check)
void putchar(char c) {
    UART_TX = c;
}

// Output with busy wait
void uart_putc(char c) {
    while (UART_STATUS & 0x01);  // Wait if TX busy
    UART_TX = c;
}
```

**RX (Receive)**:
```c
#define UART_RX      (*(volatile uint32_t*)(UART_BASE + 0x00))
#define UART_STATUS  (*(volatile uint32_t*)(UART_BASE + 0x04))

// Poll for character (returns -1 if no data)
int uart_getc(void) {
    if (UART_STATUS & 0x04) {  // Check RX ready flag
        return (int)(UART_RX & 0xFF);
    }
    return -1;
}

// Wait for character
char uart_getchar(void) {
    int c;
    while ((c = uart_getc()) < 0);
    return (char)c;
}
```

**Status Register (0x04)**:
- Bit[0]: TX busy (1 = transmitting)
- Bit[1]: TX FIFO full (1 = cannot write)
- Bit[2]: RX ready (1 = data available)
- Bit[3]: RX overrun (1 = FIFO overflow, data lost)

**Baud Rate**: 12.5 Mbaud (CLK=50MHz, BAUD_DIV=4)

### Timer Access

```c
#define CLINT_BASE    0x02000000
#define MTIME         (*(volatile uint64_t*)(CLINT_BASE + 0xBFF8))
#define MTIMECMP      (*(volatile uint64_t*)(CLINT_BASE + 0x4000))

// Read current time
uint64_t time = MTIME;

// Set timer interrupt
MTIMECMP = MTIME + 1000;  // Interrupt in 1000 cycles
```

### CSR Access

Use inline assembly or compiler intrinsics:
```c
static inline uint32_t read_csr(uint32_t csr) {
    uint32_t val;
    asm volatile ("csrr %0, %1" : "=r"(val) : "i"(csr));
    return val;
}

static inline void write_csr(uint32_t csr, uint32_t val) {
    asm volatile ("csrw %0, %1" :: "i"(csr), "r"(val));
}
```

## Compilation Flags

Tests are compiled with:
- **Architecture**: `-march=rv32ima_zicsr` (RV32I + M extension + A + Zicsr)
- **ABI**: `-mabi=ilp32`
- **Optimization**: `-O2`
- **Warnings**: `-Wall -Werror`
- **Freestanding**: `-ffreestanding -nostdlib -nostartfiles`

## Debugging

### View Disassembly
```bash
cat build/test.dump | less
cat build/test.dis | less    # With source code
```

### Check Binary Size
```bash
make sw
# Shows text, data, bss sections
```

### Trace Execution
```bash
make rtl          # Generates build/rtl_trace.txt
make sim          # Generates build/sim_trace.txt
```

### Compare with Reference
```bash
make compare      # Compares RTL vs Spike traces
```

## Limitations

- No standard C library (freestanding environment)
- No dynamic memory allocation (unless you implement malloc)
- No file I/O
- Limited stack size (~2MB minus code/data)
- Single-threaded execution only

## References

- RISC-V ISA Specification: https://riscv.org/specifications/
- RISC-V Assembly Programmer's Manual: https://github.com/riscv-non-isa/riscv-asm-manual
- Linker script documentation: GNU LD manual

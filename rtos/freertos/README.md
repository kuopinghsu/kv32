# FreeRTOS Port for kcore

Complete FreeRTOS V11.2.0 port for the RV32IM kcore processor with full RISC-V support.

## Overview

This port provides:
- **FreeRTOS Kernel V11.2.0**: Latest stable version with all core features
- **RISC-V Support**: Native RV32IM port (machine mode only)
- **Task Scheduling**: Preemptive priority-based scheduler
- **Synchronization**: Semaphores, mutexes, queues, event groups
- **Memory Management**: heap_3 (malloc/free wrapper)
- **Timer Support**: Software timers using CLINT hardware timer
- **Sample Applications**: Simple task demo and performance test

## Directory Structure

```
rtos/freertos/
├── include/               # FreeRTOS headers and configuration
├── portable/             # RISC-V port implementation
│   └── RISC-V/
│       └── chip_specific_extensions/RV32I_CLINT_no_extensions/
├── sys/                  # System files (startup, linker, syscalls)
├── samples/              # Sample applications
├── tasks.c               # Core task scheduler
├── queue.c               # Queue implementation
├── timers.c              # Software timers
├── event_groups.c        # Event group implementation
├── stream_buffer.c       # Stream buffer implementation
└── list.c                # Linked list utilities
```

## Hardware Configuration

### System Specifications
- **CPU**: RV32IM (32-bit RISC-V with multiply/divide)
- **RAM**: 2MB @ 0x80000000
- **ROM**: Code in RAM (no separate ROM)
- **Timer**: CLINT machine timer @ 0x02000000
- **Console**: Magic address write @ 0x40000000
- **Clock**: 50 MHz system clock

### Memory Layout

```
0x80000000  +------------------------+
            |  .text (code)          |
            |  .rodata (constants)   |
            |  .data (initialized)   |
            |  .sdata (small data)   |
            |  .bss (zero init)      |
            +------------------------+
            |  Stack (8KB)           | ← Main stack
            +------------------------+
            |  IRQ Stack (2KB)       | ← Interrupt stack
            +------------------------+
            |  Heap (64KB default)   | ← FreeRTOS heap
            +------------------------+
0x8003FFFF  |  (end of RAM)          |
            +------------------------+
```

## Configuration

Configuration is in [include/FreeRTOSConfig.h](include/FreeRTOSConfig.h):

### Key Settings

```c
// Clock and Timing
#define configCPU_CLOCK_HZ              50000000UL    // 50 MHz
#define configTICK_RATE_HZ              1000          // 1ms tick

// Memory
#define configTOTAL_HEAP_SIZE           (64 * 1024)   // 64KB heap
#define configMINIMAL_STACK_SIZE        128           // 512 bytes minimum

// Scheduler
#define configUSE_PREEMPTION            1             // Preemptive scheduling
#define configMAX_PRIORITIES            8             // 8 priority levels
#define configIDLE_SHOULD_YIELD         0             // Idle task behavior

// Features
#define configUSE_MUTEXES               1             // Mutex support
#define configUSE_RECURSIVE_MUTEXES     1             // Recursive mutex
#define configUSE_COUNTING_SEMAPHORES   1             // Counting semaphores
#define configUSE_TIMERS                1             // Software timers
#define configUSE_TICK_HOOK             0             // Tick hook (disabled)
#define configCHECK_FOR_STACK_OVERFLOW  0             // Stack overflow check

// Memory allocation
#define configSUPPORT_STATIC_ALLOCATION 0             // No static allocation
#define configSUPPORT_DYNAMIC_ALLOCATION 1            // Use heap_3 (malloc)
```

### Customization

To modify configuration:
1. Edit `include/FreeRTOSConfig.h`
2. Adjust heap size: Change `configTOTAL_HEAP_SIZE`
3. Adjust tick rate: Change `configTICK_RATE_HZ` (1000 Hz = 1ms)
4. Adjust priorities: Change `configMAX_PRIORITIES`
5. Enable/disable features: Toggle `configUSE_*` options

## Building Applications

### Using Make (Recommended)

```bash
# Build simple example
make freertos-simple

# Build and run in RTL simulation
make freertos-rtl-simple

# Build performance test
make freertos-perf

# Run performance test
make freertos-rtl-perf

# Clean build
make freertos-clean
```

### Build Targets

The Makefile provides these targets:
- `freertos-<example>`: Build example (outputs `build/test.elf` and `build/test.bin`)
- `freertos-rtl-<example>`: Build and run example in Verilator RTL simulation
- `freertos-clean`: Clean FreeRTOS build artifacts

### Manual Build

```bash
# Compile FreeRTOS sources
riscv-none-elf-gcc -march=rv32im -mabi=ilp32 -O2 -g \
    -Irtos/freertos/include \
    -Irtos/freertos/portable/RISC-V \
    -Irtos/freertos/portable/RISC-V/chip_specific_extensions/RV32I_CLINT_no_extensions \
    -c rtos/freertos/tasks.c \
    -c rtos/freertos/queue.c \
    [... other sources ...]

# Compile your application
riscv-none-elf-gcc -march=rv32im -mabi=ilp32 -O2 -g \
    [same includes] \
    -c your_app.c

# Link
riscv-none-elf-gcc -march=rv32im -mabi=ilp32 \
    -Trtos/freertos/sys/freertos_link.ld \
    -nostartfiles \
    *.o -o app.elf

# ELF file is used directly by the simulator (no binary conversion needed)
```

## Sample Applications

### 1. Simple Task Demo

File: [samples/simple.c](samples/simple.c)

**Description**: Basic demonstration of FreeRTOS task creation and scheduling.

**Features**:
- Creates 2 tasks with different priorities
- Tasks print messages and yield to each other
- Demonstrates task creation and deletion
- No timer delays (uses busy-wait for simplicity)

**Expected Output**:
```
FreeRTOS Simple Test Starting...
Creating tasks...
Starting scheduler...
Task 1: 0
Task 2: 0
Task 1: 1
Task 2: 1
Task 1: 2
Task 2: 2
...
Task 1: Completed
Task 2: Completed
All tasks completed. Exiting...
```

**Usage**:
```bash
make freertos-rtl-simple
```

### 2. Performance Test

File: [samples/perf.c](samples/perf.c)

**Description**: Stress test with multiple tasks, queues, and semaphores.

**Features**:
- Multiple producer/consumer tasks
- Queue communication between tasks
- Semaphore synchronization
- Memory allocation testing
- Performance measurement

**Usage**:
```bash
make freertos-rtl-perf
```

## Porting Details

### Critical Files Modified/Created

#### 1. Startup Code (`sys/freertos_start.S`)

**Purpose**: Reset vector and early initialization.

**Key operations**:
- Disable interrupts initially
- Initialize global pointer (GP)
- Set up stack pointer (SP)
- Clear BSS section
- Configure trap vector for FreeRTOS handler
- Enable timer and software interrupts (MIE.MTIE + MIE.MSIE)
- Jump to main()

**Important**: This replaces the default RISC-V startup. The `_start` symbol is the entry point.

#### 2. Linker Script (`sys/freertos_link.ld`)

**Purpose**: Memory layout for FreeRTOS.

**Key sections**:
- `.text`, `.rodata`: Code and constants
- `.data`, `.sdata`: Initialized data (with global pointer)
- `.bss`: Zero-initialized data
- `.stack`: Main thread stack (8KB)
- `.irq_stack`: Interrupt stack (2KB)
- `.heap`: FreeRTOS heap (remaining RAM up to 64KB)

**Symbols**:
- `__global_pointer$`: For GP register initialization
- `__stack_top`: Stack pointer initial value
- `__bss_start`, `__bss_end`: BSS clearing
- `__heap_start`, `__heap_end`: Heap management

#### 3. Syscalls (`sys/freertos_syscall.c`)

**Purpose**: Newlib system call implementations.

**Implemented calls**:
- `_sbrk()`: Heap allocation for malloc/free
- `_write()`: Console output to magic address (0x40000000)
- `_exit()`: Program termination

**Stubs** (not implemented):
- `_close()`, `_fstat()`, `_isatty()`, `_lseek()`, `_read()`: Return errors
- These are sufficient for printf() and basic I/O

#### 4. Configuration (`include/FreeRTOSConfig.h`)

**Purpose**: FreeRTOS port configuration.

**Key configurations**:
- Tick rate: 1000 Hz (1ms per tick)
- Heap: heap_3 (uses malloc/free from newlib)
- Stack: Minimum 128 words (512 bytes)
- Preemption: Enabled
- Priorities: 8 levels (0 = lowest, 7 = highest)

#### 5. Port Layer (`portable/RISC-V/port.c`)

**Purpose**: Context switching and task management.

**Key functions**:
- `pxPortInitialiseStack()`: Initialize task stack frame
- `xPortStartScheduler()`: Start the scheduler
- Context switch handling (in assembly)

**Note**: This is from FreeRTOS's official RISC-V port with minimal modifications.

#### 6. Interrupt Handler (`portable/.../freertos_risc_v_trap_handler.c`)

**Purpose**: Handle timer interrupts and exceptions.

**Key operations**:
- Saves all registers on interrupt entry
- Checks `mcause` to determine interrupt type
- Calls `xTaskIncrementTick()` for timer interrupts
- Performs context switch if needed
- Restores registers and returns from interrupt

### RISC-V Port Specifics

#### Machine Mode Only
- FreeRTOS runs in RISC-V machine mode (M-mode)
- No supervisor or user mode support
- Direct hardware access (no MMU)

#### Timer Setup
- Uses CLINT machine timer (mtime/mtimecmp)
- Timer interrupt via MIE.MTIE
- Tick rate: 1000 Hz (1ms resolution)
- Timer compare value updated in interrupt handler

#### Context Switch
- Full register save/restore (32 general-purpose registers)
- CSRs saved: `mepc`, `mstatus`, `mcause`
- Stack-based context switching
- Efficient assembly implementation

#### Interrupt Handling
- Vectored interrupts via `mtvec`
- Separate interrupt stack (2KB)
- Nested interrupts disabled during handler
- Critical sections use `mstatus.MIE` bit

## API Usage Examples

### Task Creation

```c
#include "FreeRTOS.h"
#include "task.h"

void vTaskFunction(void *pvParameters) {
    for(;;) {
        // Task work here
        vTaskDelay(pdMS_TO_TICKS(1000));  // Delay 1 second
    }
}

int main(void) {
    xTaskCreate(vTaskFunction,        // Function
                "TaskName",            // Name (for debugging)
                128,                   // Stack size (words)
                NULL,                  // Parameters
                1,                     // Priority (0-7)
                NULL);                 // Task handle

    vTaskStartScheduler();  // Start FreeRTOS
    return 0;  // Should never reach here
}
```

### Semaphore Usage

```c
#include "semphr.h"

SemaphoreHandle_t xSemaphore;

void vProducerTask(void *pvParameters) {
    for(;;) {
        // Produce data
        xSemaphoreGive(xSemaphore);  // Signal consumer
        vTaskDelay(pdMS_TO_TICKS(100));
    }
}

void vConsumerTask(void *pvParameters) {
    for(;;) {
        if(xSemaphoreTake(xSemaphore, portMAX_DELAY) == pdTRUE) {
            // Consume data
        }
    }
}

int main(void) {
    xSemaphore = xSemaphoreCreateBinary();

    xTaskCreate(vProducerTask, "Producer", 128, NULL, 2, NULL);
    xTaskCreate(vConsumerTask, "Consumer", 128, NULL, 2, NULL);

    vTaskStartScheduler();
    return 0;
}
```

### Queue Usage

```c
#include "queue.h"

QueueHandle_t xQueue;

void vSenderTask(void *pvParameters) {
    int32_t lValueToSend = 100;

    for(;;) {
        xQueueSend(xQueue, &lValueToSend, portMAX_DELAY);
        lValueToSend++;
        vTaskDelay(pdMS_TO_TICKS(500));
    }
}

void vReceiverTask(void *pvParameters) {
    int32_t lReceivedValue;

    for(;;) {
        if(xQueueReceive(xQueue, &lReceivedValue, portMAX_DELAY) == pdTRUE) {
            printf("Received: %d\n", lReceivedValue);
        }
    }
}

int main(void) {
    xQueue = xQueueCreate(10, sizeof(int32_t));  // 10 items

    xTaskCreate(vSenderTask, "Sender", 128, NULL, 1, NULL);
    xTaskCreate(vReceiverTask, "Receiver", 128, NULL, 2, NULL);

    vTaskStartScheduler();
    return 0;
}
```

### Mutex Usage

```c
#include "semphr.h"

SemaphoreHandle_t xMutex;
int shared_resource = 0;

void vTaskA(void *pvParameters) {
    for(;;) {
        if(xSemaphoreTake(xMutex, portMAX_DELAY) == pdTRUE) {
            // Critical section
            shared_resource++;
            printf("Task A: %d\n", shared_resource);
            xSemaphoreGive(xMutex);
        }
        vTaskDelay(pdMS_TO_TICKS(100));
    }
}

int main(void) {
    xMutex = xSemaphoreCreateMutex();

    xTaskCreate(vTaskA, "TaskA", 128, NULL, 1, NULL);
    xTaskCreate(vTaskA, "TaskB", 128, NULL, 1, NULL);

    vTaskStartScheduler();
    return 0;
}
```

## Performance Characteristics

### Memory Usage

**Code size** (simple example):
- Text (code): ~8 KB
- Data: ~500 bytes
- BSS: ~66 KB (mostly heap)
- **Total**: ~74 KB

**Heap allocation**:
- Configured: 64 KB
- Per task: ~512 bytes minimum (stack)
- TCB overhead: ~100 bytes per task

### Execution Performance

**Simple example** (2 tasks, 10 iterations):
- Total cycles: 2,647,949
- Instructions: 356,318
- CPI: 7.43
- Simulated time: 52.9 ms @ 50 MHz
- Real wall-clock time: ~5 seconds (Verilator)

**Task switching overhead**:
- Context switch: ~150 cycles
- Tick interrupt: ~200 cycles (including switch)

### Timing

- **Tick rate**: 1000 Hz (1 ms per tick)
- **Minimum delay**: 1 tick (1 ms)
- **Timer accuracy**: Limited by CLINT timer resolution

## Troubleshooting

### Build Errors

**"undefined reference to `_start`"**
- Ensure `freertos_start.S` is compiled and linked
- Check linker script specifies `ENTRY(_start)`

**"undefined reference to `freertos_risc_v_trap_handler`"**
- Verify `freertos_risc_v_trap_handler.c` is compiled
- Check that portable/RISC-V source is included

**"section `.text' will not fit in region `RAM`"**
- Code too large for 2MB RAM
- Reduce heap size in FreeRTOSConfig.h
- Compile with `-Os` for size optimization

### Runtime Issues

**No console output**
- Verify magic address (0x40000000) is implemented in testbench
- Check that `_write()` syscall is linked
- Ensure printf buffer is flushed (use `\n` or `fflush()`)

**Crash on startup**
- Check stack size (minimum 512 bytes per task)
- Verify heap is sufficient for task allocation
- Enable stack overflow checking: `configCHECK_FOR_STACK_OVERFLOW 2`

**Tasks not running**
- Verify `vTaskStartScheduler()` is called
- Check task priorities (must be < configMAX_PRIORITIES)
- Ensure timer interrupts are enabled (MIE.MTIE)

**Timer not working**
- Verify CLINT is configured at 0x02000000
- Check that timer interrupt handler is registered
- Ensure `mtvec` points to trap handler

**Memory corruption**
- Increase heap size: `configTOTAL_HEAP_SIZE`
- Increase stack per task (3rd parameter to `xTaskCreate()`)
- Enable heap integrity checking (debug build)

## Debugging

### Debug Techniques

**1. Increase verbosity**:
```c
// Add debug prints
printf("Task created: %s\n", pcTaskName);
printf("Heap free: %u bytes\n", xPortGetFreeHeapSize());
```

**2. Stack usage**:
```c
// Check stack watermark
UBaseType_t uxHighWaterMark = uxTaskGetStackHighWaterMark(NULL);
printf("Stack remaining: %u words\n", uxHighWaterMark);
```

**3. Task list**:
```c
// Enable in FreeRTOSConfig.h
#define configUSE_TRACE_FACILITY 1

// Print task list
char buffer[512];
vTaskList(buffer);
printf("%s\n", buffer);
```

**4. Call trace analysis**:
```bash
# Generate call trace report
python3 scripts/parse_call_trace.py build/rtl_trace.txt \
    build/test.elf riscv-none-elf- call_trace.txt
```

**5. Memory trace analysis**:
```bash
# Verify memory transactions
make memtrace-freertos-simple
```

## Optimization Tips

### Code Size

- Compile with `-Os` instead of `-O2`
- Disable unused features in FreeRTOSConfig.h
- Use static allocation where possible
- Remove debug prints in production

### Performance

- Increase tick rate for faster response
- Adjust task priorities appropriately
- Use direct-to-task notifications instead of queues
- Minimize critical section duration

### Memory

- Reduce heap size if not needed
- Use smaller task stacks
- Disable `configUSE_TRACE_FACILITY` (saves RAM)
- Use static allocation for fixed tasks

## Known Limitations

- **Machine mode only**: No privilege levels (supervisor/user mode)
- **No MMU**: Direct physical addressing only
- **Single core**: No SMP support
- **Limited interrupts**: Timer only (no external interrupts configured)
- **No floating point**: Software emulation only (slow)
- **Busy-wait delays**: No true sleep (CPU always running)

## References

- [FreeRTOS Official Site](https://www.freertos.org/)
- [FreeRTOS Documentation](https://www.freertos.org/Documentation/RTOS_book.html)
- [FreeRTOS RISC-V Port Guide](https://www.freertos.org/RISCV_Generic.html)
- [RISC-V Privileged Spec](https://riscv.org/specifications/privileged-isa/)
- [kcore Project Status](../../PROJECT_STATUS.md)

## License

FreeRTOS is licensed under the MIT License. See source files for details.

The kcore port follows the same license.

## Contributing

To improve this FreeRTOS port:

1. Test additional features (software timers, event groups)
2. Add more samples (network stack, file system)
3. Optimize context switching performance
4. Add external interrupt support
5. Port to RV32IMAC (compressed instructions + atomics)
6. Document performance benchmarks

See [../../PROJECT_STATUS.md](../../PROJECT_STATUS.md) for verification status and test results.

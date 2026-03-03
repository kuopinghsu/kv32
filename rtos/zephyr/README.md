# Zephyr RTOS Port for kv32

This directory contains a complete Zephyr RTOS port for the RV32IM kv32 processor with timer interrupt support and threading capabilities.

## Overview

This port provides:
- **SoC Support**: Custom RISC-V RV32IM SoC definition with CLINT timer
- **Board Support**: kv32 configuration with complete devicetree
- **Timer Driver**: RISC-V machine timer (CLINT) with interrupt support
- **UART Driver**: Serial console driver for the custom UART peripheral
- **Console Driver**: Fast magic-address console for simulation
- **Sample Applications**: Hello World, UART Echo, and Thread Synchronization demos
- **Full Threading**: Multi-threaded applications with semaphores, mutexes, and timeslicing

## Directory Structure

```
rtos/zephyr/
├── soc/
│   └── riscv/
│       └── kv32/          # SoC definition (Kconfig, devicetree, linker)
├── boards/
│   └── riscv/
│       └── kv32/    # Board definition and configuration
├── drivers/
│   ├── console/            # Magic address console driver (fast)
│   └── serial/             # UART driver (hardware accurate)
└── samples/                # Sample applications
    ├── hello/
    ├── uart_echo/
    └── threads_sync/
```

## Hardware Features

- **CPU**: RV32IM (32-bit RISC-V with multiply/divide)
- **Memory**: 2MB RAM @ 0x80000000
- **Console**: Magic address @ 0x40000000 (fast simulation output)
- **UART**: Custom UART with TX FIFO @ 0x10000000 (optional, hardware accurate)
- **Timer**: RISC-V machine timer (CLINT) @ 0x02000000
  - mtime register @ 0x0200BFF8
  - mtimecmp register @ 0x02004000
  - Timer interrupt via MIE
- **Clock**: 50 MHz system clock (20ns period)
- **Interrupts**: Machine-mode external and timer interrupts

## Console Drivers

Two console drivers are provided:

### 1. Magic Address Console (Default - Recommended for Simulation)
- **Address**: 0x40000000
- **Performance**: Very fast - no hardware timing simulation
- **Use Case**: Simulation and testing
- **Config**: `CONFIG_CONSOLE_KV32=y`
- **Initialization**: PRE_KERNEL_1 level (early boot)

### 2. UART Console (Optional - Hardware Accurate)
- **Address**: 0x10000000
- **Performance**: Slower - simulates baud rate and FIFO
- **Use Case**: Hardware validation
- **Config**: `CONFIG_UART_CONSOLE=y`, `CONFIG_SERIAL=y`
- **Baud Rate**: 115200 (configurable via devicetree)

To switch between drivers, edit the sample's `prj.conf` or board defconfig.

**Note**: Both drivers are compatible with timer interrupts and threading.

## Prerequisites

1. **Zephyr Installation**: Install Zephyr 4.x or later
   ```bash
   # Install west
   pip3 install --user west

   # Initialize workspace
   west init ~/zephyrproject
   cd ~/zephyrproject
   west update
   ```

2. **RISC-V Toolchain**: Install a RISC-V GCC toolchain

   **Option A: Zephyr SDK (Recommended)**
   ```bash
   wget https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v0.16.5/zephyr-sdk-0.16.5_linux-x86_64.tar.xz
   tar xvf zephyr-sdk-0.16.5_linux-x86_64.tar.xz
   cd zephyr-sdk-0.16.5
   ./setup.sh -t riscv64-zephyr-elf
   ```

   **Option B: xPack RISC-V GCC**
   ```bash
   # Already installed if using this project's setup
   # Located at: /opt/xpack-riscv-none-elf-gcc-15.2.0-1
   ```

3. **Environment Setup**
   ```bash
   export ZEPHYR_BASE=~/zephyrproject/zephyr
   export ZEPHYR_TOOLCHAIN_VARIANT=cross-compile
   export CROSS_COMPILE=/path/to/riscv-none-elf-
   ```

## Integration with Zephyr

This port is designed as an out-of-tree SoC/board. To use it:

### Option 1: Environment Variables (Recommended)

```bash
export ZEPHYR_BASE=~/zephyrproject/zephyr
export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
export ZEPHYR_SDK_INSTALL_DIR=~/zephyr-sdk-0.16.5

# Point to this custom SoC/board
export ZEPHYR_EXTRA_MODULES=/path/to/riscv/rtos/zephyr
```

### Option 2: Copy to Zephyr Tree

```bash
# Copy SoC definition
cp -r rtos/zephyr/soc/riscv/kv32 $ZEPHYR_BASE/soc/riscv/

# Copy board definition
cp -r rtos/zephyr/boards/riscv/kv32 $ZEPHYR_BASE/boards/riscv/

# Copy UART driver
cp rtos/zephyr/drivers/serial/uart_kv32.c $ZEPHYR_BASE/drivers/serial/
```

## Building Sample Applications

The project includes three sample applications:

### 1. Hello World (Basic Test)

Simple application that prints messages without timers or threading.

```bash
# Using Make (recommended)
make zephyr-hello

# Using west directly
cd rtos/zephyr/samples/hello
west build -b kv32
```

### 2. UART Echo (Interactive Test)

Tests UART driver with character echo. Type characters and they are echoed back.

```bash
# Using Make (recommended)
make zephyr-uart_echo

# Using west directly
cd rtos/zephyr/samples/uart_echo
west build -b kv32
```

### 3. Thread Synchronization (Advanced)

Demonstrates multi-threaded programming with timers, semaphores, and mutexes.

```bash
# Using Make (recommended)
make zephyr-threads_sync

# Using west directly
cd rtos/zephyr/samples/threads_sync
west build -b kv32
```

## Running on kv32

### Quick Run with Make

```bash
# Build and run hello in RTL simulation
make zephyr-rtl-hello

# Build and run uart_echo in RTL simulation
make zephyr-rtl-uart_echo

# Build and run threads_sync in RTL simulation
make zephyr-rtl-threads_sync
```

### Manual Run (if needed)

```bash
# From project root
./build/verilator/Vtb_soc rtos/zephyr/build.<sample>/zephyr/zephyr.elf
```

### Expected Output Examples

**hello:**
```
*** Booting Zephyr OS build v4.3.0 ***
Hello World! kv32
Counter: 0
Counter: 1
Counter: 2
...
```

**uart_echo:**
```
*** Booting Zephyr OS build v4.3.0 ***
Echo test program
Type characters, they will be echoed back
[Type 'hello']
hello
```

**threads_sync:**
```
*** Booting Zephyr OS build v4.3.0 ***

*** Zephyr Thread Synchronization Test ***

=== Test 1: Producer-Consumer Pattern ===
Producer thread started
Consumer thread started
Producer: produced item 1, counter = 1
Consumer: consumed item, counter = 1
...
*** Thread Synchronization Test PASSED ***
```

## System Configuration

### Timer and Clock Configuration

- **System Clock**: 50 MHz (CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=50000000)
- **Tick Rate**: 100 Hz (CONFIG_SYS_CLOCK_TICKS_PER_SEC=100)
- **Timer Driver**: RISC-V machine timer (CONFIG_RISCV_MACHINE_TIMER=y)
- **Timer Interrupt**: Enabled automatically with CONFIG_SYS_CLOCK_EXISTS=y

### Memory Layout

- **RAM**: 0x80000000 - 0x801FFFFF (2MB)
  - Stack: Configurable per thread (default 1KB)
  - Heap: Minimal C library heap (if enabled)
- **UART**: 0x10000000
- **CLINT/Timer**: 0x02000000
- **Console**: 0x40000000 (magic address)

### System Clock

The SoC is configured for 50 MHz (CONFIG_SYS_CLOCK_HW_CYCLES_PER_SEC=50000000)

### Memory Layout

- **RAM**: 0x80000000 - 0x801FFFFF (2MB)
  - Stack: Configurable per thread (default 1KB)
  - Heap: Minimal C library heap (if enabled)
- **UART**: 0x10000000
- **CLINT/Timer**: 0x02000000
- **Console**: 0x40000000 (magic address)

### Threading Configuration

For samples requiring threading (e.g., threads_sync):
- **CONFIG_SYS_CLOCK_EXISTS=y**: Enables system timer
- **CONFIG_TIMESLICING=y**: Enables preemptive scheduling
- **CONFIG_TIMESLICE_SIZE=10**: 10ms time slices
- **CONFIG_MAIN_STACK_SIZE=2048**: Main thread stack
- **CONFIG_IDLE_STACK_SIZE=512**: Idle thread stack

## Customization

### Creating New Applications

Follow Zephyr's application structure:

```
my_app/
├── CMakeLists.txt
├── prj.conf
└── src/
    └── main.c
```

**Minimal CMakeLists.txt:**
```cmake
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(my_app)

target_sources(app PRIVATE src/main.c)
```

**Minimal prj.conf:**
```
# For simple apps without timers
CONFIG_CONSOLE_KV32=y
CONFIG_SYS_CLOCK_EXISTS=n

# For apps with timers/threading
CONFIG_CONSOLE_KV32=y
CONFIG_SYS_CLOCK_EXISTS=y
CONFIG_TIMESLICING=y
```

### Board Configuration

Modify `boards/riscv/kv32/kv32_defconfig` to change default configurations.

### Device Tree

Edit `boards/riscv/kv32/kv32.dts` to add/modify peripherals.

## Porting Guide: Critical Issues and Solutions

### Issue 1: Zephyr 4.x Sub-Priority Initialization

**Problem**: Zephyr 4.x device initialization creates section names with `_SUB_` suffix:
```
.z_init_PRE_KERNEL_1_P_<priority>_SUB_<subpriority>_
```

But the standard `CREATE_OBJ_LEVEL` macro only matches patterns like:
```
.z_init_PRE_KERNEL_1_P_?_*     (1 digit)
.z_init_PRE_KERNEL_1_P_??_*    (2 digits)
.z_init_PRE_KERNEL_1_P_???_*   (3 digits)
```

This causes linker error: **"Undefined initialization levels used"**

**Solution**: Create extended macro that includes `_SUB_` patterns:

File: `soc/riscv/kv32/linker-defs-sub.h`
```c
#undef CREATE_OBJ_LEVEL
#define CREATE_OBJ_LEVEL(object, level)                          \
    PLACE_SYMBOL_HERE(__##object##_##level##_start);     \
    KEEP(*(SORT(.z_##object##_##level##_P_?_*)));        \
    KEEP(*(SORT(.z_##object##_##level##_P_??_*)));       \
    KEEP(*(SORT(.z_##object##_##level##_P_???_*)));      \
    KEEP(*(SORT(.z_##object##_##level##_P_*_SUB_*)));    /* NEW */
```

Include in `soc/riscv/kv32/linker.ld`:
```c
#include "linker-defs-sub.h"
```

**Why it works**: The extended pattern `P_*_SUB_*` matches any priority with sub-priority suffix, ensuring all device init symbols are linked correctly.

### Issue 2: Timer Devicetree Configuration

**Problem**: Initially had both `sifive,clint0` and `riscv,machine-timer` nodes, causing conflicts.

**Solution**: Use only `riscv,machine-timer` binding:

```dts
mtimer: timer@2000000 {
    compatible = "riscv,machine-timer";
    reg = <0x0200bff8 0x08    /* mtime */
           0x02004000 0x08>;  /* mtimecmp */
    reg-names = "mtime", "mtimecmp";
    interrupts-extended = <&hlic 7>;
};
```

**Key points**:
- `reg-names` is **required** by the binding
- Timer interrupt must be wired to hart-local interrupt controller (hlic)
- Node name should reflect actual mtime register address

### Issue 3: Console Driver Initialization Level

**Problem**: Console driver needs early initialization for printk() during boot.

**Solution**: Use `PRE_KERNEL_1` level:

```c
SYS_INIT(console_kv32_init, PRE_KERNEL_1, CONFIG_CONSOLE_INIT_PRIORITY);
```

This ensures console is ready before other drivers log messages.

### Issue 4: UART Driver Device Integration

**Problem**: UART driver needs proper device initialization for Zephyr's device model.

**Solution**: Use `DEVICE_DT_INST_DEFINE` macro:

```c
DEVICE_DT_INST_DEFINE(n,
            uart_kv32_init,
            NULL,
            &uart_kv32_data_##n,
            &uart_kv32_cfg_##n,
            PRE_KERNEL_1,
            CONFIG_SERIAL_INIT_PRIORITY,
            &uart_kv32_driver_api);
```

This automatically creates the init entry with proper sub-priority handling.

## Known Limitations

- **Single Core**: No SMP support
- **M-Mode Only**: No supervisor mode or user mode
- **No MMU**: Direct physical addressing
- **Limited Peripherals**: UART, CLINT timer, and magic console only
- **No Atomic Operations**: A-extension not fully verified
- **No DMA**: All I/O is programmed

## Troubleshooting

### Build Errors

1. **"Board kv32 not found"**:
   - Set `ZEPHYR_EXTRA_MODULES` environment variable
   - Or use project's Makefile which handles this automatically

2. **"No CMAKE_C_COMPILER"**:
   - Install RISC-V toolchain
   - Set `CROSS_COMPILE` or `ZEPHYR_TOOLCHAIN_VARIANT`

3. **"Undefined initialization levels used"**:
   - Verify `linker-defs-sub.h` is present
   - Check that `linker.ld` includes the header
   - This is normal on older Zephyr without sub-priority support

4. **Devicetree errors about timer**:
   - Ensure only `riscv,machine-timer` node exists (no `sifive,clint0`)
   - Verify `reg-names` property is present
   - Check mtime/mtimecmp addresses match hardware

5. **CMake warnings about unused variables**:
   - These are normal and can be ignored
   - Related to Zephyr's multi-architecture support

### Runtime Issues

1. **No console output**:
   - Check that `CONFIG_CONSOLE_KV32=y` is set
   - Verify magic address (0x40000000) is implemented in testbench
   - For UART: verify baud rate matches testbench (115200)

2. **Timer not working**:
   - Ensure `CONFIG_SYS_CLOCK_EXISTS=y` in prj.conf
   - Verify `CONFIG_RISCV_MACHINE_TIMER=y` in board config
   - Check timer interrupt is enabled in hardware

3. **Threads not switching**:
   - Enable `CONFIG_TIMESLICING=y`
   - Verify timer interrupt is firing (check RTL simulation)
   - Increase `CONFIG_SYS_CLOCK_TICKS_PER_SEC` for faster switching

4. **Crashes or hangs**:
   - Increase stack sizes in prj.conf:
     ```
     CONFIG_MAIN_STACK_SIZE=2048
     CONFIG_IDLE_STACK_SIZE=512
     CONFIG_ISR_STACK_SIZE=1024
     ```
   - Enable debug logging: `CONFIG_DEBUG=y`
   - Check for stack overflow: `CONFIG_THREAD_STACK_INFO=y`

5. **Slow simulation**:
   - Use magic console instead of UART: `CONFIG_CONSOLE_KV32=y`
   - Reduce tick rate: `CONFIG_SYS_CLOCK_TICKS_PER_SEC=10`
   - Disable unnecessary features

## Performance Optimization

### For Faster RTL Simulation

1. **Use Magic Console**: Eliminates UART timing delays
   ```
   CONFIG_CONSOLE_KV32=y
   CONFIG_UART_CONSOLE=n
   ```

2. **Reduce Timer Tick Rate**: Fewer interrupts = faster simulation
   ```
   CONFIG_SYS_CLOCK_TICKS_PER_SEC=10  # Instead of 100
   ```

3. **Minimize Logging**: Less output = faster simulation
   ```
   CONFIG_LOG=n
   CONFIG_PRINTK=y  # Keep printk for essential output
   ```

4. **Disable Unused Features**:
   ```
   CONFIG_TIMESLICING=n  # If single-threaded
   CONFIG_THREAD_STACK_INFO=n
   CONFIG_THREAD_NAME=n
   ```

### Memory Usage

Typical memory usage per sample:
- **hello**: ~8 KB (text: 7KB, data+bss: 1KB)
- **uart_echo**: ~12 KB (text: 9KB, data+bss: 3KB)
- **threads_sync**: ~26 KB (text: 20KB, data+bss: 6KB)

To reduce memory:
```
CONFIG_MINIMAL_LIBC=y
CONFIG_MAIN_STACK_SIZE=1024
CONFIG_IDLE_STACK_SIZE=256
```

## References

- [Zephyr Documentation](https://docs.zephyrproject.org/)
- [Zephyr RISC-V Support](https://docs.zephyrproject.org/latest/boards/riscv/index.html)
- [RISC-V Machine Timer Binding](https://docs.zephyrproject.org/latest/build/dts/api/bindings/timer/riscv%2Cmachine-timer.html)
- [Device Tree Guide](https://docs.zephyrproject.org/latest/build/dts/index.html)
- [West Tool](https://docs.zephyrproject.org/latest/develop/west/index.html)
- [Zephyr Threading](https://docs.zephyrproject.org/latest/kernel/services/threads/index.html)
- [Zephyr Synchronization](https://docs.zephyrproject.org/latest/kernel/services/synchronization/index.html)

## Status and Verification

### Tested and Working ✅

- ✅ Basic boot and console output
- ✅ UART driver with interrupt support
- ✅ Timer driver (RISC-V machine timer)
- ✅ Timer interrupts
- ✅ Multi-threading with preemption
- ✅ Semaphores for synchronization
- ✅ Mutexes for critical sections
- ✅ Thread creation and termination
- ✅ Sleep and delay functions (k_msleep, k_sleep)
- ✅ System clock and ticks
- ✅ All three sample applications

### Known Working Configuration

- **Zephyr Version**: 4.3.99 (latest development)
- **Toolchain**: RISC-V GCC 15.2.0
- **CPU**: RV32IM (no compressed, no atomics)
- **Memory**: 2MB RAM
- **Clock**: 50 MHz
- **Samples**: hello, uart_echo, threads_sync

## Contributing

When porting to new hardware or adding features:

1. **Follow Zephyr conventions**: Use standard device tree bindings where possible
2. **Test thoroughly**: Verify on RTL simulation before claiming support
3. **Document limitations**: Be clear about what works and what doesn't
4. **Update this README**: Keep porting guide current with solutions to issues
5. **Add samples**: Demonstrate new features with working examples

## License

SPDX-License-Identifier: Apache-2.0

This Zephyr port follows the Apache 2.0 license consistent with the Zephyr Project.

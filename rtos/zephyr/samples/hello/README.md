# Zephyr Hello World Sample

Simple "Hello World" application for the kcore RISC-V board.

## Description

This application demonstrates:
- Basic Zephyr kernel initialization
- Console output using printk() (via magic address driver)
- Kernel timing services (k_msleep)
- Simple counter loop

The application uses the fast magic address console driver by default for optimal simulation performance.

## Building

### Using West

```bash
cd rtos/zephyr/samples/hello
west build -b kcore_board
```

### Using Make (from project root)

```bash
make zephyr-hello
```

## Running

### On RTL Simulation

```bash
# From project root
make rtl-zephyr-hello

# With waveform
make rtl-zephyr-hello WAVE=fst
```

### Manual Simulation

```bash
# ELF file is used directly - no binary conversion needed
# The simulator automatically loads and parses ELF files

# Run simulation (the Makefile handles copying zephyr.elf to build/test.elf)
cd ../../..
make zephyr-rtl-hello
```

## Expected Output

```
*** Booting Zephyr OS build v3.x.x ***
Hello World! kcore_board
CPU: RISC-V RV32IM @ 50 MHz
RAM: 2MB @ 0x80000000

Counter: 0
Counter: 1
Counter: 2
Counter: 3
Counter: 4
Counter: 5
Counter: 6
Counter: 7
Counter: 8
Counter: 9

Test complete - exiting
```

## Customization

Edit `src/main.c` to modify the application behavior:
- Change counter limit
- Modify sleep duration
- Add additional functionality

## Configuration

Edit `prj.conf` to change build options:
- Stack sizes
- Console driver selection (magic address vs UART)
- Optimization level

### Switching Console Drivers

**Use Magic Address Console (Default - Faster)**:
```
CONFIG_CONSOLE=y
CONFIG_CONSOLE_KCORE=y
```

**Use UART Console (Hardware Accurate)**:
```
CONFIG_CONSOLE=y
CONFIG_UART_CONSOLE=y
CONFIG_SERIAL=y
```

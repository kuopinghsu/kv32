# Software Simulation

This directory contains tools for software-based verification using ISA simulators.

**Supported Simulators**:
- **Spike**: Official RISC-V ISA simulator (default, `USE_SPIKE=1`)
- **rv32sim**: Built-in RV32IMAC simulator with GDB support (`USE_SPIKE=0`)

> **Note**: For memory transaction-level verification (CPU ↔ AXI memory interface), see [../docs/memory_trace_analysis.md](../docs/memory_trace_analysis.md) and use `make memtrace` or `make memtrace-<test>` targets.

## Files

- **rv32sim.cpp**: RV32IMAC software simulator with GDB stub support
- **rv32sim.h**: Simulator class definition and interfaces
- **gdb_stub.c/h**: GDB Remote Serial Protocol implementation
- **Makefile**: Build system for rv32sim simulator

## Features

**CSR Support**: Full RISC-V CSR implementation matching RTL
- **Machine-mode CSRs**: mstatus, misa, mie, mtvec, mscratch, mepc, mcause, mtval, mip
- **Machine counters**: mcycle/mcycleh, minstret/minstreth (64-bit, writable)
- **User counters**: cycle/cycleh, time/timeh, instret/instreth (64-bit, read-only aliases)
- **Machine info**: mvendorid, marchid, mimpid, mhartid (read-only, hardwired to 0)

**Interrupt Support**: Timer, software, and external interrupts via CLINT

**GDB Remote Debugging**: Full breakpoint and watchpoint support (see below)

### Analysis Scripts (moved to scripts/)

- **trace_compare.py**: Python script to compare RTL trace with software simulator trace (now in scripts/)
- **analyze_mem_trace.py**: Memory transaction verification script (now in scripts/)
- **parse_call_trace.py**: Call trace analyzer with function profiling (now in scripts/)

## Simulator Selection

Use `USE_SPIKE` to choose between simulators:

```bash
# Use Spike (default)
make sim              # Uses Spike by default
make compare          # Compares with Spike

# Use rv32sim
make sim USE_SPIKE=0       # Use built-in rv32sim
make compare USE_SPIKE=0   # Compare with rv32sim
```

## Usage

### Build software simulator (rv32sim):
```bash
make build-sim
```

### Run software simulation:
```bash
make sim             # Run default test (uses Spike by default)
make sim-full        # Run full test (shortcut)
make sim USE_SPIKE=0 # Use rv32sim instead of Spike
make TEST=mytest sim # Run specific test (explicit)
```

### Compare traces:
```bash
make compare             # Compare default test
make compare-simple      # Compare simple test (shortcut)
make compare-full        # Compare full test (shortcut)
make TEST=mytest compare # Compare specific test (explicit)
```

**Note**: All targets support `[-<test>]` pattern. For example:
- `make sim-<test>` = `make TEST=<test> sim`
- `make compare-<test>` = `make TEST=<test> compare`

## GDB Remote Debugging

The simulator includes a GDB stub for interactive debugging with full breakpoint support.

### Starting GDB Session

**Terminal 1** - Start simulator with GDB stub:
```bash
./build/rv32sim --gdb --gdb-port=3333 build/test.elf
```

**Terminal 2** - Connect with GDB:
```bash
riscv32-unknown-elf-gdb build/test.elf
(gdb) target remote localhost:3333
(gdb) break main
(gdb) continue
```

### GDB Features

✓ **Software Breakpoints** - Set unlimited breakpoints at any address
✓ **Hardware Watchpoints** - Monitor memory reads/writes (32 watchpoints max)
✓ **Single-Step Execution** - Step through instructions one at a time
✓ **Register Access** - Read and modify all 32 general-purpose registers
✓ **Memory Access** - Inspect and modify memory contents
✓ **Continue/Stop** - Full execution control

### Common GDB Commands

```bash
# Breakpoint management
break main                  # Break at function
break *0x80000000          # Break at address
info breakpoints           # List breakpoints
delete 1                   # Delete breakpoint #1

# Watchpoint management
watch myvar                 # Break when myvar is written
rwatch myvar                # Break when myvar is read
awatch myvar                # Break when myvar is accessed (read or write)
watch *0x80001000           # Watch memory address (write)
info watchpoints            # List watchpoints
delete 2                    # Delete watchpoint #2

# Execution control
continue                   # Continue execution
step / stepi               # Step one line / instruction
next / nexti               # Step over calls
finish                     # Run until function returns

# Inspection
info registers             # Show all registers
x/10i $pc                  # Disassemble 10 instructions
x/10xw $sp                 # Examine stack (10 words hex)
print $x10                 # Print register x10
print/x *0x80000000        # Print memory value in hex

# Modification
set $x10 = 0               # Set register x10 to 0
set *0x80000100 = 0x12345  # Write to memory
```

### Configuration

Default GDB port: **3333** (configurable with `--gdb-port=<port>`)

## Requirements

- Spike RISC-V ISA simulator installed and in PATH
- Python 3 for trace comparison
- RISC-V GDB for remote debugging (optional)

## Trace Analysis Scripts

For detailed information about trace formats, analysis tools, and usage:

**See [../scripts/README.md](../scripts/README.md)** for:
- RTL and Spike trace format specifications
- Trace comparison tool (trace_compare.py)
- Call trace analysis (parse_call_trace.py)
- Memory trace verification (analyze_mem_trace.py)


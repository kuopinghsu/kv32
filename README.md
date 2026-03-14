RISC-V 32-bit IMAC Processor
============================

K<sub>V</sub>32 is a complete RISC-V 32-bit processor implementation with RV32IMAC_Zicsr_Zifencei support, featuring a 5-stage pipeline, instruction and data caches, KV32 non-standard stack-guard and cache-diagnostic CSR extensions, a JTAG/cJTAG debug interface, a 1-to-11 AXI4-Lite interconnect with ten on-chip peripherals, and both RTL and functional simulators.

## Features

### Core Features
- **ISA**: RV32IMAC_Zicsr (Integer, Multiplication, Atomic, Compressed, CSR extensions)
- **KV32 Non-Standard Extension**: Stack guard + stack watermark via custom M-mode CSRs `sguard_base` (`0x7CC`) and `spmin` (`0x7CD`), with custom exception cause `16` (`KV_EXC_STACK_OVERFLOW`)
- **KV32 Non-Standard Extension**: Cache diagnostics via custom M-mode CSRs `icap` (`0x7D0`), `dcap` (`0x7D1`), `cdiag_cmd` (`0x7D2`), `cdiag_tag` (`0x7D3`), and `cdiag_data` (`0x7D4`) for cache geometry discovery and read-only line/tag inspection
- **Pipeline**: 5-stage (Fetch, Decode, Execute, Memory, Writeback)
- **Hazard Handling**: Data forwarding, pipeline stalls, branch prediction
- **Privilege**: Machine mode (M-mode) support
- **CSRs**: Full CSR support including mstatus, mie, mtvec, mepc, mcause, etc.
- **Interrupts**: Timer, software, and external interrupt support
- **Exceptions**: Illegal instruction, ECALL, EBREAK, load/store faults

### System Features
- **Bus Interface**: AXI4-Lite 1-to-11 interconnect (single master, eleven slaves)
- **Memory**: 2MB RAM at `0x8000_0000` with DPI-C access for ELF loading
- **Instruction Cache**: 2-way set-associative, 4 KB, 64-byte cache lines (configurable via `CACHE_SIZE`, `CACHE_LINE_SIZE`, `CACHE_WAYS`); controlled by `ICACHE_EN` parameter
- **Data Cache**: configurable write-back/write-through, write-allocate/no-alloc, N-way set-associative, 4 KB 2-way default; critical-word-first AXI4 WRAP bursts; CMO (CBO.FLUSH/CBO.CLEAN/CBO.INVAL) and FENCE.I; PMA-based bypass for non-cacheable addresses; controlled by `DCACHE_EN` parameter
- **Debug Interface**: RISC-V Debug Spec 0.13 DTM; IEEE 1149.1 JTAG (4-wire) and IEEE 1149.7 cJTAG (2-wire, OScan1); halt/resume, GPR/CSR/memory access via abstract commands, System Bus Access (SBA); IDCODE `0x1DEAD3FF`; OpenOCD-compatible
- **Power Management**: WFI-triggered clock gating via ICG cell (BUFGCE on Xilinx FPGA); auto-wakes on any pending M-mode interrupt (timer, software, external); IRQ pulse capture ensures single-cycle pulses are not missed; 1-cycle wake latency
- **Peripherals**:
  - CLINT — timer (`mtime`/`mtimecmp`) and software interrupts
  - PLIC — platform-level interrupt controller
  - UART — high-speed serial I/O (up to 25 Mbaud)
  - I2C — master controller
  - SPI — master controller with 4 chip-selects
  - GPIO — up to 128 configurable I/O pins
  - Timer/PWM — four independent 32-bit timers
  - DMA — memory-to-memory transfer engine
  - Watchdog Timer (WDT) — hardware reset/interrupt on timeout
  - Magic — simulation console output and exit control
- **RTOS**: FreeRTOS and Zephyr ports (`rtos/freertos/`, `rtos/zephyr/`), Mini-RTOS (`sw/rtos`) for stress test
- **Simulation**:
  - Verilator-based RTL simulation with FST/VCD tracing
  - Fast functional ISA simulator (kv32sim) with GDB stub
  - Spike ISA simulator with custom peripheral plugins (`spike/`)
  - ELF file loader for both simulators

![Block Diagram](docs/kv32_soc_block_diagram.svg)

## Memory Map

| Slave | Device | Base Address | End Address | Size | Description |
|-------|--------|--------------|-------------|------:|-------------|
| 0 | **RAM** | `0x8000_0000` | `0x801F_FFFF` | 2 MB | Main memory |
| 1 | **Magic** | `0x4000_0000` | `0x4000_FFFF` | 64 KB | Simulation console and exit control |
| 2 | **CLINT** | `0x0200_0000` | `0x020B_FFFF` | 768 KB | `mtime`, `mtimecmp`, software interrupt |
| 3 | **PLIC** | `0x0C00_0000` | `0x0CFF_FFFF` | 16 MB | Platform-level interrupt controller |
| 4 | **DMA** | `0x2000_0000` | `0x2000_FFFF` | 64 KB | Memory-to-memory DMA engine |
| 5 | **UART** | `0x2001_0000` | `0x2001_FFFF` | 64 KB | Serial I/O (up to 25 Mbaud) |
| 6 | **I2C** | `0x2002_0000` | `0x2002_FFFF` | 64 KB | I2C master controller |
| 7 | **SPI** | `0x2003_0000` | `0x2003_FFFF` | 64 KB | SPI master, 4 chip-selects |
| 8 | **Timer/PWM** | `0x2004_0000` | `0x2004_FFFF` | 64 KB | Four independent 32-bit timers/PWM |
| 9 | **GPIO** | `0x2005_0000` | `0x2005_FFFF` | 64 KB | Up to 128 configurable GPIO pins |
| 10 | **WDT** | `0x2006_0000` | `0x2006_FFFF` | 64 KB | Hardware watchdog timer (reset or IRQ on timeout) |

### Magic Device Registers

| Address | Name | Description |
|---------|------|-------------|
| `0x4000_0000` | `KV_MAGIC_CONSOLE` | Write a byte to emit a character to the simulator console |
| `0x4000_0004` | `KV_MAGIC_EXIT` | Write exit code (`0`→write `1` for PASS; `N`→write `(N<<1)\|1` for FAIL) |
| `0x4000_1000` | `KV_NCM_BASE` | Non-Cacheable Memory (NCM) — 512 B (128 × 32-bit words). Resides below the DRAM window (`0x8000_0000+`) so it is outside both I-cache and D-cache PMA ranges; every access is routed through the AXI bypass path. Simulation-only model used to test cache-bypass behaviour: firmware can write machine code here and invoke it via a function pointer to exercise uncached instruction fetch, and data read/write exercises the D-cache bypass path including SLVERR propagation |

Refer to [docs/sdk_api_reference.adoc](docs/sdk_api_reference.adoc) and [docs/kv32_soc_datasheet.adoc](docs/kv32_soc_datasheet.adoc) for register-level details.

## Directory Structure

```
kv32/
├── rtl/                    # RTL source files
│   ├── core/               # Core processor modules
│   │   ├── kv32_pkg.sv     # Package definitions, debug macros, DBG_GRP_* defines
│   │   ├── kv32_core.sv    # Top-level core (RV32IMAC, 5-stage)
│   │   ├── kv32_alu.sv     # ALU
│   │   ├── kv32_decoder.sv # Instruction decoder (RV32 + compressed)
│   │   ├── kv32_regfile.sv # Register file
│   │   ├── kv32_csr.sv     # CSR unit (mstatus, mie, mtvec, mepc, mcause, …)
│   │   ├── kv32_rvc.sv     # RVC (compressed instruction) expander
│   │   ├── kv32_ib.sv      # Instruction buffer (outstanding fetch tracking)
│   │   └── kv32_sb.sv      # Store buffer
│   ├── jtag/               # JTAG/cJTAG debug interface
│   │   ├── jtag_top.sv     # Top-level wrapper (JTAG / cJTAG mode select)
│   │   ├── jtag_tap.sv     # IEEE 1149.1 TAP state machine
│   │   └── cjtag_bridge.sv # IEEE 1149.7 cJTAG→JTAG bridge (OScan1)
│   ├── memories/           # SRAM macro wrappers
│   │   └── sram_1rw.sv     # Single-port SRAM wrapper (used by caches)
│   ├── kv32_soc.sv         # SoC top-level
│   ├── axi_pkg.sv          # AXI definitions
│   ├── axi_xbar.sv         # AXI crossbar / 1-to-11 interconnect
│   ├── axi_arbiter.sv      # AXI arbiter (instruction/data read channels)
│   ├── kv32_icache.sv      # Instruction cache (configurable set-associative)
│   ├── kv32_dcache.sv      # Data cache (write-back/write-through, CMO, PMA)
│   ├── kv32_dtm.sv         # RISC-V Debug Spec 0.13 DTM + Debug Module
│   ├── kv32_pm.sv          # Power manager (WFI clock gating, BUFGCE/ICG)
│   ├── axi_clint.sv        # CLINT (mtime/mtimecmp/msip)
│   ├── axi_plic.sv         # PLIC (platform-level interrupt controller)
│   ├── axi_uart.sv         # UART with AXI wrapper
│   ├── axi_i2c.sv          # I2C master controller
│   ├── axi_spi.sv          # SPI master controller (4 chip-selects)
│   ├── axi_dma.sv          # DMA engine (memory-to-memory)
│   ├── axi_gpio.sv         # GPIO controller (up to 128 pins)
│   ├── axi_timer.sv        # Timer/PWM (4 independent 32-bit timers)
│   ├── axi_wdt.sv          # Hardware watchdog timer
│   ├── axi_magic.sv        # Simulation console, exit control, NCM region
│   ├── mem_axi.sv          # Memory-to-AXI bridge (read/write)
│   └── mem_axi_ro.sv       # Memory-to-AXI bridge (read-only, I-cache bypass)
├── testbench/              # Testbench files
│   ├── tb_kv32_soc.sv      # SystemVerilog top-level wrapper
│   ├── tb_kv32_soc.cpp     # Verilator C++ testbench
│   ├── axi_memory.sv       # 2 MB AXI memory slave with DPI-C ELF loader
│   ├── axi_monitor.sv      # AXI protocol monitor
│   ├── ddr4_axi4_slave.sv  # DDR4-model AXI4 slave (latency stress testing)
│   ├── i2c_slave_eeprom.sv # I2C EEPROM slave model
│   ├── spi_slave_memory.sv # SPI flash/SRAM slave model
│   ├── uart_loopback.sv    # UART loopback model
│   ├── elfloader.h         # ELF loader header
│   └── elfloader.cpp       # ELF loader implementation
├── sim/                    # Software ISA simulator
│   ├── kv32sim.cpp         # Main simulator (GDB stub, trace, signature)
│   ├── kv32sim.h           # Header
│   ├── riscv-dis.cpp       # Disassembler
│   ├── device.cpp          # Peripheral device models
│   └── Makefile            # Build file
├── spike/                  # Spike ISA simulator plugin adapters
│   ├── plugin_clint.cc     # CLINT plugin
│   ├── plugin_uart.cc      # UART plugin
│   ├── plugin_gpio.cc      # GPIO plugin
│   ├── plugin_dma.cc       # DMA plugin
│   ├── plugin_magic.cc     # Magic console plugin
│   ├── plugin_plic.cc      # PLIC plugin
│   ├── plugin_spi.cc       # SPI plugin
│   ├── plugin_timer.cc     # Timer plugin
│   └── plugin_i2c.cc       # I2C plugin
├── sw/                     # Software tests and examples
│   ├── common/             # Shared startup, trap, linker script, IRQ helpers
│   ├── include/            # Peripheral driver headers
│   └── <test>/             # One directory per test (hello, uart, gpio, …)
├── rtos/                   # RTOS ports
│   ├── freertos/           # FreeRTOS port
│   └── zephyr/             # Zephyr RTOS port
├── verif/                  # Formal/functional verification
│   ├── kv32-dv/            # riscv-dv random instruction generator integration
│   └── riscof_targets/     # RISCOF (RISC-V architecture test) targets
├── fpga/                   # FPGA (Xilinx) implementation
│   ├── fpga_top.sv         # FPGA top-level wrapper
│   ├── fpga_top.xdc        # Physical constraints (Xilinx XDC)
│   └── build.tcl           # Vivado build script
├── syn/                    # ASIC synthesis scripts
│   ├── scripts/yosys/      # Yosys open-source synthesis flow
│   ├── scripts/dc/         # Synopsys Design Compiler flow
│   └── scripts/genus/      # Cadence Genus flow
├── scripts/                # Utility and analysis scripts
│   ├── trace_compare.py    # Compare RTL vs software simulator traces
│   ├── trace_resync.py     # Re-synchronise diverged traces
│   ├── parse_call_trace.py # Parse call-graph traces
│   ├── cache_benchmark_v2.sh # I-cache / D-cache benchmark sweep
│   └── doxygen_sv_filter.py # Doxygen pre-filter for SystemVerilog
├── docs/                   # Documentation
│   ├── pipeline_architecture.md   # 5-stage pipeline design
│   ├── cache_architecture.md      # I-cache and D-cache architecture
│   ├── cache_benchmark_report.md  # I-cache + D-cache benchmark results
│   ├── jtag_cjtag_integration.md  # JTAG/cJTAG debug interface guide
│   ├── kv32_soc_datasheet.adoc    # SoC datasheet (register maps, parameters)
│   └── sdk_api_reference.adoc     # Software SDK API reference
├── build/                  # Build outputs (generated)
│   ├── kv32soc             # Verilator simulator binary
│   └── kv32sim             # Software simulator binary
├── Makefile                # Main build system
└── env.config              # Environment configuration (tool paths)
```

## Quick Start

### Prerequisites
- Verilator 5.0+ (for RTL simulation)
- GCC/Clang with C++11 support
- RISC-V GCC toolchain (for compiling programs)
- Make

### Building

#### Build RTL Simulator
```bash
make build-rtl
```
This creates `build/kv32soc` Verilator simulator.

#### Build Software Simulator
```bash
make build-sim
```
This creates `build/kv32sim` functional simulator.

#### Build Both
```bash
make all
```

#### Clean Build
```bash
make clean
```

#### Debug Builds
Two debug levels are available, controlled by the `DEBUG` variable:

```bash
make DEBUG=1 rtl-simple   # Level 1 — critical events (exceptions, branches, …)
make DEBUG=2 rtl-simple   # Level 2 — verbose pipeline/AXI detail + level 1
```

Level 2 additionally supports **group filtering** via a 32-bit `DEBUG_GROUP` bitmask
(default `0xFFFFFFFF` — all groups). Only groups whose corresponding bit is set produce
output:

| Bit | Hex | Group | Description |
|-----|-----|-------|-------------|
| 0 | `0x00001` | `FETCH` | Instruction fetch, PC tracking, instruction buffer |
| 1 | `0x00002` | `PIPE` | Pipeline stalls and stage flushes |
| 2 | `0x00004` | `EX` | Execute stage (ALU, branch, forwarding) |
| 3 | `0x00008` | `MEM` | Memory stage (load/store, AMO, LR/SC) |
| 4 | `0x00010` | `CSR` | CSR read/write |
| 5 | `0x00020` | `IRQ` | Interrupts and exceptions |
| 6 | `0x00040` | `WFI` | WFI / power management |
| 7 | `0x00080` | `AXI` | AXI bus transactions (core side) |
| 8 | `0x00100` | `REG` | Register file write-back and forwarding |
| 9 | `0x00200` | `JTAG` | JTAG / TAP / cJTAG bridge |
| 10 | `0x00400` | `CLINT` | CLINT timer/software interrupt |
| 11 | `0x00800` | `GPIO` | GPIO peripheral |
| 12 | `0x01000` | `I2C` | I2C peripheral |
| 13 | `0x02000` | `ICACHE` | I-cache state machine |
| 14 | `0x04000` | `ALU` | ALU operations |
| 15 | `0x08000` | `SB` | Store buffer |
| 16 | `0x10000` | `AXIMEM` | AXI memory slave (testbench) |
| 17 | `0x20000` | `DTM` | DTM debug module (DM registers, commands, SBA) |
| 18 | `0x40000` | `DCACHE` | D-cache state machine |

Examples:
```bash
make DEBUG=2 DEBUG_GROUP=0x40    rtl-wfi    # WFI only
make DEBUG=2 DEBUG_GROUP=0x60    rtl-wfi    # WFI + IRQ
make DEBUG=2 DEBUG_GROUP=0x10000 rtl-hello  # AXI memory slave only
make DEBUG=2 DEBUG_GROUP=0x20200 rtl-hello  # DTM + JTAG
make DEBUG=2 DEBUG_GROUP=0x400   rtl-timer  # CLINT only
make DEBUG=2 DEBUG_GROUP=0x42000 rtl-dcache # DCACHE + ICACHE
```

#### Assertion Control
SystemVerilog assertions are enabled by default to verify design integrity. To disable assertions for faster simulation:

```bash
# Disable assertions (not recommended for debugging)
make ASSERT=0 rtl-simple
```

Assertions verify:
- **Core Pipeline**: PC alignment, register protection, data forwarding, hazard detection
- **Instruction Buffer**: FIFO integrity, overflow/underflow protection
- **Store Buffer**: State machine correctness, count consistency
- **SoC Integration**: AXI protocol compliance, memory interface correctness
- **X/Z Detection**: Unknown values on critical control signals

When an assertion fails, the simulator displays the error location and description.

### Running Simulations

#### Run Test Programs (Recommended)
```bash
make rtl-<test>    # Run test with RTL simulator
make sim-<test>    # Run test with software simulator
```
See [Testing](#testing) section for available tests and details.

#### Run RTL Simulation with ELF File
```bash
./build/kv32soc program.elf
```
- Generates `kv32soc.vcd` waveform file
- Outputs console text via magic address writes
- Exits when program writes to EXIT_MAGIC_ADDR

#### Run Software Simulator

```bash
Usage: ./kv32sim [options] <elf_file>
Options:
  --isa=<name>         Specify ISA (default: rv32ima_zicsr)
                       Supported: rv32ima, rv32ima_zicsr
  --trace              Enable Spike-format trace logging (alias for --log-commits)
  --log-commits        Enable Spike-format trace logging
  --rtl-trace          Enable RTL-format trace logging
  --log=<file>         Specify trace log output file (default: sim_trace.txt)
  +signature=<file>    Write signature to file (RISCOF compatibility)
  +signature-granularity=<n>  Signature granularity in bytes (1, 2, or 4, default: 4)
  -m<base>:<size>      Specify memory range (e.g., -m0x80000000:0x200000)
                       Default: -m0x80000000:0x200000 (2MB at 0x80000000)
  --instructions=<n>   Limit execution to N instructions (0 = no limit)
  --gdb                Enable GDB stub for remote debugging
  --gdb-port=<port>    Specify GDB port (default: 3333)
Examples:
  ./kv32sim program.elf
  ./kv32sim --log-commits --log=output.log program.elf
  ./kv32sim --rtl-trace --log=rtl_trace.txt program.elf
  ./kv32sim --log-commits -m0x80000000:0x200000 program.elf
  ./kv32sim --gdb --gdb-port=3333 program.elf
  ./kv32sim +signature=output.sig +signature-granularity=4 test.elf
```

#### View Waveforms
```bash
gtkwave kv32soc.vcd
```

## ELF File Loading

Both simulators support loading ELF files directly:

1. **RTL Simulator**: Uses DPI-C to load ELF segments into memory before simulation
2. **Software Simulator**: Parses ELF and loads into internal memory array

Example program usage:
```c
#include "kv_platform.h"   /* sw/include/kv_platform.h */

int main() {
    kv_magic_putc('H');
    kv_magic_putc('e');
    kv_magic_putc('l');
    kv_magic_putc('o');
    kv_magic_putc('\n');
    kv_magic_exit(0);
    return 0;
}
```

## Pipeline Architecture

### 5-Stage Pipeline
1. **IF (Instruction Fetch)**: Fetches instructions from memory via AXI
2. **ID (Instruction Decode)**: Decodes instructions, reads register file
3. **EX (Execute)**: ALU operations, branch resolution, CSR access
4. **MEM (Memory)**: Data memory access via AXI
5. **WB (Write Back)**: Writes results to register file

### Hazard Resolution
- **Data Hazards**: Forwarding from EX/MEM/WB stages
- **Load-Use Hazards**: Pipeline stall (1 cycle)
- **Control Hazards**: Branch prediction (not-taken), flush on mispredict
- **Structural Hazards**: Instruction/data arbitration via axi_arbiter

## AXI4-Lite Interface

The SoC uses AXI4-Lite for all peripheral accesses. The instruction-fetch and data-memory paths additionally use AXI4 burst transfers (INCR/WRAP) for cache-line fills and evictions.

- **Address Width**: 32 bits
- **Data Width**: 32 bits
- **Byte Strobes**: 4 bits (byte/halfword/word access)
- **Response Codes**: OKAY, DECERR (unmapped addresses), SLVERR (non-cacheable region in testbench)
- **Topology**: single master → 11 slaves via `axi_xbar`
- **Bursts**: INCR/WRAP supported on the instruction port (I-cache line fills) and data port (D-cache critical-word-first fills and dirty-line evictions)

## Development

### Environment Configuration
Edit `env.config` to set tool paths:
```bash
RISCV_PREFIX=/path/to/riscv-toolchain/bin/riscv32-unknown-elf-
VERILATOR=/usr/local/bin/verilator
```
## Testing

### Test Programs Structure

The `sw/` directory contains example test programs organized by folder:
- **common/**: Shared code, headers, and linker scripts
- **Other folders**: Each folder contains a specific test program

### Running Test Programs

Use the following make targets to run tests:

#### RTL Simulation
```bash
make rtl-<test>    # Run <test> with Verilator RTL simulation
```
Example:
```bash
make rtl-hello     # Run hello test with RTL simulator
make rtl-timer     # Run timer test with RTL simulator
```

#### Software Simulation
```bash
make sim-<test>    # Run <test> with fast software simulator
```
Example:
```bash
make sim-hello     # Run hello test with software simulator
make sim-timer     # Run timer test with software simulator
```

### Available Tests

Check the `sw/` directory for available test programs. Each subdirectory (except `common/`) represents a test that can be run with the above commands.

### Compiling Programs Manually

If you want to compile a program manually:
```bash
riscv32-unknown-elf-gcc -march=rv32ima_zicsr -mabi=ilp32 \
    -nostartfiles -T linker.ld -o program.elf program.c
```

**Important Notes:**
- The `_zicsr` extension is required for CSR instructions (mandatory in newer GCC versions)
- Floating-point `printf` support requires properly configured `libgcc` for RV32IMAC
- Current common library provides: `puts()`, `putc()`, and basic console I/O via `_write()`
- For printf functionality, include `printf.c` from common/ and ensure `-lgcc` is added to link against compiler runtime

### Generated Files

When building test programs with `make <test>` or `make rtl-<test>`, the following files are generated in `build/`:
- **<test>.elf**: Executable ELF file
- **<test>.dis**: Disassembly listing (objdump output)
- **<test>.readelf**: ELF file information
- **kv32soc.vcd**: Waveform file (RTL simulation only)

### Debugging with GDB (Software Simulator)
```bash
# Terminal 1: Start simulator with GDB server
./build/kv32sim --gdb --gdb-port=3333 program.elf

# Terminal 2: Connect GDB
riscv32-unknown-elf-gdb program.elf
(gdb) target remote :3333
(gdb) break main
(gdb) continue
```

## Documentation

Detailed documentation is available in the [docs/](docs/) directory:

- **[Pipeline Architecture](docs/pipeline_architecture.md)**: 5-stage pipeline, data forwarding, hazard handling, pipeline registers, performance characteristics
- **[Cache Architecture](docs/cache_architecture.md)**: I-cache and D-cache design — parameters, address decomposition, state machines, CMO, PMA, FENCE.I
- **[Cache Benchmark Report](docs/cache_benchmark_report.md)**: I-cache + D-cache hit-rate and CPI measurements across SRAM/DDR4 memory types
- **[JTAG/cJTAG Integration](docs/jtag_cjtag_integration.md)**: Debug interface architecture, DTM register map, abstract commands, SBA, OpenOCD/GDB setup
- **[SoC Datasheet](docs/kv32_soc_datasheet.adoc)**: Full register maps, peripheral descriptions, SoC parameters
- **[SDK API Reference](docs/sdk_api_reference.adoc)**: Software driver API for all on-chip peripherals

Additional reference material:
- Source code comments in all RTL files
- `scripts/README.md` — trace comparison and analysis tools
- `fpga/README.md` — FPGA build instructions (Xilinx Vivado)
- `syn/README.md` — ASIC synthesis flows (Yosys, DC, Genus)
- `sim/README.md` — software simulator build and usage
- `verif/kv32-dv/README.md` — riscv-dv random instruction generation
- `verif/riscof_targets/README.md` — RISCOF architecture test setup

## Synthesis

ASIC synthesis scripts are in [`syn/`](syn/). Three flows are supported:

| Tool | Script | Description |
|------|--------|-----------|
| Yosys | `syn/scripts/yosys/synthesis.tcl` | Open-source synthesis + formal equivalence checking |
| Synopsys DC | `syn/scripts/dc/synthesis.tcl` | Design Compiler flow |
| Cadence Genus | `syn/scripts/genus/synthesis.tcl` | Genus flow |

See [`syn/README.md`](syn/README.md) for setup instructions and PDK configuration.

For FPGA targets, see [`fpga/README.md`](fpga/README.md) (Xilinx Vivado, `fpga_top.sv`).

## Performance

- **RTL Simulation**: ~100–500 Hz (depends on host and enabled features)
- **Software Simulator**: ~1–10 MHz
- **Target FPGA Frequency**: 50–100 MHz

## Known Limitations

- Single-issue, in-order pipeline; no out-of-order or superscalar execution
- No MMU / virtual memory
- No floating-point unit (FPU)
- CSR support limited to M-mode

## License

See LICENSE file for details.

## References

- [RISC-V Instruction Set Manual](https://riscv.org/technical/specifications/)
- [RISC-V Privileged Architecture](https://riscv.org/technical/specifications/)
- [Verilator User Guide](https://verilator.org/guide/latest/)
- [AXI4-Lite Protocol Specification](https://developer.arm.com/documentation/)

## Contributing

Contributions are welcome! Please ensure:
1. Code follows existing style
2. All tests pass
3. Documentation is updated
4. Commit messages are descriptive

## Authors

See git history for contributors.


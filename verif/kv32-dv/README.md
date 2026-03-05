# KV32 riscv-dv Integration

Random instruction verification for the KV32 RV32IMAC processor using
[Google riscv-dv](https://github.com/chipsalliance/riscv-dv).

## Overview

This directory contains the KV32-specific target configuration and scripts
to run riscv-dv's random instruction generator against the KV32 RTL and
reference ISS (Spike or kv32sim).  **The upstream riscv-dv repository is
cloned at setup time and left unmodified.**

### Directory Structure

```
verif/kv32-dv/
├── Makefile                    # Top-level Makefile
├── README.md                   # This file
├── riscv-dv/                   # Google riscv-dv clone (created by `make setup`)
├── target/kv32/                # KV32 target configuration
│   ├── riscv_core_setting.sv   # Core capabilities (ISA, CSRs, modes)
│   ├── testlist.yaml           # Test definitions
│   ├── simulator.yaml          # Simulator tool commands
│   ├── link.ld                 # Linker script for generated tests
│   └── kv32_asm_program_gen.sv # Custom program generator (optional)
├── scripts/
│   ├── run.sh                  # End-to-end run script
│   ├── spike2trace.py          # Spike log → riscv-dv CSV
│   └── kv32sim2trace.py        # kv32sim log → riscv-dv CSV
└── out/                        # Generated output (created at runtime)
    ├── gen/                    # Generated assembly
    ├── bin/                    # Compiled ELF/BIN
    ├── iss/                    # ISS execution logs & traces
    └── rtl/                    # RTL simulation logs
```

## Quick Start

```bash
# 1. One-time setup: clone riscv-dv and install Python deps
make setup

# 2. Run a specific test
make run TEST=kv32_arithmetic_basic

# 3. Run all tests
make run

# 4. Generate assembly only (inspect before running)
make gen TEST=kv32_rand_instr ITERATIONS=1 SEED=42
```

## Requirements

- **Python 3.6+** with `pip`
- **RISC-V GCC** toolchain (`RISCV_PREFIX` in `env.config`)
- **Spike** ISA simulator (`SPIKE` in `env.config`)
- **Verilator** (for RTL simulation)
- **Git** (to clone riscv-dv)

## Available Tests

| Test Name | Description |
|---|---|
| `kv32_arithmetic_basic` | Basic arithmetic and logic (I-type) |
| `kv32_mul_div` | M-extension: MUL, DIV, REM |
| `kv32_amo` | A-extension: LR/SC, AMO operations |
| `kv32_branch_jump` | Branch and jump instruction coverage |
| `kv32_load_store` | Load/store with various widths |
| `kv32_csr` | CSR read/write operations |
| `kv32_rand_instr` | Fully random mixed instructions |
| `kv32_machine_mode_trap` | Trap handling: ECALL, EBREAK, MRET |
| `kv32_hint_nop` | HINT and NOP sequences |
| `kv32_rand_stress` | Large random program (10K instructions) |

## Makefile Targets

| Target | Description |
|---|---|
| `make setup` | Clone riscv-dv, create venv, install deps |
| `make run` | Full flow: generate → compile → ISS → RTL → compare |
| `make gen` | Generate random assembly only |
| `make compile` | Generate + compile (no execution) |
| `make run-iss` | Generate, compile, run on ISS only |
| `make run-rtl` | Full flow including RTL simulation |
| `make clean` | Remove generated output |
| `make clean-all` | Remove output + riscv-dv clone + venv |
| `make help` | Show help |

## Options

| Variable | Default | Description |
|---|---|---|
| `TEST` | (all) | Run specific test from `testlist.yaml` |
| `ITERATIONS` | (from yaml) | Override iteration count |
| `SEED` | (random) | Random seed for reproducibility |
| `ISS` | `spike` | ISS for comparison (`spike` or `kv32sim`) |
| `MAX_CYCLES` | `10000000` | RTL simulation cycle timeout |

## How It Works

1. **Generate**: riscv-dv produces random RISC-V assembly programs constrained
   by the KV32 core settings in `riscv_core_setting.sv` (RV32IMAC, M-mode only).

2. **Compile**: The generated `.S` files are compiled with the project's GCC
   toolchain using the KV32-specific linker script (`link.ld`), which places
   code at `0x80000000`.

3. **ISS Run**: The compiled ELF is run on Spike (or kv32sim) to get a reference
   instruction trace.

4. **RTL Run**: The same ELF is loaded into the Verilator RTL simulation of the
   KV32 SoC.

5. **Compare**: Instruction traces from ISS and RTL are compared to find
   mismatches which indicate RTL bugs.

## KV32 Core Configuration

The KV32 is configured for riscv-dv as:

| Setting | Value |
|---|---|
| XLEN | 32 |
| ISA | RV32IMAC |
| Privilege Modes | Machine (M) only |
| PMP Regions | 0 |
| Boot Address | `0x80000000` |
| RAM Size | 2 MB |
| Stack | Top of RAM (`0x801FFFFF`) |
| Exit Mechanism | Write to `0xFFFFFFF0` |

## Customisation

### Adding New Tests

Add entries to `target/kv32/testlist.yaml`.  Each entry specifies:
- `test`: unique name
- `gen_opts`: riscv-dv generator options (instruction count, features)
- `iterations`: how many random programs to generate
- `gen_test`: riscv-dv test class

### Modifying Core Settings

Edit `target/kv32/riscv_core_setting.sv` to reflect any changes to the
KV32 core (e.g., adding new extensions, CSRs, or changing privilege modes).

### Using Without Make

You can also run the scripts directly:

```bash
# Activate the virtual environment
source .venv/bin/activate

# Run riscv-dv directly
python3 riscv-dv/run.py \
  --target kv32 \
  --custom_target target/kv32 \
  --simulator pyflow \
  --mabi ilp32 \
  --isa rv32ima \
  --test kv32_arithmetic_basic \
  --output out/gen \
  --steps gen

# Or use the wrapper script
./scripts/run.sh --test kv32_arithmetic_basic --seed 42
```

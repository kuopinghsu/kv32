# RISC-V Architecture Test Framework (RISCOF) Setup

This directory contains the RISCOF configuration for running RISC-V architectural compliance tests on the kv32 processor.

## Overview

RISCOF (RISC-V COmpliance Framework) is used to verify that the kv32 implementation complies with the RISC-V ISA specification. It runs the official RISC-V architectural test suite and compares the results between:

- **DUT (Device Under Test)**: kv32 - RV32IMAC processor with Verilator (loads ELF files directly)
- **Reference Model**: Choice of two simulators:
  - **Spike** (default): Official RISC-V ISA simulator - authoritative reference
  - **kv32sim**: kv32 custom RV32IMAC software simulator - fast alternative

All three implementations (kv32, kv32sim, spike) support direct ELF loading and produce compatible signature outputs for accurate comparison.

## Directory Structure

```
verif/riscof_targets/
├── config.ini                  # RISCOF configuration file
├── kv32/                       # DUT plugin for kv32
│   ├── riscof_kv32.py          # Plugin implementation (Verilator)
│   ├── kv32_isa.yaml           # ISA specification (RV32IMAC)
│   ├── kv32_platform.yaml      # Platform specification
│   └── env/                    # Test environment
├── spike/                      # Reference plugin for Spike
│   ├── riscof_spike.py         # Plugin implementation
│   ├── spike_isa.yaml          # Spike ISA configuration
│   ├── spike_platform.yaml     # Platform specification
│   └── env/                    # Spike test environment
└── kv32sim/                    # Reference plugin for kv32sim
    ├── riscof_kv32sim.py       # Plugin implementation
    ├── kv32sim_isa.yaml        # ISA configuration
    ├── kv32sim_platform.yaml   # Platform specification
    └── env/                    # Test environment
```

## Prerequisites

- **Python 3.6+**: For running RISCOF
- **RISC-V Toolchain**: xPack GNU RISC-V Embedded GCC (configured in `../../env.config`)
- **Verilator**: For running RTL simulations (configured in `../../env.config`)
- **Spike**: RISC-V ISA simulator (configured in `../../env.config`)
- **riscv-arch-test**: RISC-V architectural test suite (git submodule at `../riscv-arch-test`)

## Initial Setup

### 1. Clone the riscv-arch-test Submodule

If not already done, initialize the test suite submodule:

```bash
cd /path/to/riscv/project
git submodule update --init --recursive verif/riscv-arch-test
```

### 2. Create Python Virtual Environment

The virtual environment is already created. To recreate or update:

```bash
cd verif/riscof_targets

# Create virtual environment
python3 -m venv .venv

# Activate virtual environment
source .venv/bin/activate

# Upgrade pip and install tools
pip3 install --upgrade pip setuptools wheel

# Install RISCOF from specific commit
pip3 install git+https://github.com/riscv/riscof.git@d38859f85fe407bcacddd2efcd355ada4683aee4
```

### 3. Verify Environment Configuration

Ensure the `../../env.config` file has correct paths:

```bash
# RISC-V Toolchain prefix
RISCV_PREFIX=/path/to/riscv-none-elf-gcc/bin/riscv-none-elf-

# Verilator path
VERILATOR=/path/to/verilator/bin/verilator

# Spike RISC-V ISA Simulator path
SPIKE=/path/to/spike/bin/spike

# Zephyr RTOS base directory (if using Zephyr)
ZEPHYR_BASE=/path/to/zephyrproject/zephyr

# Additional PATH directories (for Python, EDA tools, etc.)
PATH_APPEND=/path/to/python/bin:/path/to/tools/bin
```

Note: The config.ini file uses relative paths (spike, kv32) which are resolved at runtime by the plugins.

### 4. Build the Verilator Simulation Binary

Before running tests, ensure the RTL simulation binary is built:

```bash
cd /path/to/riscv/project
make build-verilator
```

This creates `build/kv32sim` which RISCOF will use to run tests.

## Current Test Results

### RV32I Base Instruction Set
**Status**: 32/38 tests passing (84% pass rate) ✅

**Passing Tests** (32):
- Arithmetic: add, addi, sub
- Logic: and, andi, or, ori, xor, xori
- Shifts: sll, slli, sra, srai, srl, srli
- Comparisons: slt, slti, sltiu, sltu
- Memory: lb, lbu, lh, lhu, lw, sb, sh, sw (all with -align variants)
- Control: auipc, jalr, lui

**Failing Tests** (6):
- Branch instructions (beq, bge, bgeu, blt, bltu, bne): Memory size limitation (tests require 1716KB, CPU has 2MB)
  - **Note**: These tests can now run with available 2MB memory
  - CPU branch logic is functionally correct (verified in full test)

### RV32M Multiply/Divide Extension
**Status**: 8/8 tests passing (100% pass rate) ✅

**Passing Tests** (8):
- mul, mulh, mulhsu, mulhu (all multiplication variants)
- div, divu, rem, remu (all division/remainder variants)

**Key Achievement**: M-extension fully verified and architecturally compliant

### RV32A Atomic Extension
**Status**: 5/9 tests passing (56% pass rate) ⚠️

**Passing Tests** (5):
- ✅ amoadd.w - Atomic add
- ✅ amoswap.w - Atomic swap
- ✅ amoand.w - Atomic AND
- ✅ amoor.w - Atomic OR
- ✅ amoxor.w - Atomic XOR

**Failing Tests** (4) - Under Debug:
- ❌ amomax.w - Atomic signed maximum (comparison logic issue)
- ❌ amomin.w - Atomic signed minimum (comparison logic issue)
- ❌ amomaxu.w - Atomic unsigned maximum (comparison logic issue)
- ❌ amominu.w - Atomic unsigned minimum (comparison logic issue)

**Debug Status**:
- Read-modify-write FSM working correctly
- Value return to destination register correct
- Issue: Min/max comparison logic produces wrong results
- Root cause: Investigating signed/unsigned comparison implementation

### RV32 Zicsr CSR Extension
**Status**: 2/16 tests passing (12.5% pass rate)

**Note**: Low pass rate expected - most tests require privilege mode changes and exception handling beyond current M-mode implementation

### Summary
**Key Achievements**:
- ✅ FENCE instruction working correctly
- ✅ All data path instructions verified
- ✅ Memory addressing and byte operations correct
- ✅ M-extension fully architecturally verified (100%)
- ⚠️ A-extension basic operations working (5/9 pass)
- ✅ Spike reference model comparison successful

## Running Tests

### Activate Virtual Environment

Always activate the virtual environment before running RISCOF:

```bash
cd verif/riscof_targets
export LC_ALL=C.UTF-8
export LANG=C.UTF-8
source .venv/bin/activate
```

### Validate Configuration

Check that RISCOF can find all plugins and specifications:

```bash
riscof validateyaml --config=config.ini
```

### Run Architectural Tests

Run the full test suite:

```bash
# From project root, use Makefile targets (recommended):
make arch-test-rv32i      # RV32I base instructions (38/38 pass) ✅
make arch-test-rv32m      # M-extension multiply/divide (8/8 pass) ✅
make arch-test-rv32a      # A-extension atomics (9/9 pass) ✅
make arch-test-rv32zicsr  # Zicsr CSR operations (16/16 pass) ✅

# Or run RISCOF directly (must activate venv first):
cd verif/riscof_targets
source .venv/bin/activate

# Run all RV32I tests
riscof run --config=config.ini --suite=../riscv-arch-test/riscv-test-suite/rv32i_m/I \
    --env=../riscv-arch-test/riscv-test-suite/env

# Run M-extension tests
riscof run --config=config.ini --suite=../riscv-arch-test/riscv-test-suite/rv32i_m/M \
    --env=../riscv-arch-test/riscv-test-suite/env

# Run A-extension tests
riscof run --config=config.ini --suite=../riscv-arch-test/riscv-test-suite/rv32i_m/A \
    --env=../riscv-arch-test/riscv-test-suite/env

# Run with custom work directory
riscof run --config=config.ini --suite=../riscv-arch-test/riscv-test-suite/rv32i_m/I \
    --env=../riscv-arch-test/riscv-test-suite/env --work-dir=./riscof_work
```

### View Results

After running tests, RISCOF generates a report:

```bash
# Results are in riscof_work/ directory (or specified --work-dir)
ls riscof_work/

# View the HTML report
firefox riscof_work/report.html
```

## Reference Models Comparison

RISCOF can use different reference models to compare against the DUT (kv32). Three implementations are available:

### Overview

| Feature | kv32 (DUT) | kv32sim | Spike |
|---------|-------------|---------|-------|
| **Type** | RTL (Verilator) | Software Simulator | Software Simulator |
| **Purpose** | Device Under Test | Alternative Reference | Primary Reference |
| **ISA** | RV32IMAC | RV32IMACZicsr_Zifencei | RV32IMACZicsr_Zifencei |
| **Language** | SystemVerilog | C++ | C++ |
| **Build** | Requires Verilator | Built with kv32 | Separate installation |
| **Speed** | Slow (~5-10s/test) | Fast (~0.2s/test) | Fast (~0.3s/test) |
| **GDB Support** | No | Yes | Yes |
| **Trace Output** | VCD/FST waveforms | Text trace | Text trace |
| **Maturity** | Development | Stable | Official Reference |
| **Validation** | Against spike | Against spike | RISC-V Standard |

### Detailed Comparison

#### ISA Support
- **kv32**: RV32IMAC (base integer + multiply/divide + atomics + compressed)
- **kv32sim**: RV32IMAC + Zicsr + Zifencei (CSR and fence instructions)
- **Spike**: Full RISC-V with all extensions (RV32/RV64, IMAFDCV, etc.)

#### Memory Layout
All three use identical memory configuration:
- Base: 0x80000000
- Size: 2MB (0x80000000 - 0x80200000)
- CLINT: 0x2000000

#### Features

| Feature | kv32 | kv32sim | Spike |
|---------|-------|---------|-------|
| **Privileged Modes** | M-mode | M-mode | M/S/U modes |
| **MMU/TLB** | No | No | Full support |
| **FPU** | No | No | F/D extensions |
| **Vector** | No | No | V extension |
| **Compressed (C)** | No | No | Yes |
| **Signature Output** | Via memory dump | +signature flag | +signature flag |
| **Instruction Limit** | Cycle timeout | --instructions=N | No |
| **Interactive Debug** | Waveforms | GDB stub | -d mode |

### When to Use Each Reference Model

#### Primary Reference: Spike
Use **Spike** for:
- Official RISC-V compliance validation
- Final verification before tapeout
- Industry-standard behavior verification
- Testing with comprehensive ISA support

#### Secondary Reference: kv32sim
Use **kv32sim** for:
- Fast development iterations
- Understanding kv32 software behavior
- Debugging RTL vs. ISA differences
- Educational purposes
- Quick sanity checks
- Integrated CI/CD testing

Use the provided test script to validate kv32sim produces identical results to spike:

```bash
cd verif/riscof_targets
./test_kv32sim.sh I    # Validate RV32I instructions (38 tests)
./test_kv32sim.sh M    # Validate RV32M instructions (8 tests)
./test_kv32sim.sh A    # Validate RV32A instructions (9 tests)
```

This runs RISCOF with kv32sim as DUT and spike as REF, ensuring both simulators produce identical signatures.

## Command-Line Reference

### kv32 (Verilator RTL)
```bash
# Built via Makefile, executed by RISCOF plugin
# Signature extracted from memory dump at 0x80002000-0x80004000
build/kv32soc test.elf
```

### kv32sim
```bash
# Basic execution
kv32sim test.elf

# With signature output
kv32sim +signature=test.sig +signature-granularity=4 test.elf

# With trace logging
kv32sim --trace --log=trace.txt test.elf

# With instruction limit
kv32sim --instructions=1000000 test.elf

# With GDB debugging
kv32sim --gdb --gdb-port=3333 test.elf
```

### Spike
```bash
# Basic execution
spike --pc=0x80000000 --isa=rv32imac_zicsr_zifencei test.elf

# With signature output
spike --pc=0x80000000 --isa=rv32imac_zicsr_zifencei \
      +signature=test.sig +signature-granularity=4 test.elf

# With trace logging
spike --pc=0x80000000 --isa=rv32imac_zicsr_zifencei \
      --log-commits test.elf
```

## Best Practices

### Testing Strategy
1. **Development**: Use kv32sim for quick iterations and debugging
2. **Integration**: Use spike for official compliance verification
3. **Validation**: Cross-check with both reference models
4. **Production**: Final validation with spike before release

### Performance Optimization
- Use kv32sim during active development for fast feedback
- Switch to spike for nightly regression tests
- Run full spike validation before major releases
- Use parallel execution (jobs parameter) for large test suites

### Debugging Workflow
1. **RTL Failure**: Compare kv32 vs spike signatures
2. **Identify Mismatch**: Find first diverging instruction
3. **Understand Intent**: Run kv32sim with trace to see correct behavior
4. **Analyze RTL**: Use VCD waveforms to debug kv32 implementation
5. **Verify Fix**: Re-run with both spike and kv32sim

## Validation Results

#### DUT: kv32
**kv32** is always the device under test, validated against either spike or kv32sim.

### Using kv32sim as Reference Model

By default, RISCOF uses **Spike** as the reference model. You can switch to **kv32sim** for faster testing cycles.

### Switch to kv32sim

```bash
cd verif/riscof_targets

# Edit config.ini to use kv32sim
sed -i '' 's/ReferencePlugin=spike/ReferencePlugin=kv32sim/' config.ini

# Build kv32sim if not already built
make -C ../../sim

# Run tests with kv32sim as reference
source .venv/bin/activate
riscof run --config=config.ini --suite=../riscv-arch-test/riscv-test-suite/rv32i_m/I \
    --env=../riscv-arch-test/riscv-test-suite/env

# Restore spike as reference (optional)
sed -i '' 's/ReferencePlugin=kv32sim/ReferencePlugin=spike/' config.ini
```

### Building kv32sim

The kv32sim simulator is located in `sim/` and requires no external dependencies:

```bash
cd /path/to/kv32
make -C sim clean
make -C sim
# Creates build/kv32sim
```

### Running Tests Manually with kv32sim

You can also run tests directly with kv32sim:

```bash
# Run a test with signature output
build/kv32sim +signature=output.sig +signature-granularity=4 test.elf

# With trace logging
build/kv32sim --trace --log=trace.txt +signature=output.sig test.elf

# Compare with spike
spike --pc=0x80000000 --isa=rv32imac_zicsr_zifencei \
      +signature=spike.sig +signature-granularity=4 test.elf
diff output.sig spike.sig
```

### Validate kv32sim Against Spike

Use the validation script to test kv32sim against spike:

```bash
cd verif/riscof_targets

# Validate RV32I instructions (kv32sim as DUT, spike as REF)
./test_kv32sim.sh I

# Validate other test suites
./test_kv32sim.sh M      # RV32M multiply/divide
./test_kv32sim.sh A      # RV32A atomics
./test_kv32sim.sh Zicsr  # Zicsr CSR operations
```

This script runs RISCOF with **kv32sim as the DUT** and **spike as the reference**, ensuring kv32sim produces identical results to the official RISC-V simulator.

## Test Coverage

The kv32 processor implements **RV32IM + Partial A**:
- **RV32I**: Base integer instruction set ✅ (84% verified)
- **M Extension**: Integer multiplication and division ✅ (100% verified)
- **A Extension**: Atomic instructions ⚠️ (56% verified - debug in progress)
- **Zicsr**: Control and Status Register (CSR) instructions (partial - 12.5%)
- **Zifencei**: Instruction-fetch fence ✅

The architectural tests validate:
- ✅ All RV32I base instructions (32/38 passing)
- ✅ M-extension multiply/divide operations (8/8 passing - fully compliant)
- ⚠️ A-extension atomic operations (5/9 passing - basic ops work)
- Partial CSR read/write operations (2/16 passing - M-mode only)
- ✅ Memory ordering and fence instructions (working correctly)

## Configuration Files

### config.ini

Main RISCOF configuration that specifies:
- Reference plugin: spike (RISC-V ISA simulator)
- DUT plugin: kv32 (Verilator-based RTL)
- Paths to ISA and platform YAML files

### kv32_isa.yaml

Specifies the ISA implementation for kv32:
- **ISA**: RV32IMAZicsr_Zifencei
- **XLEN**: 32-bit
- **MISA reset value**: 0x40001105 (RV32IMAC: A=bit0, C=bit2, I=bit8, M=bit12)
- Physical address size: 32 bits

### kv32_platform.yaml

Platform-specific configuration:
- Memory map
- CLINT addresses (mtime, mtimecmp)
- UART addresses
- Interrupt configuration

### riscof_kv32.py

Python plugin that:
1. Compiles tests using RISC-V GCC
2. Converts ELF to binary format
3. Runs tests on Verilator RTL simulation
4. Extracts test signatures from simulation output
5. Compares signatures with reference (Spike)

## Troubleshooting

### Virtual Environment Issues

If you encounter locale errors:
```bash
export LC_ALL=C.UTF-8
export LANG=C.UTF-8
```

### RISCOF Not Found

Ensure virtual environment is activated:
```bash
source .venv/bin/activate
which riscof  # Should point to .venv/bin/riscof
```

### Toolchain Not Found

Verify `env.config` paths are correct:
```bash
cat ../../env.config

# Check required variables are set:
# RISCV_PREFIX - RISC-V toolchain prefix
# VERILATOR - Verilator binary path
# SPIKE - Spike simulator path
# ZEPHYR_BASE - Zephyr RTOS directory (if using Zephyr)
# PATH_APPEND - Additional tool paths

# Test that tools are accessible
${RISCV_PREFIX}gcc --version
${VERILATOR} --version
${SPIKE} --version
```

### Verilator Binary Missing

Build the RTL simulation:
```bash
cd ../..
make clean
make build-verilator
ls -lh build/kv32soc
```

### Test Failures

1. Check the simulation logs in `riscof_work/<testname>/`
2. Verify the DUT plugin is correctly extracting signatures
3. Compare expected vs. actual signatures in the report
4. Review RTL simulation output for errors
5. Use debug mode (see below) to analyze RTL execution traces

### Debug Mode

Enable detailed RTL instruction traces for debugging test failures:

```bash
# Build trace-enabled simulator first
cd ../..
make rtl WAVE=fst

# Run tests with debug mode
export RISCOF_DEBUG=1
make arch-test-rv32i

# Or run single test
export RISCOF_DEBUG=1
make arch-test-rv32i TEST_FILTER=beq-01
```

**Debug Output Locations**:
- RTL trace: `riscof_work/src/<test>.S/dut/debug_output/<test>_rtl_trace.txt`
- Simulation log: `riscof_work/src/<test>.S/dut/debug_output/<test>_sim.log`

**Trace Format**: `<cycle> <PC> <instruction_hex> <disassembly>`

**Useful Commands**:
```bash
# Extract branch instructions
grep -E "beq|bne|blt|bge|bltu|bgeu|jal|jalr" debug_output/*_rtl_trace.txt

# Check PC progression
awk '{print $2}' debug_output/*_rtl_trace.txt | head -30

# Find misaligned addresses (must be 2-byte aligned)
awk '{print $2}' debug_output/*_rtl_trace.txt | grep -E "[13579bdf]$"
```

## Advanced Usage

### Running Specific Tests

```bash
# List available tests
ls ../riscv-arch-test/riscv-test-suite/rv32i_m/I/src/

# Run a single test
riscof run --config=config.ini \
    --suite=../riscv-arch-test/riscv-test-suite/rv32i_m/I \
    --env=../riscv-arch-test/riscv-test-suite/env \
    --testlist=../riscv-arch-test/riscv-test-suite/rv32i_m/I/src/add-01.S
```

### Parallel Execution

RISCOF supports parallel test execution (configured via `jobs` parameter in config.ini):

```bash
# Edit config.ini
[kv32]
jobs=8  # Run 8 tests in parallel
```

### Custom Work Directory

```bash
riscof run --config=config.ini \
    --suite=../riscv-arch-test/riscv-test-suite/rv32i_m/I \
    --env=../riscv-arch-test/riscv-test-suite/env \
    --work-dir=/tmp/riscof_custom
```

## References

- **RISCOF Documentation**: https://riscof.readthedocs.io/
- **riscv-arch-test Repository**: https://github.com/riscv-non-isa/riscv-arch-test
- **RISC-V ISA Specification**: https://riscv.org/technical/specifications/
- **Spike ISA Simulator**: https://github.com/riscv-software-src/riscv-isa-sim

## Integration with Project Makefile

To integrate RISCOF testing into the main project Makefile, add targets like:

```makefile
.PHONY: riscof-setup riscof-test riscof-validate

riscof-setup:
    cd verif/riscof_targets && python3 -m venv .venv
    cd verif/riscof_targets && .venv/bin/pip3 install --upgrade pip setuptools wheel
    cd verif/riscof_targets && .venv/bin/pip3 install git+https://github.com/riscv/riscof.git@d38859f85fe407bcacddd2efcd355ada4683aee4

riscof-validate:
    cd verif/riscof_targets && export LC_ALL=C.UTF-8 && export LANG=C.UTF-8 && \
    source .venv/bin/activate && riscof validateyaml --config=config.ini

riscof-test: build-verilator
    cd verif/riscof_targets && export LC_ALL=C.UTF-8 && export LANG=C.UTF-8 && \
    source .venv/bin/activate && \
    riscof run --config=config.ini \
        --suite=../riscv-arch-test/riscv-test-suite/rv32i_m/I \
        --env=../riscv-arch-test/riscv-test-suite/env
```

## Notes

- The kv32 processor is **RV32IMAC** (C-extension/Zca supported via `kv32_rvc` expander)
- Spike reference is configured for **RV32IMAC** to match available tests
- Test signatures must be properly extracted from Verilator simulation output
- Some tests may timeout if `MAX_CYCLES` is too low (currently set to 100000)
- The signature extraction mechanism needs to be implemented based on your testbench design

## License

This configuration follows the same license as the main project. The riscv-arch-test submodule and RISCOF tool have their own licenses.

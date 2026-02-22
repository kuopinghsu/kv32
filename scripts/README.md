# Analysis Scripts

This directory contains Python scripts for trace analysis and verification.

## Files

- **trace_compare.py**: Compare RTL trace with Spike simulator trace
- **parse_call_trace.py**: Call trace analyzer with function profiling and stack analysis

---

## Trace Formats

### RTL Trace (build/rtl_trace.txt)

Comprehensive execution trace with architectural state changes:
```
9 0x80000000 (0x30047073) c300_mstatus 0x00000000                       ; csrci mstatus,8
15 0x80000004 (0x00020117) x2  0x80020004                               ; auipc sp,0x20
113 0x80000194 (0x00f12623) mem 0x8001fffc 0x00000003                   ; sw a5,12(sp)
173 0x800001a8 (0x00c12783) x15 0x00000004 mem 0x8001fffc               ; lw a5,12(sp)
```

**Format**: `CYCLE 0xPC (0xINSTR) [REGWRITE] [MEMACCESS] [CSRACCESS] ; DISASM`

- **CYCLE**: CPU cycle number when instruction retired from WB stage
- **0xPC**: Program counter (32-bit hex with 0x prefix)
- **(0xINSTR)**: Instruction encoding (32-bit hex in parentheses)
- **[REGWRITE]**: Optional register write: `xN 0xVALUE` (omitted if rd=0)
- **[MEMACCESS]**: Optional memory operation: `mem 0xADDR [0xDATA]`
  - For loads: address only
  - For stores: address and data written
- **[CSRACCESS]**: Optional CSR write: `cXXX_name 0xVALUE` (Spike-compatible format)
- **; DISASM**: Disassembly with source code (aligned at column 72)

**Features**:
- Complete architectural state changes per instruction
- Spike-compatible CSR naming (e.g., `c305_mtvec`)
- Integrated disassembly from objdump
- NULL pointer detection (PC=0 or memory address 0)

### Spike Trace (build/sim_trace.txt)
Format: `core PRIV PC (INSTRUCTION) [REGWRITE] [MEMACCESS]`
```
core   0: 3 0x80000000 (0x30047073) c768_mstatus 0x00000000
core   0: 3 0x80000004 (0x00020117) x2  0x80020004
core   0: 3 0x80000008 (0xffc10113) x2  0x80020000
```
- PRIV: Privilege level (3 = machine mode)
- Includes register writes and memory accesses
- Includes bootloader code at 0x00001000

---

## Trace Comparison (trace_compare.py)

The `trace_compare.py` script compares RTL and Spike traces:

### How It Works

1. Parses both trace formats
2. Aligns traces by finding first matching PC (skips Spike bootloader)
3. Compares PC and instruction for each entry
4. Reports first 10 mismatches
5. **Passes** if all RTL instructions match (even if RTL has fewer)
6. **Fails** if traces are empty or instructions mismatch

### Usage

```bash
python3 scripts/trace_compare.py build/rtl_trace.txt build/sim_trace.txt
```

### Example Output
```
RTL trace entries: 8587
Spike trace entries: 10000
Aligning traces: Spike offset = 5 (skipping bootloader)

[PASS] All 8587 RTL instructions match Spike
  (Spike continued for 1408 more instructions)
```

### Current Status
✅ Comprehensive trace format with register writes, memory ops, CSR ops, and disassembly
✅ All trace generation and comparison working
✅ Exit detection working correctly
✅ NULL pointer detection implemented

### Verification Results
- ✅ **Simple test**: 561/561 instructions match
- ✅ **Hello test**: 8587/8587 instructions match (with _write, puts, printf)
- ✅ **Full test**: Ready for comprehensive verification

---

## Call Trace Analysis (parse_call_trace.py)

The `parse_call_trace.py` tool analyzes RTL execution traces to generate comprehensive function call reports with profiling data and stack analysis.

### Features

- **Function Call Tree**: Hierarchical visualization of function calls with nesting depth
- **Stack Frame Analysis**: Calculates stack frame sizes for each function
- **Call Frequency Profiling**: Counts how many times each function is called
- **PC Range Validation**: Detects invalid program counter values
- **Symbol Resolution**: Maps addresses to function names using ELF symbol table

### Usage

```bash
# Basic usage
python3 scripts/parse_call_trace.py <trace_file> <elf_file> <toolchain_prefix> [output_file]

# Example
python3 scripts/parse_call_trace.py build/rtl_trace.txt build/test.elf riscv-none-elf- call_report.txt

# With custom output file
python3 scripts/parse_call_trace.py build/rtl_trace.txt build/test.elf riscv-none-elf- my_report.txt
```

**Arguments**:
- `trace_file`: RTL trace file (typically `build/rtl_trace.txt`)
- `elf_file`: Compiled ELF binary with symbols (e.g., `build/test.elf`)
- `toolchain_prefix`: RISC-V toolchain prefix (e.g., `riscv-none-elf-`)
- `output_file`: Optional output report filename (default: `call_trace_report.txt`)

### Report Contents

The generated report includes:

#### 1. Call Tree Structure
Hierarchical view of function calls with indentation showing nesting depth:
```
main [frame: 32 bytes]
  printf+0x0 [frame: 48 bytes]
    __sfvwrite_r+0x0 [frame: 64 bytes]
      _write_r+0x0 [frame: 16 bytes]
        _write+0x0
```

#### 2. Stack Frame Sizes
Sorted list of functions by stack usage:
```
Stack Frame Sizes:
  128 bytes  memcpy
   64 bytes  __sfvwrite_r
   48 bytes  printf
   32 bytes  main
   16 bytes  _write_r
```

#### 3. Function Call Summary
Functions sorted by call frequency:
```
Function Call Summary (by frequency):
    523x  __sfvwrite_r+0x12
    156x  memcpy
     89x  _write_r
     23x  printf
      1x  main
```

#### 4. Detailed Call Trace
Complete sequence of function transitions with PC addresses:
```
Detailed Call Trace (function transitions):
Line      15: PC=0x80000000  => main
Line     142: PC=0x80001234  => printf  [call #1]
Line     289: PC=0x80002abc  => __sfvwrite_r  [call #1]
Line     356: PC=0x80002def  => _write_r  [call #1]
```

#### 5. PC Range Summary
Execution statistics and validation:
```
PC Range Summary:
  Min PC: 0x80000000
  Max PC: 0x80012abc
  Total unique PCs: 2,345

  WARNING: Found 0 PCs outside RAM range!
```

### How It Works

1. **Symbol Extraction**: Uses `nm` to extract function symbols from ELF file
2. **Address Resolution**: Maps each PC in trace to closest function symbol
3. **Call Detection**: Identifies `jal`/`jalr` instructions that save return address
4. **Return Detection**: Identifies `ret`/`jalr` instructions that return from functions
5. **Stack Analysis**: Uses `objdump` to analyze function prologues for `addi sp,sp,-XXX`
6. **Profiling**: Tracks function entry counts and calling patterns

### Example Output

Running on a Zephyr threads_sync sample:
```
$ python3 scripts/parse_call_trace.py build/rtl_trace.txt \
    rtos/zephyr/build.threads_sync/zephyr/zephyr.elf riscv-none-elf-

Extracting symbols from rtos/zephyr/build.threads_sync/zephyr/zephyr.elf...
Found 1,234 symbols
Parsing build/rtl_trace.txt for tree structure...
Processed 10000 lines...
Processed 20000 lines...
Total lines processed: 26,543
Call tree entries: 342
Maximum call depth: 8
Parsing build/rtl_trace.txt...
Processed 10000 lines...
Total lines processed: 26,543

Report generated: call_trace_report.txt
Total function transitions: 1,256
Unique functions called: 89
Call tree entries: 342
```

### Use Cases

- **Performance Analysis**: Identify hot functions called frequently
- **Stack Usage**: Calculate maximum stack depth for embedded systems
- **Call Flow**: Understand program execution flow and function relationships
- **Debugging**: Trace unexpected function calls or missing returns
- **Optimization**: Find functions to optimize based on call frequency

### Limitations

- Requires ELF file with symbol table (compile with `-g` for best results)
- Call detection based on instruction patterns (may miss indirect calls)
- Stack analysis only works for standard function prologues
- Large traces (>100K lines) may take several minutes to process
- Report limited to first 500 call tree entries for readability

### Tips

- **Include Debug Symbols**: Compile with `-g` flag for complete symbol information
- **Keep Functions Small**: Easier to analyze and profile
- **Review Stack Frames**: Ensure total stack usage fits in available RAM
- **Check Call Depth**: Deep call chains may indicate recursion issues
- **Validate PC Range**: Invalid PCs indicate bugs (null pointers, corruption)

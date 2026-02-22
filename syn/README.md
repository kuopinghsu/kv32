# Synthesis for rv32

This directory contains synthesis files for the RV32IM rv32 using open-source tools.

## Overview

- **Tools**: oss-cad-suite (Yosys only)
- **PDK**: ASAP7 7nm (Predictive PDK)
- **Target Frequency**: 120 MHz (8.33 ns period)
- **Flow**: Synthesis only (RTL → Gate-level netlist)
- **Verification**: Formal equivalence checking included

## Directory Structure

```
syn/
├── Makefile              # Synthesis automation
├── config.tcl            # Design configuration
├── pdk/                  # PDK
├── scripts/              # Synthesis scripts
├── results/              # Output files (netlists)
└── reports/              # Synthesis reports
```

## Prerequisites

### 1. Yosys and Synthesis Tools

Yosys synthesis tool should be in your PATH. The project uses `PATH_APPEND` in `env.config` to add tool directories:

```bash
# env.config includes:
# PATH_APPEND=/opt/oss-cad-suite/bin
```

Verify installation:
```bash
make check    # Verify tools are accessible
```

### 2. ASAP7 PDK Liberty Files

The ASAP7 PDK Liberty files are included in the `syn/pdk/` directory:
- `asap7sc7p5t_SIMPLE_RVT_TT_nldm_201020.lib` - Combinational cells
- `asap7sc7p5t_SEQ_RVT_TT_nldm_201020.lib` - Sequential cells (flip-flops, latches)

**Note**: ASAP7 is a predictive 7nm PDK for academic research only, not for production tapeout. For production designs, use Sky130 or other foundry PDKs.

## Quick Start

### Run Synthesis

```bash
make synth
```

This will:
- Synthesize RTL to gate-level netlist
- Generate synthesis reports (area, cell count, timing estimate)
- Output: `results/rv32_synth.v`

### View Results

```bash
make syn-reports  # View all reports
make stats        # Quick statistics
make area         # Area breakdown
make cells        # Cell usage
```

### Formal Equivalence Check

```bash
make formal     # Verify RTL <-> Gate-level equivalence
```

This verifies that the synthesized netlist is functionally equivalent to the RTL design using formal methods.

### Clean

```bash
make clean        # Remove generated files
make cleanall     # Remove all results and reports
```

## Design Configuration

Edit [config.tcl](config.tcl) to modify:

```tcl
# Design parameters
set DESIGN_NAME "rv32"
set TOP_MODULE "rv32"
set TARGET_FREQ_MHZ 120
set CLOCK_PERIOD 8.33  ;# ns (120 MHz)

# RTL files
set RTL_FILES {
    ../rtl/rv32.sv
    ../rtl/csr.sv
    ../rtl/clint.sv
}

# PDK configuration
set PDK "asap7"
set PDK_VARIANT "7nm"
set CELL_LIBRARY "RVT"  ;# Regular threshold voltage
```

## Reports Generated

After synthesis:
- `reports/synth_area.rpt`: Area breakdown by module and cell type
- `reports/synth_cells.rpt`: Cell usage statistics and gate count
- `reports/synth_timing_estimate.rpt`: Pre-placement timing estimate

After formal verification:
- `reports/formal_equiv.rpt`: Equivalence check results (RTL vs gate-level)

**Note**: Without P&R, timing and area are estimates only. For accurate results, use a full ASIC flow with place & route tools.

## Target Specifications

### Timing
- **Clock Frequency**: 120 MHz
- **Clock Period**: 8.33 ns
- **Setup Time Margin**: 10% (0.83 ns)
- **Hold Time Margin**: 5% (0.42 ns)

### Technology
- **Process**: ASAP7 7nm (Predictive PDK)
- **Cell Library**: RVT (Regular Vt) cells
- **Standard Cell Height**: 7 tracks
- **Metal Layers**:
  - M1-M4: Lower routing layers
  - M5-M7: Upper routing layers
  - M8-M9: Top-level routing (power, global)
- **Note**: Academic/research PDK only, not for production tapeout

## Design Constraints

### Clock
- Primary clock: `clk` @ 120 MHz
- Clock uncertainty: 0.5 ns
- Clock transition: 0.1 ns

### I/O
- Input delay: 20% of clock period (1.67 ns)
- Output delay: 20% of clock period (1.67 ns)
- Drive strength: Standard cell equivalent

### Power
- Single voltage domain
- RVT cells (regular threshold voltage)
- No power gating

## Optimization Tips

### Area Reduction
1. Reduce `UTILIZATION` in config.tcl (trade-off: routing congestion)
2. Enable gate-level constant propagation
3. Use more aggressive register merging

### Timing Improvement
1. Increase die size (lower utilization)
2. Add pipeline stages in critical paths
3. Adjust clock tree buffer sizing
4. Enable hold time fixing

### Power Reduction
1. Enable clock gating (requires RTL changes)
2. Use multi-Vt cells if available
3. Reduce switching activity (lower frequency)
4. Gate unused logic

## Formal Verification

### Equivalence Checking

The synthesis flow includes formal equivalence checking to verify that the synthesized gate-level netlist is functionally equivalent to the RTL design.

**Run equivalence check**:
```bash
make formal
```

**What it verifies**:
- All outputs of the gate-level netlist match RTL for all possible inputs
- No functionality lost during synthesis
- Optimizations preserve design behavior
- Structural equivalence between designs

**How it works**:
1. Loads RTL design (golden reference)
2. Loads synthesized netlist (implementation)
3. Creates equivalence miter circuit
4. Uses formal methods to prove equivalence
5. Reports PASS or FAIL with counterexamples

**Limitations**:
- Does not verify timing (only functionality)
- Does not verify physical design
- Assumes same clock domain
- Memory models must be identical

**When equivalence fails**:
- Check for unsupported SystemVerilog constructs
- Verify all modules are included in synthesis
- Check for simulation vs synthesis mismatches
- Review synthesis warnings for unmapped cells

### Integration with RISC-V Formal

This project also includes RISC-V Formal verification in [verif/riscv-formal/](../verif/riscv-formal/). That framework verifies ISA compliance, while synthesis equivalence checking verifies implementation correctness.

**Complete verification flow**:
1. ISA verification: `cd ../verif/formal_configs && make` (RISC-V Formal)
2. Synthesis equivalence: `cd ../syn && make formal` (RTL vs netlist)
3. Both ensure design correctness at different abstraction levels

## Known Issues and Limitations

### ASAP7 PDK
- **Predictive PDK**: Not a real fabrication process (academic model)
- **Academic use only**: Not suitable for production tapeout
- **Limited IP**: No SRAM, I/O pads, analog blocks
- **7nm process**: Results are estimates for modern process nodes

### Tool Limitations
- **Synthesis only**: No P&R without additional tools (OpenROAD/Magic)
- **No DFT**: No scan chain insertion or ATPG
- **Generic mapping**: Without Sky130 Liberty files, area/timing estimates only
- **Limited STA**: Basic timing analysis without full PDK

### Design Limitations
- **Single clock domain**: No CDC handling
- **No power management**: Always-on design
- **Memory interface**: Assumes ideal memory (no timing constraints)
- **No I/O pads**: Core logic only (need padframe for tapeout)

## Troubleshooting

### Synthesis Fails

**Error**: "Cannot find module 'rv32'"
- Check RTL file paths in config.tcl
- Verify all dependencies are included

**Error**: "Unmapped cells remaining"
- ASAP7 library may not have all required cells
- Check if all Verilog constructs are synthesizable
- Try disabling advanced features (use simpler logic)

### Timing Issues

**Long critical paths**:
1. Reduce target frequency in config.tcl (120 MHz is aggressive for generic mapping)
2. Add pipeline stages in RTL
3. Optimize critical path logic

**Unrealistic timing estimates**:
- Without ASAP7 Liberty files, timing is approximate only
- Expect results to be optimistic compared to real 7nm processes
- Consider this PDK for relative comparisons, not absolute performance

### Area Issues

**Design too large**:
1. Enable more aggressive optimization (opt -full)
2. Reduce peripheral features if possible
3. Use resource sharing

## Advanced Usage

### Using ASAP7 Liberty Files

For accurate timing/area, provide Liberty files:

```tcl
# In synthesis.tcl, update:
dfflibmap -liberty $::env(ASAP7_HOME)/lib/asap7sc7p5t_SIMPLE_RVT_TT_08302018.lib
abc9 -liberty $::env(ASAP7_HOME)/lib/asap7sc7p5t_SIMPLE_RVT_TT_08302018.lib
```

### Multi-Corner Analysis

Add timing corners:
```tcl
# Fast corner (high temp, high voltage)
# Slow corner (low temp, low voltage)
set CORNERS {ff_100C_1v95 tt_025C_1v80 ss_n40C_1v60}
```

### Custom Optimization

Edit synthesis.tcl for custom optimization:
```tcl
# More aggressive optimization
opt -full -fast
share -aggressive
alumacc
```

## References

- [Yosys Manual](https://yosyshq.readthedocs.io/)
- [ASAP7 PDK](https://github.com/The-OpenROAD-Project/asap7)
- [ASAP7 Documentation](http://asap.asu.edu/asap/)
- [OpenROAD Project](https://theopenroadproject.org/)

## License

The synthesis scripts are provided under the same license as the rv32 project.

ASAP7 PDK has its own license terms (BSD 3-Clause).

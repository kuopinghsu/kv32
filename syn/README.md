# kv32 Synthesis (Yosys + Genus + DC)

This directory supports three synthesis tools under one shared structure:

- Yosys
- Cadence Genus
- Synopsys Design Compiler (`dc_shell`)

All three flows reuse the same design configuration, RTL list, and baseline constraints.

## Directory layout

```text
syn/
├── Makefile
├── common/
│   ├── design.tcl                # shared design config + library/corner selection
│   ├── constraints.sdc           # shared timing/I/O constraints
│   └── rtl_filelist.f            # shared RTL list
├── lib/
│   └── generic_sram_1rw.sv       # generic SRAM fallback used by sram_1rw wrapper
├── scripts/
│   ├── yosys/
│   │   ├── synthesis.tcl
│   │   └── formal_equiv.tcl
│   ├── genus/
│   │   └── synthesis.tcl
│   ├── dc/
│   │   └── synthesis.tcl
├── pdk/
│   ├── asap7sc7p5t_SIMPLE_RVT_TT_nldm_201020.lib
│   └── asap7sc7p5t_SEQ_RVT_TT_nldm_201020.lib
├── build/
│   ├── results/
│   │   ├── yosys/
│   │   ├── genus/
│   │   └── dc/
│   ├── reports/
│   │   ├── yosys/
│   │   ├── genus/
│   │   └── dc/
│   └── logs/
```

## Unified usage

From this directory:

```bash
make synth
```

Default tool is Yosys. Choose tool explicitly:

```bash
make synth SYNTH_TOOL=yosys
make synth SYNTH_TOOL=genus
make synth SYNTH_TOOL=dc
```

Genus flow compiles direct SystemVerilog RTL (no Yosys netlist fallback).

Choose corner:

```bash
make synth SYNTH_TOOL=dc ACTIVE_CORNER=tt
make synth SYNTH_TOOL=genus ACTIVE_CORNER=ss
make synth SYNTH_TOOL=yosys ACTIVE_CORNER=ff
```

Check setup:

```bash
make check SYNTH_TOOL=genus
```

Yosys-only formal equivalence:

```bash
make formal SYNTH_TOOL=yosys
```

## Shared configuration

Edit common/design.tcl for:

- `DESIGN_NAME`, `TOP_MODULE`
- `TARGET_FREQ_MHZ`, `CLOCK_PORT`, uncertainty/transition
- `RTL_FILES`
- corner and library mapping (`CORNER_LIB_FILES`)

The current default assumes ASAP7 libraries under `syn/pdk`.

## Extending to other libraries/PDKs

You can keep the same flow and change library root / naming:

1. Point to another library root:

```bash
make synth SYNTH_TOOL=dc LIB_ROOT=/path/to/your/lib
```

2. Update `CORNER_LIB_FILES` in common/design.tcl to your `.lib` filenames.

3. Keep `common/constraints.sdc` and `common/rtl_filelist.f` unchanged unless needed.

## Multi-corner support

Framework is included in shared config and commercial scripts:

- `ACTIVE_CORNER`: compile corner (`tt` default)
- `SUPPORTED_CORNERS`: `tt ss ff`
- `ENABLE_MCMM`: controls extra corner timing report attempts

Behavior:

- If requested corner libraries are missing, flow falls back to `tt` (with warning).
- Genus/DC scripts generate timing reports per available corner when enabled.
- With only TT ASAP7 files present, reports are effectively TT-based.

## Tool environment and licenses

Documented-only requirement:

- Cadence Genus: set `CDS_LIC_FILE` (or equivalent Cadence license variable)
- Synopsys DC: set `SNPSLMD_LICENSE_FILE`

Example (shell setup):

```bash
export CDS_LIC_FILE=5280@your-license-server
export SNPSLMD_LICENSE_FILE=27000@your-license-server
```

Also ensure tool binaries are in `PATH` (or use `PATH_APPEND` in `env.config`).

## Outputs

- Netlists: `build/results/<tool>/`
- Reports: `build/reports/<tool>/`

Useful report commands:

```bash
make syn-reports SYNTH_TOOL=dc
make area SYNTH_TOOL=genus
make timing SYNTH_TOOL=yosys
```

Commercial-tool extra reports (Genus/DC):

- Hierarchical area report: `build/reports/<tool>/synth_area_hier_<corner>.rpt`
- Formatted hierarchy gate report: `build/reports/<tool>/synth_area_gate_<corner>.rpt`
    - Per hierarchy/module: total area, gate count, sequential cell count,
        combinational cell count, NAND2-equivalent gate count (`NAND2Eq`).
    - NAND2 unit area is auto-detected from loaded libraries (prefers
        `NAND2x1_ASAP7_75t_R`, else smallest `NAND2*` area).
- Detailed structural checks: `build/reports/<tool>/check_design_detail.rpt`
    - Includes best-effort sections for multi-driven nets, undriven/floating
        nets, and unused/unconnected ports.

## Notes

- ASAP7 is a predictive research PDK; not for production tapeout.
- Yosys flow remains the default reference flow and supports formal target in this setup.

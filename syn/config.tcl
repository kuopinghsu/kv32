# Synthesis Configuration for rv32
# ASAP7 7nm Predictive PDK with Yosys synthesis

# Design name
set DESIGN_NAME "rv32_soc"
set TOP_MODULE "rv32_soc"

# Target frequency (optimized for 7nm process)
set TARGET_FREQ_MHZ 120
set CLOCK_PERIOD [expr {1000.0 / $TARGET_FREQ_MHZ}]  ;# 8.33 ns
set CLOCK_PORT "clk"

# Clock uncertainty and transition
set CLOCK_UNCERTAINTY 0.5   ;# ns
set CLOCK_TRANSITION 0.1    ;# ns

# I/O delays (as percentage of clock period)
set INPUT_DELAY_PERCENT 20
set OUTPUT_DELAY_PERCENT 20
set INPUT_DELAY [expr {$CLOCK_PERIOD * $INPUT_DELAY_PERCENT / 100.0}]
set OUTPUT_DELAY [expr {$CLOCK_PERIOD * $OUTPUT_DELAY_PERCENT / 100.0}]

# RTL source files
set RTL_ROOT "../rtl"
set RTL_FILES [list \
    "$RTL_ROOT/core/rv32_pkg.sv" \
    "$RTL_ROOT/core/rv32_ib.sv" \
    "$RTL_ROOT/core/rv32_regfile.sv" \
    "$RTL_ROOT/core/rv32_csr.sv" \
    "$RTL_ROOT/core/rv32_alu.sv" \
    "$RTL_ROOT/core/rv32_decoder.sv" \
    "$RTL_ROOT/core/rv32_sb.sv" \
    "$RTL_ROOT/core/rv32_core.sv" \
    "$RTL_ROOT/memories/sram_1rw.sv" \
    "$RTL_ROOT/axi_pkg.sv" \
    "$RTL_ROOT/axi_arbiter.sv" \
    "$RTL_ROOT/axi_xbar.sv" \
    "$RTL_ROOT/axi_clint.sv" \
    "$RTL_ROOT/axi_i2c.sv" \
    "$RTL_ROOT/axi_spi.sv" \
    "$RTL_ROOT/axi_uart.sv" \
    "$RTL_ROOT/axi_magic.sv" \
    "$RTL_ROOT/mem_axi.sv" \
    "$RTL_ROOT/mem_axi_ro.sv" \
    "$RTL_ROOT/rv32_icache.sv" \
    "$RTL_ROOT/rv32_soc.sv" \
]

# PDK configuration
set PDK "asap7"
set PDK_VARIANT "7nm"
set PROCESS_NODE 7

# Standard cell library
# ASAP7 has multiple Vt libraries: SLVT, LVT, RVT, SRAM
# We'll use RVT (Regular Vt) for balanced performance/power
set CELL_LIBRARY "RVT"

# Synthesis settings
set CORE_UTILIZATION 0.70    ;# Target utilization

# Timing settings
set SETUP_SLACK_MARGIN 0.1   ;# Required setup slack (ns)
set HOLD_SLACK_MARGIN 0.05   ;# Required hold slack (ns)

# Output directories
set RESULTS_DIR "results"
set REPORTS_DIR "reports"
set SCRIPTS_DIR "scripts"

# Output files
set SYNTH_NETLIST "$RESULTS_DIR/${DESIGN_NAME}_synth.v"
set MAPPED_NETLIST "$RESULTS_DIR/${DESIGN_NAME}_mapped.v"
set FINAL_NETLIST "$RESULTS_DIR/${DESIGN_NAME}_final.v"
set FINAL_DEF "$RESULTS_DIR/${DESIGN_NAME}_final.def"
set FINAL_GDS "$RESULTS_DIR/${DESIGN_NAME}_final.gds"

# Report files
set SYNTH_AREA_RPT "$REPORTS_DIR/synth_area.rpt"
set SYNTH_CELLS_RPT "$REPORTS_DIR/synth_cells.rpt"
set SYNTH_TIMING_RPT "$REPORTS_DIR/synth_timing_estimate.rpt"
set FINAL_AREA_RPT "$REPORTS_DIR/final_area.rpt"
set FINAL_TIMING_RPT "$REPORTS_DIR/final_timing.rpt"
set FINAL_POWER_RPT "$REPORTS_DIR/final_power.rpt"
set FINAL_UTIL_RPT "$REPORTS_DIR/final_utilization.rpt"
set FINAL_CELLS_RPT "$REPORTS_DIR/final_cells.rpt"

# Synthesis options
set SYNTH_OPTIONS {
    -flatten
    -abc9
}

# I-Cache parameters for synthesis
# (smaller than simulation defaults; SRAM macros are instantiated separately)
set ICACHE_EN         1    ;# 1=enabled, 0=bypass
set ICACHE_SIZE       512  ;# bytes  (512 B)
set ICACHE_LINE_SIZE  16   ;# bytes per cache line (4 words)
set ICACHE_WAYS       1    ;# direct-mapped

# Optimization options
set OPT_STRATEGY "balanced"  ;# Options: area, delay, balanced

# DFT configuration (disabled per requirement)
set ENABLE_DFT 0
set ENABLE_SCAN_CHAIN 0
set ENABLE_MBIST 0

# Debug options
set VERBOSE 1
set GENERATE_LOGS 1

# Technology-specific parameters for ASAP7
# Reference: https://github.com/The-OpenROAD-Project/asap7
set TECH_LEF_FILES {}
set STD_CELL_LEF_FILES {}
set TECH_LIB_FILES [list \
    "pdk/asap7sc7p5t_SIMPLE_RVT_TT_nldm_201020.lib" \
    "pdk/asap7sc7p5t_SEQ_RVT_TT_nldm_201020.lib" \
]

# ASAP7 standard cell height (in tracks)
set CELL_HEIGHT_TRACKS 7

# ASAP7 metal stack
# M1-M4: Lower routing layers
# M5-M7: Upper routing layers
# M8-M9: Top-level routing (power, global signals)

puts "Configuration loaded:"
puts "  Design: $DESIGN_NAME"
puts "  Target Frequency: $TARGET_FREQ_MHZ MHz"
puts "  Clock Period: $CLOCK_PERIOD ns"
puts "  PDK: $PDK ($PROCESS_NODE nm)"
puts "  Cell Library: $CELL_LIBRARY"
puts "  Utilization Target: [expr {$CORE_UTILIZATION * 100}]%"
puts "  DFT Enabled: $ENABLE_DFT"
puts "  Flow: Synthesis only"

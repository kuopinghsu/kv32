# Shared synthesis configuration for kv32
# Used by Yosys, Cadence Genus, and Synopsys Design Compiler.

set COMMON_DIR [file dirname [file normalize [info script]]]
set SYN_DIR    [file normalize [file join $COMMON_DIR ..]]
set SYN_LIB_ROOT [file normalize [file join $SYN_DIR lib]]

# Design
set DESIGN_NAME "kv32_soc"
set TOP_MODULE  "kv32_soc"

# Target timing
set TARGET_FREQ_MHZ 120.0
set CLOCK_PERIOD [expr {1000.0 / $TARGET_FREQ_MHZ}]  ;# ns
set CLOCK_PORT "clk"
set CLOCK_UNCERTAINTY 0.5
set CLOCK_TRANSITION 0.1

# I/O delays (percentage of period)
set INPUT_DELAY_PERCENT 20.0
set OUTPUT_DELAY_PERCENT 20.0
set INPUT_DELAY  [expr {$CLOCK_PERIOD * $INPUT_DELAY_PERCENT / 100.0}]
set OUTPUT_DELAY [expr {$CLOCK_PERIOD * $OUTPUT_DELAY_PERCENT / 100.0}]

# Optional IO collections for constraints. Override in tool scripts if needed.
set INPUT_PORTS_EXCLUDE [list $CLOCK_PORT]
set OUTPUT_PORTS_EXCLUDE [list]

# RTL
set RTL_ROOT [file normalize [file join $SYN_DIR .. rtl]]
set RTL_FILES [list \
    "$RTL_ROOT/core/kv32_pkg.sv" \
    "$RTL_ROOT/core/kv32_ib.sv" \
    "$RTL_ROOT/core/kv32_regfile.sv" \
    "$RTL_ROOT/core/kv32_csr.sv" \
    "$RTL_ROOT/core/kv32_alu.sv" \
    "$RTL_ROOT/core/kv32_decoder.sv" \
    "$RTL_ROOT/core/kv32_sb.sv" \
    "$RTL_ROOT/core/kv32_core.sv" \
    "$SYN_LIB_ROOT/generic_sram_1rw.sv" \
    "$RTL_ROOT/memories/sram_1rw.sv" \
    "$RTL_ROOT/axi_pkg.sv" \
    "$RTL_ROOT/axi_arbiter.sv" \
    "$RTL_ROOT/axi_dma.sv" \
    "$RTL_ROOT/axi_xbar.sv" \
    "$RTL_ROOT/axi_clint.sv" \
    "$RTL_ROOT/axi_i2c.sv" \
    "$RTL_ROOT/axi_spi.sv" \
    "$RTL_ROOT/axi_plic.sv" \
    "$RTL_ROOT/axi_uart.sv" \
    "$RTL_ROOT/axi_gpio.sv" \
    "$RTL_ROOT/axi_timer.sv" \
    "$RTL_ROOT/axi_magic.sv" \
    "$RTL_ROOT/mem_axi.sv" \
    "$RTL_ROOT/mem_axi_ro.sv" \
    "$RTL_ROOT/kv32_icache.sv" \
    "$RTL_ROOT/kv32_pm.sv" \
    "$RTL_ROOT/kv32_dtm.sv" \
    "$RTL_ROOT/jtag/jtag_tap.sv" \
    "$RTL_ROOT/jtag/cjtag_bridge.sv" \
    "$RTL_ROOT/jtag/jtag_top.sv" \
    "$RTL_ROOT/kv32_soc.sv" \
]

# I-Cache synthesis parameter overrides
set ICACHE_EN         1
set ICACHE_SIZE       512
set ICACHE_LINE_SIZE  16
set ICACHE_WAYS       1

# Flow outputs (tool-specific scripts can override to subdirs)
set RESULTS_DIR [file join "results"]
set REPORTS_DIR [file join "reports"]

# Tech / PDK
set PDK "asap7"
set PDK_VARIANT "7nm"
set PROCESS_NODE 7
set CELL_LIBRARY "RVT"

# Library selection
# For extensibility, override LIB_ROOT and LIB_PREFIX from environment or tool scripts.
if {[info exists ::env(LIB_ROOT)] && $::env(LIB_ROOT) ne ""} {
    set LIB_ROOT $::env(LIB_ROOT)
} elseif {![info exists LIB_ROOT]} {
    set LIB_ROOT [file normalize [file join $SYN_DIR pdk]]
}
if {[info exists ::env(LIB_PREFIX)] && $::env(LIB_PREFIX) ne ""} {
    set LIB_PREFIX $::env(LIB_PREFIX)
} elseif {![info exists LIB_PREFIX]} {
    set LIB_PREFIX "asap7sc7p5t"
}

# Corner control
if {[info exists ::env(ACTIVE_CORNER)] && $::env(ACTIVE_CORNER) ne ""} {
    set ACTIVE_CORNER [string tolower $::env(ACTIVE_CORNER)]
} else {
    set ACTIVE_CORNER "tt"
}
set SUPPORTED_CORNERS [list tt ss ff]
set ENABLE_MCMM 1

# Map corner -> library files. By default, ss/ff fall back to tt if not present.
array set CORNER_LIB_FILES {
    tt {asap7sc7p5t_SIMPLE_RVT_TT_nldm_201020.lib asap7sc7p5t_SEQ_RVT_TT_nldm_201020.lib}
    ss {asap7sc7p5t_SIMPLE_RVT_SS_nldm_201020.lib asap7sc7p5t_SEQ_RVT_SS_nldm_201020.lib}
    ff {asap7sc7p5t_SIMPLE_RVT_FF_nldm_201020.lib asap7sc7p5t_SEQ_RVT_FF_nldm_201020.lib}
}

proc kv32_resolve_libs_for_corner {corner} {
    global LIB_ROOT CORNER_LIB_FILES

    if {![info exists CORNER_LIB_FILES($corner)]} {
        error "Unsupported corner '$corner'"
    }

    set resolved [list]
    foreach lib $CORNER_LIB_FILES($corner) {
        lappend resolved [file join $LIB_ROOT $lib]
    }

    # Fallback to TT if requested corner libs are absent.
    set all_found 1
    foreach lib_path $resolved {
        if {![file exists $lib_path]} {
            set all_found 0
            break
        }
    }

    if {!$all_found && $corner ne "tt"} {
        puts "WARNING: Missing $corner corner libs under '$LIB_ROOT'. Falling back to tt."
        set resolved [list]
        foreach lib $CORNER_LIB_FILES(tt) {
            lappend resolved [file join $LIB_ROOT $lib]
        }
    }

    return $resolved
}

proc kv32_available_corners {} {
    global SUPPORTED_CORNERS
    set out [list]
    foreach c $SUPPORTED_CORNERS {
        set libs [kv32_resolve_libs_for_corner $c]
        set ok 1
        foreach l $libs {
            if {![file exists $l]} {
                set ok 0
                break
            }
        }
        if {$ok} {
            lappend out $c
        }
    }
    return $out
}

set TECH_LIB_FILES [kv32_resolve_libs_for_corner $ACTIVE_CORNER]

puts "Configuration loaded:"
puts "  Design: $DESIGN_NAME"
puts "  Top: $TOP_MODULE"
puts "  Target: $TARGET_FREQ_MHZ MHz (period=${CLOCK_PERIOD}ns)"
puts "  PDK: $PDK ($PROCESS_NODE nm, $CELL_LIBRARY)"
puts "  Active corner: $ACTIVE_CORNER"
puts "  Results dir: $RESULTS_DIR"
puts "  Reports dir: $REPORTS_DIR"

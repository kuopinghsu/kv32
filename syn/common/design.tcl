# Shared synthesis configuration for kv32
# Used by Yosys, Cadence Genus, and Synopsys Design Compiler.

set COMMON_DIR [file dirname [file normalize [info script]]]
set SYN_DIR    [file normalize [file join $COMMON_DIR ..]]
set SYN_LIB_ROOT [file normalize [file join $SYN_DIR lib]]

# Design
set DESIGN_NAME "kv32_soc"
set TOP_MODULE  "kv32_soc"

# Target timing
set TARGET_FREQ_MHZ 450.0
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
    "$RTL_ROOT/core/kv32_rvc.sv" \
    "$RTL_ROOT/core/kv32_sb.sv" \
    "$RTL_ROOT/core/kv32_core.sv" \
    "$SYN_LIB_ROOT/sram_1rw.sv" \
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

# I-Cache synthesis parameters (match RTL defaults in kv32_soc.sv)
set ICACHE_EN         1
set ICACHE_SIZE       4096
set ICACHE_LINE_SIZE  32
set ICACHE_WAYS       2

# RTL synthesis parameters
set FAST_DIV          0     ;# 0=serial divider, 1=combinatorial single-cycle

# Derived SRAM dimensions — must match the I-cache parameters above.
# Used to locate OpenRAM-generated macro files and select the correct wrapper.
set _num_sets      [expr {$ICACHE_SIZE / ($ICACHE_LINE_SIZE * $ICACHE_WAYS)}]
set _wpl           [expr {$ICACHE_LINE_SIZE / 4}]
set _byte_off_bits [expr {int(log(double($ICACHE_LINE_SIZE)) / log(2.0))}]
set _index_bits    [expr {int(log(double($_num_sets))        / log(2.0))}]
set TAG_SRAM_DEPTH  $_num_sets
set TAG_SRAM_WIDTH  [expr {32 - $_byte_off_bits - $_index_bits}]
set DATA_SRAM_DEPTH [expr {$_num_sets * $_wpl}]
set DATA_SRAM_WIDTH 32
set OPENRAM_TAG_NAME  "sram_1rw_${TAG_SRAM_DEPTH}x${TAG_SRAM_WIDTH}"
set OPENRAM_DATA_NAME "sram_1rw_${DATA_SRAM_DEPTH}x${DATA_SRAM_WIDTH}"

# Flow outputs (tool-specific scripts can override to subdirs)
set RESULTS_DIR [file join "results"]
set REPORTS_DIR [file join "reports"]

# Tech / PDK selection
# Override via: make PDK=asap7 synth   or   export PDK=asap7 before running
# Supported: freepdk45 (default), asap7
if {[info exists ::env(PDK)] && $::env(PDK) ne ""} {
    set PDK [string tolower $::env(PDK)]
} elseif {![info exists PDK]} {
    set PDK "freepdk45"
}

# PDK-specific settings
if {$PDK eq "asap7"} {
    set PDK_VARIANT    "7nm"
    set PROCESS_NODE   7
    set CELL_LIBRARY   "RVT"
    set LIB_PREFIX     "asap7sc7p5t"
    set NAND2_CELL     "NAND2x1_ASAP7_75t_R"
    array set CORNER_LIB_FILES {
        tt {asap7sc7p5t_SIMPLE_RVT_TT_nldm_201020.lib asap7sc7p5t_SEQ_RVT_TT_nldm_201020.lib}
        ss {asap7sc7p5t_SIMPLE_RVT_SS_nldm_201020.lib asap7sc7p5t_SEQ_RVT_SS_nldm_201020.lib}
        ff {asap7sc7p5t_SIMPLE_RVT_FF_nldm_201020.lib asap7sc7p5t_SEQ_RVT_FF_nldm_201020.lib}
    }
} elseif {$PDK eq "freepdk45"} {
    set PDK_VARIANT    "45nm"
    set PROCESS_NODE   45
    set CELL_LIBRARY   "std"
    set LIB_PREFIX     "NangateOpenCellLibrary"
    set NAND2_CELL     "NAND2_X1"
    # FreePDK45 / Nangate45 ships only a typical (TT) corner.
    # ss/ff entries point to the same file; kv32_resolve_libs_for_corner will
    # find them directly without triggering the tt fallback warning.
    array set CORNER_LIB_FILES {
        tt {NangateOpenCellLibrary_typical.lib}
        ss {NangateOpenCellLibrary_typical.lib}
        ff {NangateOpenCellLibrary_typical.lib}
    }
} else {
    error "Unknown PDK '$PDK'. Supported values: freepdk45, asap7"
}

# Library root (LIB_ROOT may be overridden from env or Makefile)
if {[info exists ::env(LIB_ROOT)] && $::env(LIB_ROOT) ne ""} {
    set LIB_ROOT $::env(LIB_ROOT)
} elseif {![info exists LIB_ROOT]} {
    set LIB_ROOT [file normalize [file join $SYN_DIR pdk]]
}

set SUPPORTED_CORNERS [list tt ss ff]
set ENABLE_MCMM 1

# Corner control
if {[info exists ::env(ACTIVE_CORNER)] && $::env(ACTIVE_CORNER) ne ""} {
    set ACTIVE_CORNER [string tolower $::env(ACTIVE_CORNER)]
} else {
    set ACTIVE_CORNER "tt"
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

# OpenRAM-generated memory macros
# Primary:  syn/lib/openram/  – produced by 'make gen-mem'
# Fallback: syn/lib/          – committed copies (TT/SS/FF corners + Verilog)
set OPENRAM_DIR      [file normalize [file join $SYN_LIB_ROOT openram]]
set OPENRAM_DIR_FALLBACK [file normalize $SYN_LIB_ROOT]
set OPENRAM_LIB_FILES {}
set OPENRAM_RTL_FILES {}
# OpenRAM names Liberty files with a corner suffix, e.g. sram_1rw_64x21_TT_1p0V_25C.lib.
# Map the active corner to the OpenRAM suffix prefix (TT/SS/FF).
set _openram_corner_map {tt TT  ss SS  ff FF}
set _openram_corner_pfx [dict get $_openram_corner_map $ACTIVE_CORNER]
foreach mem_name [list $OPENRAM_TAG_NAME $OPENRAM_DATA_NAME] {
    # Liberty: check generated dir first, then committed fallback.
    set lib_candidates [glob -nocomplain \
        [file join $OPENRAM_DIR "${mem_name}_${_openram_corner_pfx}_*.lib"]]
    if {[llength $lib_candidates] == 0} {
        set lib_candidates [glob -nocomplain \
            [file join $OPENRAM_DIR_FALLBACK "${mem_name}_${_openram_corner_pfx}_*.lib"]]
    }
    if {[llength $lib_candidates] > 0} {
        lappend OPENRAM_LIB_FILES [lindex $lib_candidates 0]
    }
    # Verilog functional model: check generated dir first, then fallback.
    set vlog_f [file join $OPENRAM_DIR "${mem_name}.v"]
    if {![file exists $vlog_f]} {
        set vlog_f [file join $OPENRAM_DIR_FALLBACK "${mem_name}.v"]
    }
    if {[file exists $vlog_f]} { lappend OPENRAM_RTL_FILES $vlog_f }
}
# Prepend OpenRAM Liberty files so they take precedence for memory timing.
if {[llength $OPENRAM_LIB_FILES] > 0} {
    set TECH_LIB_FILES [concat $OPENRAM_LIB_FILES $TECH_LIB_FILES]
}
# Append OpenRAM Verilog functional models to the RTL list (needed by Yosys).
if {[llength $OPENRAM_RTL_FILES] > 0} {
    set RTL_FILES [concat $RTL_FILES $OPENRAM_RTL_FILES]
}

puts "Configuration loaded:"
puts "  Design: $DESIGN_NAME"
puts "  Top: $TOP_MODULE"
puts "  Target: $TARGET_FREQ_MHZ MHz (period=${CLOCK_PERIOD}ns)"
puts "  PDK: $PDK ($PROCESS_NODE nm, $CELL_LIBRARY)"
puts "  Active corner: $ACTIVE_CORNER"
puts "  SRAM macros:"
puts "    tag  SRAM: $OPENRAM_TAG_NAME  (${TAG_SRAM_DEPTH}x${TAG_SRAM_WIDTH})"
puts "    data SRAM: $OPENRAM_DATA_NAME (${DATA_SRAM_DEPTH}x${DATA_SRAM_WIDTH})"
if {[llength $OPENRAM_LIB_FILES] > 0} {
    puts "    OpenRAM libs: [llength $OPENRAM_LIB_FILES] file(s) found"
} else {
    puts "    WARNING: No OpenRAM libs found in $OPENRAM_DIR or $OPENRAM_DIR_FALLBACK — run 'make gen-mem'"
}
puts "  Results dir: $RESULTS_DIR"
puts "  Reports dir: $REPORTS_DIR"

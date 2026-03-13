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
    "$RTL_ROOT/kv32_dcache.sv" \
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

# D-Cache synthesis parameters (match RTL defaults in kv32_soc.sv)
set DCACHE_EN          1
set DCACHE_SIZE        4096
set DCACHE_LINE_SIZE   32
set DCACHE_WAYS        2
set DCACHE_WRITE_BACK  1
set DCACHE_WRITE_ALLOC 1

# RTL synthesis parameters
set FAST_DIV          0     ;# 0=serial divider, 1=combinatorial single-cycle

# Derived I-cache SRAM dimensions — must match the I-cache parameters above.
# Used to locate OpenRAM-generated macro files and select the correct wrapper.
set _icache_num_sets      [expr {$ICACHE_SIZE / ($ICACHE_LINE_SIZE * $ICACHE_WAYS)}]
set _icache_wpl           [expr {$ICACHE_LINE_SIZE / 4}]
set _icache_byte_off_bits [expr {int(log(double($ICACHE_LINE_SIZE)) / log(2.0))}]
set _icache_index_bits    [expr {int(log(double($_icache_num_sets)) / log(2.0))}]
set ICACHE_TAG_SRAM_DEPTH  $_icache_num_sets
set ICACHE_TAG_SRAM_WIDTH  [expr {32 - $_icache_byte_off_bits - $_icache_index_bits}]
set ICACHE_DATA_SRAM_DEPTH [expr {$_icache_num_sets * $_icache_wpl}]
set ICACHE_DATA_SRAM_WIDTH 32
set OPENRAM_ICACHE_TAG_NAME  "sram_1rw_${ICACHE_TAG_SRAM_DEPTH}x${ICACHE_TAG_SRAM_WIDTH}"
set OPENRAM_ICACHE_DATA_NAME "sram_1rw_${ICACHE_DATA_SRAM_DEPTH}x${ICACHE_DATA_SRAM_WIDTH}"

# Derived D-cache SRAM dimensions — must match the D-cache parameters above.
set _dcache_num_sets      [expr {$DCACHE_SIZE / ($DCACHE_LINE_SIZE * $DCACHE_WAYS)}]
set _dcache_wpl           [expr {$DCACHE_LINE_SIZE / 4}]
set _dcache_byte_off_bits [expr {int(log(double($DCACHE_LINE_SIZE)) / log(2.0))}]
set _dcache_index_bits    [expr {int(log(double($_dcache_num_sets)) / log(2.0))}]
set DCACHE_TAG_SRAM_DEPTH  $_dcache_num_sets
set DCACHE_TAG_SRAM_WIDTH  [expr {32 - $_dcache_byte_off_bits - $_dcache_index_bits}]
set DCACHE_DATA_SRAM_DEPTH [expr {$_dcache_num_sets * $_dcache_wpl}]
set DCACHE_DATA_SRAM_WIDTH 32
set OPENRAM_DCACHE_TAG_NAME  "sram_1rw_${DCACHE_TAG_SRAM_DEPTH}x${DCACHE_TAG_SRAM_WIDTH}"
set OPENRAM_DCACHE_DATA_NAME "sram_1rw_${DCACHE_DATA_SRAM_DEPTH}x${DCACHE_DATA_SRAM_WIDTH}"

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

# Returns the OpenRAM Liberty files for the given corner (TT/SS/FF).
# Searches syn/lib/openram/ first (generated), then syn/lib/ (committed fallback).
# Used by all Liberty-based tool flows (Genus, DC) for both the active corner
# and per-corner MCMM timing sweeps.
proc kv32_resolve_openram_libs_for_corner {corner} {
    global OPENRAM_ICACHE_TAG_NAME OPENRAM_ICACHE_DATA_NAME \
           OPENRAM_DCACHE_TAG_NAME OPENRAM_DCACHE_DATA_NAME \
           OPENRAM_DIR OPENRAM_DIR_FALLBACK
    set corner_map {tt TT  ss SS  ff FF}
    if {![dict exists $corner_map $corner]} {
        error "kv32_resolve_openram_libs_for_corner: unknown corner '$corner'"
    }
    set pfx [dict get $corner_map $corner]
    set result {}
    foreach mem_name [list $OPENRAM_ICACHE_TAG_NAME $OPENRAM_ICACHE_DATA_NAME \
                           $OPENRAM_DCACHE_TAG_NAME $OPENRAM_DCACHE_DATA_NAME] {
        set candidates [glob -nocomplain \
            [file join $OPENRAM_DIR "${mem_name}_${pfx}_*.lib"]]
        if {[llength $candidates] == 0} {
            set candidates [glob -nocomplain \
                [file join $OPENRAM_DIR_FALLBACK "${mem_name}_${pfx}_*.lib"]]
        }
        if {[llength $candidates] > 0} {
            lappend result [lindex $candidates 0]
        }
    }
    return $result
}

# Returns all Liberty files for a corner: OpenRAM macros prepended to PDK cells.
# This is the single source of truth used by Genus and DC for read_libs /
# target_library.  Always call this instead of kv32_resolve_libs_for_corner
# directly when a complete library set is needed.
proc kv32_resolve_all_libs_for_corner {corner} {
    set openram_libs [kv32_resolve_openram_libs_for_corner $corner]
    set pdk_libs     [kv32_resolve_libs_for_corner $corner]
    return [concat $openram_libs $pdk_libs]
}

# OpenRAM-generated memory macros
# Primary:  syn/lib/openram/  – produced by 'make gen-mem'
# Fallback: syn/lib/          – committed copies (TT/SS/FF corners + Verilog)
set OPENRAM_DIR          [file normalize [file join $SYN_LIB_ROOT openram]]
set OPENRAM_DIR_FALLBACK [file normalize $SYN_LIB_ROOT]
set OPENRAM_RTL_FILES {}

# Verilog functional models (needed by Yosys; Liberty-based tools use .lib).
foreach mem_name [list $OPENRAM_ICACHE_TAG_NAME $OPENRAM_ICACHE_DATA_NAME \
                       $OPENRAM_DCACHE_TAG_NAME $OPENRAM_DCACHE_DATA_NAME] {
    set vlog_f [file join $OPENRAM_DIR "${mem_name}.v"]
    if {![file exists $vlog_f]} {
        set vlog_f [file join $OPENRAM_DIR_FALLBACK "${mem_name}.v"]
    }
    if {[file exists $vlog_f]} { lappend OPENRAM_RTL_FILES $vlog_f }
}

# TECH_LIB_FILES: complete lib set for the active corner (OpenRAM + PDK).
# Used directly by Genus/DC main library loading so neither tool has to
# reconstruct this list itself.
set OPENRAM_LIB_FILES [kv32_resolve_openram_libs_for_corner $ACTIVE_CORNER]
set TECH_LIB_FILES    [kv32_resolve_all_libs_for_corner     $ACTIVE_CORNER]
# NOTE: OPENRAM_RTL_FILES is intentionally NOT appended to RTL_FILES here.
# Liberty-based tools (Genus, DC) treat the OpenRAM macros as black boxes
# using the .lib timing models — feeding the behavioral .v to read_hdl would
# cause the tool to elaborate the simulation model (multiple always-blocks
# driving dout0 → CDFG2G-622) instead of using the library cell.
# The Yosys flow appends OPENRAM_RTL_FILES itself because it has no .lib
# black-box mechanism and must elaborate the functional model directly.

puts "Configuration loaded:"
puts "  Design: $DESIGN_NAME"
puts "  Top: $TOP_MODULE"
puts "  Target: $TARGET_FREQ_MHZ MHz (period=${CLOCK_PERIOD}ns)"
puts "  PDK: $PDK ($PROCESS_NODE nm, $CELL_LIBRARY)"
puts "  Active corner: $ACTIVE_CORNER"
puts "  SRAM macros:"
    puts "    I$ tag  SRAM: $OPENRAM_ICACHE_TAG_NAME  (${ICACHE_TAG_SRAM_DEPTH}x${ICACHE_TAG_SRAM_WIDTH})"
    puts "    I$ data SRAM: $OPENRAM_ICACHE_DATA_NAME (${ICACHE_DATA_SRAM_DEPTH}x${ICACHE_DATA_SRAM_WIDTH})"
puts "    D$ tag  SRAM: $OPENRAM_DCACHE_TAG_NAME  (${DCACHE_TAG_SRAM_DEPTH}x${DCACHE_TAG_SRAM_WIDTH})"
puts "    D$ data SRAM: $OPENRAM_DCACHE_DATA_NAME (${DCACHE_DATA_SRAM_DEPTH}x${DCACHE_DATA_SRAM_WIDTH})"
if {[llength $OPENRAM_LIB_FILES] > 0} {
    puts "    OpenRAM libs: [llength $OPENRAM_LIB_FILES] file(s) found"
} else {
    puts "    WARNING: No OpenRAM libs found in $OPENRAM_DIR or $OPENRAM_DIR_FALLBACK — run 'make gen-mem'"
}
puts "  Results dir: $RESULTS_DIR"
puts "  Reports dir: $REPORTS_DIR"

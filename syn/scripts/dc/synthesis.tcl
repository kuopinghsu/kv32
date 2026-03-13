# Synopsys Design Compiler (dc_shell) synthesis flow for kv32

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set SYN_DIR    [file normalize [file join $SCRIPT_DIR .. ..]]

source [file join $SYN_DIR common design.tcl]

set RESULTS_DIR [file join "results" "dc"]
set REPORTS_DIR [file join "reports" "dc"]
file mkdir $RESULTS_DIR
file mkdir $REPORTS_DIR

set DC_NETLIST "$RESULTS_DIR/${DESIGN_NAME}_synth.v"
set DC_DDC     "$RESULTS_DIR/${DESIGN_NAME}.ddc"
set DC_SDC     "$RESULTS_DIR/${DESIGN_NAME}.sdc"

set available_corners [kv32_available_corners]
if {[llength $available_corners] == 0} {
    echo "ERROR: No valid library corner found under $LIB_ROOT"
    exit 1
}

# TECH_LIB_FILES is built by design.tcl: OpenRAM .lib files prepended to the
# PDK standard-cell library.  Use it directly so SRAM macros are black-boxed
# with correct timing models rather than elaborated as behavioral RTL.
set_app_var search_path [concat . $LIB_ROOT [file normalize [file join $SYN_DIR lib]]]
set_app_var target_library $TECH_LIB_FILES
set_app_var link_library   [concat * $TECH_LIB_FILES]

# Apply top-level parameter overrides before analysis
set_app_var hdl_parameter_override_list [list \
    FAST_DIV           $FAST_DIV \
    ICACHE_EN          $ICACHE_EN \
    ICACHE_SIZE        $ICACHE_SIZE \
    ICACHE_LINE_SIZE   $ICACHE_LINE_SIZE \
    ICACHE_WAYS        $ICACHE_WAYS \
    DCACHE_EN          $DCACHE_EN \
    DCACHE_SIZE        $DCACHE_SIZE \
    DCACHE_LINE_SIZE   $DCACHE_LINE_SIZE \
    DCACHE_WAYS        $DCACHE_WAYS \
    DCACHE_WRITE_BACK  $DCACHE_WRITE_BACK \
    DCACHE_WRITE_ALLOC $DCACHE_WRITE_ALLOC \
]

# Read RTL
foreach rtl $RTL_FILES {
    analyze -format sverilog -define {SYNTHESIS NO_ASSERTION GENERIC_SRAM} $rtl
}
elaborate $TOP_MODULE
current_design $TOP_MODULE
link

# Constraints
source [file join $SYN_DIR common constraints.sdc]
write_sdc $DC_SDC

check_design > "$REPORTS_DIR/check_design.rpt"

# Detailed structural checks (best-effort across tool versions)
proc kv32_append_text {report_file text} {
    set fp [open $report_file a]
    puts $fp $text
    close $fp
}

proc kv32_try_cmds_to_report {report_file section_title cmd_list} {
    kv32_append_text $report_file ""
    kv32_append_text $report_file "============================================================"
    kv32_append_text $report_file $section_title
    kv32_append_text $report_file "============================================================"

    set success 0
    foreach cmd $cmd_list {
        if {![catch {redirect -append $report_file $cmd} err]} {
            kv32_append_text $report_file "\[INFO\] Command used: $cmd"
            set success 1
            break
        }
    }

    if {!$success} {
        kv32_append_text $report_file "\[WARN\] No compatible command was available for this section."
    }
}

set CHECK_DETAIL_RPT "$REPORTS_DIR/check_design_detail.rpt"
set fp [open $CHECK_DETAIL_RPT w]
puts $fp "KV32 Detailed Design Checks (DC)"
puts $fp "Design: $DESIGN_NAME"
puts $fp "Top: $TOP_MODULE"
puts $fp "Active corner: $ACTIVE_CORNER"
close $fp

kv32_try_cmds_to_report $CHECK_DETAIL_RPT "Comprehensive design checks" [list \
    "check_design -all" \
    "check_design" \
]

kv32_try_cmds_to_report $CHECK_DETAIL_RPT "Empty modules / unresolved references" [list \
    "check_design -unresolved" \
]

kv32_try_cmds_to_report $CHECK_DETAIL_RPT "Unloaded ports / sequential pins" [list \
    "check_design -unloaded" \
]

kv32_try_cmds_to_report $CHECK_DETAIL_RPT "Unloaded combinational pins" [list \
    "check_design -unloaded_comb" \
]

kv32_try_cmds_to_report $CHECK_DETAIL_RPT "Multi-driven nets" [list \
    "check_design -multiple_driver" \
]

kv32_try_cmds_to_report $CHECK_DETAIL_RPT "Undriven / floating nets" [list \
    "check_design -undriven" \
]

kv32_try_cmds_to_report $CHECK_DETAIL_RPT "Unused / unconnected ports" [list \
    "check_design -unloaded" \
]

# Preserve hierarchy during synthesis so area can be reported per module.
set_app_var compile_auto_ungroup none

# Compile
set_fix_hold [get_clocks core_clk]
compile_ultra -gate_clock

# Outputs
write -format verilog -hierarchy -output $DC_NETLIST
write -format ddc -hierarchy -output $DC_DDC

# Formatted area/gate report helpers
proc kv32_find_nand2_area {} {
    global NAND2_CELL
    # Use PDK-specific NAND2 cell defined in common/design.tcl
    set cands [get_lib_cells */$NAND2_CELL]
    if {[sizeof_collection $cands] == 0} {
        set cands [get_lib_cells */NAND2*]
    }

    set best 0.0
    foreach_in_collection c $cands {
        set a 0.0
        catch { set a [get_attribute $c area] }
        if {$a > 0.0 && ($best == 0.0 || $a < $best)} {
            set best $a
        }
    }

    if {$best <= 0.0} {
        set best 1.0
    }
    return $best
}

# Build a flat Tcl list of all leaf instances: {{full_path area is_seq} ...}
# Traverses the design once; all per-hierarchy queries filter this list in Tcl.
proc kv32_build_leaf_list {} {
    set result {}
    set all_leafs [get_cells -hierarchical -filter "is_hierarchical == false"]
    foreach_in_collection c $all_leafs {
        set cname     [get_object_name $c]
        set cell_area 0.0
        set is_seq    0

        set ref ""
        catch { set ref [get_attribute $c ref_name] }
        if {$ref ne ""} {
            set lc [get_lib_cells */$ref]
            if {[sizeof_collection $lc] > 0} {
                set lc0 [index_collection $lc 0]
                catch { set cell_area [get_attribute $lc0 area] }
                set s ""
                catch { set s [get_attribute $lc0 is_sequential] }
                if {$s eq "true" || $s eq "1" || $s == 1} { set is_seq 1 }
            }
        }
        if {$cell_area <= 0.0} { catch { set cell_area [get_attribute $c area] } }

        lappend result [list $cname $cell_area $is_seq]
    }
    return $result
}

# Sum leaf entries whose full path starts with <prefix>/.
# prefix "/" means sum ALL leaves (top level).
proc kv32_sum_for_prefix {leaf_list prefix nand2_area} {
    set area  0.0
    set gates 0
    set seq   0
    set comb  0
    # Escape square brackets so that array-generate instance names like
    # l_g_sram[0] are not mis-interpreted as Tcl character-class patterns
    # in string match (e.g. [0] would otherwise match only digit "0").
    set esc_prefix [string map [list {[} {\[} {]} {\]}] $prefix]
    foreach entry $leaf_list {
        lassign $entry lname larea lis_seq
        if {$prefix eq "/" || [string match "${esc_prefix}/*" $lname]} {
            set area [expr {$area + $larea}]
            incr gates
            if {$lis_seq} { incr seq } else { incr comb }
        }
    }
    set nand2eq [expr {$nand2_area > 0 ? $area / $nand2_area : 0.0}]
    return [list $area $gates $seq $comb $nand2eq]
}

# Truncate a string to at most $maxlen characters.
# If the string is longer, keep the first (maxlen-3) chars and append "...".
proc kv32_trunc {s maxlen} {
    if {[string length $s] <= $maxlen} { return $s }
    return "[string range $s 0 [expr {$maxlen - 4}]]..."
}

proc kv32_write_formatted_area_gate_report {report_file top_module} {
    set nand2_area [kv32_find_nand2_area]

    puts "Collecting leaf instances for area report..."
    set leaf_list [kv32_build_leaf_list]
    puts [format "  %d leaf cells collected." [llength $leaf_list]]

    # Column widths: Hierarchy=48, Module=32, numeric cols unchanged.
    # Total line width: 48+1+32+1+12+1+12+1+12+1+12+1+14 = 148 chars.
    set H_W 48
    set M_W 32

    set fp [open $report_file w]
    puts $fp "KV32 Formatted Area/Gate Report (DC)"
    puts $fp "Top Module      : $top_module"
    puts $fp [format "NAND2 Unit Area: %.6f" $nand2_area]
    puts $fp ""
    puts $fp [format "%-${H_W}s %-${M_W}s %12s %12s %12s %12s %14s" \
        "Hierarchy" "Module" "Area" "GateCnt" "SeqCnt" "CombCnt" "NAND2Eq"]
    puts $fp [string repeat "-" 148]

    # Top summary row (all leaves)
    lassign [kv32_sum_for_prefix $leaf_list "/" $nand2_area] t_area t_gates t_seq t_comb t_n2
    puts $fp [format "%-${H_W}s %-${M_W}s %12.3f %12d %12d %12d %14.3f" \
        "/" [kv32_trunc $top_module $M_W] $t_area $t_gates $t_seq $t_comb $t_n2]

    # Per-hierarchy-module rows, sorted by instance path
    set hmods [get_cells -hierarchical -filter "is_hierarchical == true"]
    set hmod_names {}
    foreach_in_collection h $hmods {
        set hname [get_object_name $h]
        set mname ""
        catch { set mname [get_attribute $h ref_name] }
        lappend hmod_names [list $hname $mname]
    }
    set hmod_names [lsort -index 0 $hmod_names]

    foreach entry $hmod_names {
        lassign $entry hname mname
        lassign [kv32_sum_for_prefix $leaf_list $hname $nand2_area] area gates seq comb n2
        puts $fp [format "%-${H_W}s %-${M_W}s %12.3f %12d %12d %12d %14.3f" \
            [kv32_trunc $hname $H_W] [kv32_trunc $mname $M_W] \
            $area $gates $seq $comb $n2]
    }

    puts $fp ""
    puts $fp "Notes:"
    puts $fp "- GateCnt counts leaf standard-cell instances."
    puts $fp "- SeqCnt/CombCnt are classified using lib-cell is_sequential attribute."
    puts $fp "- NAND2Eq = Area / NAND2 Unit Area."
    close $fp
}

# Reports (active corner)
report_area > "$REPORTS_DIR/synth_area_${ACTIVE_CORNER}.rpt"
report_area -hierarchy > "$REPORTS_DIR/synth_area_hier_${ACTIVE_CORNER}.rpt"
report_power > "$REPORTS_DIR/synth_power_${ACTIVE_CORNER}.rpt"
report_timing -max_paths 20 > "$REPORTS_DIR/synth_timing_${ACTIVE_CORNER}.rpt"
report_qor > "$REPORTS_DIR/synth_qor_${ACTIVE_CORNER}.rpt"

if {[catch {
    kv32_write_formatted_area_gate_report \
        "$REPORTS_DIR/synth_area_gate_${ACTIVE_CORNER}.rpt" \
        $TOP_MODULE
} area_err]} {
    echo "WARNING: Failed to generate formatted area/gate report: $area_err"
}

# Multi-corner timing reports if enabled
if {$ENABLE_MCMM} {
    foreach c $available_corners {
        puts "Generating timing report for corner: $c"
        # Include OpenRAM libs for this corner so SRAM timing is correct.
        set corner_libs [kv32_resolve_all_libs_for_corner $c]
        if {[catch {
            set_app_var target_library $corner_libs
            set_app_var link_library [concat * $corner_libs]
            link
            report_timing -max_paths 20 > "$REPORTS_DIR/synth_timing_${c}.rpt"
        } err]} {
            echo "WARNING: Failed to generate timing for corner '$c': $err"
        }
    }
}

echo "DC synthesis completed. Netlist: $DC_NETLIST"

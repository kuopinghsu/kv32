# Cadence Genus synthesis flow for kv32

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set SYN_DIR    [file normalize [file join $SCRIPT_DIR .. ..]]

source [file join $SYN_DIR common design.tcl]

set RESULTS_DIR [file join "results" "genus"]
set REPORTS_DIR [file join "reports" "genus"]
file mkdir $RESULTS_DIR
file mkdir $REPORTS_DIR

set GENUS_NETLIST "$RESULTS_DIR/${DESIGN_NAME}_synth.v"
set GENUS_DDC     "$RESULTS_DIR/${DESIGN_NAME}.db"

set available_corners [kv32_available_corners]
if {[llength $available_corners] == 0} {
    error "No valid library corner found under $LIB_ROOT"
}

puts "=== Genus synthesis start ==="
puts "Design: $DESIGN_NAME"
puts "Corners available: $available_corners"
puts "Active compile corner: $ACTIVE_CORNER"

# Read active corner libs for compile
set active_libs [kv32_resolve_libs_for_corner $ACTIVE_CORNER]
set genus_helper_lib [file join $LIB_ROOT "kv32_genus_prelib.lib"]
if {[file exists $genus_helper_lib]} {
    set active_libs [concat [list $genus_helper_lib] $active_libs]
}
read_libs $active_libs

# Some ASAP7 liberty views mark many cells as avoid/preserve which can prevent
# Genus from finding basic gates needed for RTL timing modeling (TIM-30).
# Relax these attributes for synthesis runs in this repository.
if {![catch {set all_lib_cells [get_db lib_cells *]}]} {
    if {[llength $all_lib_cells] > 0} {
        catch {set_db $all_lib_cells .avoid false}
        catch {set_db $all_lib_cells .preserve false}
    }
}

puts "Genus input mode: rtl"
set_db init_hdl_search_path [list ../rtl ../rtl/core ../rtl/jtag]
read_hdl -language sv \
    -define SYNTHESIS \
    -define NO_ASSERTION \
    -define GENERIC_SRAM \
    $RTL_FILES
elaborate $TOP_MODULE

# Constraints
source [file join $SYN_DIR common constraints.sdc]

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
puts $fp "KV32 Detailed Design Checks (Genus)"
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
set_db auto_ungroup none

# Synthesis
syn_generic
syn_map
syn_opt

# Write outputs
write_hdl > $GENUS_NETLIST
write_db -design $TOP_MODULE $GENUS_DDC

# Formatted area/gate report helpers
proc kv32_find_nand2_area {} {
    # Prefer canonical ASAP7 NAND2 cell
    set cands [get_lib_cells */NAND2x1_ASAP7_75t_R]
    if {[sizeof_collection $cands] == 0} {
        set cands [get_lib_cells */NAND2*]
    }

    set best 0.0
    foreach_in_collection c $cands {
        set a 0.0
        catch { set a [get_db $c .area] }
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
        set cname     ""
        set cell_area 0.0
        set is_seq    0
        catch { set cname [get_db $c .name] }

        set base_cell ""
        catch { set base_cell [get_db $c .base_cell.name] }
        if {$base_cell ne ""} {
            set lc [get_lib_cells */$base_cell]
            if {[sizeof_collection $lc] > 0} {
                set lc0 [index_collection $lc 0]
                catch { set cell_area [get_db $lc0 .area] }
                set s ""
                catch { set s [get_db $lc0 .is_sequential] }
                if {$s eq "true" || $s eq "1" || $s == 1} { set is_seq 1 }
            }
        }
        if {$cell_area <= 0.0} { catch { set cell_area [get_db $c .area] } }

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
    foreach entry $leaf_list {
        lassign $entry lname larea lis_seq
        if {$prefix eq "/" || [string match "${prefix}/*" $lname]} {
            set area [expr {$area + $larea}]
            incr gates
            if {$lis_seq} { incr seq } else { incr comb }
        }
    }
    set nand2eq [expr {$nand2_area > 0 ? $area / $nand2_area : 0.0}]
    return [list $area $gates $seq $comb $nand2eq]
}

proc kv32_write_formatted_area_gate_report {report_file top_module} {
    set nand2_area [kv32_find_nand2_area]

    puts "Collecting leaf instances for area report..."
    set leaf_list [kv32_build_leaf_list]
    puts [format "  %d leaf cells collected." [llength $leaf_list]]

    set fp [open $report_file w]
    puts $fp "KV32 Formatted Area/Gate Report (Genus)"
    puts $fp "Top Module      : $top_module"
    puts $fp [format "NAND2 Unit Area: %.6f" $nand2_area]
    puts $fp ""
    puts $fp [format "%-70s %-28s %12s %12s %12s %12s %14s" \
        "Hierarchy" "Module" "Area" "GateCnt" "SeqCnt" "CombCnt" "NAND2Eq"]
    puts $fp [string repeat "-" 168]

    # Top summary row (all leaves)
    lassign [kv32_sum_for_prefix $leaf_list "/" $nand2_area] t_area t_gates t_seq t_comb t_n2
    puts $fp [format "%-70s %-28s %12.3f %12d %12d %12d %14.3f" \
        "/" $top_module $t_area $t_gates $t_seq $t_comb $t_n2]

    # Per-hierarchy-module rows, sorted by instance path
    set hmods [get_cells -hierarchical -filter "is_hierarchical == true"]
    set hmod_names {}
    foreach_in_collection h $hmods {
        set hname ""
        set mname ""
        catch { set hname [get_db $h .name] }
        catch { set mname [get_db $h .module.name] }
        lappend hmod_names [list $hname $mname]
    }
    set hmod_names [lsort -index 0 $hmod_names]

    foreach entry $hmod_names {
        lassign $entry hname mname
        lassign [kv32_sum_for_prefix $leaf_list $hname $nand2_area] area gates seq comb n2
        puts $fp [format "%-70s %-28s %12.3f %12d %12d %12d %14.3f" \
            $hname $mname $area $gates $seq $comb $n2]
    }

    puts $fp ""
    puts $fp "Notes:"
    puts $fp "- GateCnt counts leaf standard-cell instances."
    puts $fp "- SeqCnt/CombCnt are classified using lib-cell is_sequential attribute."
    puts $fp "- NAND2Eq = Area / NAND2 Unit Area."
    close $fp
}

# Reports for active corner
redirect "$REPORTS_DIR/synth_area_${ACTIVE_CORNER}.rpt"         { report_area }
redirect "$REPORTS_DIR/synth_area_hier_${ACTIVE_CORNER}.rpt"    { report_area -depth 10 }
redirect "$REPORTS_DIR/synth_power_${ACTIVE_CORNER}.rpt"        { report_power }
redirect "$REPORTS_DIR/synth_timing_${ACTIVE_CORNER}.rpt"       { report_timing -max_paths 20 }
redirect "$REPORTS_DIR/synth_qor_${ACTIVE_CORNER}.rpt"          { report_qor }

if {[catch {
    kv32_write_formatted_area_gate_report \
        "$REPORTS_DIR/synth_area_gate_${ACTIVE_CORNER}.rpt" \
        $TOP_MODULE
} area_err]} {
    puts "WARNING: Failed to generate formatted area/gate report: $area_err"
}

# Multi-corner timing snapshots if corner libs exist
if {$ENABLE_MCMM} {
    foreach c $available_corners {
        puts "Generating timing report for corner: $c"
        set corner_libs [kv32_resolve_libs_for_corner $c]
        # Re-point libraries and re-report timing using current netlist if supported.
        if {[catch {
            reset_timing
            read_libs $corner_libs
            redirect "$REPORTS_DIR/synth_timing_${c}.rpt" { report_timing -max_paths 20 }
        } err]} {
            puts "WARNING: Failed to generate timing for corner '$c': $err"
        }
    }
}

puts "=== Genus synthesis done ==="
puts "Netlist: $GENUS_NETLIST"

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

set target_libs [kv32_resolve_libs_for_corner $ACTIVE_CORNER]
set_app_var search_path [concat . $LIB_ROOT]
set_app_var target_library $target_libs
set_app_var link_library [concat * $target_libs]

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

# Compile
set_fix_hold [get_clocks core_clk]
compile_ultra -gate_clock

# Outputs
write -format verilog -hierarchy -output $DC_NETLIST
write -format ddc -hierarchy -output $DC_DDC

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

proc kv32_count_leaf_cells {leaf_cells nand2_area} {
    set area 0.0
    set gates 0
    set seq 0
    set comb 0

    foreach_in_collection c $leaf_cells {
        incr gates
        set ref ""
        catch { set ref [get_attribute $c ref_name] }

        set cell_area 0.0
        set is_seq 0

        if {$ref ne ""} {
            set lc [get_lib_cells */$ref]
            if {[sizeof_collection $lc] > 0} {
                set lc0 [index_collection $lc 0]
                catch { set cell_area [get_attribute $lc0 area] }
                catch { set is_seq [get_attribute $lc0 is_sequential] }
            }
        }

        if {$cell_area <= 0.0} {
            catch { set cell_area [get_attribute $c area] }
        }

        set area [expr {$area + $cell_area}]

        if {$is_seq eq "true" || $is_seq eq "1" || $is_seq == 1} {
            incr seq
        } else {
            incr comb
        }
    }

    set nand2eq [expr {$area / $nand2_area}]
    return [list $area $gates $seq $comb $nand2eq]
}

proc kv32_write_formatted_area_gate_report {report_file top_module} {
    set nand2_area [kv32_find_nand2_area]

    set fp [open $report_file w]
    puts $fp "KV32 Formatted Area/Gate Report (DC)"
    puts $fp "Top Module      : $top_module"
    puts $fp [format "NAND2 Unit Area: %.6f" $nand2_area]
    puts $fp ""
    puts $fp [format "%-70s %-28s %12s %12s %12s %12s %14s" \
        "Hierarchy" "Module" "Area" "GateCnt" "SeqCnt" "CombCnt" "NAND2Eq"]
    puts $fp [string repeat "-" 168]

    # Top summary row
    set top_leafs [get_cells -hierarchical -filter "is_hierarchical == false"]
    lassign [kv32_count_leaf_cells $top_leafs $nand2_area] t_area t_gates t_seq t_comb t_n2
    puts $fp [format "%-70s %-28s %12.3f %12d %12d %12d %14.3f" \
        "/" $top_module $t_area $t_gates $t_seq $t_comb $t_n2]

    # Per-hierarchy-module rows
    set hmods [get_cells -hierarchical -filter "is_hierarchical == true"]
    foreach_in_collection h $hmods {
        set hname [get_object_name $h]
        set mname ""
        catch { set mname [get_attribute $h ref_name] }

        set leafs [get_cells -hierarchical -of_objects $h -filter "is_hierarchical == false"]
        lassign [kv32_count_leaf_cells $leafs $nand2_area] area gates seq comb n2

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
        set libs [kv32_resolve_libs_for_corner $c]
        if {[catch {
            set_app_var target_library $libs
            set_app_var link_library [concat * $libs]
            link
            report_timing -max_paths 20 > "$REPORTS_DIR/synth_timing_${c}.rpt"
        } err]} {
            echo "WARNING: Failed to generate timing for corner '$c': $err"
        }
    }
}

echo "DC synthesis completed. Netlist: $DC_NETLIST"

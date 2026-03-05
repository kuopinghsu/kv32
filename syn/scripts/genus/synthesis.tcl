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

# Read active corner libs for compile.
# TECH_LIB_FILES is built by design.tcl and already contains, in order:
#   1. OpenRAM Liberty files  (sram_1rw_64x21_TT*.lib, sram_1rw_512x32_TT*.lib)
#   2. PDK standard-cell lib  (NangateOpenCellLibrary_typical.lib / asap7 libs)
# kv32_genus_prelib.lib is a helper that defines two stub cells (INVX1_KV32,
# AND2X1_KV32) used to work around ASAP7's aggressive dont_use markings so
# Genus can model RTL inverters/ANDs during elaboration (TIM-30).
# FreePDK45 / Nangate45 does NOT mark any cells dont_use, so loading this lib
# there would introduce cells with wrong operating conditions (0.7 V vs 1.1 V)
# and fake 0.01 ns timing, causing Genus to prefer them over properly
# characterised Nangate cells.  Load it only for ASAP7.
set active_libs $TECH_LIB_FILES
if {$PDK eq "asap7"} {
    set genus_helper_lib [file join $LIB_ROOT "kv32_genus_prelib.lib"]
    if {[file exists $genus_helper_lib]} {
        set active_libs [concat [list $genus_helper_lib] $active_libs]
    }
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

# Suppress expected non-actionable warnings:
#   VLOGPT-35 — simulation #delay specifiers in OpenRAM blackbox models (harmless)
#   LBR-81    — non-monotonic wireload table in NangateOpenCellLibrary (PDK issue)
suppress_message VLOGPT-35
suppress_message LBR-81

puts "Genus input mode: rtl"
set_db init_hdl_search_path [list ../rtl ../rtl/core ../rtl/jtag]
read_hdl -language sv \
    -define SYNTHESIS \
    -define NO_ASSERTION \
    -define GENERIC_SRAM \
    $RTL_FILES

# Genus elaborate -parameters accepts ONLY positional (numeric) values, in the
# exact order parameters are declared in the module.  Both the "name=value" and
# the alternating "name value ..." forms cause [VLOGPT-20] errors because Genus
# evaluates every token as a Verilog constant expression; bare identifiers such
# as "FAST_DIV" are not valid constants, and elaboration fails with [CDFG-304].
#
# kv32_build_param_list parses the top-level SV file at run time to extract all
# parameter declarations in order, converts each default to a plain integer, and
# substitutes any values from the overrides dict.  This means the positional
# list is always in sync with the RTL — no manual update needed when parameters
# are added, removed, or reordered.

proc kv32_build_param_list {sv_file overrides} {
    # --- read source ---
    set fh [open $sv_file r]
    set src [read $fh]
    close $fh

    # --- locate the parameter block inside module ... #( ... ) ---
    # Remove single-line // comments so they don't confuse the parser.
    regsub -all -line {//[^\n]*} $src {} src

    if {![regexp {module\s+kv32_soc\s*#\s*\(} $src]} {
        error "kv32_build_param_list: cannot find 'module kv32_soc #(' in $sv_file"
    }

    # Grab everything from the opening #( up to the matching closing )
    set start [string first "#(" $src [string first "module kv32_soc" $src]]
    set depth 0
    set block ""
    set i $start
    foreach ch [split [string range $src $start end] ""] {
        append block $ch
        if {$ch eq "("} { incr depth }
        if {$ch eq ")"} {
            incr depth -1
            if {$depth == 0} break
        }
        incr i
    }

    # --- extract each "parameter ... NAME = DEFAULT" entry ---
    set params {}
    # Match the parameter keyword, skip optional type/sign/width, capture NAME and DEFAULT
    set re {parameter\s+(?:(?:int|bit|logic|reg|wire)\s+)?(?:unsigned\s+)?(?:\[[^\]]*\]\s*)?(\w+)\s*=\s*([^,)]+)}
    set pos 0
    while {[regexp -indices -start $pos $re $block match g_name g_default]} {
        set name    [string range $block {*}$g_name]
        set default [string trim [string range $block {*}$g_default]]
        lappend params [list $name $default]
        set pos [lindex $match 1]
        incr pos
    }

    if {[llength $params] == 0} {
        error "kv32_build_param_list: no parameters found in $sv_file"
    }

    # --- sv_to_int: convert a SV literal to a plain decimal integer ---
    proc sv_to_int {val} {
        # Remove underscores used as digit separators (e.g. 100_000_000)
        regsub -all {_} $val {} val
        set val [string trim $val]
        # Sized literals: N'hHHH  N'bBBB  N'dDDD  N'oOOO
        # Note: use scan for binary/octal — expr {0b$bin} / {0$oct} does NOT
        # substitute variables inside braces, causing "invalid bareword" errors.
        if {[regexp {^\d+'h([0-9A-Fa-f]+)$} $val -> hex]}  { scan $hex %x r; return $r }
        if {[regexp {^\d+'b([01]+)$}         $val -> bin]}  { scan $bin %b r; return $r }
        if {[regexp {^\d+'d(\d+)$}           $val -> dec]}  { return [expr {$dec + 0}] }
        if {[regexp {^\d+'o([0-7]+)$}        $val -> oct]}  { scan $oct %o r; return $r }
        # Plain integer
        if {[regexp {^-?\d+$} $val]}                        { return [expr {$val + 0}] }
        # Fallback: let Tcl evaluate simple constant expressions (e.g. "4*8")
        if {[catch {set r [expr {$val}]}]} {
            error "sv_to_int: cannot convert '$val' to integer"
        }
        return $r
    }

    # --- build the positional value list ---
    set values {}
    foreach entry $params {
        set name    [lindex $entry 0]
        set default [lindex $entry 1]
        if {[dict exists $overrides $name]} {
            lappend values [dict get $overrides $name]
        } else {
            lappend values [sv_to_int $default]
        }
    }

    puts "  Parameters ([llength $params]):"
    foreach entry $params v $values {
        puts "    [lindex $entry 0] = $v"
    }
    return [join $values " "]
}

# Synthesis overrides — only list parameters that differ from the RTL defaults.
# Adding/removing/reordering parameters in kv32_soc.sv requires NO change here.
set _param_overrides [dict create \
    FAST_DIV         $FAST_DIV         \
    ICACHE_EN        $ICACHE_EN        \
    ICACHE_SIZE      $ICACHE_SIZE      \
    ICACHE_LINE_SIZE $ICACHE_LINE_SIZE \
    ICACHE_WAYS      $ICACHE_WAYS      \
]

set _top_sv [file join [file normalize [file join $SYN_DIR .. rtl]] "kv32_soc.sv"]
if {![file exists $_top_sv]} {
    puts "ERROR: Top-level RTL file not found: $_top_sv"
    exit 1
}

puts "Building positional parameter list from $_top_sv ..."
if {[catch {set _param_list [kv32_build_param_list $_top_sv $_param_overrides]} _err]} {
    puts "ERROR: kv32_build_param_list failed: $_err"
    exit 1
}

if {[catch {elaborate $TOP_MODULE -parameters $_param_list} _err]} {
    puts "ERROR: elaborate failed: $_err"
    exit 1
}

# Verify the design was actually elaborated — Genus returns success even when
# [CDFG-304] fires ("No top-level HDL designs to process"), so check explicitly.
# When parameters are passed, Genus creates a mangled name such as
# kv32_soc_CLK_FREQ100000000_... — use a wildcard prefix search to be robust.
set _found_designs {}
catch {set _found_designs [get_db designs ${TOP_MODULE}*]}
if {[llength $_found_designs] == 0} {
    puts "ERROR: elaborate completed but no design matching '${TOP_MODULE}*' found in database."
    puts "       Likely cause: parameter list mismatch caused \[VLOGPT-20\]/\[CDFG-304\]."
    exit 1
}
# Update TOP_MODULE to the actual elaborated name (parameterized) so that
# write_db, area reports, and other downstream commands reference it correctly.
set TOP_MODULE [get_db [lindex $_found_designs 0] .name]
puts "Elaborated design: $TOP_MODULE"

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
    global NAND2_CELL
    # Use PDK-specific NAND2 cell defined in common/design.tcl
    set cands [get_lib_cells */$NAND2_CELL]
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
    # Escape square brackets so that array-generate instance names like
    # l_g_sram[0] are not mis-interpreted as Tcl character-class patterns
    # in string match (e.g. [0] would otherwise match only digit "0").
    # IMPORTANT: use [list ...] so brace-quoting preserves the literal
    # backslash in the replacement value.  {[ \[ ] \]} looks right but
    # Tcl's list parser strips the backslash, making it a no-op.
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
    puts $fp "KV32 Formatted Area/Gate Report (Genus)"
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
        # Include OpenRAM libs for this corner so SRAM timing is correct.
        set corner_libs [kv32_resolve_all_libs_for_corner $c]
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

# Yosys synthesis flow for kv32
# Target: ASAP7 (default), extensible via common/design.tcl

set SCRIPT_DIR [file dirname [file normalize [info script]]]
set SYN_DIR    [file normalize [file join $SCRIPT_DIR .. ..]]

source [file join $SYN_DIR common design.tcl]

# Tool-specific output segregation
set RESULTS_DIR [file join "results" "yosys"]
set REPORTS_DIR [file join "reports" "yosys"]
file mkdir $RESULTS_DIR
file mkdir $REPORTS_DIR

set SYNTH_NETLIST "$RESULTS_DIR/${DESIGN_NAME}_synth.v"
set SYNTH_BLIF    "$RESULTS_DIR/${DESIGN_NAME}_synth.blif"
set SYNTH_JSON    "$RESULTS_DIR/${DESIGN_NAME}_synth.json"

set SYNTH_AREA_RPT   "$REPORTS_DIR/synth_area.rpt"
set SYNTH_CELLS_RPT  "$REPORTS_DIR/synth_cells.rpt"
set SYNTH_TIMING_RPT "$REPORTS_DIR/synth_timing_estimate.rpt"

puts "=========================================="
puts "Starting Yosys Synthesis for $DESIGN_NAME"
puts "Target: $PDK ($PROCESS_NODE nm) @ ${TARGET_FREQ_MHZ} MHz"
puts "Corner: $ACTIVE_CORNER"
puts "=========================================="

puts "\n\[1/6\] Reading RTL files..."
# Yosys has no Liberty black-box mechanism so the OpenRAM Verilog functional
# models must be included in the RTL list (unlike Genus/DC which use the .lib).
set yosys_rtl_files [concat $RTL_FILES $OPENRAM_RTL_FILES]
foreach rtl_file $yosys_rtl_files {
    if {![file exists $rtl_file]} {
        puts "ERROR: RTL file not found: $rtl_file"
        exit 1
    }
}
yosys read_verilog -sv -D SYNTHESIS -D NO_ASSERTION -D GENERIC_SRAM {*}$yosys_rtl_files

puts "\n\[2/6\] Applying top parameters..."
yosys chparam -set FAST_DIV          $FAST_DIV          $TOP_MODULE
yosys chparam -set ICACHE_EN        $ICACHE_EN        $TOP_MODULE
yosys chparam -set ICACHE_SIZE      $ICACHE_SIZE      $TOP_MODULE
yosys chparam -set ICACHE_LINE_SIZE $ICACHE_LINE_SIZE $TOP_MODULE
yosys chparam -set ICACHE_WAYS      $ICACHE_WAYS      $TOP_MODULE

puts "\n\[3/6\] Hierarchy and checks..."
yosys hierarchy -check -top $TOP_MODULE
yosys check

puts "\n\[4/6\] High-level synthesis and optimization..."
yosys proc
yosys flatten
yosys opt -full
yosys opt_expr
yosys opt_clean
yosys opt_reduce

puts "\n\[5/6\] Tech-independent mapping..."
yosys memory -nomap
yosys memory_collect
yosys memory_map
yosys fsm
yosys fsm_opt
yosys alumacc
yosys share
yosys opt -full

puts "\n\[6/6\] Tech mapping..."
if {[llength $TECH_LIB_FILES] > 0} {
    foreach lib_file $TECH_LIB_FILES {
        if {[file exists $lib_file]} {
            yosys dfflibmap -liberty $lib_file
        }
    }
}
yosys abc9 -lut 6
yosys opt_clean -purge
yosys opt -fast
yosys opt -full
yosys opt_clean

yosys stat

puts "Writing outputs..."
yosys write_verilog -noattr -noexpr -nohex -nodec $SYNTH_NETLIST
yosys write_blif -attr -param $SYNTH_BLIF
yosys write_json $SYNTH_JSON

catch {set timestamp [clock format [clock seconds]]} err
if {$err != ""} {
    set timestamp "Unknown"
}

set area_fp [open $SYNTH_AREA_RPT w]
puts $area_fp "Synthesis Area Report"
puts $area_fp "====================="
puts $area_fp "Design: $DESIGN_NAME"
puts $area_fp "Tool: Yosys"
puts $area_fp "Corner: $ACTIVE_CORNER"
puts $area_fp "Date: $timestamp"
puts $area_fp ""
close $area_fp
yosys tee -a $SYNTH_AREA_RPT stat -top $TOP_MODULE

set cells_fp [open $SYNTH_CELLS_RPT w]
puts $cells_fp "Synthesis Cell Usage Report"
puts $cells_fp "==========================="
puts $cells_fp "Design: $DESIGN_NAME"
puts $cells_fp "Tool: Yosys"
puts $cells_fp "Corner: $ACTIVE_CORNER"
puts $cells_fp "Date: $timestamp"
puts $cells_fp ""
close $cells_fp
yosys tee -a $SYNTH_CELLS_RPT stat -top $TOP_MODULE -width

set timing_fp [open $SYNTH_TIMING_RPT w]
puts $timing_fp "Synthesis Timing Estimate Report"
puts $timing_fp "==============================="
puts $timing_fp "Design: $DESIGN_NAME"
puts $timing_fp "Tool: Yosys"
puts $timing_fp "Corner: $ACTIVE_CORNER"
puts $timing_fp "Target Frequency: $TARGET_FREQ_MHZ MHz"
puts $timing_fp "Clock Period: $CLOCK_PERIOD ns"
puts $timing_fp "Date: $timestamp"
puts $timing_fp ""
puts $timing_fp "Pre-layout estimate only."
close $timing_fp

puts "Yosys synthesis completed."
puts "Netlist: $SYNTH_NETLIST"

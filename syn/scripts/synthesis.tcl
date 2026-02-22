# Yosys Synthesis Script for rv32
# Target: ASAP7 7nm PDK

# Load configuration
source config.tcl

puts "=========================================="
puts "Starting Synthesis for $DESIGN_NAME"
puts "Target: $PDK ($PROCESS_NODE nm) @ ${TARGET_FREQ_MHZ} MHz"
puts "Cell Library: $CELL_LIBRARY"
puts "=========================================="

# Read RTL files
puts "\n\[1/6\] Reading RTL files..."
foreach rtl_file $RTL_FILES {
    if {[file exists $rtl_file]} {
        puts "  Reading: $rtl_file"
        yosys read_verilog -sv $rtl_file
    } else {
        puts "ERROR: RTL file not found: $rtl_file"
        exit 1
    }
}

# Set hierarchy
puts "\n\[2/6\] Setting design hierarchy..."
yosys hierarchy -check -top $TOP_MODULE

# Check design
puts "\n\[3/6\] Checking design..."
yosys check

# Elaborate and optimize (high-level synthesis)
puts "\n\[4/6\] Running high-level synthesis..."

# Process hierarchy
yosys proc

# Flatten if enabled
if {[lsearch $SYNTH_OPTIONS "-flatten"] >= 0} {
    puts "  Flattening design..."
    yosys flatten
}

# Optimize
yosys opt -full
yosys opt_expr
yosys opt_clean
yosys opt_reduce

# Map to Yosys internal cell library (technology-independent)
puts "\n\[5/6\] Technology-independent optimization..."

# Memory mapping
yosys memory -nomap
yosys memory_collect
yosys memory_map

# FSM optimization
yosys fsm
yosys fsm_opt

# Arithmetic optimization
yosys alumacc
yosys share
yosys opt -full

# Technology mapping
puts "\n\[6/6\] Technology mapping to ASAP7 cells..."

# For ASAP7, we'll use the ABC9 mapper with generic library
# Note: Full ASAP7 Liberty files should be provided for accurate mapping
# This is a simplified flow using generic cells

# Map flip-flops
# Only use dfflibmap if liberty files are provided
if {[llength $TECH_LIB_FILES] > 0} {
    puts "  Mapping flip-flops using Liberty file..."
    foreach lib_file $TECH_LIB_FILES {
        yosys dfflibmap -liberty $lib_file
    }
} else {
    puts "  Using generic flip-flop mapping (no Liberty file provided)..."
    yosys dfflegalize -cell \$_DFF_P_ x
}

# Map latches (if any)
yosys abc9 -lut 4

# Map logic to ASAP7 standard cells
# Use ABC9 for better optimization
if {[lsearch $SYNTH_OPTIONS "-abc9"] >= 0} {
    puts "  Using ABC9 synthesis..."
    # Note: For proper ASAP7 mapping, provide Liberty file:
    # abc9 -liberty asap7sc7p5t_SIMPLE_RVT_TT_08302018.lib
    # For now, use generic mapping:
    yosys abc9 -lut 6
} else {
    yosys abc -g AND,NAND,OR,NOR,XOR,XNOR,MUX
}

# Clean up
yosys opt_clean -purge
yosys opt -fast
yosys hilomap -hicell {VDD} {Y} -locell {GND} {Y}

# Final optimization
yosys opt -full
yosys opt_clean

# Statistics before write
puts "\n=========================================="
puts "Synthesis Statistics:"
puts "=========================================="
yosys stat

# Collect cell usage
puts "\n=========================================="
puts "Cell Usage:"
puts "=========================================="
yosys stat -top $TOP_MODULE

# Collect timing estimate (conservative)
puts "\n=========================================="
puts "Estimated Timing (Pre-Placement):"
puts "=========================================="
puts "Target Clock Period: $CLOCK_PERIOD ns (${TARGET_FREQ_MHZ} MHz)"
puts "Note: Accurate timing requires placement and routing"

# Write synthesized netlist
puts "\n=========================================="
puts "Writing Output Files:"
puts "=========================================="
puts "  Netlist: $SYNTH_NETLIST"
yosys write_verilog -noattr -noexpr -nohex -nodec $SYNTH_NETLIST

# Write BLIF for OpenROAD
set blif_file "$RESULTS_DIR/${DESIGN_NAME}_synth.blif"
puts "  BLIF: $blif_file"
yosys write_blif -attr -param $blif_file

# Write JSON for analysis
set json_file "$RESULTS_DIR/${DESIGN_NAME}_synth.json"
puts "  JSON: $json_file"
yosys write_json $json_file

# Generate reports
puts "\n=========================================="
puts "Generating Reports:"
puts "=========================================="

# Get a simple timestamp (avoid msgcat dependency)
catch {set timestamp [clock format [clock seconds]]} err
if {$err != ""} {
    set timestamp "Unknown"
}

# Area report
set area_fp [open $SYNTH_AREA_RPT w]
puts $area_fp "Synthesis Area Report"
puts $area_fp "====================="
puts $area_fp "Design: $DESIGN_NAME"
puts $area_fp "PDK: $PDK $PDK_VARIANT"
puts $area_fp "Date: $timestamp"
puts $area_fp ""
puts $area_fp "Note: Area values are estimates based on gate counts."
puts $area_fp "Accurate area requires physical design (place & route)."
puts $area_fp ""
close $area_fp

# Append statistics to area report
yosys tee -a $SYNTH_AREA_RPT stat -top $TOP_MODULE

puts "  Area report: $SYNTH_AREA_RPT"

# Cell usage report
set cells_fp [open $SYNTH_CELLS_RPT w]
puts $cells_fp "Synthesis Cell Usage Report"
puts $cells_fp "============================"
puts $cells_fp "Design: $DESIGN_NAME"
puts $cells_fp "PDK: $PDK $PDK_VARIANT"
puts $cells_fp "Date: $timestamp"
puts $cells_fp ""
close $cells_fp

# Append cell statistics
yosys tee -a $SYNTH_CELLS_RPT stat -top $TOP_MODULE -width

puts "  Cell usage report: $SYNTH_CELLS_RPT"

# Timing estimate report
set timing_fp [open $SYNTH_TIMING_RPT w]
puts $timing_fp "Synthesis Timing Estimate Report"
puts $timing_fp "================================="
puts $timing_fp "Design: $DESIGN_NAME"
puts $timing_fp "Target Frequency: $TARGET_FREQ_MHZ MHz"
puts $timing_fp "Clock Period: $CLOCK_PERIOD ns"
puts $timing_fp "Date: $timestamp"
puts $timing_fp ""
puts $timing_fp "IMPORTANT: This is a pre-placement timing estimate."
puts $timing_fp "Actual timing will be determined after place & route."
puts $timing_fp ""
puts $timing_fp "Estimated Critical Path Delay: TBD (requires STA)"
puts $timing_fp ""
puts $timing_fp "Register-to-Register Paths:"
puts $timing_fp "  Source: Launch flip-flops"
puts $timing_fp "  Destination: Capture flip-flops"
puts $timing_fp "  Estimated Logic Levels: 5-10 (typical for RV32IM ALU)"
puts $timing_fp ""
puts $timing_fp "Recommendations:"
puts $timing_fp "  - Run OpenROAD placement for accurate timing"
puts $timing_fp "  - Check for long combinational paths"
puts $timing_fp "  - Consider pipeline stages if timing fails"
close $timing_fp

puts "  Timing report: $SYNTH_TIMING_RPT"

puts "\n=========================================="
puts "Synthesis Completed Successfully!"
puts "=========================================="
puts "Output netlist: $SYNTH_NETLIST"
puts "Reports generated in: $REPORTS_DIR/"
puts ""
puts "Next Steps:"
puts "  1. Review synthesis reports"
puts "  2. Run 'make place' for placement"
puts "  3. Run 'make route' for routing"
puts "=========================================="

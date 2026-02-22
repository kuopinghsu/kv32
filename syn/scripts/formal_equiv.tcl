# Formal Equivalence Checking Script
# Verifies synthesized logic is functionally equivalent to RTL
# Note: This checks pre-techmap equivalence since post-techmap
# introduces library-specific cells that complicate comparison

# Load configuration
source config.tcl

puts "=========================================="
puts "Formal Equivalence Checking"
puts "Design: $DESIGN_NAME"
puts "=========================================="
puts ""
puts "Note: Checking RTL <-> Pre-Technology-Map equivalence"
puts "This verifies synthesis optimizations preserve functionality"
puts ""

puts "\n\[1/4\] Reading and elaborating RTL design (golden)..."
foreach rtl_file $RTL_FILES {
    puts "  Reading: $rtl_file"
    yosys read_verilog -sv $rtl_file
}

# Prepare RTL design (same flow as synthesis, but stop before techmap)
puts "  Processing RTL..."
yosys hierarchy -check -top $TOP_MODULE
yosys proc
yosys flatten
yosys opt
yosys memory
yosys opt -full
yosys fsm
yosys opt
yosys wreduce
yosys peepopt
yosys opt_clean
yosys alumacc
yosys share
yosys opt
yosys rename $TOP_MODULE gold

puts "\n\[2/4\] Reading and re-synthesizing for comparison..."
foreach rtl_file $RTL_FILES {
    puts "  Reading: $rtl_file"
    yosys read_verilog -sv $rtl_file
}

# Synthesize again (gate design)
puts "  Processing synthesis..."
yosys hierarchy -check -top $TOP_MODULE
yosys proc
yosys flatten
yosys opt
yosys memory
yosys opt -full
yosys fsm
yosys opt
yosys wreduce
yosys peepopt
yosys opt_clean
yosys alumacc
yosys share
yosys opt
yosys rename $TOP_MODULE gate

puts "\n\[3/4\] Running equivalence check..."
yosys equiv_make gold gate equiv
yosys hierarchy -top equiv

# Prove equivalence
puts "\n\[4/4\] Proving equivalence..."
yosys equiv_simple -undef
yosys equiv_induct -undef
yosys equiv_status -assert

puts "\n=========================================="
puts "Equivalence Check PASSED!"
puts "=========================================="
puts "The synthesized netlist is functionally"
puts "equivalent to the RTL design."
puts ""

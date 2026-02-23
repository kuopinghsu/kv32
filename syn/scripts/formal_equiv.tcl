# Formal Equivalence Checking Script
# Checks pre-techmap equivalence: RTL vs. synthesis-optimised design.
# Uses design -stash / -copy-from to isolate the two RTL reads
# so package enum items are not re-defined on second pass.

source config.tcl

puts {=== Formal Equivalence Checking ===}
puts {Design: $DESIGN_NAME}
puts {Note: RTL <=> Pre-Technology-Map equivalence}
puts {}

# ------------------------------------------------
# [1/4]  Golden design  (RTL, minimal passes)
# ------------------------------------------------
puts "\n\[1/4\] Reading RTL (golden)..."
yosys read_verilog -sv -D SYNTHESIS -D NO_ASSERTION {*}$RTL_FILES
yosys chparam -set ICACHE_EN        $ICACHE_EN        $TOP_MODULE
yosys chparam -set ICACHE_SIZE      $ICACHE_SIZE      $TOP_MODULE
yosys chparam -set ICACHE_LINE_SIZE $ICACHE_LINE_SIZE $TOP_MODULE
yosys chparam -set ICACHE_WAYS      $ICACHE_WAYS      $TOP_MODULE
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
yosys design -stash gold

# ------------------------------------------------
# [2/4]  Gate design  (same passes)
# ------------------------------------------------
puts "\n\[2/4\] Reading RTL (gate)..."
yosys design -reset
yosys read_verilog -sv -D SYNTHESIS -D NO_ASSERTION {*}$RTL_FILES
yosys chparam -set ICACHE_EN        $ICACHE_EN        $TOP_MODULE
yosys chparam -set ICACHE_SIZE      $ICACHE_SIZE      $TOP_MODULE
yosys chparam -set ICACHE_LINE_SIZE $ICACHE_LINE_SIZE $TOP_MODULE
yosys chparam -set ICACHE_WAYS      $ICACHE_WAYS      $TOP_MODULE
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
yosys opt -full
yosys opt_clean
yosys design -stash gate

# ------------------------------------------------
# [3/4]  Equivalence check
# ------------------------------------------------
puts "\n\[3/4\] Running equivalence check..."
yosys design -reset
yosys design -copy-from gold -as gold $TOP_MODULE
yosys design -copy-from gate -as gate $TOP_MODULE
yosys equiv_make gold gate equiv
yosys hierarchy -top equiv

# ------------------------------------------------
# [4/4]  Prove
# ------------------------------------------------
puts "\n\[4/4\] Proving equivalence..."
yosys async2sync
yosys equiv_simple -undef
yosys equiv_induct -undef
yosys equiv_status -assert

puts {}
puts {=== Equivalence Check PASSED! ===}

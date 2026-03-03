# Shared constraints for kv32 synthesis
# This file is sourced by Genus/DC Tcl flows after design is loaded.

if {![info exists TOP_MODULE]} {
    error "TOP_MODULE is not defined. Source common/design.tcl before constraints.sdc"
}
if {![info exists CLOCK_PORT]} {
    error "CLOCK_PORT is not defined. Source common/design.tcl before constraints.sdc"
}
if {![info exists CLOCK_PERIOD]} {
    error "CLOCK_PERIOD is not defined. Source common/design.tcl before constraints.sdc"
}

create_clock -name core_clk -period $CLOCK_PERIOD [get_ports $CLOCK_PORT]
set_clock_uncertainty $CLOCK_UNCERTAINTY [get_clocks core_clk]
set_clock_transition $CLOCK_TRANSITION [get_clocks core_clk]

set in_ports [remove_from_collection [all_inputs] [get_ports $CLOCK_PORT]]
if {[sizeof_collection $in_ports] > 0} {
    set_input_delay $INPUT_DELAY -clock [get_clocks core_clk] $in_ports
}

set out_ports [all_outputs]
if {[sizeof_collection $out_ports] > 0} {
    set_output_delay $OUTPUT_DELAY -clock [get_clocks core_clk] $out_ports
}

# Basic sanity checks
if {[llength [info commands set_fix_multiple_port_nets]] > 0} {
    set_fix_multiple_port_nets -all -buffer_constants
}

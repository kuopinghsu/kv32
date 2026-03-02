 ============================================================================
# File: build.tcl
# Project: KV32 RISC-V Processor - Vivado Batch Build Script
# Target: xcku5p-ffvb676-1-e (Kintex UltraScale+)
#
# Usage:
#   vivado -mode batch -source fpga/build.tcl
#   vivado -mode batch -source fpga/build.tcl -tclargs synth
#   vivado -mode batch -source fpga/build.tcl -tclargs impl
#   vivado -mode batch -source fpga/build.tcl -tclargs bit
# ============================================================================

# ============================================================================
# Configuration
# ============================================================================
set project_name    "kv32_fpga"
set project_dir     "fpga/vivado"
set part            "xcku5p-ffvb676-1-e"
set top_module      "fpga_top"

# Determine project root (script is in fpga/)
set script_dir [file dirname [file normalize [info script]]]
set proj_root  [file dirname $script_dir]

# Build target from command line (default: create project only)
set build_target "project"
if {[llength $argv] > 0} {
    set build_target [lindex $argv 0]
}

puts "============================================================"
puts " KV32 FPGA Build"
puts " Part:   $part"
puts " Target: $build_target"
puts " Root:   $proj_root"
puts "============================================================"

# ============================================================================
# Create Project
# ============================================================================
create_project $project_name $proj_root/$project_dir -part $part -force
set_property target_language SystemVerilog [current_project]

# ============================================================================
# Add RTL Source Files
# ============================================================================
puts "Adding RTL source files..."

# Core package (must be compiled first)
add_files -norecurse $proj_root/rtl/axi_pkg.sv
add_files -norecurse $proj_root/rtl/core/kv32_pkg.sv

# Processor core
add_files -norecurse [glob $proj_root/rtl/core/*.sv]

# AXI peripherals and interconnect
add_files -norecurse $proj_root/rtl/axi_arbiter.sv
add_files -norecurse $proj_root/rtl/axi_clint.sv
add_files -norecurse $proj_root/rtl/axi_i2c.sv
add_files -norecurse $proj_root/rtl/axi_magic.sv
add_files -norecurse $proj_root/rtl/axi_spi.sv
add_files -norecurse $proj_root/rtl/axi_uart.sv
add_files -norecurse $proj_root/rtl/axi_gpio.sv
add_files -norecurse $proj_root/rtl/axi_timer.sv
add_files -norecurse $proj_root/rtl/axi_xbar.sv

# Memory interfaces
add_files -norecurse $proj_root/rtl/mem_axi.sv
add_files -norecurse $proj_root/rtl/mem_axi_ro.sv

# I-cache
add_files -norecurse $proj_root/rtl/kv32_icache.sv

# Power manager
add_files -norecurse $proj_root/rtl/kv32_pm.sv

# JTAG / Debug
add_files -norecurse [glob $proj_root/rtl/jtag/*.sv]
add_files -norecurse $proj_root/rtl/kv32_dtm.sv

# Interrupt controller
add_files -norecurse $proj_root/rtl/kv32_plic.sv

# SoC top level
add_files -norecurse $proj_root/rtl/kv32_soc.sv

# Memories
add_files -norecurse [glob $proj_root/rtl/memories/*.sv]

# FPGA top
add_files -norecurse $proj_root/fpga/fpga_top.sv

# Set file compilation order (packages first)
set_property file_type SystemVerilog [get_files *.sv]

# ============================================================================
# Add Constraints
# ============================================================================
puts "Adding constraints..."
add_files -fileset constrs_1 -norecurse $proj_root/fpga/fpga_top.xdc
set_property used_in_synthesis true  [get_files fpga_top.xdc]
set_property used_in_implementation true [get_files fpga_top.xdc]

# ============================================================================
# Create DDR4 MIG IP (ddr4_0) with AXI Interface
# ============================================================================
puts "Creating DDR4 MIG IP..."
create_ip -name ddr4 -vendor xilinx.com -library ip -version 2.2 \
    -module_name ddr4_0

set_property -dict [list \
    CONFIG.C0.DDR4_MemoryPart           {MT40A512M16HA-075E} \
    CONFIG.C0.DDR4_MemoryType           {Components} \
    CONFIG.C0.DDR4_DataWidth            {16} \
    CONFIG.C0.DDR4_TimePeriod           {833} \
    CONFIG.C0.DDR4_InputClockPeriod     {9996} \
    CONFIG.C0.DDR4_CasLatency           {17} \
    CONFIG.C0.DDR4_CasWriteLatency      {12} \
    CONFIG.C0.DDR4_DataMask             {DM_NO_DBI} \
    CONFIG.C0.DDR4_Mem_Add_Map          {ROW_COLUMN_BANK} \
    CONFIG.C0.DDR4_AxiSelection         {true} \
    CONFIG.C0.DDR4_AxiDataWidth         {64} \
    CONFIG.C0.DDR4_AxiAddressWidth      {32} \
    CONFIG.C0.DDR4_AxiIDWidth           {4} \
    CONFIG.C0.DDR4_AxiArbitrationScheme {RD_PRI_REG} \
    CONFIG.C0.DDR4_AxiNarrowBurst       {false} \
    CONFIG.System_Clock                 {Differential} \
    CONFIG.Reference_Clock              {Differential} \
    CONFIG.C0.BANK_GROUP_WIDTH          {1} \
    CONFIG.C0.DDR4_CLKFBOUT_MULT        {15} \
    CONFIG.C0.DDR4_CLKOUT0_DIVIDE       {5} \
    CONFIG.C0.DDR4_Ordering             {Normal} \
    CONFIG.C0.DDR4_BurstLength          {8} \
    CONFIG.C0.DDR4_BurstType            {Sequential} \
    CONFIG.C0.DDR4_PhyClockRatio        {4:1} \
    CONFIG.C0.DDR4_ChipSelect           {true} \
    CONFIG.C0.DDR4_Slot                 {Single} \
    CONFIG.C0.DDR4_isCustom             {false} \
    CONFIG.DIFF_TERM_SYSCLK             {false} \
    CONFIG.Debug_Signal                 {Disable} \
] [get_ips ddr4_0]

generate_target all [get_ips ddr4_0]
synth_ip [get_ips ddr4_0] -quiet

# ============================================================================
# Create AXI Clock Converter IP (axi_clock_converter_0)
# ============================================================================
# Async clock domain crossing: cpu_clk (50MHz) <-> ui_clk (300MHz)
# AXI4 protocol, 32-bit data, 32-bit addr, 4-bit ID
puts "Creating AXI Clock Converter IP..."
create_ip -name axi_clock_converter -vendor xilinx.com -library ip \
    -module_name axi_clock_converter_0

set_property -dict [list \
    CONFIG.PROTOCOL         {AXI4} \
    CONFIG.DATA_WIDTH       {32} \
    CONFIG.ID_WIDTH         {4} \
    CONFIG.ADDR_WIDTH       {32} \
    CONFIG.ACLK_ASYNC       {1} \
    CONFIG.ACLK_RATIO       {1:1} \
    CONFIG.ARUSER_WIDTH     {0} \
    CONFIG.AWUSER_WIDTH     {0} \
    CONFIG.RUSER_WIDTH      {0} \
    CONFIG.WUSER_WIDTH      {0} \
    CONFIG.BUSER_WIDTH      {0} \
] [get_ips axi_clock_converter_0]

generate_target all [get_ips axi_clock_converter_0]
synth_ip [get_ips axi_clock_converter_0] -quiet

# ============================================================================
# Create AXI Data Width Converter IP (axi_dwidth_converter_0)
# ============================================================================
# Converts 32-bit AXI data width to 64-bit for DDR4 MIG.
# Runs in ui_clk (300MHz) domain.
puts "Creating AXI Data Width Converter IP..."
create_ip -name axi_dwidth_converter -vendor xilinx.com -library ip \
    -module_name axi_dwidth_converter_0

set_property -dict [list \
    CONFIG.SI_DATA_WIDTH    {32} \
    CONFIG.MI_DATA_WIDTH    {64} \
    CONFIG.SI_ID_WIDTH      {4} \
    CONFIG.ADDR_WIDTH       {32} \
    CONFIG.ACLK_ASYNC       {0} \
    CONFIG.MAX_SPLIT_BEATS  {16} \
] [get_ips axi_dwidth_converter_0]

generate_target all [get_ips axi_dwidth_converter_0]
synth_ip [get_ips axi_dwidth_converter_0] -quiet

# ============================================================================
# Set Top Module
# ============================================================================
set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1

# ============================================================================
# Synthesis Settings
# ============================================================================
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
    -value {-verilog_define SYNTHESIS} \
    -objects [get_runs synth_1]

# ============================================================================
# Implementation Settings
# ============================================================================
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]

# ============================================================================
# Build Targets
# ============================================================================
if {$build_target eq "synth" || $build_target eq "impl" || $build_target eq "bit"} {
    puts "Running synthesis..."
    launch_runs synth_1 -jobs [exec nproc]
    wait_on_run synth_1
    if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
        puts "ERROR: Synthesis failed!"
        exit 1
    }
    puts "Synthesis complete."

    # Report utilization after synthesis
    open_run synth_1
    report_utilization -file $proj_root/$project_dir/reports/utilization_synth.rpt
    report_timing_summary -file $proj_root/$project_dir/reports/timing_synth.rpt
    close_design
}

if {$build_target eq "impl" || $build_target eq "bit"} {
    puts "Running implementation..."
    launch_runs impl_1 -jobs [exec nproc]
    wait_on_run impl_1
    if {[get_property STATUS [get_runs impl_1]] ne "route_design Complete!"} {
        puts "ERROR: Implementation failed!"
        exit 1
    }
    puts "Implementation complete."

    # Reports
    open_run impl_1
    file mkdir $proj_root/$project_dir/reports
    report_utilization -file $proj_root/$project_dir/reports/utilization_impl.rpt
    report_timing_summary -file $proj_root/$project_dir/reports/timing_impl.rpt
    report_power -file $proj_root/$project_dir/reports/power_impl.rpt
    close_design
}

if {$build_target eq "bit"} {
    puts "Generating bitstream..."
    launch_runs impl_1 -to_step write_bitstream -jobs [exec nproc]
    wait_on_run impl_1

    # Copy bitstream to output directory
    file mkdir $proj_root/$project_dir/output
    file copy -force \
        $proj_root/$project_dir/$project_name.runs/impl_1/${top_module}.bit \
        $proj_root/$project_dir/output/${top_module}.bit
    puts "Bitstream generated: $project_dir/output/${top_module}.bit"
}

puts "============================================================"
puts " Build complete: $build_target"
puts "============================================================"

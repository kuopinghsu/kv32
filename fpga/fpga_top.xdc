# ============================================================================
# File: fpga_top.xdc
# Project: RV32 RISC-V Processor - FPGA Constraints
# Target: xcku5p-ffvb676-1-e (Kintex UltraScale+)
# Description: Pin assignments, IO standards, and timing constraints
# ============================================================================

# ============================================================================
# Bitstream Configuration
# ============================================================================
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 51.0 [current_design]

# ============================================================================
# System Clock (100MHz Differential)
# ============================================================================
set_property PACKAGE_PIN T25 [get_ports sys_clk_p]
set_property PACKAGE_PIN U25 [get_ports sys_clk_n]
set_property IOSTANDARD DIFF_SSTL12 [get_ports sys_clk_p]
set_property IOSTANDARD DIFF_SSTL12 [get_ports sys_clk_n]

create_clock -period 10.000 -name sys_clk [get_ports sys_clk_p]

# ============================================================================
# System Reset (active-low push button)
# Assign PACKAGE_PIN to actual board reset button
# ============================================================================
# set_property PACKAGE_PIN <PIN> [get_ports sys_rst_n]
# set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]
set_property -quiet IOSTANDARD LVCMOS33 [get_ports sys_rst_n]
set_false_path -from [get_ports sys_rst_n]

# ============================================================================
# DDR4 SDRAM Pin Assignments (MT40A512M16HA-075E, 16-bit)
# ============================================================================

# ---- Bank Group ----
set_property PACKAGE_PIN E25 [get_ports {c0_ddr4_bg[0]}]

# ---- ODT ----
set_property PACKAGE_PIN M24 [get_ports {c0_ddr4_odt[0]}]
set_property IOSTANDARD SSTL12_DCI [get_ports {c0_ddr4_odt[0]}]

# ---- Address Bus ----
set_property PACKAGE_PIN F22 [get_ports {c0_ddr4_adr[0]}]
set_property PACKAGE_PIN K20 [get_ports {c0_ddr4_adr[1]}]
set_property PACKAGE_PIN C26 [get_ports {c0_ddr4_adr[2]}]
set_property PACKAGE_PIN K18 [get_ports {c0_ddr4_adr[3]}]
set_property PACKAGE_PIN K22 [get_ports {c0_ddr4_adr[4]}]
set_property PACKAGE_PIN L19 [get_ports {c0_ddr4_adr[5]}]
set_property PACKAGE_PIN D23 [get_ports {c0_ddr4_adr[6]}]
set_property PACKAGE_PIN J20 [get_ports {c0_ddr4_adr[7]}]
set_property PACKAGE_PIN C24 [get_ports {c0_ddr4_adr[8]}]
set_property PACKAGE_PIN J19 [get_ports {c0_ddr4_adr[9]}]
set_property PACKAGE_PIN L22 [get_ports {c0_ddr4_adr[10]}]
set_property PACKAGE_PIN B26 [get_ports {c0_ddr4_adr[11]}]
set_property PACKAGE_PIN M20 [get_ports {c0_ddr4_adr[12]}]
set_property PACKAGE_PIN D24 [get_ports {c0_ddr4_adr[13]}]
set_property PACKAGE_PIN F23 [get_ports {c0_ddr4_adr[14]}]
set_property PACKAGE_PIN L18 [get_ports {c0_ddr4_adr[15]}]
set_property PACKAGE_PIN L20 [get_ports {c0_ddr4_adr[16]}]

# ---- Data Strobe (DQS) ----
set_property PACKAGE_PIN V21 [get_ports {c0_ddr4_dqs_t[0]}]
set_property PACKAGE_PIN V22 [get_ports {c0_ddr4_dqs_c[0]}]
set_property PACKAGE_PIN W25 [get_ports {c0_ddr4_dqs_t[1]}]
set_property PACKAGE_PIN W26 [get_ports {c0_ddr4_dqs_c[1]}]
set_property IOSTANDARD DIFF_POD12_DCI [get_ports {c0_ddr4_dqs_t[0]}]
set_property IOSTANDARD DIFF_POD12_DCI [get_ports {c0_ddr4_dqs_c[0]}]
set_property IOSTANDARD DIFF_POD12_DCI [get_ports {c0_ddr4_dqs_t[1]}]
set_property IOSTANDARD DIFF_POD12_DCI [get_ports {c0_ddr4_dqs_c[1]}]

# ---- Data Bus (DQ) ----
set_property PACKAGE_PIN U22  [get_ports {c0_ddr4_dq[0]}]
set_property PACKAGE_PIN W20  [get_ports {c0_ddr4_dq[1]}]
set_property PACKAGE_PIN U20  [get_ports {c0_ddr4_dq[2]}]
set_property PACKAGE_PIN W19  [get_ports {c0_ddr4_dq[3]}]
set_property PACKAGE_PIN U21  [get_ports {c0_ddr4_dq[4]}]
set_property PACKAGE_PIN T22  [get_ports {c0_ddr4_dq[5]}]
set_property PACKAGE_PIN T23  [get_ports {c0_ddr4_dq[6]}]
set_property PACKAGE_PIN T20  [get_ports {c0_ddr4_dq[7]}]
set_property PACKAGE_PIN AA24 [get_ports {c0_ddr4_dq[8]}]
set_property PACKAGE_PIN Y25  [get_ports {c0_ddr4_dq[9]}]
set_property PACKAGE_PIN V24  [get_ports {c0_ddr4_dq[10]}]
set_property PACKAGE_PIN Y26  [get_ports {c0_ddr4_dq[11]}]
set_property PACKAGE_PIN AA25 [get_ports {c0_ddr4_dq[12]}]
set_property PACKAGE_PIN W24  [get_ports {c0_ddr4_dq[13]}]
set_property PACKAGE_PIN W23  [get_ports {c0_ddr4_dq[14]}]
set_property PACKAGE_PIN V23  [get_ports {c0_ddr4_dq[15]}]

set_property IOSTANDARD POD12_DCI [get_ports {c0_ddr4_dq[*]}]

# ---- Chip Select ----
set_property PACKAGE_PIN G22 [get_ports {c0_ddr4_cs_n[0]}]

# ---- Clock (Differential) ----
set_property PACKAGE_PIN G24 [get_ports {c0_ddr4_ck_t[0]}]
set_property PACKAGE_PIN G25 [get_ports {c0_ddr4_ck_c[0]}]

# ---- Clock Enable ----
set_property PACKAGE_PIN K23 [get_ports {c0_ddr4_cke[0]}]

# ---- Reset ----
set_property PACKAGE_PIN D26 [get_ports c0_ddr4_reset_n]

# ---- Activate ----
set_property PACKAGE_PIN M21 [get_ports c0_ddr4_act_n]

# ---- Bank Address ----
set_property PACKAGE_PIN E23 [get_ports {c0_ddr4_ba[0]}]
set_property PACKAGE_PIN H22 [get_ports {c0_ddr4_ba[1]}]

# ---- Data Mask ----
set_property PACKAGE_PIN U19 [get_ports {c0_ddr4_dm_dbi_n[0]}]
set_property PACKAGE_PIN Y22 [get_ports {c0_ddr4_dm_dbi_n[1]}]
set_property IOSTANDARD POD12_DCI [get_ports {c0_ddr4_dm_dbi_n[*]}]

# ---- Internal VREF for DDR4 IO Banks ----
set_property INTERNAL_VREF 0.6 [get_iobanks 65]
set_property INTERNAL_VREF 0.6 [get_iobanks 66]

# ============================================================================
# UART (adjust PACKAGE_PIN for your board)
# ============================================================================
# set_property PACKAGE_PIN <PIN> [get_ports uart_rx]
# set_property PACKAGE_PIN <PIN> [get_ports uart_tx]
set_property -quiet IOSTANDARD LVCMOS33 [get_ports uart_rx]
set_property -quiet IOSTANDARD LVCMOS33 [get_ports uart_tx]

# ============================================================================
# SPI (adjust PACKAGE_PIN for your board)
# ============================================================================
# set_property PACKAGE_PIN <PIN> [get_ports spi_sclk]
# set_property PACKAGE_PIN <PIN> [get_ports spi_mosi]
# set_property PACKAGE_PIN <PIN> [get_ports spi_miso]
# set_property PACKAGE_PIN <PIN> [get_ports {spi_cs_n[0]}]
# set_property PACKAGE_PIN <PIN> [get_ports {spi_cs_n[1]}]
# set_property PACKAGE_PIN <PIN> [get_ports {spi_cs_n[2]}]
# set_property PACKAGE_PIN <PIN> [get_ports {spi_cs_n[3]}]
set_property -quiet IOSTANDARD LVCMOS33 [get_ports spi_sclk]
set_property -quiet IOSTANDARD LVCMOS33 [get_ports spi_mosi]
set_property -quiet IOSTANDARD LVCMOS33 [get_ports spi_miso]
set_property -quiet IOSTANDARD LVCMOS33 [get_ports {spi_cs_n[*]}]

# ============================================================================
# I2C (adjust PACKAGE_PIN for your board)
# ============================================================================
# set_property PACKAGE_PIN <PIN> [get_ports i2c_scl]
# set_property PACKAGE_PIN <PIN> [get_ports i2c_sda]
set_property -quiet IOSTANDARD LVCMOS33 [get_ports i2c_scl]
set_property -quiet IOSTANDARD LVCMOS33 [get_ports i2c_sda]
set_property -quiet PULLUP true [get_ports i2c_scl]
set_property -quiet PULLUP true [get_ports i2c_sda]

# ============================================================================
# Status LED
# ============================================================================
# set_property PACKAGE_PIN <PIN> [get_ports led0]
set_property -quiet IOSTANDARD LVCMOS33 [get_ports led0]

# ============================================================================
# Timing Constraints
# ============================================================================

# CPU clock (50MHz, generated by MMCM from DDR4 ui_clk)
# The MMCM auto-derives this clock; add explicit constraint for clarity
# create_generated_clock is not needed as Vivado auto-derives MMCM outputs

# False paths between asynchronous clock domains (handled by AXI clock converter)
set_false_path -from [get_clocks -of_objects [get_pins u_mmcm/CLKOUT0]] \
               -to   [get_clocks -of_objects [get_pins u_ddr4/*/ui_clk]]
set_false_path -from [get_clocks -of_objects [get_pins u_ddr4/*/ui_clk]] \
               -to   [get_clocks -of_objects [get_pins u_mmcm/CLKOUT0]]

# UART input timing (async, false path)
set_false_path -from [get_ports uart_rx]
set_false_path -to   [get_ports uart_tx]

# SPI output timing constraints (relaxed, peripheral speed)
set_false_path -to [get_ports spi_sclk]
set_false_path -to [get_ports spi_mosi]
set_false_path -to [get_ports {spi_cs_n[*]}]
set_false_path -from [get_ports spi_miso]

# I2C (slow bus, false path)
set_false_path -to [get_ports i2c_scl]
set_false_path -to [get_ports i2c_sda]
set_false_path -from [get_ports i2c_scl]
set_false_path -from [get_ports i2c_sda]

# LED output (async)
set_false_path -to [get_ports led0]

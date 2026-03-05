# FPGA Build

This FPGA implementation targets a specific verification board (Kintex UltraScale+ `xcku5p-ffvb676-1-e`) used for hardware validation of the KV32 processor. It is **not** intended for general-purpose deployment and does not provide configurable extensibility for other FPGA boards or platforms.

## Features

- **Processor**: RV32IMAC core running at 50MHz
- **Memory**: DDR4 SDRAM interface (external, 300MHz UI clock)
- **Peripherals**: UART, SPI, I2C
- **Debug**: JTAG/cJTAG interface with 4-pin multiplexing
  - Compile-time selectable: JTAG (IEEE 1149.1) or cJTAG (IEEE 1149.7)
  - Pin 0: TCK/TCKC (clock)
  - Pin 1: TMS/TMSC (bidirectional in cJTAG)
  - Pin 2: TDI (JTAG only)
  - Pin 3: TDO (JTAG only)

## Debug Interface Configuration

The debug interface defaults to **cJTAG mode**. To change modes, edit `fpga_top.sv`:

```systemverilog
localparam USE_CJTAG = 1;  // 0=JTAG, 1=cJTAG (default: 1)
```

- **JTAG Mode (0)**: Standard 4-wire JTAG, compatible with OpenOCD/J-Link
- **cJTAG Mode (1)**: 2-wire cJTAG (uses only pins 0-1), saves I/O pins

### cJTAG Benefits (Default)
- Only 2 wires required (TCKC on pin 0, TMSC on pin 1)
- Saves PCB routing space
- Pins 2-3 can be left unconnected or repurposed
- Full RISC-V debug capability maintained

## Usage

```
vivado -mode batch -source fpga/build.tcl                    # Create project only
vivado -mode batch -source fpga/build.tcl -tclargs synth     # Run synthesis
vivado -mode batch -source fpga/build.tcl -tclargs impl      # Run implementation
vivado -mode batch -source fpga/build.tcl -tclargs bit       # Generate bitstream
```

## Pin Assignments

Update package pin assignments in `fpga_top.xdc` for your specific board:

- **UART**: `uart_rx`, `uart_tx`
- **SPI**: `spi_sclk`, `spi_mosi`, `spi_miso`, `spi_cs_n[3:0]`
- **I2C**: `i2c_scl`, `i2c_sda`
- **JTAG**: `dbg_tck`, `dbg_tms`, `dbg_tdi`, `dbg_tdo`
- **LEDs**: `led0` (DDR4 calibration), `led1` (debug status)

# FPGA Build

This FPGA implementation targets a specific verification board (Kintex UltraScale+ `xcku5p-ffvb676-1-e`) used for hardware validation of the RV32 processor. It is **not** intended for general-purpose deployment and does not provide configurable extensibility for other FPGA boards or platforms.

## Usage

```
vivado -mode batch -source fpga/build.tcl                    # Create project only
vivado -mode batch -source fpga/build.tcl -tclargs synth     # Run synthesis
vivado -mode batch -source fpga/build.tcl -tclargs impl      # Run implementation
vivado -mode batch -source fpga/build.tcl -tclargs bit       # Generate bitstream
```

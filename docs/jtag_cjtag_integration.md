# JTAG/cJTAG Debug Interface Integration

## Overview

The KV32 processor now supports configurable JTAG or cJTAG debug interfaces for RISC-V debugging. This implementation provides full compatibility with both IEEE 1149.1 (JTAG) and IEEE 1149.7 (cJTAG) standards.

## Architecture

```
External Interface (JTAG or cJTAG)
         |
         v
   +-----------+
   | jtag_top  |  Top-level wrapper with mode selection
   +-----------+
         |
         v
   +----------------+         +-----------+
   | cjtag_bridge   | ----->  | jtag_tap  |  TAP state machine
   | (if USE_CJTAG) |         +-----------+
   +----------------+              |
                                   v
                             +-----------+
                             | kv32_dtm  |  Debug Transport Module
                             +-----------+
```

## Module Hierarchy

### 1. **jtag_top.sv** (Top-Level)
- **Purpose**: Configurable wrapper for JTAG/cJTAG interface selection
- **Parameters**:
  - `USE_CJTAG`: 0 for JTAG mode, 1 for cJTAG mode
  - `IDCODE`: 32-bit JTAG device identification code
  - `IR_LEN`: Instruction register length (default: 5)

- **Interfaces**:
  - Standard JTAG (4-wire): `jtag_tck_i`, `jtag_tms_i`, `jtag_tdi_i`, `jtag_tdo_o`
  - cJTAG (2-wire): `cjtag_tckc_i`, `cjtag_tmsc_i`, `cjtag_tmsc_o`, `cjtag_tmsc_oen`
  - System: `clk_i` (required for cJTAG), `ntrst_i`

### 2. **cjtag_bridge.sv**
- **Purpose**: Converts 2-pin cJTAG (IEEE 1149.7) to 4-pin JTAG
- **Features**:
  - Implements OScan1 format with TAP.7 star-2 scan topology
  - Escape sequence detection (selection, deselection, reset)
  - Online/offline state management
  - Activation packet handling

- **Clock Requirements**:
  - System clock must be ≥ 6× TCKC frequency for reliable operation
  - Example: 100MHz system clock supports up to 16MHz TCKC

### 3. **jtag_tap.sv**
- **Purpose**: IEEE 1149.1 TAP Controller state machine
- **Features**:
  - Full TAP state machine (16 states)
  - Instruction register management
  - Data register operations
  - Instantiates kv32_dtm for RISC-V debug support

- **Supported Instructions**:
  - `IDCODE` (0x01): Device identification
  - `DTMCS` (0x10): DTM control and status
  - `DMI` (0x11): Debug Module Interface
  - `BYPASS` (0x1F): Bypass register

### 4. **kv32_dtm.sv**
- **Purpose**: RISC-V Debug Transport Module (DTM)
- **Features**:
  - Implements RISC-V Debug Specification 0.13
  - DMI register access (41 bits with 6-bit address)
  - Debug Module registers: dmcontrol, dmstatus, hartinfo
  - Shift and update operations for debug access

- **DMI Address Space**:
  - `0x10`: dmcontrol (Debug Module Control)
  - `0x11`: dmstatus (Debug Module Status)
  - `0x16`: hartinfo (Hart Information)

## Integration Example

### JTAG Mode (4-wire)
```systemverilog
jtag_top #(
    .USE_CJTAG  (0),
    .IDCODE     (32'h1DEAD3FF)
) u_jtag (
    .clk_i          (clk),
    .ntrst_i        (ntrst),

    // Connect JTAG pins
    .jtag_tck_i     (jtag_tck),
    .jtag_tms_i     (jtag_tms),
    .jtag_tdi_i     (jtag_tdi),
    .jtag_tdo_o     (jtag_tdo),

    // Unused cJTAG pins
    .cjtag_tckc_i   (1'b0),
    .cjtag_tmsc_i   (1'b0),
    .cjtag_tmsc_o   (),
    .cjtag_tmsc_oen (),
    .cjtag_online_o (),
    .cjtag_nsp_o    ()
);
```

### cJTAG Mode (2-wire)
```systemverilog
jtag_top #(
    .USE_CJTAG  (1),
    .IDCODE     (32'h1DEAD3FF)
) u_jtag (
    .clk_i          (clk_100mhz),  // Must be ≥6× TCKC freq
    .ntrst_i        (ntrst),

    // Unused JTAG pins
    .jtag_tck_i     (1'b0),
    .jtag_tms_i     (1'b0),
    .jtag_tdi_i     (1'b0),
    .jtag_tdo_o     (),

    // Connect cJTAG pins
    .cjtag_tckc_i   (cjtag_tckc),
    .cjtag_tmsc_i   (cjtag_tmsc_in),
    .cjtag_tmsc_o   (cjtag_tmsc_out),
    .cjtag_tmsc_oen (cjtag_tmsc_oen),
    .cjtag_online_o (cjtag_online),
    .cjtag_nsp_o    (cjtag_nsp)
);

// Bidirectional TMSC pin handling
assign cjtag_tmsc_in = cjtag_tmsc_bidir;
assign cjtag_tmsc_bidir = cjtag_tmsc_oen ? 1'bz : cjtag_tmsc_out;
```

## Signal Descriptions

### JTAG Signals (4-wire)
| Signal | Direction | Description |
|--------|-----------|-------------|
| `jtag_tck_i` | Input | JTAG Test Clock |
| `jtag_tms_i` | Input | JTAG Test Mode Select |
| `jtag_tdi_i` | Input | JTAG Test Data In |
| `jtag_tdo_o` | Output | JTAG Test Data Out |

### cJTAG Signals (2-wire)
| Signal | Direction | Description |
|--------|-----------|-------------|
| `cjtag_tckc_i` | Input | cJTAG Clock |
| `cjtag_tmsc_i` | Input | cJTAG Data/Control In |
| `cjtag_tmsc_o` | Output | cJTAG Data Out |
| `cjtag_tmsc_oen` | Output | cJTAG Output Enable (0=drive, 1=tristate) |
| `cjtag_online_o` | Output | Online status (1=OScan1 active) |
| `cjtag_nsp_o` | Output | Standard Protocol indicator |

### Common Signals
| Signal | Direction | Description |
|--------|-----------|-------------|
| `clk_i` | Input | System clock (required for cJTAG) |
| `ntrst_i` | Input | JTAG/Debug reset (active low) |

## Debug Operations

### Connecting with GDB/OpenOCD

The JTAG interface supports standard RISC-V debug tools:

1. **OpenOCD Configuration** (for JTAG):
```tcl
interface ftdi
ftdi_vid_pid 0x0403 0x6014

adapter_khz 1000

transport select jtag
jtag newtap kv32 cpu -irlen 5 -expected-id 0x1DEAD3FF

target create kv32.cpu riscv -chain-position kv32.cpu
init
```

2. **OpenOCD Configuration** (for cJTAG):
```tcl
interface ftdi
ftdi_vid_pid 0x0403 0x6014

adapter_khz 1000

# cJTAG requires special adapter or bridge
transport select cjtag
cjtag newtap kv32 cpu -irlen 5 -expected-id 0x1DEAD3FF

target create kv32.cpu riscv -chain-position kv32.cpu
init
```

3. **GDB Connection**:
```bash
riscv32-unknown-elf-gdb program.elf
(gdb) target extended-remote localhost:3333
(gdb) load
(gdb) continue
```

## Timing Requirements

### JTAG Mode
- **TCK Frequency**: Up to 50 MHz (design dependent)
- **Setup/Hold Times**: Follow IEEE 1149.1 specification
- **TDO**: Valid on falling edge of TCK

### cJTAG Mode
- **TCKC Frequency**: Up to system_clock / 6
  - Example: 100MHz system → 16MHz TCKC max
- **Synchronization**: 2-stage synchronizer with edge detection
- **Escape Timing**: TCKC held high during escape sequences

## Debug Registers

### DTMCS (DTM Control and Status)
```
[31:18] Reserved (0)
[17]    dmihardreset (0 - not supported)
[16]    dmireset (0 - not supported)
[15]    Reserved (0)
[14:12] idle (0 - no idle cycles required)
[11:10] dmistat (0 - no error)
[9:4]   abits (6 - DMI address width is 6 bits)
[3:0]   version (1 - DTM version 0.13)
```

### DMI (Debug Module Interface) - 41 bits
```
[40:34] address (7 bits, only 6 used)
[33:2]  data (32 bits)
[1:0]   op (0=NOP, 1=Read, 2=Write, 3=Reserved)
```

### dmstatus (Debug Module Status)
```
[31:23] Reserved
[22]    impebreak
[20]    allhavereset / anyhavereset
[10]    allhalted
[9]     anyhalted
[8]     authenticated
[3:0]   version (3 - Debug Spec 0.13)
```

## Testing

### JTAG Mode Test
1. Apply IDCODE instruction (0x01)
2. Shift out 32-bit IDCODE
3. Verify IDCODE matches expected value (0x1DEAD3FF)

### cJTAG Mode Test
1. Send selection escape sequence (6-7 TMSC toggles with TCKC high)
2. Send activation packet (OAC=1100, EC=1000, CP=0100)
3. Verify online_o = 1
4. Send OScan1 packets (3-bit format)
5. Verify data transfer

## Known Limitations

1. **Simplified DMI**: Current implementation provides basic dmcontrol, dmstatus, and hartinfo registers. Full Debug Module implementation is separate.

2. **Single Hart**: Supports debugging a single hart (hardware thread). Multi-hart support requires extension.

3. **No Authentication**: Authentication is always granted (dmstatus.authenticated = 1).

4. **cJTAG Subset**: Implements OScan1 format only. Advanced cJTAG features (CP0-CP7 scan formats) not implemented.

## File Locations

- Top-level wrapper: `rtl/kv32/jtag/jtag_top.sv`
- cJTAG bridge: `rtl/kv32/jtag/cjtag_bridge.sv`
- TAP controller: `rtl/kv32/jtag/jtag_tap.sv`
- Debug Transport Module: `rtl/kv32/jtag/kv32_dtm.sv`

## References

- RISC-V Debug Specification v0.13
- IEEE 1149.1-2013 (JTAG)
- IEEE 1149.7-2009 (cJTAG)

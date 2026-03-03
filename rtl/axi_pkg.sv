// ============================================================================
// File: axi_pkg.sv
// Project: KV32 RISC-V Processor
// Description: AXI4 Interface Package
//
// Defines AXI4 protocol types and constants used throughout the system.
// Includes response codes, ID width parameters, and common type definitions
// for AXI transactions supporting multiple outstanding requests.
// ============================================================================

package axi_pkg;

    // AXI Response codes
    typedef enum logic [1:0] {
        RESP_OKAY   = 2'b00,
        RESP_EXOKAY = 2'b01,
        RESP_SLVERR = 2'b10,
        RESP_DECERR = 2'b11
    } axi_resp_e;

    // AXI ID width parameter (supports up to 16 outstanding transactions)
    parameter int AXI_ID_WIDTH = 4;

    // Transaction ID type
    typedef logic [AXI_ID_WIDTH-1:0] axi_id_t;

endpackage


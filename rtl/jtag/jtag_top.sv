// ============================================================================
// File: jtag_top.sv
// Project: KV32 RISC-V Processor
// Description: Top-level JTAG/cJTAG Interface Module with Pin Multiplexing
//
// Provides configurable JTAG or cJTAG interface support for RISC-V debug
// - USE_CJTAG=0: Standard 4-wire JTAG (TCK, TMS, TDI, TDO)
// - USE_CJTAG=1: 2-wire cJTAG (TCKC, TMSC) with IEEE 1149.7 bridge
//
// PIN MULTIPLEXING (all modes share same 4 physical pins):
//   Pin 0: TCK (JTAG) / TCKC (cJTAG)    - Clock input
//   Pin 1: TMS (JTAG) / TMSC (cJTAG)    - Input/Bidirectional
//   Pin 2: TDI (JTAG) / unused (cJTAG)  - Input
//   Pin 3: TDO (JTAG) / unused (cJTAG)  - Output
//
// ARCHITECTURE:
//   External Interface (JTAG or cJTAG) -> [cjtag_bridge] -> jtag_tap -> kv32_dtm
//
// CONNECTIONS:
//   - cJTAG mode: cjtag_bridge converts 2-wire to 4-wire, feeds jtag_tap
//   - JTAG mode: External 4-wire JTAG directly connects to jtag_tap
//   - jtag_tap implements TAP state machine and instantiates kv32_dtm
//   - kv32_dtm implements Debug Transport Module per RISC-V Debug Spec
// ============================================================================

module jtag_top #(
    parameter USE_CJTAG = 1,            // 0=JTAG, 1=cJTAG (default: cJTAG)
    parameter IDCODE = 32'h1DEAD3FF,    // JTAG ID code
    parameter IR_LEN = 5                // Instruction register length
)(
    // System clock (required for cJTAG mode)
    input  logic        clk_i,          // System clock (e.g., 100MHz)
    input  logic        rst_n_i,        // System reset (active low)
    input  logic        ntrst_i,        // JTAG reset (active low)

    // Shared Physical Pins (4-pin interface, muxed between JTAG/cJTAG)
    // Pin 0: TCK/TCKC (clock input)
    input  logic        pin0_tck_i,     // JTAG TCK or cJTAG TCKC

    // Pin 1: TMS/TMSC (bidirectional in cJTAG, input in JTAG)
    input  logic        pin1_tms_i,     // JTAG TMS or cJTAG TMSC input
    output logic        pin1_tms_o,     // cJTAG TMSC output (JTAG: unused)
    output logic        pin1_tms_oe,    // Output enable: 0=drive output, 1=tristate

    // Pin 2: TDI (JTAG only, unused in cJTAG)
    input  logic        pin2_tdi_i,     // JTAG TDI (cJTAG: don't care)

    // Pin 3: TDO (JTAG only, unused in cJTAG)
    output logic        pin3_tdo_o,     // JTAG TDO (cJTAG: 0)
    output logic        pin3_tdo_oe,    // Output enable: 0=drive output, 1=tristate

    // Status outputs (cJTAG mode only)
    output logic        cjtag_online_o, // cJTAG online status
    output logic        cjtag_nsp_o,    // cJTAG standard protocol indicator

    // Debug interface to CPU
    output logic        halt_req_o,      // Request CPU to halt
    input  logic        halted_i,        // CPU is halted
    output logic        resume_req_o,    // Request CPU to resume
    input  logic        resumeack_i,     // CPU acknowledged resume

    // Register access
    output logic [4:0]  dbg_reg_addr_o,    // Register address
    output logic [31:0] dbg_reg_wdata_o,   // Register write data
    output logic        dbg_reg_we_o,      // Register write enable
    input  logic [31:0] dbg_reg_rdata_i,   // Register read data

    // PC access
    output logic [31:0] dbg_pc_wdata_o,    // PC write data
    output logic        dbg_pc_we_o,       // PC write enable
    input  logic [31:0] dbg_pc_i,          // Current PC

    // Memory access
    output logic        dbg_mem_req_o,      // Memory request
    output logic [31:0] dbg_mem_addr_o,    // Memory address
    output logic [3:0]  dbg_mem_we_o,      // Memory write enable (byte mask)
    output logic [31:0] dbg_mem_wdata_o,   // Memory write data
    input  logic        dbg_mem_ready_i,   // Memory ready
    input  logic [31:0] dbg_mem_rdata_i,   // Memory read data

    // System reset outputs
    output logic        dbg_ndmreset_o,    // Non-debug module reset (resets SoC except DM)
    output logic        dbg_hartreset_o    // Hart reset request
);

    // =========================================================================
    // Internal JTAG signals (between bridge/external and TAP controller)
    // =========================================================================
    logic tap_tck;      // JTAG clock to TAP
    logic tap_tms;      // JTAG TMS to TAP
    logic tap_tdi;      // JTAG TDI to TAP
    logic tap_tdo;      // JTAG TDO from TAP

    // =========================================================================
    // Pin Multiplexing: Demux inputs and mux outputs based on mode
    // =========================================================================
    // Internal signals for each mode
    logic jtag_tck, jtag_tms, jtag_tdi, jtag_tdo;
    logic cjtag_tckc, cjtag_tmsc_in, cjtag_tmsc_out, cjtag_tmsc_oen;

    // Demux inputs from shared pins
    assign jtag_tck     = pin0_tck_i;           // JTAG TCK from pin 0
    assign jtag_tms     = pin1_tms_i;           // JTAG TMS from pin 1
    assign jtag_tdi     = pin2_tdi_i;           // JTAG TDI from pin 2

    assign cjtag_tckc   = pin0_tck_i;           // cJTAG TCKC from pin 0
    assign cjtag_tmsc_in = pin1_tms_i;          // cJTAG TMSC from pin 1

    // Mux outputs to shared pins based on mode
    generate
        if (USE_CJTAG) begin : gen_pin_mux_cjtag
            // cJTAG mode: Pin 1 is bidirectional TMSC, Pin 3 is unused
            assign pin1_tms_o   = cjtag_tmsc_out;
            assign pin1_tms_oe  = cjtag_tmsc_oen;
            assign pin3_tdo_o   = 1'b0;
            assign pin3_tdo_oe  = 1'b1;         // Tristate (unused)

        end else begin : gen_pin_mux_jtag
            // JTAG mode: Pin 1 is input-only TMS, Pin 3 is TDO output
            assign pin1_tms_o   = 1'b0;
            assign pin1_tms_oe  = 1'b1;         // Tristate (input mode)
            assign pin3_tdo_o   = jtag_tdo;
            assign pin3_tdo_oe  = 1'b0;         // Drive output
        end
    endgenerate

    // =========================================================================
    // Conditional cJTAG Bridge Instantiation
    // =========================================================================
    generate
        if (USE_CJTAG) begin : gen_cjtag_mode
            // cJTAG mode: Instantiate bridge to convert 2-wire to 4-wire
            cjtag_bridge u_cjtag_bridge (
                .clk_i          (clk_i),
                .ntrst_i        (ntrst_i),

                // cJTAG Interface (external 2-wire via shared pins)
                .tckc_i         (cjtag_tckc),
                .tmsc_i         (cjtag_tmsc_in),
                .tmsc_o         (cjtag_tmsc_out),
                .tmsc_oen       (cjtag_tmsc_oen),

                // JTAG Interface (internal 4-wire to TAP)
                .tck_o          (tap_tck),
                .tms_o          (tap_tms),
                .tdi_o          (tap_tdi),
                .tdo_i          (tap_tdo),

                // Status
                .online_o       (cjtag_online_o),
                .nsp_o          (cjtag_nsp_o)
            );

        end else begin : gen_jtag_mode
            // JTAG mode: Direct connection from shared pins
            assign tap_tck = jtag_tck;
            assign tap_tms = jtag_tms;
            assign tap_tdi = jtag_tdi;
            assign jtag_tdo = tap_tdo;

            // Tie off unused cJTAG status outputs
            assign cjtag_online_o = 1'b0;
            assign cjtag_nsp_o = 1'b1;
        end
    endgenerate

    // =========================================================================
    // JTAG TAP Controller (Always Instantiated)
    // =========================================================================
    // Implements IEEE 1149.1 TAP state machine and instantiates kv32_dtm
    jtag_tap #(
        .IDCODE     (IDCODE),
        .IR_LEN     (IR_LEN)
    ) u_jtag_tap (
        // JTAG interface
        .tck_i      (tap_tck),
        .tms_i      (tap_tms),
        .tdi_i      (tap_tdi),
        .tdo_o      (tap_tdo),
        .ntrst_i    (ntrst_i),

        // System clock and reset
        .clk        (clk_i),
        .rst_n      (rst_n_i),

        // Debug interface to CPU
        .halt_req_o     (halt_req_o),
        .halted_i       (halted_i),
        .resume_req_o   (resume_req_o),
        .resumeack_i    (resumeack_i),

        // Register access
        .dbg_reg_addr_o  (dbg_reg_addr_o),
        .dbg_reg_wdata_o (dbg_reg_wdata_o),
        .dbg_reg_we_o    (dbg_reg_we_o),
        .dbg_reg_rdata_i (dbg_reg_rdata_i),

        // PC access
        .dbg_pc_wdata_o  (dbg_pc_wdata_o),
        .dbg_pc_we_o     (dbg_pc_we_o),
        .dbg_pc_i        (dbg_pc_i),

        // Memory access
        .dbg_mem_req_o    (dbg_mem_req_o),
        .dbg_mem_addr_o   (dbg_mem_addr_o),
        .dbg_mem_we_o     (dbg_mem_we_o),
        .dbg_mem_wdata_o  (dbg_mem_wdata_o),
        .dbg_mem_ready_i  (dbg_mem_ready_i),
        .dbg_mem_rdata_i  (dbg_mem_rdata_i),

        // System reset outputs
        .dbg_ndmreset_o   (dbg_ndmreset_o),
        .dbg_hartreset_o  (dbg_hartreset_o)
    );

    // =========================================================================
    // Assertions and Checks
    // =========================================================================
    // Monitor JTAG/cJTAG activity
    `ifdef DEBUG
    always @(posedge tap_tck) begin
        `DEBUG2(`DBG_GRP_JTAG, ("[%0t] JTAG_TOP: TAP TCK posedge, TMS=%b TDI=%b TDO=%b",
               $time, tap_tms, tap_tdi, tap_tdo));
    end
    `endif

    // When USE_CJTAG=1, jtag_tck/tms/tdi/tdo are assigned from pins
    // but not forwarded to the TAP (cJTAG bridge handles it instead).
`ifndef SYNTHESIS
    // Lint sink (debug only): standard JTAG pins unused when cJTAG bridge is active.
    logic _unused_ok_jtag;
    assign _unused_ok_jtag = &{1'b0, jtag_tck, jtag_tms, jtag_tdi, jtag_tdo};
`endif // SYNTHESIS

endmodule


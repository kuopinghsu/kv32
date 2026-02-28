// ============================================================================
// File: kv32_dtm.sv
// Project: KV32 RISC-V Processor
// Description: RISC-V Debug Transport Module (DTM) with Debug Module
//
// Implements the JTAG Debug Transport Module interface per RISC-V Debug Spec 0.13
// Includes full Debug Module with register access, memory access, halt/resume control
//
// Supported Instructions:
//   - IDCODE (0x01): Returns device ID
//   - DTMCS  (0x10): DTM Control and Status register
//   - DMI    (0x11): Debug Module Interface access
//   - BYPASS (0x1F): Bypass register
//
// Debug Module Registers:
//   - 0x04-0x0f: data0-data11 (Abstract data registers)
//   - 0x10: dmcontrol (Debug Module Control)
//   - 0x11: dmstatus (Debug Module Status)
//   - 0x16: hartinfo (Hart Information)
//   - 0x17: abstracts (Abstract Control and Status)
//   - 0x18: command (Abstract Command)
//   - 0x20-0x2f: progbuf0-progbuf15 (Program Buffer)
//   - 0x40: haltsum0 (Halt Summary)
//
// ============================================================================

module kv32_dtm #(
    parameter IDCODE = 32'h1DEAD3FF
) (
    // JTAG Interface (from TAP controller)
    input  logic       tck_i,        // JTAG clock
    input  logic       tdi_i,        // JTAG data in
    output logic       tdo_o,        // JTAG data out
    input  logic       capture_dr_i, // Capture-DR state
    input  logic       shift_dr_i,   // Shift-DR state
    input  logic       update_dr_i,  // Update-DR state
    input  logic [4:0] ir_i,         // Current instruction register

    // System
    input  logic       ntrst_i,      // JTAG reset (active low)
    input  logic       clk,          // System clock
    input  logic       rst_n,        // System reset (active low)

    // Debug Interface to CPU Core
    output logic        dbg_halt_req_o,      // Request CPU to halt
    input  logic        dbg_halted_i,        // CPU is halted
    output logic        dbg_resume_req_o,    // Request CPU to resume
    input  logic        dbg_resumeack_i,     // CPU has resumed
    output logic [4:0]  dbg_reg_addr_o,      // GPR address for access
    output logic [31:0] dbg_reg_wdata_o,     // GPR write data
    output logic        dbg_reg_we_o,        // GPR write enable
    input  logic [31:0] dbg_reg_rdata_i,     // GPR read data
    input  logic [31:0] dbg_pc_i,            // Current PC from CPU
    output logic [31:0] dbg_pc_wdata_o,      // PC write data
    output logic        dbg_pc_we_o,         // PC write enable

    // Debug memory access interface
    output logic       dbg_mem_req_o,       // Memory request valid
    output logic [31:0] dbg_mem_addr_o,     // Memory address
    output logic [3:0] dbg_mem_we_o,        // Memory write enable (byte mask)
    output logic [31:0] dbg_mem_wdata_o,    // Memory write data
    input  logic       dbg_mem_ready_i,     // Memory ready
    input  logic [31:0] dbg_mem_rdata_i     // Memory read data
);

    // ========================================================================
    // Instruction Opcodes
    // ========================================================================
    localparam IR_IDCODE  = 5'h01;  // IDCODE instruction
    localparam IR_DTMCS   = 5'h10;  // DTM Control and Status
    localparam IR_DMI     = 5'h11;  // Debug Module Interface
    localparam IR_BYPASS  = 5'h1F;  // Bypass

    // ========================================================================
    // DMI Register Addresses (6 bits)
    // ========================================================================
    localparam DMI_DATA0     = 7'h04;  // Abstract data 0
    localparam DMI_DATA1     = 7'h05;  // Abstract data 1
    localparam DMI_DMCONTROL = 7'h10;  // Debug Module Control
    localparam DMI_DMSTATUS  = 7'h11;  // Debug Module Status
    localparam DMI_HARTINFO  = 7'h12;  // Hart Information
    localparam DMI_ABSTRACTCS = 7'h16; // Abstract Control and Status
    localparam DMI_COMMAND   = 7'h17;  // Abstract Command
    localparam DMI_PROGBUF0  = 7'h20;  // Program Buffer 0
    localparam DMI_PROGBUF1  = 7'h21;  // Program Buffer 1
    localparam DMI_HALTSUM0  = 7'h40;  // Halt Summary 0

    // ========================================================================
    // Abstract Command Encoding
    // ========================================================================
    localparam CMD_ACCESS_REG = 8'h00;  // Register access command
    localparam CMD_QUICK_ACCESS = 8'h01; // Quick access command
    localparam CMD_ACCESS_MEM = 8'h02;  // Memory access command

    // Abstract command status
    localparam CMDERR_NONE = 3'd0;      // No error
    localparam CMDERR_BUSY = 3'd1;      // Command is busy
    localparam CMDERR_NOTSUP = 3'd2;    // Command not supported
    localparam CMDERR_EXCEPTION = 3'd3; // Exception during command
    localparam CMDERR_HALTRESUME = 3'd4; // Hart not in correct state
    localparam CMDERR_BUS = 3'd5;       // Bus error
    localparam CMDERR_OTHER = 3'd7;     // Other error

    // ========================================================================
    // DTMCS Register (32 bits) - Read Only
    // ========================================================================
    // Bits [31:18]: Reserved (0)
    // Bits [17]:    dmihardreset (0 - not supported)
    // Bits [16]:    dmireset (0 - not supported)
    // Bits [15]:    Reserved (0)
    // Bits [14:12]: idle (0 - no idle cycles required)
    // Bits [11:10]: dmistat (0 - no error)
    // Bits [9:4]:   abits (6 - DMI address width is 6 bits)
    // Bits [3:0]:   version (1 - DTM version 0.13)
    localparam [31:0] DTMCS_VALUE = {
        14'b0,           // [31:18] Reserved
        1'b0,            // [17] dmihardreset
        1'b0,            // [16] dmireset
        1'b0,            // [15] Reserved
        3'd0,            // [14:12] idle (no idle cycles needed)
        2'b00,           // [11:10] dmistat (no error)
        6'd6,            // [9:4] abits (DMI address = 6 bits)
        4'd1             // [3:0] version (0.13)
    };

    // ========================================================================
    // DMI Register (41 bits for abits=6)
    // ========================================================================
    // Bits [40:34]: address (7 bits, but only 6 used)
    // Bits [33:2]:  data (32 bits)
    // Bits [1:0]:   op (2 bits: 0=NOP, 1=Read, 2=Write, 3=Reserved)

    // ========================================================================
    // Debug Module Registers
    // ========================================================================

    // dmcontrol register (0x10)
    logic        dmcontrol_haltreq;     // Halt request
    logic        dmcontrol_resumereq;   // Resume request
    logic        dmcontrol_hartreset;   // Hart reset
    logic        dmcontrol_ackhavereset; // Acknowledge have reset
    logic        dmcontrol_ndmreset;    // Debug module reset
    logic        dmcontrol_dmactive;    // Debug module active

    // dmstatus register (0x11) - Read only, reflects current state
    wire         dmstatus_allresumeack;
    wire         dmstatus_anyresumeack;
    wire         dmstatus_allrunning;
    wire         dmstatus_anyrunning;
    wire         dmstatus_allhalted;
    wire         dmstatus_anyhalted;

    // hartinfo register (0x12) - Read only
    localparam [31:0] HARTINFO_VALUE = {
        8'b0,           // [31:24] Reserved
        4'd1,           // [23:20] nscratch (1 scratch register)
        3'b0,           // [19:17] Reserved
        1'b0,           // [16] dataaccess (no direct data access)
        4'd2,           // [15:12] datasize (2 = 64-bit for GPR + CSR)
        12'd0           // [11:0] dataaddr
    };

    // abstractcs register (0x16) - split between TCK and system domains
    logic [2:0]  abstractcs_cmderr;     // Command error (TCK domain)
    logic [2:0]  abstractcs_cmderr_sys; // Command error (system clock domain)
    logic        abstractcs_busy;       // Command busy (system clock domain)
    localparam [3:0] ABSTRACTCS_DATACOUNT = 4'd2;   // 2 data registers
    localparam [4:0] ABSTRACTCS_PROGBUFSIZE = 5'd2; // 2 progbuf registers

    // Abstract data registers (TCK domain)
    logic [31:0] data0;                 // data0 register
    logic [31:0] data1;                 // data1 register (for 64-bit accesses)

    // Program buffer registers
    logic [31:0] progbuf0;
    logic [31:0] progbuf1;

    // Abstract command register (TCK domain)
    logic [31:0] command_reg;

    // System clock domain shadow registers for abstract command execution
    logic [31:0] data0_sys;
    logic [31:0] data0_result;      // Result written by system domain
    logic        data0_result_valid; // Result valid flag
    logic [31:0] command_reg_sys;
    logic        command_valid_sys;

    // ========================================================================
    // State Machine for Abstract Command Execution
    // ========================================================================
    typedef enum logic [2:0] {
        CMD_IDLE,
        CMD_REG_READ,
        CMD_REG_WRITE,
        CMD_MEM_READ,
        CMD_MEM_WRITE,
        CMD_WAIT,
        CMD_DONE
    } cmd_state_t;

    cmd_state_t cmd_state, cmd_state_next;
    logic [4:0] cmd_regno;              // Register number being accessed
    logic [2:0] cmd_size;               // Access size (0=byte, 1=half, 2=word, 3=double)
    logic       cmd_write;              // Command is write (vs read)
    logic       cmd_postexec;           // Execute progbuf after command
    logic       cmd_transfer;           // Perform transfer

    // CPU Control Signals
    logic       halt_req_sync;
    logic       resume_req_sync;
    logic       halted_sync, halted_sync_r;
    logic       resumeack_sync, resumeack_sync_r;

    // Memory access tracking
    logic       mem_req_pending;
    logic [1:0] mem_wait_cnt;

    // ========================================================================
    // Status signals derived from CPU state
    // ========================================================================
    assign dmstatus_anyhalted = halted_sync;
    assign dmstatus_allhalted = halted_sync;
    assign dmstatus_anyrunning = !halted_sync;
    assign dmstatus_allrunning = !halted_sync;
    assign dmstatus_anyresumeack = resumeack_sync && !resumeack_sync_r;
    assign dmstatus_allresumeack = dmstatus_anyresumeack;

    // ========================================================================
    // Clock Domain Crossing Synchronizers
    // ========================================================================
    // Synchronize CPU signals from system clock domain to TCK domain
    logic [2:0] halted_sync_chain;
    logic [2:0] resumeack_sync_chain;

    always_ff @(posedge tck_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            halted_sync_chain <= 3'b0;
            resumeack_sync_chain <= 3'b0;
            halted_sync <= 1'b0;
            halted_sync_r <= 1'b0;
            resumeack_sync <= 1'b0;
            resumeack_sync_r <= 1'b0;
        end else begin
            // Double-synchronize CPU status signals
            halted_sync_chain <= {halted_sync_chain[1:0], dbg_halted_i};
            halted_sync <= halted_sync_chain[2];
            halted_sync_r <= halted_sync;

            resumeack_sync_chain <= {resumeack_sync_chain[1:0], dbg_resumeack_i};
            resumeack_sync <= resumeack_sync_chain[2];
            resumeack_sync_r <= resumeack_sync;
        end
    end

    // Synchronize debug requests from TCK domain to system clock domain
    logic [2:0] halt_req_sync_chain;
    logic [2:0] resume_req_sync_chain;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            halt_req_sync_chain <= 3'b0;
            resume_req_sync_chain <= 3'b0;
        end else begin
            halt_req_sync_chain <= {halt_req_sync_chain[1:0], dmcontrol_haltreq};
            resume_req_sync_chain <= {resume_req_sync_chain[1:0], dmcontrol_resumereq};
        end
    end

    assign dbg_halt_req_o = halt_req_sync_chain[2];
    assign dbg_resume_req_o = resume_req_sync_chain[2];

    // ========================================================================
    // Shift Registers
    // ========================================================================
    logic [31:0] idcode_shift;
    logic [31:0] dtmcs_shift;
    logic [40:0] dmi_shift;
    logic        bypass_shift;

    // DMI state
    logic [6:0]  dmi_address;

    // ========================================================================
    // Construct dmcontrol read value
    // ========================================================================
    wire [31:0] dmcontrol_rdata = {
        1'b0,                   // [31] haltreq
        1'b0,                   // [30] resumereq
        1'b0,                   // [29] hartreset
        1'b0,                   // [28] ackhavereset
        1'b0,                   // [27] Reserved
        1'b1,                   // [26] hasel (single hart selected)
        10'b0,                  // [25:16] hartsello (hart 0)
        10'b0,                  // [15:6] hartselhi
        4'b0,                   // [5:2] Reserved
        1'b0,                   // [1] ndmreset
        dmcontrol_dmactive      // [0] dmactive
    };

    // ========================================================================
    // Construct dmstatus read value
    // ========================================================================
    wire [31:0] dmstatus_rdata = {
        9'b0,                       // [31:23] Reserved
        1'b0,                       // [22] impebreak
        1'b0,                       // [21] Reserved
        1'b0,                       // [20] allhavereset
        1'b0,                       // [19] anyhavereset
        dmstatus_allresumeack,      // [18]
        dmstatus_anyresumeack,      // [17]
        1'b0,                       // [16] allnonexistent
        1'b0,                       // [15] anynonexistent
        1'b0,                       // [14] allunavail
        1'b0,                       // [13] anyunavail
        dmstatus_allrunning,        // [12]
        dmstatus_anyrunning,        // [11]
        dmstatus_allhalted,         // [10]
        dmstatus_anyhalted,         // [9]
        1'b1,                       // [8] authenticated
        1'b0,                       // [7] authbusy
        1'b0,                       // [6] hasresethaltreq
        1'b0,                       // [5] confstrptrvalid
        1'b0,                       // [4] Reserved
        4'b0011                     // [3:0] version
    };

    // ========================================================================
    // Construct abstractcs read value
    // ========================================================================
    wire [31:0] abstractcs_rdata = {
        3'b0,                       // [31:29] Reserved
        5'd0,                       // [28:24] progbufsize
        11'b0,                      // [23:13] Reserved
        abstractcs_busy,            // [12] busy
        1'b0,                       // [11] Reserved
        abstractcs_cmderr,          // [10:8] cmderr
        4'b0,                       // [7:4] Reserved
        ABSTRACTCS_DATACOUNT        // [3:0] datacount
    };

    // ========================================================================
    // Construct haltsum0 read value
    // ========================================================================
    wire [31:0] haltsum0_rdata = {
        31'b0,
        dmstatus_anyhalted          // Hart 0 halted
    };
    // ========================================================================
    // Capture-DR and Shift-DR: Load and shift registers
    // ========================================================================
    always_ff @(posedge tck_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            // Initialize shift registers to zero (loaded during CAPTURE_DR)
            idcode_shift  <= 32'b0;
            dtmcs_shift   <= 32'b0;
            dmi_shift     <= 41'b0;
            bypass_shift  <= 1'b0;
        end else if (capture_dr_i) begin
            case (ir_i)
                IR_IDCODE: begin
                    idcode_shift <= IDCODE;
                    `DEBUG2(("[%0t] DTM: CAPTURE_DR IDCODE, loading %h", $time, IDCODE));
                end
                IR_DTMCS: begin
                    dtmcs_shift <= DTMCS_VALUE;
                end
                IR_DMI: begin
                    // Capture: Return data from previous operation
                    // Read the requested DMI register
                    case (dmi_address)
                        DMI_DATA0:     dmi_shift <= {dmi_address, data0, 2'b00};
                        DMI_DATA1:     dmi_shift <= {dmi_address, data1, 2'b00};
                        DMI_DMCONTROL: dmi_shift <= {dmi_address, dmcontrol_rdata, 2'b00};
                        DMI_DMSTATUS:  dmi_shift <= {dmi_address, dmstatus_rdata, 2'b00};
                        DMI_HARTINFO:  dmi_shift <= {dmi_address, HARTINFO_VALUE, 2'b00};
                        DMI_ABSTRACTCS: dmi_shift <= {dmi_address, abstractcs_rdata, 2'b00};
                        DMI_COMMAND:   dmi_shift <= {dmi_address, command_reg, 2'b00};
                        DMI_PROGBUF0:  dmi_shift <= {dmi_address, progbuf0, 2'b00};
                        DMI_PROGBUF1:  dmi_shift <= {dmi_address, progbuf1, 2'b00};
                        DMI_HALTSUM0:  dmi_shift <= {dmi_address, haltsum0_rdata, 2'b00};
                        default:       dmi_shift <= {dmi_address, 32'h0, 2'b00};
                    endcase
                end
                IR_BYPASS: begin
                    bypass_shift <= 1'b0;
                end
                default: begin
                    bypass_shift <= 1'b0;
                end
            endcase
        end else if (shift_dr_i) begin
            case (ir_i)
                IR_IDCODE: begin
                    idcode_shift  <= {tdi_i, idcode_shift[31:1]};
                    `DEBUG2(("[%0t] DTM: SHIFT_DR IDCODE, tdo=%b, idcode_shift=%h -> %h",
                           $time, idcode_shift[0], idcode_shift, {tdi_i, idcode_shift[31:1]}));
                end
                IR_DTMCS: begin
                    dtmcs_shift   <= {tdi_i, dtmcs_shift[31:1]};
                end
                IR_DMI: begin
                    dmi_shift     <= {tdi_i, dmi_shift[40:1]};
                end
                IR_BYPASS: begin
                    bypass_shift  <= tdi_i;
                end
                default: begin
                    bypass_shift  <= tdi_i;
                end
            endcase
        end
    end

    // ========================================================================
    // Synchronize system domain status back to TCK domain
    // ========================================================================
    logic [2:0] abstractcs_cmderr_sync [2:0];
    logic [31:0] data0_result_sync [2:0];
    logic data0_result_valid_sync [2:0];

    always_ff @(posedge tck_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            abstractcs_cmderr_sync[0] <= 3'b0;
            abstractcs_cmderr_sync[1] <= 3'b0;
            abstractcs_cmderr_sync[2] <= 3'b0;
            data0_result_sync[0] <= 32'b0;
            data0_result_sync[1] <= 32'b0;
            data0_result_sync[2] <= 32'b0;
            data0_result_valid_sync[0] <= 1'b0;
            data0_result_valid_sync[1] <= 1'b0;
            data0_result_valid_sync[2] <= 1'b0;
        end else begin
            abstractcs_cmderr_sync[0] <= abstractcs_cmderr_sys;
            abstractcs_cmderr_sync[1] <= abstractcs_cmderr_sync[0];
            abstractcs_cmderr_sync[2] <= abstractcs_cmderr_sync[1];
            data0_result_sync[0] <= data0_result;
            data0_result_sync[1] <= data0_result_sync[0];
            data0_result_sync[2] <= data0_result_sync[1];
            data0_result_valid_sync[0] <= data0_result_valid;
            data0_result_valid_sync[1] <= data0_result_valid_sync[0];
            data0_result_valid_sync[2] <= data0_result_valid_sync[1];
        end
    end

    // ========================================================================
    // Update-DR: Process DMI operations
    // ========================================================================
    always_ff @(posedge tck_i or negedge ntrst_i) begin
        if (!ntrst_i) begin
            dmi_address <= 7'b0;
            dmcontrol_haltreq <= 1'b0;
            dmcontrol_resumereq <= 1'b0;
            dmcontrol_hartreset <= 1'b0;
            dmcontrol_ackhavereset <= 1'b0;
            dmcontrol_ndmreset <= 1'b0;
            dmcontrol_dmactive <= 1'b0;
            data0 <= 32'b0;
            data1 <= 32'b0;
            progbuf0 <= 32'b0;
            progbuf1 <= 32'b0;
            command_reg <= 32'b0;
            abstractcs_cmderr <= 3'b0;
        end else if (update_dr_i && ir_i == IR_DMI) begin
            // Extract address field from shifted data
            dmi_address <= dmi_shift[40:34];

            // Sync results from system domain even when not writing
            if (data0_result_valid_sync[2] && !data0_result_valid_sync[1]) begin
                data0 <= data0_result_sync[2];
                `DEBUG1(("[DTM] Sync DATA0 result = 0x%h", data0_result_sync[2]));
            end
            if (abstractcs_cmderr_sync[2] != abstractcs_cmderr) begin
                abstractcs_cmderr <= abstractcs_cmderr_sync[2];
                `DEBUG1(("[DTM] Sync ABSTRACTCS cmderr = %0d", abstractcs_cmderr_sync[2]));
            end

            // Process write operations (op == 2'b10)
            if (dmi_shift[1:0] == 2'b10) begin  // Write operation
                case (dmi_shift[40:34])
                    DMI_DATA0: begin
                        if (!abstractcs_busy) begin
                            data0 <= dmi_shift[33:2];
                            `DEBUG1(("[DTM] Write DATA0 = 0x%h", dmi_shift[33:2]));
                        end
                    end
                    DMI_DATA1: begin
                        if (!abstractcs_busy) begin
                            data1 <= dmi_shift[33:2];
                            `DEBUG1(("[DTM] Write DATA1 = 0x%h", dmi_shift[33:2]));
                        end
                    end
                    DMI_DMCONTROL: begin
                        dmcontrol_dmactive <= dmi_shift[2];  // bit 0
                        dmcontrol_ndmreset <= dmi_shift[3];  // bit 1
                        dmcontrol_haltreq <= dmi_shift[33];  // bit 31
                        dmcontrol_resumereq <= dmi_shift[32]; // bit 30
                        dmcontrol_hartreset <= dmi_shift[31]; // bit 29
                        dmcontrol_ackhavereset <= dmi_shift[30]; // bit 28
                        `DEBUG1(("[DTM] Write DMCONTROL: dmactive=%b haltreq=%b resumereq=%b",
                               dmi_shift[2], dmi_shift[33], dmi_shift[32]));
                    end
                    DMI_ABSTRACTCS: begin
                        // Writing to cmderr clears it (write-1-to-clear)
                        if (dmi_shift[10:8] != 3'b0) begin
                            abstractcs_cmderr <= 3'b0;
                            `DEBUG1(("[DTM] Clear ABSTRACTCS cmderr"));
                        end
                    end
                    DMI_COMMAND: begin
                        if (!abstractcs_busy && dmcontrol_dmactive) begin
                            command_reg <= dmi_shift[33:2];
                            `DEBUG1(("[DTM] Write COMMAND = 0x%h", dmi_shift[33:2]));
                        end else if (abstractcs_busy) begin
                            // Don't write error here, let system domain handle it
                            `DEBUG1(("[DTM] COMMAND write rejected: busy"));
                        end
                    end
                    DMI_PROGBUF0: begin
                        if (!abstractcs_busy) begin
                            progbuf0 <= dmi_shift[33:2];
                            `DEBUG1(("[DTM] Write PROGBUF0 = 0x%h", dmi_shift[33:2]));
                        end
                    end
                    DMI_PROGBUF1: begin
                        if (!abstractcs_busy) begin
                            progbuf1 <= dmi_shift[33:2];
                            `DEBUG1(("[DTM] Write PROGBUF1 = 0x%h", dmi_shift[33:2]));
                        end
                    end
                    default: begin
                        // Other registers are read-only
                    end
                endcase
            end
        end
    end

    // ========================================================================
    // Synchronize command and data from TCK to system clock domain
    // ========================================================================
    logic [31:0] command_reg_sync [2:0];
    logic [31:0] data0_sync [2:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            command_reg_sync[0] <= 32'b0;
            command_reg_sync[1] <= 32'b0;
            command_reg_sync[2] <= 32'b0;
            data0_sync[0] <= 32'b0;
            data0_sync[1] <= 32'b0;
            data0_sync[2] <= 32'b0;
            command_reg_sys <= 32'b0;
            data0_sys <= 32'b0;
            command_valid_sys <= 1'b0;
        end else begin
            command_reg_sync[0] <= command_reg;
            command_reg_sync[1] <= command_reg_sync[0];
            command_reg_sync[2] <= command_reg_sync[1];
            data0_sync[0] <= data0;
            data0_sync[1] <= data0_sync[0];
            data0_sync[2] <= data0_sync[1];

            // Detect new command (transition from 0 to non-zero)
            if (command_reg_sync[2] != 32'b0 && command_reg_sys == 32'b0) begin
                command_reg_sys <= command_reg_sync[2];
                data0_sys <= data0_sync[2];
                command_valid_sys <= 1'b1;
                data0_result_valid <= 1'b0;  // Clear result valid
            end else if (cmd_state == CMD_DONE) begin
                command_reg_sys <= 32'b0;
                command_valid_sys <= 1'b0;
            end
        end
    end

    // ========================================================================
    // Abstract Command Execution State Machine (System Clock Domain)
    // ========================================================================
    // This runs in the system clock domain to interact with the CPU

    // Decode command when written
    wire cmd_is_access_reg = (command_reg_sys[31:24] == CMD_ACCESS_REG);
    wire cmd_is_access_mem = (command_reg_sys[31:24] == CMD_ACCESS_MEM);

    // Register access command fields (cmdtype == 0)
    assign cmd_size = command_reg_sys[22:20];     // Size: 2=32-bit, 3=64-bit
    assign cmd_postexec = command_reg_sys[18];    // Execute progbuf after
    assign cmd_transfer = command_reg_sys[17];    // Perform transfer
    assign cmd_write = command_reg_sys[16];       // 1=write, 0=read
    assign cmd_regno = command_reg_sys[15:0][4:0]; // Register number (GPR 0-31)

    // Memory access command fields (cmdtype == 2)
    logic [31:0] mem_addr;
    logic [2:0]  mem_size;
    wire mem_write_cmd = command_reg_sys[16];

    // Command execution logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_state <= CMD_IDLE;
            abstractcs_busy <= 1'b0;
            abstractcs_cmderr_sys <= 3'b0;
            data0_result <= 32'b0;
            data0_result_valid <= 1'b0;
            dbg_reg_we_o <= 1'b0;
            dbg_pc_we_o <= 1'b0;
            dbg_mem_req_o <= 1'b0;
            dbg_mem_we_o <= 4'b0;
            mem_req_pending <= 1'b0;
            mem_wait_cnt <= 2'b0;
        end else begin
            cmd_state <= cmd_state_next;

            // Default: deassert control signals
            dbg_reg_we_o <= 1'b0;
            dbg_pc_we_o <= 1'b0;

            case (cmd_state)
                CMD_IDLE: begin
                    abstractcs_busy <= 1'b0;
                    dbg_mem_req_o <= 1'b0;
                    mem_req_pending <= 1'b0;

                    // Check if new command written (transition from TCK domain)
                    if (command_valid_sys && !abstractcs_busy) begin
                        if (!halted_sync) begin
                            // Hart must be halted to execute commands
                            abstractcs_cmderr_sys <= CMDERR_HALTRESUME;
                            `DEBUG1(("[DTM] Command rejected: hart not halted"));
                        end else if (cmd_is_access_reg && cmd_transfer) begin
                            abstractcs_busy <= 1'b1;
                            if (cmd_regno < 32) begin  // GPR access (x0-x31)
                                if (cmd_write) begin
                                    cmd_state <= CMD_REG_WRITE;
                                    `DEBUG1(("[DTM] Execute: Write GPR x%0d = 0x%h", cmd_regno, data0_sys));
                                end else begin
                                    cmd_state <= CMD_REG_READ;
                                    `DEBUG1(("[DTM] Execute: Read GPR x%0d", cmd_regno));
                                end
                            end else if (cmd_regno == 16'h1000) begin  // DPC (PC) access
                                if (cmd_write) begin
                                    cmd_state <= CMD_REG_WRITE;
                                    `DEBUG1(("[DTM] Execute: Write PC = 0x%h", data0_sys));
                                end else begin
                                    cmd_state <= CMD_REG_READ;
                                    `DEBUG1(("[DTM] Execute: Read PC"));
                                end
                            end else begin
                                abstractcs_cmderr_sys <= CMDERR_NOTSUP;
                                abstractcs_busy <= 1'b0;
                                `DEBUG1(("[DTM] Unsupported register: 0x%h", cmd_regno));
                            end
                        end else if (cmd_is_access_mem) begin
                            abstractcs_busy <= 1'b1;
                            mem_addr <= data1;  // Address in data1
                            if (mem_write_cmd) begin
                                cmd_state <= CMD_MEM_WRITE;
                                `DEBUG1(("[DTM] Execute: Write memory[0x%h] = 0x%h", data1, data0_sys));
                            end else begin
                                cmd_state <= CMD_MEM_READ;
                                `DEBUG1(("[DTM] Execute: Read memory[0x%h]", data1));
                            end
                        end else begin
                            abstractcs_cmderr_sys <= CMDERR_NOTSUP;
                            `DEBUG1(("[DTM] Unsupported command type"));
                        end
                    end
                end

                CMD_REG_READ: begin
                    // Read register value
                    if (cmd_regno < 32) begin  // GPR
                        dbg_reg_addr_o <= cmd_regno;
                        data0_result <= dbg_reg_rdata_i;
                        data0_result_valid <= 1'b1;
                        `DEBUG1(("[DTM] Read GPR x%0d = 0x%h", cmd_regno, dbg_reg_rdata_i));
                    end else if (cmd_regno == 16'h1000) begin  // PC
                        data0_result <= dbg_pc_i;
                        data0_result_valid <= 1'b1;
                        `DEBUG1(("[DTM] Read PC = 0x%h", dbg_pc_i));
                    end
                    cmd_state <= CMD_DONE;
                end

                CMD_REG_WRITE: begin
                    // Write register value
                    if (cmd_regno < 32) begin  // GPR
                        dbg_reg_addr_o <= cmd_regno;
                        dbg_reg_wdata_o <= data0_sys;
                        dbg_reg_we_o <= 1'b1;
                        `DEBUG1(("[DTM] Write GPR x%0d = 0x%h", cmd_regno, data0_sys));
                    end else if (cmd_regno == 16'h1000) begin  // PC
                        dbg_pc_wdata_o <= data0_sys;
                        dbg_pc_we_o <= 1'b1;
                        `DEBUG1(("[DTM] Write PC = 0x%h", data0_sys));
                    end
                    cmd_state <= CMD_DONE;
                end

                CMD_MEM_READ: begin
                    if (!mem_req_pending) begin
                        // Issue memory read request
                        dbg_mem_req_o <= 1'b1;
                        dbg_mem_addr_o <= mem_addr;
                        dbg_mem_we_o <= 4'b0;  // Read
                        mem_req_pending <= 1'b1;
                        mem_wait_cnt <= 2'b0;
                    end else if (dbg_mem_ready_i) begin
                        // Memory read complete
                        data0_result <= dbg_mem_rdata_i;
                        data0_result_valid <= 1'b1;
                        dbg_mem_req_o <= 1'b0;
                        mem_req_pending <= 1'b0;
                        cmd_state <= CMD_DONE;
                        `DEBUG1(("[DTM] Memory read complete: 0x%h", dbg_mem_rdata_i));
                    end else begin
                        // Wait for memory
                        mem_wait_cnt <= mem_wait_cnt + 1;
                        if (mem_wait_cnt == 2'b11) begin
                            // Timeout
                            abstractcs_cmderr_sys <= CMDERR_BUS;
                            dbg_mem_req_o <= 1'b0;
                            mem_req_pending <= 1'b0;
                            cmd_state <= CMD_DONE;
                            `DEBUG1(("[DTM] Memory read timeout"));
                        end
                    end
                end

                CMD_MEM_WRITE: begin
                    if (!mem_req_pending) begin
                        // Issue memory write request
                        dbg_mem_req_o <= 1'b1;
                        dbg_mem_addr_o <= mem_addr;
                        dbg_mem_wdata_o <= data0_sys;
                        dbg_mem_we_o <= 4'b1111;  // Write all bytes
                        mem_req_pending <= 1'b1;
                        mem_wait_cnt <= 2'b0;
                    end else if (dbg_mem_ready_i) begin
                        // Memory write complete
                        dbg_mem_req_o <= 1'b0;
                        mem_req_pending <= 1'b0;
                        cmd_state <= CMD_DONE;
                        `DEBUG1(("[DTM] Memory write complete"));
                    end else begin
                        // Wait for memory
                        mem_wait_cnt <= mem_wait_cnt + 1;
                        if (mem_wait_cnt == 2'b11) begin
                            // Timeout
                            abstractcs_cmderr_sys <= CMDERR_BUS;
                            dbg_mem_req_o <= 1'b0;
                            mem_req_pending <= 1'b0;
                            cmd_state <= CMD_DONE;
                            `DEBUG1(("[DTM] Memory write timeout"));
                        end
                    end
                end

                CMD_DONE: begin
                    abstractcs_busy <= 1'b0;
                    // Don't clear command_reg here - it's in TCK domain
                    cmd_state <= CMD_IDLE;
                end

                default: begin
                    cmd_state <= CMD_IDLE;
                end
            endcase
        end
    end

    // Command state machine next-state logic
    always_comb begin
        cmd_state_next = cmd_state;
        case (cmd_state)
            CMD_IDLE: begin
                // Handled in sequential block
                cmd_state_next = cmd_state;
            end
            CMD_REG_READ, CMD_REG_WRITE: begin
                cmd_state_next = CMD_DONE;
            end
            CMD_MEM_READ, CMD_MEM_WRITE: begin
                // Stays in state until memory completes (handled in sequential block)
                cmd_state_next = cmd_state;
            end
            CMD_DONE: begin
                cmd_state_next = CMD_IDLE;
            end
            default: begin
                cmd_state_next = CMD_IDLE;
            end
        endcase
    end
    // ========================================================================
    // TDO Output Multiplexer
    // ========================================================================
    always_comb begin
        case (ir_i)
            IR_IDCODE:  tdo_o = idcode_shift[0];
            IR_DTMCS:   tdo_o = dtmcs_shift[0];
            IR_DMI:     tdo_o = dmi_shift[0];
            IR_BYPASS:  tdo_o = bypass_shift;
            default:    tdo_o = bypass_shift;
        endcase
    end

endmodule

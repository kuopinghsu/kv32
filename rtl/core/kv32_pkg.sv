// ============================================================================
// File: kv32_pkg.sv
// Project: KV32 RISC-V Processor
// Description: RISC-V 32-bit Core Package
//
// Defines types, enums, and macros used by the RISC-V RV32IMA processor core.
// Includes instruction types, ALU operations, memory operations, CSR addresses,
// and debug display macros.
// ============================================================================

package kv32_pkg;

    // ========================================================================
    // Debug Display Macros
    // ========================================================================
    // DEBUG1(msg)             — always shown when DEBUG_LEVEL_1 is enabled.
    //                           No group filtering; use for critical events.
    //
    // DEBUG2(grp, msg)        — shown only when DEBUG_LEVEL_2 is enabled AND
    //                           bit DBG_GRP_<grp> is set in DEBUG_GROUP.
    //                           Pass the bare group suffix token:
    //
    //   `DEBUG1(("[IRQ] Interrupt: cause=0x%h", cause))
    //   `DEBUG2(WFI,   ("wfi_stall=%b icache_idle=%b", wfi_stall, icache_idle_i))
    //   `DEBUG2(FETCH, ("[FETCH_REQ] pc=0x%h outstanding=%0d", pc, out))
    //   `DEBUG2(AXI,   ("arvalid=%b arready=%b", arvalid, arready))
    //
    // Filtering — override DEBUG_GROUP at elaboration time:
    //   +define+DEBUG_GROUP=32'h0000_0040   // WFI only  (bit 6)
    //   +define+DEBUG_GROUP=32'h0000_0003   // FETCH+PIPE (bits 0-1)
    //   +define+DEBUG_GROUP=32'hFFFF_FFFF   // all groups (default)
    //
    // From the Makefile: make DEBUG=2 DEBUG_GROUP=40 rtl-<test>
    //
    // Note: Use double parentheses for msg arguments (variadic macro workaround)
    // ========================================================================

    // ── Debug group bit indices ─────────────────────────────────────────────
    `define DBG_GRP_FETCH   0   // Instruction fetch, PC tracking, IB
    `define DBG_GRP_PIPE    1   // Pipeline stalls and stage flushes
    `define DBG_GRP_EX      2   // Execute stage (ALU, branch, forward)
    `define DBG_GRP_MEM     3   // Memory stage (load/store, AMO, LR/SC)
    `define DBG_GRP_CSR     4   // CSR read/write
    `define DBG_GRP_IRQ     5   // Interrupts and exceptions
    `define DBG_GRP_WFI     6   // WFI / power management
    `define DBG_GRP_AXI     7   // AXI bus transactions
    `define DBG_GRP_REG     8   // Register file write-back and forwarding
    `define DBG_GRP_JTAG    9   // JTAG / DTM / debug module
    `define DBG_GRP_CLINT  10   // CLINT timer/software interrupt
    `define DBG_GRP_GPIO   11   // GPIO peripheral
    `define DBG_GRP_I2C    12   // I2C peripheral
    `define DBG_GRP_ICACHE 13   // I-Cache state machine
    `define DBG_GRP_ALU    14   // ALU operations
    `define DBG_GRP_SB     15   // Store buffer
    `define DBG_GRP_AXIMEM 16   // AXI memory slave (testbench)

`ifndef SYNTHESIS
    // ── Display name strings (6-char fixed width for aligned output) ─────────
    // ── Group name lookup (maps bit-index → 6-char display name) ──────────
    // Used by the DEBUG2 macro to prefix each message with [GROUP ].
    function automatic string dbg_grp_name(int unsigned idx);
        case (idx)
            `DBG_GRP_FETCH:  return "FETCH ";
            `DBG_GRP_PIPE:   return "PIPE  ";
            `DBG_GRP_EX:     return "EX    ";
            `DBG_GRP_MEM:    return "MEM   ";
            `DBG_GRP_CSR:    return "CSR   ";
            `DBG_GRP_IRQ:    return "IRQ   ";
            `DBG_GRP_WFI:    return "WFI   ";
            `DBG_GRP_AXI:    return "AXI   ";
            `DBG_GRP_REG:    return "REG   ";
            `DBG_GRP_JTAG:   return "JTAG  ";
            `DBG_GRP_CLINT:  return "CLINT ";
            `DBG_GRP_GPIO:   return "GPIO  ";
            `DBG_GRP_I2C:    return "I2C   ";
            `DBG_GRP_ICACHE: return "ICACHE";
            `DBG_GRP_ALU:    return "ALU   ";
            `DBG_GRP_SB:     return "SB    ";
            `DBG_GRP_AXIMEM: return "AXIMEM";
            default:         return "?     ";
        endcase
    endfunction
`endif // SYNTHESIS

    // ── Default DEBUG_GROUP: all groups enabled ──────────────────────────────
    `ifndef DEBUG_GROUP
        `define DEBUG_GROUP 32'hFFFF_FFFF
    `endif

`ifdef SYNTHESIS
    `define DEBUG1(msg)
`else
`ifdef DEBUG_LEVEL_1
    `define DEBUG1(msg) $display("[DBG1] %s", $sformatf msg)
`else
    `define DEBUG1(msg)
`endif
`endif // SYNTHESIS

`ifdef SYNTHESIS
    `define DEBUG2(grp, msg)
`else
`ifdef DEBUG_LEVEL_2
    // grp must be one of the `DBG_GRP_* integer defines, e.g. `DBG_GRP_WFI.
    // The corresponding bit in DEBUG_GROUP must be set for the message to print.
    // Output format: [GROUP ] message
    `define DEBUG2(grp, msg) \
        if (|((`DEBUG_GROUP >> (grp)) & 32'h1)) \
            $display("[%s] %s", kv32_pkg::dbg_grp_name(grp), $sformatf msg)
`else
    `define DEBUG2(grp, msg)
`endif
`endif // SYNTHESIS

    // Opcodes
    typedef enum logic [6:0] {
        OPCODE_LOAD     = 7'b0000011,
        OPCODE_STORE    = 7'b0100011,
        OPCODE_BRANCH   = 7'b1100011,
        OPCODE_JAL      = 7'b1101111,
        OPCODE_JALR     = 7'b1100111,
        OPCODE_OP_IMM   = 7'b0010011,
        OPCODE_OP       = 7'b0110011,
        OPCODE_LUI      = 7'b0110111,
        OPCODE_AUIPC    = 7'b0010111,
        OPCODE_SYSTEM   = 7'b1110011,
        OPCODE_MISC_MEM = 7'b0001111,
        OPCODE_AMO      = 7'b0101111
    } opcode_e;

    // ALU operations
    typedef enum logic [4:0] {
        ALU_ADD,
        ALU_SUB,
        ALU_SLL,
        ALU_SLT,
        ALU_SLTU,
        ALU_XOR,
        ALU_SRL,
        ALU_SRA,
        ALU_OR,
        ALU_AND,
        ALU_MUL,
        ALU_MULH,
        ALU_MULHSU,
        ALU_MULHU,
        ALU_DIV,
        ALU_DIVU,
        ALU_REM,
        ALU_REMU
    } alu_op_e;

    // Branch types
    typedef enum logic [2:0] {
        BRANCH_EQ  = 3'b000,
        BRANCH_NE  = 3'b001,
        BRANCH_LT  = 3'b100,
        BRANCH_GE  = 3'b101,
        BRANCH_LTU = 3'b110,
        BRANCH_GEU = 3'b111
    } branch_op_e;

    // Memory access types
    typedef enum logic [2:0] {
        MEM_BYTE   = 3'b000,
        MEM_HALF   = 3'b001,
        MEM_WORD   = 3'b010,
        MEM_BYTE_U = 3'b100,
        MEM_HALF_U = 3'b101
    } mem_op_e;

    // Atomic Memory Operation (AMO) types
    typedef enum logic [4:0] {
        AMO_LR      = 5'b00010,  // Load Reserved
        AMO_SC      = 5'b00011,  // Store Conditional
        AMO_SWAP    = 5'b00001,  // Atomic Swap
        AMO_ADD     = 5'b00000,  // Atomic Add
        AMO_XOR     = 5'b00100,  // Atomic XOR
        AMO_AND     = 5'b01100,  // Atomic AND
        AMO_OR      = 5'b01000,  // Atomic OR
        AMO_MIN     = 5'b10000,  // Atomic Min (signed)
        AMO_MAX     = 5'b10100,  // Atomic Max (signed)
        AMO_MINU    = 5'b11000,  // Atomic Min (unsigned)
        AMO_MAXU    = 5'b11100   // Atomic Max (unsigned)
    } amo_op_e;

    // Exception causes
    typedef enum logic [4:0] {
        EXC_INSTR_ADDR_MISALIGNED   = 5'd0,
        EXC_INSTR_ACCESS_FAULT      = 5'd1,
        EXC_ILLEGAL_INSTR           = 5'd2,
        EXC_BREAKPOINT              = 5'd3,
        EXC_LOAD_ADDR_MISALIGNED    = 5'd4,
        EXC_LOAD_ACCESS_FAULT       = 5'd5,
        EXC_STORE_ADDR_MISALIGNED   = 5'd6,
        EXC_STORE_ACCESS_FAULT      = 5'd7,
        EXC_ECALL_UMODE             = 5'd8,
        EXC_ECALL_MMODE             = 5'd11
    } exception_e;

    // CSR addresses
    typedef enum logic [11:0] {
        CSR_MSTATUS    = 12'h300,
        CSR_MISA       = 12'h301,
        CSR_MIE        = 12'h304,
        CSR_MTVEC      = 12'h305,
        CSR_MSCRATCH   = 12'h340,
        CSR_MEPC       = 12'h341,
        CSR_MCAUSE     = 12'h342,
        CSR_MTVAL      = 12'h343,
        CSR_MIP        = 12'h344,
        CSR_MCYCLE     = 12'hB00,
        CSR_MINSTRET   = 12'hB02,
        CSR_MCYCLEH    = 12'hB80,
        CSR_MINSTRETH  = 12'hB82,
        // User-mode read-only shadow registers
        CSR_CYCLE      = 12'hC00,
        CSR_TIME       = 12'hC01,
        CSR_INSTRET    = 12'hC02,
        CSR_CYCLEH     = 12'hC80,
        CSR_TIMEH      = 12'hC81,
        CSR_INSTRETH   = 12'hC82,
        // Machine information registers (read-only)
        CSR_MVENDORID  = 12'hF11,
        CSR_MARCHID    = 12'hF12,
        CSR_MIMPID     = 12'hF13,
        CSR_MHARTID    = 12'hF14
    } csr_addr_e;

endpackage

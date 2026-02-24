// ============================================================================
// File: rv32_pkg.sv
// Project: RV32 RISC-V Processor
// Description: RISC-V 32-bit Core Package
//
// Defines types, enums, and macros used by the RISC-V RV32IMA processor core.
// Includes instruction types, ALU operations, memory operations, CSR addresses,
// and debug display macros.
// ============================================================================

package rv32_pkg;

    // ========================================================================
    // Debug Display Macros
    // ========================================================================
    // Usage:
    //   `DEBUG1(("[INFO] Critical event: value=0x%h", value))
    //   `DEBUG2(("[VERBOSE] Internal state: x=%d y=%d", x, y))
    //
    // Note: Use double parentheses for arguments to handle variable arg lists
    // ========================================================================

`ifdef DEBUG_LEVEL_1
    `define DEBUG1(msg) $display("[DEBUG] ", $sformatf msg)
`else
    `define DEBUG1(msg)
`endif

`ifdef DEBUG_LEVEL_2
    `define DEBUG2(msg) $display("[DEBUG] ", $sformatf msg)
`else
    `define DEBUG2(msg)
`endif

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

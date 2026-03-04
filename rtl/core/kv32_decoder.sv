// ============================================================================
// File: kv32_decoder.sv
// Project: KV32 RISC-V Processor
// Description: RISC-V 32-bit Instruction Decoder
//
// Decodes 32-bit RISC-V instructions into control signals for pipeline stages.
// Supports RV32IMA instruction set:
//   - Base integer instructions (RV32I)
//   - Multiply/divide extension (M)
//   - Atomic operations extension (A)
//
// Outputs:
//   - Register addresses (rs1, rs2, rd)
//   - Immediate values (I, S, B, U, J formats)
//   - Control signals (ALU op, memory op, branch type, etc.)
//   - Illegal instruction detection
// ============================================================================

`ifdef SYNTHESIS
import kv32_pkg::*;
`endif

module kv32_decoder (
    input  logic [31:0] instr,
    input  logic        valid,

    // Decoded signals
    output logic [4:0]  rs1_addr,
    output logic [4:0]  rs2_addr,
    output logic [4:0]  rd_addr,
    output logic [31:0] imm,
`ifndef SYNTHESIS
    output alu_op_e     alu_op,
`else
    output logic [4:0]  alu_op,    // alu_op_e (synthesis: logic [4:0])
`endif
    output logic        alu_src,      // 0: rs2, 1: imm
    output logic        reg_we,
    output logic        mem_read,
    output logic        mem_write,
`ifndef SYNTHESIS
    output mem_op_e     mem_op,
`else
    output logic [2:0]  mem_op,     // mem_op_e (synthesis: logic [2:0])
`endif
    output logic        branch,
`ifndef SYNTHESIS
    output branch_op_e  branch_op,
`else
    output logic [2:0]  branch_op,  // branch_op_e (synthesis: logic [2:0])
`endif
    output logic        jal,
    output logic        jalr,
    output logic        lui,
    output logic        auipc,
    output logic        system,
    output logic        illegal,
    output logic [2:0]  csr_op,
    output logic [11:0] csr_addr,
    output logic        is_mret,
    output logic        is_ecall,
    output logic        is_ebreak,
    output logic        is_amo,
`ifndef SYNTHESIS
    output amo_op_e     amo_op,
`else
    output logic [4:0]  amo_op,     // amo_op_e (synthesis: logic [4:0])
`endif
    output logic        is_fence,
    output logic        is_fence_i,   // FENCE.I (funct3=001): flush instruction cache
    output logic        is_cbo,       // Zicbom CBO (funct3=010): cache block operation
    output logic        is_wfi        // WFI instruction (funct3=000, imm=0x105)
);
`ifndef SYNTHESIS
    import kv32_pkg::*;
`endif

    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;
    logic [4:0] funct5;

    assign opcode = instr[6:0];
    assign funct3 = instr[14:12];
    assign funct7 = instr[31:25];
    assign funct5 = instr[31:27];

    assign rs1_addr = instr[19:15];
    assign rs2_addr = instr[24:20];
    assign rd_addr  = instr[11:7];
    assign csr_addr = instr[31:20];

    // Immediate generation
    always_comb begin
        case (opcode)
            OPCODE_OP_IMM, OPCODE_LOAD, OPCODE_JALR, OPCODE_SYSTEM:
                imm = {{20{instr[31]}}, instr[31:20]};  // I-type
            OPCODE_STORE:
                imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};  // S-type
            OPCODE_BRANCH:
                imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};  // B-type
            OPCODE_LUI, OPCODE_AUIPC:
                imm = {instr[31:12], 12'b0};  // U-type
            OPCODE_JAL:
                imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};  // J-type
            default:
                imm = 32'd0;
        endcase
    end

    // Control signal generation
    always_comb begin
        // Default values
        alu_op     = ALU_ADD;
        alu_src    = 1'b0;
        reg_we     = 1'b0;
        mem_read   = 1'b0;
        mem_write  = 1'b0;
        mem_op     = MEM_WORD;
        branch     = 1'b0;
        branch_op  = BRANCH_EQ;
        jal        = 1'b0;
        jalr       = 1'b0;
        lui        = 1'b0;
        auipc      = 1'b0;
        system     = 1'b0;
        illegal    = 1'b0;
        csr_op     = 3'b0;
        is_mret    = 1'b0;
        is_ecall   = 1'b0;
        is_ebreak  = 1'b0;
        is_amo     = 1'b0;
        amo_op     = AMO_ADD;  // Default AMO operation
        is_fence   = 1'b0;
        is_fence_i = 1'b0;
        is_cbo     = 1'b0;
        is_wfi     = 1'b0;

        if (valid) begin
            case (opcode)
                OPCODE_OP_IMM: begin
                    alu_src = 1'b1;
                    reg_we  = 1'b1;
                    case (funct3)
                        3'b000: alu_op = ALU_ADD;
                        3'b010: alu_op = ALU_SLT;
                        3'b011: alu_op = ALU_SLTU;
                        3'b100: alu_op = ALU_XOR;
                        3'b110: alu_op = ALU_OR;
                        3'b111: alu_op = ALU_AND;
                        3'b001: alu_op = ALU_SLL;
                        3'b101: alu_op = (instr[30]) ? ALU_SRA : ALU_SRL;
                        default: illegal = 1'b1;
                    endcase
                end

                OPCODE_OP: begin
                    reg_we = 1'b1;
                    if (funct7 == 7'b0000001) begin  // M extension
                        case (funct3)
                            3'b000: alu_op = ALU_MUL;
                            3'b001: alu_op = ALU_MULH;
                            3'b010: alu_op = ALU_MULHSU;
                            3'b011: alu_op = ALU_MULHU;
                            3'b100: alu_op = ALU_DIV;
                            3'b101: alu_op = ALU_DIVU;
                            3'b110: alu_op = ALU_REM;
                            3'b111: alu_op = ALU_REMU;
                            default: illegal = 1'b1;
                        endcase
                    end else begin
                        case (funct3)
                            3'b000: alu_op = (funct7[5]) ? ALU_SUB : ALU_ADD;
                            3'b001: alu_op = ALU_SLL;
                            3'b010: alu_op = ALU_SLT;
                            3'b011: alu_op = ALU_SLTU;
                            3'b100: alu_op = ALU_XOR;
                            3'b101: alu_op = (funct7[5]) ? ALU_SRA : ALU_SRL;
                            3'b110: alu_op = ALU_OR;
                            3'b111: alu_op = ALU_AND;
                            default: illegal = 1'b1;
                        endcase
                    end
                end

                OPCODE_LOAD: begin
                    alu_src  = 1'b1;
                    reg_we   = 1'b1;
                    mem_read = 1'b1;
`ifndef SYNTHESIS
                    mem_op   = mem_op_e'(funct3);
`else
                    mem_op   = funct3;
`endif
                    if (funct3 == 3'b011 || funct3 == 3'b110 || funct3 == 3'b111)
                        illegal = 1'b1;
                end

                OPCODE_STORE: begin
                    alu_src   = 1'b1;
                    mem_write = 1'b1;
`ifndef SYNTHESIS
                    mem_op    = mem_op_e'(funct3);
`else
                    mem_op    = funct3;
`endif
                    if (funct3[2:0] > 3'b010)
                        illegal = 1'b1;
                end

                OPCODE_BRANCH: begin
                    branch    = 1'b1;
`ifndef SYNTHESIS
                    branch_op = branch_op_e'(funct3);
`else
                    branch_op = funct3;
`endif
                    if (funct3 == 3'b010 || funct3 == 3'b011)
                        illegal = 1'b1;
                end

                OPCODE_JAL: begin
                    jal    = 1'b1;
                    reg_we = 1'b1;
                end

                OPCODE_JALR: begin
                    jalr    = 1'b1;
                    reg_we  = 1'b1;
                    alu_src = 1'b1;
                    if (funct3 != 3'b000)
                        illegal = 1'b1;
                end

                OPCODE_LUI: begin
                    lui    = 1'b1;
                    reg_we = 1'b1;
                end

                OPCODE_AUIPC: begin
                    auipc   = 1'b1;
                    alu_src = 1'b1;
                    reg_we  = 1'b1;
                end

                OPCODE_SYSTEM: begin
                    system = 1'b1;
                    if (funct3 == 3'b000) begin
                        if (instr[31:20] == 12'h000) begin
                            is_ecall = 1'b1;
                        end else if (instr[31:20] == 12'h001) begin
                            is_ebreak = 1'b1;
                        end else if (instr[31:20] == 12'h302) begin
                            is_mret = 1'b1;
                        end else if (instr[31:20] == 12'h105) begin
                            is_wfi = 1'b1;  // WFI: wait for interrupt
                        end else begin
                            illegal = 1'b1;
                        end
                    end else begin
                        csr_op = funct3;
                        reg_we = 1'b1;
                        // RISC-V Zicsr spec: CSR address bits[11:10]='11' means
                        // read-only.  Any instruction that would write such a CSR
                        // raises Illegal Instruction.
                        // Write is attempted when:
                        //   funct3[1:0]==01  → CSRRW/CSRRWI (always write)
                        //   funct3[1:0]!=01  → CSRRS/CSRRC/CSRRSI/CSRRCI only
                        //                       when rs1_addr (or zimm) ≠ 0
                        if (instr[31:30] == 2'b11) begin
                            if (funct3[1:0] == 2'b01 || rs1_addr != 5'd0) begin
                                illegal = 1'b1;
                            end
                        end
                        // Unknown CSR address: any access (read or write) to a
                        // non-existent CSR is illegal (RISC-V priv. spec §2.1).
                        if (!(instr[31:20] inside {
                            CSR_MSTATUS, CSR_MISA, CSR_MIE, CSR_MTVEC,
                            CSR_MSCRATCH, CSR_MEPC, CSR_MCAUSE, CSR_MTVAL, CSR_MIP,
                            CSR_MCYCLE, CSR_MCYCLEH, CSR_MINSTRET, CSR_MINSTRETH,
                            CSR_CYCLE, CSR_TIME, CSR_INSTRET,
                            CSR_CYCLEH, CSR_TIMEH, CSR_INSTRETH,
                            CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID, CSR_MHARTID
                        })) begin
                            illegal = 1'b1;
                        end
                    end
                end

                OPCODE_AMO: begin
                    is_amo   = 1'b1;
                    reg_we   = 1'b1;
                    mem_read = 1'b1;
                    alu_src  = 1'b1;   // Use immediate (0) for address calculation, not rs2
                    if (funct3 != 3'b010)  // Only word-sized
                        illegal = 1'b1;
                    // Decode AMO operation from funct5
`ifndef SYNTHESIS
                    amo_op = amo_op_e'(funct5);
`else
                    amo_op = funct5;
`endif
                end

                OPCODE_MISC_MEM: begin
                    if (funct3 == 3'b000) begin
                        is_fence = 1'b1;             // FENCE: drain stores only
                    end else if (funct3 == 3'b001) begin
                        is_fence   = 1'b1;           // FENCE.I: drain stores ...
                        is_fence_i = 1'b1;           //          ... then flush I-cache
                    end else if (funct3 == 3'b010) begin
                        is_cbo  = 1'b1;              // Zicbom: cbo.inval / cbo.clean / cbo.flush
                        alu_src = 1'b1;              // ALU_ADD(rs1, imm=0) → rs1 = cache address
                    end else begin
                        illegal = 1'b1;
                    end
                end

                default: begin
                    illegal = 1'b1;
                end
            endcase
        end
    end

endmodule


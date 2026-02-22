#include "riscv-dis.h"
#include <sstream>
#include <iomanip>

RiscvDisassembler::RiscvDisassembler() {
}

std::string RiscvDisassembler::disassemble(uint32_t instr, uint32_t pc) {
    // Check if this is a compressed instruction (bottom 2 bits != 0b11)
    if ((instr & 0x3) != 0x3) {
        return decode_compressed((uint16_t)(instr & 0xFFFF), pc);
    }

    // Extract common fields for 32-bit instructions
    uint32_t opcode = instr & 0x7F;
    uint32_t funct3 = (instr >> 12) & 0x7;
    uint32_t funct7 = (instr >> 25) & 0x7F;
    uint32_t funct5 = (instr >> 27) & 0x1F;

    // Decode based on opcode
    switch (opcode) {
        case 0x37: // LUI
        case 0x17: // AUIPC
            return decode_u_type(instr, opcode);

        case 0x6F: // JAL
            return decode_j_type(instr, pc);

        case 0x67: // JALR
            return decode_i_type(instr, opcode, funct3);

        case 0x63: // BRANCH
            return decode_b_type(instr, funct3, pc);

        case 0x03: // LOAD
            return decode_i_type(instr, opcode, funct3);

        case 0x23: // STORE
            return decode_s_type(instr, funct3);

        case 0x13: // OP-IMM
            return decode_i_type(instr, opcode, funct3);

        case 0x33: // OP (R-type ALU)
            return decode_r_type(instr, opcode, funct3, funct7);

        case 0x0F: // FENCE
            if (funct3 == 0) return "fence";
            return "fence.i";

        case 0x73: // SYSTEM (ECALL, EBREAK, CSR)
            return decode_system(instr, funct3);

        case 0x2F: // AMO (Atomic)
            return decode_amo(instr, funct3, funct5);

        default:
            return "unknown";
    }
}

std::string RiscvDisassembler::decode_r_type(uint32_t instr, uint32_t opcode, uint32_t funct3, uint32_t funct7) {
    uint32_t rd = (instr >> 7) & 0x1F;
    uint32_t rs1 = (instr >> 15) & 0x1F;
    uint32_t rs2 = (instr >> 20) & 0x1F;

    std::ostringstream oss;
    std::string mnemonic;

    if (opcode == 0x33) { // OP
        if (funct7 == 0x00) {
            switch (funct3) {
                case 0x0: mnemonic = "add"; break;
                case 0x1: mnemonic = "sll"; break;
                case 0x2: mnemonic = "slt"; break;
                case 0x3: mnemonic = "sltu"; break;
                case 0x4: mnemonic = "xor"; break;
                case 0x5: mnemonic = "srl"; break;
                case 0x6: mnemonic = "or"; break;
                case 0x7: mnemonic = "and"; break;
            }
        } else if (funct7 == 0x20) {
            if (funct3 == 0x0) mnemonic = "sub";
            else if (funct3 == 0x5) mnemonic = "sra";
            // Zbb
            else if (funct3 == 0x4) mnemonic = "xnor";
            else if (funct3 == 0x6) mnemonic = "orn";
            else if (funct3 == 0x7) mnemonic = "andn";
        } else if (funct7 == 0x01) { // RV32M
            switch (funct3) {
                case 0x0: mnemonic = "mul"; break;
                case 0x1: mnemonic = "mulh"; break;
                case 0x2: mnemonic = "mulhsu"; break;
                case 0x3: mnemonic = "mulhu"; break;
                case 0x4: mnemonic = "div"; break;
                case 0x5: mnemonic = "divu"; break;
                case 0x6: mnemonic = "rem"; break;
                case 0x7: mnemonic = "remu"; break;
            }
        } else if (funct7 == 0x05) { // Zbb (min/max)
            switch (funct3) {
                case 0x4: mnemonic = "min"; break;
                case 0x5: mnemonic = "minu"; break;
                case 0x6: mnemonic = "max"; break;
                case 0x7: mnemonic = "maxu"; break;
            }
        } else if (funct7 == 0x04) { // Zbb (pack)
            if (funct3 == 0x4) mnemonic = "pack";
            else if (funct3 == 0x7) mnemonic = "packh";
        } else if (funct7 == 0x30) { // Zbb (rol/ror)
            if (funct3 == 0x1) mnemonic = "rol";
            else if (funct3 == 0x5) mnemonic = "ror";
        } else if (funct7 == 0x0A) { // Zbc (clmul)
            switch (funct3) {
                case 0x1: mnemonic = "clmul"; break;
                case 0x2: mnemonic = "clmulr"; break;
                case 0x3: mnemonic = "clmulh"; break;
            }
        } else if (funct7 == 0x10) { // Zba (sh*add)
            switch (funct3) {
                case 0x2: mnemonic = "sh1add"; break;
                case 0x4: mnemonic = "sh2add"; break;
                case 0x6: mnemonic = "sh3add"; break;
            }
        } else if (funct7 == 0x24) { // Zbs (bclr/bext)
            if (funct3 == 0x1) mnemonic = "bclr";
            else if (funct3 == 0x5) mnemonic = "bext";
        } else if (funct7 == 0x34) { // Zbs (binv)
            if (funct3 == 0x1) mnemonic = "binv";
        } else if (funct7 == 0x14) { // Zbs (bset)
            if (funct3 == 0x1) mnemonic = "bset";
        }
    }

    if (mnemonic.empty()) {
        return "unknown";
    }

    oss << mnemonic << " " << reg_name(rd) << "," << reg_name(rs1) << "," << reg_name(rs2);
    return oss.str();
}

std::string RiscvDisassembler::decode_i_type(uint32_t instr, uint32_t opcode, uint32_t funct3) {
    uint32_t rd = (instr >> 7) & 0x1F;
    uint32_t rs1 = (instr >> 15) & 0x1F;
    int32_t imm = sign_extend(instr >> 20, 12);

    std::ostringstream oss;
    std::string mnemonic;

    if (opcode == 0x03) { // LOAD
        switch (funct3) {
            case 0x0: mnemonic = "lb"; break;
            case 0x1: mnemonic = "lh"; break;
            case 0x2: mnemonic = "lw"; break;
            case 0x4: mnemonic = "lbu"; break;
            case 0x5: mnemonic = "lhu"; break;
        }
        if (!mnemonic.empty()) {
            oss << mnemonic << " " << reg_name(rd) << "," << imm << "(" << reg_name(rs1) << ")";
            return oss.str();
        }
    } else if (opcode == 0x13) { // OP-IMM
        uint32_t shamt = imm & 0x1F;
        uint32_t funct7 = (instr >> 25) & 0x7F;

        switch (funct3) {
            case 0x0: mnemonic = "addi"; break;
            case 0x1:
                if (funct7 == 0x60) {
                    // Zbb count/extend instructions (single operand)
                    if (shamt == 0x00) { return "clz " + reg_name(rd) + "," + reg_name(rs1); }
                    if (shamt == 0x01) { return "ctz " + reg_name(rd) + "," + reg_name(rs1); }
                    if (shamt == 0x02) { return "cpop " + reg_name(rd) + "," + reg_name(rs1); }
                    if (shamt == 0x04) { return "sext.b " + reg_name(rd) + "," + reg_name(rs1); }
                    if (shamt == 0x05) { return "sext.h " + reg_name(rd) + "," + reg_name(rs1); }
                } else if (funct7 == 0x30) {
                    if (shamt == 0x18) { return "rev8 " + reg_name(rd) + "," + reg_name(rs1); }
                } else if (funct7 == 0x28) {
                    if (shamt == 0x07) { return "orc.b " + reg_name(rd) + "," + reg_name(rs1); }
                } else if (funct7 == 0x04) {
                    if (shamt == 0x07) { return "zext.h " + reg_name(rd) + "," + reg_name(rs1); }
                } else {
                    mnemonic = "slli"; imm = shamt;
                }
                break;
            case 0x2: mnemonic = "slti"; break;
            case 0x3: mnemonic = "sltiu"; break;
            case 0x4: mnemonic = "xori"; break;
            case 0x5:
                if (funct7 == 0x00) {
                    mnemonic = "srli";
                    imm = shamt;
                } else if (funct7 == 0x20) {
                    mnemonic = "srai";
                    imm = shamt;
                } else if (funct7 == 0x30) { // Zbb rori
                    mnemonic = "rori";
                    imm = shamt;
                } else if (funct7 == 0x24) { // Zbs bexti
                    mnemonic = "bexti";
                    imm = shamt;
                } else if (funct7 == 0x34) { // Zbs binvi
                    mnemonic = "binvi";
                    imm = shamt;
                } else if (funct7 == 0x14) { // Zbs bseti
                    mnemonic = "bseti";
                    imm = shamt;
                } else if (funct7 == 0x2C) { // Zbs bclri
                    mnemonic = "bclri";
                    imm = shamt;
                }
                break;
            case 0x6: mnemonic = "ori"; break;
            case 0x7: mnemonic = "andi"; break;
        }

        if (!mnemonic.empty()) {
            oss << mnemonic << " " << reg_name(rd) << "," << reg_name(rs1) << "," << imm;
            return oss.str();
        }
    } else if (opcode == 0x67) { // JALR
        oss << "jalr " << reg_name(rd) << "," << reg_name(rs1) << "," << imm;
        return oss.str();
    }

    return "unknown";
}

std::string RiscvDisassembler::decode_s_type(uint32_t instr, uint32_t funct3) {
    uint32_t rs1 = (instr >> 15) & 0x1F;
    uint32_t rs2 = (instr >> 20) & 0x1F;
    int32_t imm = sign_extend(((instr >> 25) << 5) | ((instr >> 7) & 0x1F), 12);

    std::ostringstream oss;
    std::string mnemonic;

    switch (funct3) {
        case 0x0: mnemonic = "sb"; break;
        case 0x1: mnemonic = "sh"; break;
        case 0x2: mnemonic = "sw"; break;
    }

    if (mnemonic.empty()) {
        return "unknown";
    }

    oss << mnemonic << " " << reg_name(rs2) << "," << imm << "(" << reg_name(rs1) << ")";
    return oss.str();
}

std::string RiscvDisassembler::decode_b_type(uint32_t instr, uint32_t funct3, uint32_t pc) {
    uint32_t rs1 = (instr >> 15) & 0x1F;
    uint32_t rs2 = (instr >> 20) & 0x1F;

    // Reconstruct branch offset
    int32_t imm = sign_extend(
        ((instr >> 31) << 12) |
        (((instr >> 7) & 0x1) << 11) |
        (((instr >> 25) & 0x3F) << 5) |
        (((instr >> 8) & 0xF) << 1), 13);

    std::ostringstream oss;
    std::string mnemonic;

    switch (funct3) {
        case 0x0: mnemonic = "beq"; break;
        case 0x1: mnemonic = "bne"; break;
        case 0x4: mnemonic = "blt"; break;
        case 0x5: mnemonic = "bge"; break;
        case 0x6: mnemonic = "bltu"; break;
        case 0x7: mnemonic = "bgeu"; break;
    }

    if (mnemonic.empty()) {
        return "unknown";
    }

    uint32_t target = pc + imm;
    oss << mnemonic << " " << reg_name(rs1) << "," << reg_name(rs2) << "," << format_address(target);
    return oss.str();
}

std::string RiscvDisassembler::decode_u_type(uint32_t instr, uint32_t opcode) {
    uint32_t rd = (instr >> 7) & 0x1F;
    uint32_t imm = instr & 0xFFFFF000;

    std::ostringstream oss;

    if (opcode == 0x37) { // LUI
        oss << "lui " << reg_name(rd) << ",0x" << std::hex << (imm >> 12);
    } else if (opcode == 0x17) { // AUIPC
        oss << "auipc " << reg_name(rd) << ",0x" << std::hex << (imm >> 12);
    } else {
        return "unknown";
    }

    return oss.str();
}

std::string RiscvDisassembler::decode_j_type(uint32_t instr, uint32_t pc) {
    uint32_t rd = (instr >> 7) & 0x1F;

    // Reconstruct jump offset
    int32_t imm = sign_extend(
        ((instr >> 31) << 20) |
        (((instr >> 12) & 0xFF) << 12) |
        (((instr >> 20) & 0x1) << 11) |
        (((instr >> 21) & 0x3FF) << 1), 21);

    std::ostringstream oss;
    uint32_t target = pc + imm;
    oss << "jal " << reg_name(rd) << "," << format_address(target);
    return oss.str();
}

std::string RiscvDisassembler::decode_system(uint32_t instr, uint32_t funct3) {
    uint32_t rd = (instr >> 7) & 0x1F;
    uint32_t rs1 = (instr >> 15) & 0x1F;
    uint32_t csr = instr >> 20;
    uint32_t zimm = rs1; // For CSRI instructions, rs1 field is immediate

    std::ostringstream oss;

    if (funct3 == 0x0) {
        // ECALL, EBREAK, MRET, WFI, etc.
        uint32_t imm = instr >> 20;
        if (imm == 0x0) return "ecall";
        if (imm == 0x1) return "ebreak";
        if (imm == 0x105) return "wfi";
        if (imm == 0x302) return "mret";
        if (imm == 0x102) return "sret";
        if (imm == 0x002) return "uret";
        return "unknown";
    }

    std::string mnemonic;
    bool is_imm = false;

    switch (funct3) {
        case 0x1: mnemonic = "csrrw"; break;
        case 0x2: mnemonic = "csrrs"; break;
        case 0x3: mnemonic = "csrrc"; break;
        case 0x5: mnemonic = "csrrwi"; is_imm = true; break;
        case 0x6: mnemonic = "csrrsi"; is_imm = true; break;
        case 0x7: mnemonic = "csrrci"; is_imm = true; break;
    }

    if (mnemonic.empty()) {
        return "unknown";
    }

    if (is_imm) {
        oss << mnemonic << " " << reg_name(rd) << "," << csr_name(csr) << "," << zimm;
    } else {
        oss << mnemonic << " " << reg_name(rd) << "," << csr_name(csr) << "," << reg_name(rs1);
    }

    return oss.str();
}

std::string RiscvDisassembler::decode_amo(uint32_t instr, uint32_t funct3, uint32_t funct5) {
    uint32_t rd = (instr >> 7) & 0x1F;
    uint32_t rs1 = (instr >> 15) & 0x1F;
    uint32_t rs2 = (instr >> 20) & 0x1F;
    uint32_t aq = (instr >> 26) & 0x1;
    uint32_t rl = (instr >> 27) & 0x1;

    std::ostringstream oss;
    std::string mnemonic;
    std::string suffix;

    // Width suffix
    if (funct3 == 0x2) suffix = ".w";
    else if (funct3 == 0x3) suffix = ".d";
    else return "unknown";

    // Ordering suffix
    if (aq && rl) suffix += ".aqrl";
    else if (aq) suffix += ".aq";
    else if (rl) suffix += ".rl";

    switch (funct5) {
        case 0x02: mnemonic = "lr"; break;
        case 0x03: mnemonic = "sc"; break;
        case 0x01: mnemonic = "amoswap"; break;
        case 0x00: mnemonic = "amoadd"; break;
        case 0x04: mnemonic = "amoxor"; break;
        case 0x0C: mnemonic = "amoand"; break;
        case 0x08: mnemonic = "amoor"; break;
        case 0x10: mnemonic = "amomin"; break;
        case 0x14: mnemonic = "amomax"; break;
        case 0x18: mnemonic = "amominu"; break;
        case 0x1C: mnemonic = "amomaxu"; break;
    }

    if (mnemonic.empty()) {
        return "unknown";
    }

    if (funct5 == 0x02) { // LR - no rs2
        oss << mnemonic << suffix << " " << reg_name(rd) << ",(" << reg_name(rs1) << ")";
    } else {
        oss << mnemonic << suffix << " " << reg_name(rd) << "," << reg_name(rs2) << ",(" << reg_name(rs1) << ")";
    }

    return oss.str();
}

std::string RiscvDisassembler::reg_name(uint32_t reg) {
    static const char* abi_names[] = {
        "zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
        "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
        "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
        "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"
    };

    if (reg < 32) {
        return abi_names[reg];
    }
    return "x?";
}

std::string RiscvDisassembler::csr_name(uint32_t csr) {
    switch (csr) {
        // Machine Information Registers
        case 0xF11: return "mvendorid";
        case 0xF12: return "marchid";
        case 0xF13: return "mimpid";
        case 0xF14: return "mhartid";

        // Machine Trap Setup
        case 0x300: return "mstatus";
        case 0x301: return "misa";
        case 0x302: return "medeleg";
        case 0x303: return "mideleg";
        case 0x304: return "mie";
        case 0x305: return "mtvec";
        case 0x306: return "mcounteren";

        // Machine Trap Handling
        case 0x340: return "mscratch";
        case 0x341: return "mepc";
        case 0x342: return "mcause";
        case 0x343: return "mtval";
        case 0x344: return "mip";

        // Machine Memory Protection
        case 0x3A0: return "pmpcfg0";
        case 0x3A1: return "pmpcfg1";
        case 0x3A2: return "pmpcfg2";
        case 0x3A3: return "pmpcfg3";
        case 0x3B0: return "pmpaddr0";
        case 0x3B1: return "pmpaddr1";
        case 0x3B2: return "pmpaddr2";
        case 0x3B3: return "pmpaddr3";
        case 0x3B4: return "pmpaddr4";
        case 0x3B5: return "pmpaddr5";
        case 0x3B6: return "pmpaddr6";
        case 0x3B7: return "pmpaddr7";
        case 0x3B8: return "pmpaddr8";
        case 0x3B9: return "pmpaddr9";
        case 0x3BA: return "pmpaddr10";
        case 0x3BB: return "pmpaddr11";
        case 0x3BC: return "pmpaddr12";
        case 0x3BD: return "pmpaddr13";
        case 0x3BE: return "pmpaddr14";
        case 0x3BF: return "pmpaddr15";

        // Machine Counter/Timers
        case 0xB00: return "mcycle";
        case 0xB02: return "minstret";
        case 0xB80: return "mcycleh";
        case 0xB82: return "minstreth";

        // User Counter/Timers
        case 0xC00: return "cycle";
        case 0xC01: return "time";
        case 0xC02: return "instret";
        case 0xC80: return "cycleh";
        case 0xC81: return "timeh";
        case 0xC82: return "instreth";

        default: {
            std::ostringstream oss;
            oss << "0x" << std::hex << csr;
            return oss.str();
        }
    }
}

std::string RiscvDisassembler::format_address(uint32_t addr) {
    std::ostringstream oss;
    oss << "0x" << std::hex << addr;
    return oss.str();
}

int32_t RiscvDisassembler::sign_extend(uint32_t value, int bits) {
    uint32_t sign_bit = 1U << (bits - 1);
    if (value & sign_bit) {
        // Negative - extend with 1s
        uint32_t mask = ~((1U << bits) - 1);
        return (int32_t)(value | mask);
    } else {
        // Positive - just return value
        return (int32_t)value;
    }
}

std::string RiscvDisassembler::c_reg_name(uint32_t reg) {
    // Compressed instructions use registers x8-x15 (s0-a5)
    return reg_name(reg + 8);
}

std::string RiscvDisassembler::decode_compressed(uint16_t instr, uint32_t pc) {
    uint32_t quadrant = instr & 0x3;

    switch (quadrant) {
        case 0: return decode_c_quadrant0(instr);
        case 1: return decode_c_quadrant1(instr, pc);
        case 2: return decode_c_quadrant2(instr);
        default: return "unknown";
    }
}

std::string RiscvDisassembler::decode_c_quadrant0(uint16_t instr) {
    uint32_t funct3 = (instr >> 13) & 0x7;
    uint32_t rd_rs2_p = (instr >> 2) & 0x7;  // rd'/rs2' for 3-bit encoding
    uint32_t rs1_p = (instr >> 7) & 0x7;     // rs1' for 3-bit encoding

    std::ostringstream oss;

    switch (funct3) {
        case 0x0: { // C.ADDI4SPN
            uint32_t nzuimm = ((instr >> 7) & 0x30) | ((instr >> 1) & 0x3C0) |
                             ((instr >> 4) & 0x4) | ((instr >> 2) & 0x8);
            if (nzuimm == 0) return "illegal";
            oss << "c.addi4spn " << c_reg_name(rd_rs2_p) << ",sp," << nzuimm;
            return oss.str();
        }
        case 0x1: { // C.FLD (not implemented for integer-only)
            return "c.fld";
        }
        case 0x2: { // C.LW
            uint32_t uimm = ((instr >> 7) & 0x38) | ((instr >> 4) & 0x4) | ((instr << 1) & 0x40);
            oss << "c.lw " << c_reg_name(rd_rs2_p) << "," << uimm << "(" << c_reg_name(rs1_p) << ")";
            return oss.str();
        }
        case 0x3: { // C.FLW (not implemented for integer-only)
            return "c.flw";
        }
        case 0x5: { // C.FSD (not implemented for integer-only)
            return "c.fsd";
        }
        case 0x6: { // C.SW
            uint32_t uimm = ((instr >> 7) & 0x38) | ((instr >> 4) & 0x4) | ((instr << 1) & 0x40);
            oss << "c.sw " << c_reg_name(rd_rs2_p) << "," << uimm << "(" << c_reg_name(rs1_p) << ")";
            return oss.str();
        }
        case 0x7: { // C.FSW (not implemented for integer-only)
            return "c.fsw";
        }
        default:
            return "unknown";
    }
}

std::string RiscvDisassembler::decode_c_quadrant1(uint16_t instr, uint32_t pc) {
    uint32_t funct3 = (instr >> 13) & 0x7;
    uint32_t rd_rs1 = (instr >> 7) & 0x1F;

    std::ostringstream oss;

    switch (funct3) {
        case 0x0: { // C.ADDI / C.NOP
            int32_t nzimm = sign_extend(((instr >> 7) & 0x20) | ((instr >> 2) & 0x1F), 6);
            if (rd_rs1 == 0 && nzimm == 0) {
                return "c.nop";
            } else if (rd_rs1 == 0) {
                return "illegal";
            }
            oss << "c.addi " << reg_name(rd_rs1) << "," << nzimm;
            return oss.str();
        }
        case 0x1: { // C.JAL (RV32) / C.ADDIW (RV64)
            int32_t imm = sign_extend(
                ((instr >> 1) & 0x800) | ((instr >> 7) & 0x10) | ((instr >> 1) & 0x300) |
                ((instr << 2) & 0x400) | ((instr >> 1) & 0x40) | ((instr << 1) & 0x80) |
                ((instr >> 2) & 0xE) | ((instr << 3) & 0x20), 12);
            uint32_t target = pc + imm;
            oss << "c.jal " << format_address(target);
            return oss.str();
        }
        case 0x2: { // C.LI
            int32_t imm = sign_extend(((instr >> 7) & 0x20) | ((instr >> 2) & 0x1F), 6);
            if (rd_rs1 == 0) return "illegal";
            oss << "c.li " << reg_name(rd_rs1) << "," << imm;
            return oss.str();
        }
        case 0x3: { // C.ADDI16SP / C.LUI
            if (rd_rs1 == 2) { // C.ADDI16SP
                int32_t nzimm = sign_extend(
                    ((instr >> 3) & 0x200) | ((instr >> 2) & 0x10) | ((instr << 1) & 0x40) |
                    ((instr << 4) & 0x180) | ((instr << 3) & 0x20), 10);
                if (nzimm == 0) return "illegal";
                oss << "c.addi16sp sp," << nzimm;
                return oss.str();
            } else { // C.LUI
                int32_t nzimm = sign_extend(((instr >> 7) & 0x20) | ((instr >> 2) & 0x1F), 6);
                if (rd_rs1 == 0 || nzimm == 0) return "illegal";
                oss << "c.lui " << reg_name(rd_rs1) << ",0x" << std::hex << (nzimm & 0x1F);
                return oss.str();
            }
        }
        case 0x4: { // Arithmetic
            uint32_t funct2 = (instr >> 10) & 0x3;
            uint32_t rd_rs1_p = (instr >> 7) & 0x7;
            uint32_t rs2_p = (instr >> 2) & 0x7;

            if (funct2 == 0x0) { // C.SRLI
                uint32_t shamt = ((instr >> 7) & 0x20) | ((instr >> 2) & 0x1F);
                oss << "c.srli " << c_reg_name(rd_rs1_p) << "," << shamt;
                return oss.str();
            } else if (funct2 == 0x1) { // C.SRAI
                uint32_t shamt = ((instr >> 7) & 0x20) | ((instr >> 2) & 0x1F);
                oss << "c.srai " << c_reg_name(rd_rs1_p) << "," << shamt;
                return oss.str();
            } else if (funct2 == 0x2) { // C.ANDI
                int32_t imm = sign_extend(((instr >> 7) & 0x20) | ((instr >> 2) & 0x1F), 6);
                oss << "c.andi " << c_reg_name(rd_rs1_p) << "," << imm;
                return oss.str();
            } else if (funct2 == 0x3) {
                uint32_t funct1 = (instr >> 12) & 0x1;
                uint32_t funct2_low = (instr >> 5) & 0x3;

                if (funct1 == 0 && funct2_low == 0x0) {
                    oss << "c.sub " << c_reg_name(rd_rs1_p) << "," << c_reg_name(rs2_p);
                } else if (funct1 == 0 && funct2_low == 0x1) {
                    oss << "c.xor " << c_reg_name(rd_rs1_p) << "," << c_reg_name(rs2_p);
                } else if (funct1 == 0 && funct2_low == 0x2) {
                    oss << "c.or " << c_reg_name(rd_rs1_p) << "," << c_reg_name(rs2_p);
                } else if (funct1 == 0 && funct2_low == 0x3) {
                    oss << "c.and " << c_reg_name(rd_rs1_p) << "," << c_reg_name(rs2_p);
                } else {
                    return "unknown";
                }
                return oss.str();
            }
            return "unknown";
        }
        case 0x5: { // C.J
            int32_t imm = sign_extend(
                ((instr >> 1) & 0x800) | ((instr >> 7) & 0x10) | ((instr >> 1) & 0x300) |
                ((instr << 2) & 0x400) | ((instr >> 1) & 0x40) | ((instr << 1) & 0x80) |
                ((instr >> 2) & 0xE) | ((instr << 3) & 0x20), 12);
            uint32_t target = pc + imm;
            oss << "c.j " << format_address(target);
            return oss.str();
        }
        case 0x6: { // C.BEQZ
            uint32_t rs1_p = (instr >> 7) & 0x7;
            int32_t imm = sign_extend(
                ((instr >> 4) & 0x100) | ((instr >> 7) & 0x18) | ((instr << 1) & 0xC0) |
                ((instr >> 2) & 0x6) | ((instr << 3) & 0x20), 9);
            uint32_t target = pc + imm;
            oss << "c.beqz " << c_reg_name(rs1_p) << "," << format_address(target);
            return oss.str();
        }
        case 0x7: { // C.BNEZ
            uint32_t rs1_p = (instr >> 7) & 0x7;
            int32_t imm = sign_extend(
                ((instr >> 4) & 0x100) | ((instr >> 7) & 0x18) | ((instr << 1) & 0xC0) |
                ((instr >> 2) & 0x6) | ((instr << 3) & 0x20), 9);
            uint32_t target = pc + imm;
            oss << "c.bnez " << c_reg_name(rs1_p) << "," << format_address(target);
            return oss.str();
        }
        default:
            return "unknown";
    }
}

std::string RiscvDisassembler::decode_c_quadrant2(uint16_t instr) {
    uint32_t funct3 = (instr >> 13) & 0x7;
    uint32_t rd_rs1 = (instr >> 7) & 0x1F;
    uint32_t rs2 = (instr >> 2) & 0x1F;

    std::ostringstream oss;

    switch (funct3) {
        case 0x0: { // C.SLLI
            uint32_t shamt = ((instr >> 7) & 0x20) | ((instr >> 2) & 0x1F);
            if (rd_rs1 == 0 || shamt == 0) return "illegal";
            oss << "c.slli " << reg_name(rd_rs1) << "," << shamt;
            return oss.str();
        }
        case 0x1: { // C.FLDSP (not implemented)
            return "c.fldsp";
        }
        case 0x2: { // C.LWSP
            uint32_t uimm = ((instr >> 7) & 0x20) | ((instr >> 2) & 0x1C) | ((instr << 4) & 0xC0);
            if (rd_rs1 == 0) return "illegal";
            oss << "c.lwsp " << reg_name(rd_rs1) << "," << uimm << "(sp)";
            return oss.str();
        }
        case 0x3: { // C.FLWSP (not implemented)
            return "c.flwsp";
        }
        case 0x4: { // C.JR / C.MV / C.EBREAK / C.JALR / C.ADD
            uint32_t funct1 = (instr >> 12) & 0x1;

            if (funct1 == 0) {
                if (rs2 == 0) { // C.JR
                    if (rd_rs1 == 0) return "illegal";
                    oss << "c.jr " << reg_name(rd_rs1);
                } else { // C.MV
                    oss << "c.mv " << reg_name(rd_rs1) << "," << reg_name(rs2);
                }
            } else {
                if (rd_rs1 == 0 && rs2 == 0) { // C.EBREAK
                    return "c.ebreak";
                } else if (rs2 == 0) { // C.JALR
                    oss << "c.jalr " << reg_name(rd_rs1);
                } else { // C.ADD
                    oss << "c.add " << reg_name(rd_rs1) << "," << reg_name(rs2);
                }
            }
            return oss.str();
        }
        case 0x5: { // C.FSDSP (not implemented)
            return "c.fsdsp";
        }
        case 0x6: { // C.SWSP
            uint32_t uimm = ((instr >> 7) & 0x3C) | ((instr >> 1) & 0xC0);
            oss << "c.swsp " << reg_name(rs2) << "," << uimm << "(sp)";
            return oss.str();
        }
        case 0x7: { // C.FSWSP (not implemented)
            return "c.fswsp";
        }
        default:
            return "unknown";
    }
}

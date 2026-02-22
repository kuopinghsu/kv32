#ifndef RISCV_DIS_H
#define RISCV_DIS_H

#include <cstdint>
#include <string>

// RISC-V Instruction Disassembler
// Supports RV32I base ISA, M extension (multiply/divide), A extension (atomics),
// and Zicsr extension (CSR instructions)

class RiscvDisassembler {
public:
    RiscvDisassembler();

    // Disassemble a 32-bit instruction at given PC
    // Automatically detects compressed (16-bit) vs normal (32-bit) instructions
    // Returns human-readable assembly string
    std::string disassemble(uint32_t instr, uint32_t pc = 0);

private:
    // Instruction format decoders
    std::string decode_r_type(uint32_t instr, uint32_t opcode, uint32_t funct3, uint32_t funct7);
    std::string decode_i_type(uint32_t instr, uint32_t opcode, uint32_t funct3);
    std::string decode_s_type(uint32_t instr, uint32_t funct3);
    std::string decode_b_type(uint32_t instr, uint32_t funct3, uint32_t pc);
    std::string decode_u_type(uint32_t instr, uint32_t opcode);
    std::string decode_j_type(uint32_t instr, uint32_t pc);
    std::string decode_system(uint32_t instr, uint32_t funct3);
    std::string decode_amo(uint32_t instr, uint32_t funct3, uint32_t funct5);
    std::string decode_compressed(uint16_t instr, uint32_t pc);
    std::string decode_c_quadrant0(uint16_t instr);
    std::string decode_c_quadrant1(uint16_t instr, uint32_t pc);
    std::string decode_c_quadrant2(uint16_t instr);

    // Helper functions
    std::string reg_name(uint32_t reg);
    std::string c_reg_name(uint32_t reg);  // Compressed register (x8-x15)
    std::string csr_name(uint32_t csr);
    std::string format_address(uint32_t addr);
    int32_t sign_extend(uint32_t value, int bits);
};

#endif // RISCV_DIS_H

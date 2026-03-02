// ============================================================================
// File: kv32_asm_program_gen.sv
// Project: KV32 RISC-V Processor — riscv-dv target
// Description: KV32-specific assembly program generator.
//
// Extends the base riscv_asm_program_gen to customise the generated assembly
// for the KV32 SoC environment:
//   - Boot address at 0x8000_0000
//   - Stack at top of 2 MB RAM (0x801F_FFFF)
//   - Machine-mode only operation
//   - Exit via KV_MAGIC_EXIT write (0x10000000)
// ============================================================================

class kv32_asm_program_gen extends riscv_asm_program_gen;

  `uvm_object_utils(kv32_asm_program_gen)

  function new(string name = "");
    super.new(name);
  endfunction

endclass

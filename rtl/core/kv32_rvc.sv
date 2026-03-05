// ============================================================================
// File: kv32_rvc.sv
// Project: KV32 RISC-V Processor
// Description: RVC (Zca) Compressed-Instruction Expander
//
// Sits between the icache response interface and the IF/ID pipeline register.
// Fetches always arrive as 32-bit words aligned to 4-byte boundaries.  This
// module handles the two complications that arise from 16-bit instructions:
//
//   1. Two compressed instructions packed into one 32-bit word.
//   2. A 32-bit instruction that spans two consecutive fetch words (split case).
//
// Interface
//   imem_resp_*  — icache (or raw memory) 32-bit word response
//   flush_pc     — full target PC (possibly halfword-aligned) on any pipeline
//                  flush; bit[1] sets init_offset for the next fetch
//   instr_valid  — output instruction valid to IF/ID
//   instr_data   — 32-bit expanded instruction (RV32I encoding)
//   instr_pc     — PC of the instruction presented on instr_data
//   mem_ready    — back-pressure to icache (replaces imem_resp_ready in core)
//   is_compressed — asserted when the current output was a 16-bit RVC insn
//
// State registers
//   hold_valid  — 1 when the upper halfword of the previous fetch is buffered
//   hold[15:0]  — the buffered upper halfword
//   hold_pc     — PC of the instruction described by hold
//   init_offset — 1 when the next fetch word should be entered at bit[16]
//                 (target PC has bit[1]=1, i.e. second halfword of a word)
//   pend_valid  — 1 when a fetch word has arrived but could not be consumed
//                 because the pipeline was stalled (case_a backpressure relief)
//   pend_data   — the stalled fetch word
//
// Decode cases (evaluated each cycle)
//   case_hold    — output the buffered halfword (hold_valid=1)
//   case_a       — lower halfword is a 32-bit instruction (bits[1:0]=11)
//   case_b       — lower halfword is a compressed instruction
//   case_c       — upper halfword is a compressed instruction (after case_b)
//   case_d       — 32-bit instruction split across two fetch words (hold upper)
//   case_load_hold — init_offset=1: upper halfword is lower half of 32-bit insn
//
// Expansion
//   All 16-bit RVC instructions (Zca subset) are expanded to their 32-bit
//   RV32I/M equivalents.  The downstream decoder sees only standard 32-bit
//   encodings and requires no knowledge of the C extension.
//
// References
//   RISC-V ISA Volume I, Chapter 26 (C Standard Extension, Zca)
//   sim/kv32sim.cpp expand_compressed() — golden functional reference

// `default_nettype none is beneficial for simulation (catches undeclared nets)
// but triggers Genus VLOGPT-43 for `input logic` ports even in SV mode.
// Guard it so synthesis tools that define SYNTHESIS skip the directive.
`ifndef SYNTHESIS
`default_nettype none
`endif

module kv32_rvc (
    input  logic        clk,
    input  logic        rst_n,

    // -------------------------------------------------------------------------
    // Memory response (from icache, via kv32_core)
    // -------------------------------------------------------------------------
    input  logic        imem_resp_valid,    // icache response valid
    input  logic [31:0] imem_resp_data,     // 32-bit fetch word
    input  logic [31:0] ib_resp_pc,         // 4-byte-aligned fetch PC (from IB)
    input  logic        ib_resp_discard,    // IB says discard this response

    // -------------------------------------------------------------------------
    // Pipeline control
    // -------------------------------------------------------------------------
    // consume_en mirrors the old imem_resp_ready gating:
    //   = !if_id_stall || ib_resp_discard || wfi_sleeping
    // kv32_core computes this and passes it in so the logic is centralised.
    input  logic        consume_en,

    input  logic        flush,              // if_flush — clear held state
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] flush_pc,           // target PC on flush (bit[1] → init_offset)
    /* verilator lint_on UNUSEDSIGNAL */

    // -------------------------------------------------------------------------
    // Instruction output (to IF/ID register and decode stage)
    // -------------------------------------------------------------------------
    output logic        instr_valid,        // valid instruction ready for IF/ID
    output logic [31:0] instr_data,         // expanded 32-bit instruction
    output logic [31:0] orig_instr,         // original encoding: 16-bit (zero-ext) for RVC, 32-bit for regular
    output logic [31:0] instr_pc,           // actual instruction PC (halfword aligned)
    output logic        is_compressed,      // instruction was originally 16-bit

    // -------------------------------------------------------------------------
    // Memory handshake control
    // -------------------------------------------------------------------------
    output logic        mem_ready           // drives imem_resp_ready in kv32_core
);

    // =========================================================================
    // State registers
    // =========================================================================
    logic        hold_valid;
    logic [15:0] hold;
    logic [31:0] hold_pc;
    logic        init_offset;   // 1 → skip lower halfword of first post-flush fetch

    // "Pending word" buffer: when hold is FULL (case_a) and the icache delivers
    // the next fetch word simultaneously, we cannot process it immediately.
    // We accept it (to release the icache from S_RESP) and park it here.
    // Next cycle, this word is processed exactly as if it had just arrived from
    // the icache (case_b / case_c / case_load_hold logic).
    logic        pend_valid;
    logic [31:0] pend_data;
    logic [31:0] pend_pc;

    // =========================================================================
    // RVC expansion function
    // Translates a 16-bit compressed encoding to its 32-bit canonical form.
    // Returns 32'h0 for illegal/reserved encodings (decoder will raise illegal-
    // instruction exception via the illegal_id signal).
    // Mirrors sim/kv32sim.cpp expand_compressed() exactly.
    // =========================================================================

    // Sign-extend helpers: return 32-bit value
    /* verilator lint_off WIDTHEXPAND */
    function automatic logic [31:0] c_sext6(input logic [5:0] v);
        c_sext6 = 32'(v);
        if (v[5]) c_sext6 = c_sext6 | 32'hFFFF_FFC0;
    endfunction
    function automatic logic [31:0] c_sext9(input logic [8:0] v);
        c_sext9 = 32'(v);
        if (v[8]) c_sext9 = c_sext9 | 32'hFFFF_FF00;
    endfunction
    function automatic logic [31:0] c_sext10(input logic [9:0] v);
        c_sext10 = 32'(v);
        if (v[9]) c_sext10 = c_sext10 | 32'hFFFF_FE00;
    endfunction
    function automatic logic [31:0] c_sext12(input logic [11:0] v);
        c_sext12 = 32'(v);
        if (v[11]) c_sext12 = c_sext12 | 32'hFFFF_F000;
    endfunction
    /* verilator lint_on WIDTHEXPAND */

    // C.J / C.JAL offset — 12-bit signed (bit shuffle from spec §26.9)
    // Bit layout (spec §26.9): offset[11|4|9:8|10|6|7|3:1|5|0]
    //   raw[11]=ci[12], raw[10]=ci[8], raw[9:8]=ci[10:9], raw[7]=ci[6],
    //   raw[6]=ci[7],   raw[5]=ci[2],  raw[4]=ci[11],     raw[3:1]=ci[5:3],
    //   raw[0]=0 (halfword-aligned, must be explicit to get the right width)
    /* verilator lint_off UNUSEDSIGNAL */
    /* verilator lint_off WIDTHEXPAND */
    // Inlined to avoid local-variable declarations inside ANSI-style function bodies
    // (not supported by all synthesis tools including older Yosys versions).
    function automatic logic [31:0] c_j_offset(input logic [15:0] ci);
        c_j_offset = c_sext12({ci[12], ci[8], ci[10:9], ci[6], ci[7], ci[2], ci[11], ci[5:3], 1'b0});
    endfunction

    // C.BEQZ / C.BNEZ offset — 9-bit signed (bit shuffle from spec §26.9)
    // Bit layout: offset[8|4:3|7:6|2:1|5|0]
    //   raw[8]=ci[12], raw[7:6]=ci[6:5], raw[5]=ci[2],
    //   raw[4:3]=ci[11:10], raw[2:1]=ci[4:3], raw[0]=0 (halfword-aligned)
    function automatic logic [31:0] c_b_offset(input logic [15:0] ci);
        c_b_offset = c_sext9({ci[12], ci[6:5], ci[2], ci[11:10], ci[4:3], 1'b0});
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    /* verilator lint_on WIDTHEXPAND */

    // encode_jal: JAL rd, imm (imm is a PC-relative signed offset)
    // Note: only specific bits of imm are used per J-type encoding; others are intentionally not referenced.
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [31:0] encode_jal(input logic [4:0] rd,
                                               input logic [31:0] imm);
        encode_jal = {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'h6F};
    endfunction

    // encode_branch: B-type (funct3, rs1, rs2, imm)
    function automatic logic [31:0] encode_branch(input logic [2:0] ft3,
                                                   input logic [4:0] rs1,
                                                   input logic [4:0] rs2,
                                                   input logic [31:0] imm);
        encode_branch = {imm[12], imm[10:5], rs2, rs1, ft3, imm[4:1], imm[11], 7'h63};
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // Main expansion — returns 32-bit canonical instruction, or 32'h0 (illegal)
    // lint_off: nzimm/imm are 32-bit but only selected bits (11:0 or 19:12 etc)
    // are referenced in each instruction encoding — this is intentional.
    /* verilator lint_off UNUSEDSIGNAL */
    /* verilator lint_off WIDTHEXPAND */
    // Non-ANSI port style so that local variable declarations appear before the
    // function body — required for Yosys compatibility.
    function automatic logic [31:0] expand_c;
        input logic [15:0] ci;
        logic [1:0]  quad;
        logic [2:0]  funct3;
        logic [4:0]  rd_rs1, rs2;
        logic [4:0]  rd_p, rs1_p, rs2_p;
        logic [11:0] nzuimm12, uimm12;   // 12-bit immediate fields
        logic [31:0] nzimm, imm;         // sign-extended immediates
        logic [1:0]  funct2;
        logic        f1;
        logic [1:0]  f2_low;

        quad   = ci[1:0];
        funct3 = ci[15:13];

        rd_p   = {2'b01, ci[4:2]};   // rd'/rs2' → x8–x15
        rs1_p  = {2'b01, ci[9:7]};   // rs1'     → x8–x15
        rs2_p  = {2'b01, ci[4:2]};   // same bits as rd_p for Q0/Q1

        expand_c = 32'h0; // default: illegal

        case (quad)
        2'b00: begin // -------------------------------------------------------
            // Quadrant 0
            case (funct3)
            3'h0: begin // C.ADDI4SPN → ADDI rd', x2, nzuimm
                nzuimm12 = {ci[10:7], ci[12:11], ci[5], ci[6], 2'b00};
                if (nzuimm12 == 12'h0) expand_c = 32'h0; // illegal
                else expand_c = {nzuimm12, 5'd2, 3'h0, rd_p, 7'h13};
            end
            3'h2: begin // C.LW → LW rd', offset(rs1')
                uimm12 = {5'b0, ci[5], ci[12:10], ci[6], 2'b00};
                expand_c = {uimm12, rs1_p, 3'h2, rd_p, 7'h03};
            end
            3'h6: begin // C.SW → SW rs2', offset(rs1')
                uimm12 = {5'b0, ci[5], ci[12:10], ci[6], 2'b00};
                expand_c = {uimm12[11:5], rs2_p, rs1_p, 3'h2, uimm12[4:0], 7'h23};
            end
            default: expand_c = 32'h0; // FP/reserved
            endcase
        end

        2'b01: begin // -------------------------------------------------------
            // Quadrant 1
            rd_rs1 = ci[11:7];
            case (funct3)
            3'h0: begin // C.NOP / C.ADDI → ADDI rd, rd, nzimm
                nzimm = c_sext6({ci[12], ci[6:2]});
                expand_c = {nzimm[11:0], rd_rs1, 3'h0, rd_rs1, 7'h13};
            end
            3'h1: begin // C.JAL (RV32) → JAL x1, offset
                expand_c = encode_jal(5'd1, c_j_offset(ci));
            end
            3'h2: begin // C.LI → ADDI rd, x0, imm  (rd=0 → HINT, expand anyway)
                imm = c_sext6({ci[12], ci[6:2]});
                expand_c = {imm[11:0], 5'd0, 3'h0, rd_rs1, 7'h13};
            end
            3'h3: begin
                if (rd_rs1 == 5'd2) begin // C.ADDI16SP → ADDI x2, x2, nzimm
                    nzimm = c_sext10({ci[12], ci[4:3], ci[5], ci[2], ci[6], 4'b0000});
                    if (nzimm == 32'h0) expand_c = 32'h0; // illegal
                    else expand_c = {nzimm[11:0], 5'd2, 3'h0, 5'd2, 7'h13};
                end else begin // C.LUI → LUI rd, nzimm[17:12]  (rd=0 → HINT)
                    // C.LUI nzimm is a 6-bit signed value in ci[12]:ci[6:2].
                    // LUI puts this 6-bit field into the upper bits [17:12] of
                    // the register, sign-extended to 32 bits.  The LUI encoding
                    // stores the 20-bit immediate as nzimm[19:0] (bits [17:12]
                    // of the address, plus sign extension in [19:18]).
                    nzimm = c_sext6({ci[12], ci[6:2]});
                    if (nzimm == 32'h0) expand_c = 32'h0; // illegal
                    else expand_c = {nzimm[19:0], rd_rs1, 7'h37};
                end
            end
            3'h4: begin // Arithmetic
                funct2 = ci[11:10];
                rd_p   = {2'b01, ci[9:7]}; // override for Q1 arith
                rs2_p  = {2'b01, ci[4:2]};
                case (funct2)
                2'h0: begin // C.SRLI → SRLI rd', rd', shamt
                    uimm12 = {6'b0, ci[12], ci[6:2]};  // shamt in bits[4:0]
                    expand_c = {7'h00, uimm12[4:0], rd_p, 3'h5, rd_p, 7'h13};
                end
                2'h1: begin // C.SRAI → SRAI rd', rd', shamt
                    uimm12 = {6'b0, ci[12], ci[6:2]};
                    expand_c = {7'h20, uimm12[4:0], rd_p, 3'h5, rd_p, 7'h13};
                end
                2'h2: begin // C.ANDI → ANDI rd', rd', imm
                    imm = c_sext6({ci[12], ci[6:2]});
                    expand_c = {imm[11:0], rd_p, 3'h7, rd_p, 7'h13};
                end
                2'h3: begin
                    f1     = ci[12];
                    f2_low = ci[6:5];
                    if (f1 == 1'b0) begin
                        case (f2_low)
                        2'h0: expand_c = {7'h20, rs2_p, rd_p, 3'h0, rd_p, 7'h33}; // C.SUB
                        2'h1: expand_c = {7'h00, rs2_p, rd_p, 3'h4, rd_p, 7'h33}; // C.XOR
                        2'h2: expand_c = {7'h00, rs2_p, rd_p, 3'h6, rd_p, 7'h33}; // C.OR
                        2'h3: expand_c = {7'h00, rs2_p, rd_p, 3'h7, rd_p, 7'h33}; // C.AND
                        endcase
                    end
                    // f1=1: RV64-only (C.ADDW/C.SUBW) → illegal on RV32
                end
                endcase
            end
            3'h5: begin // C.J → JAL x0, offset
                expand_c = encode_jal(5'd0, c_j_offset(ci));
            end
            3'h6: begin // C.BEQZ → BEQ rs1', x0, offset
                expand_c = encode_branch(3'h0, {2'b01, ci[9:7]}, 5'd0, c_b_offset(ci));
            end
            3'h7: begin // C.BNEZ → BNE rs1', x0, offset
                expand_c = encode_branch(3'h1, {2'b01, ci[9:7]}, 5'd0, c_b_offset(ci));
            end
            endcase
        end

        2'b10: begin // -------------------------------------------------------
            // Quadrant 2
            rd_rs1 = ci[11:7];
            rs2    = ci[6:2];
            case (funct3)
            3'h0: begin // C.SLLI → SLLI rd, rd, shamt  (rd=0 or shamt=0 → HINT)
                uimm12 = {6'b0, ci[12], ci[6:2]};
                expand_c = {7'h00, uimm12[4:0], rd_rs1, 3'h1, rd_rs1, 7'h13};
            end
            3'h2: begin // C.LWSP → LW rd, offset(x2)
                if (rd_rs1 == 5'd0) expand_c = 32'h0; // illegal
                else begin
                    uimm12 = {4'b0, ci[3:2], ci[12], ci[6:4], 2'b00};
                    expand_c = {uimm12, 5'd2, 3'h2, rd_rs1, 7'h03};
                end
            end
            3'h4: begin
                f1 = ci[12];
                if (f1 == 1'b0) begin
                    if (rs2 == 5'd0) begin // C.JR → JALR x0, rs1, 0
                        if (rd_rs1 == 5'd0) expand_c = 32'h0; // illegal
                        else expand_c = {12'h0, rd_rs1, 3'h0, 5'd0, 7'h67};
                    end else begin // C.MV → ADD rd, x0, rs2
                        expand_c = {7'h00, rs2, 5'd0, 3'h0, rd_rs1, 7'h33};
                    end
                end else begin
                    if (rd_rs1 == 5'd0 && rs2 == 5'd0) begin // C.EBREAK
                        expand_c = 32'h00100073;
                    end else if (rs2 == 5'd0) begin // C.JALR → JALR x1, rs1, 0
                        expand_c = {12'h0, rd_rs1, 3'h0, 5'd1, 7'h67};
                    end else begin // C.ADD → ADD rd, rd, rs2
                        expand_c = {7'h00, rs2, rd_rs1, 3'h0, rd_rs1, 7'h33};
                    end
                end
            end
            3'h6: begin // C.SWSP → SW rs2, offset(x2)
                uimm12 = {4'b0, ci[8:7], ci[12:9], 2'b00};
                expand_c = {uimm12[11:5], rs2, 5'd2, 3'h2, uimm12[4:0], 7'h23};
            end
            default: expand_c = 32'h0; // FP/reserved
            endcase
        end

        default: expand_c = 32'h0; // quad=11: caller must not pass 32-bit instructions
        endcase
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */
    /* verilator lint_on WIDTHEXPAND */

    // =========================================================================
    // Combinational decode of the current memory word
    // =========================================================================
    // Which halfword to examine depends on state:
    //   IDLE   + !init_offset → look at data[15:0]
    //   IDLE   + init_offset  → look at data[31:16]
    //   HAVE_UPPER            → look at hold[15:0]
    //
    // A "pending word" buffer (pend_valid/pend_data/pend_pc) is used to decouple
    // the icache handshake from the hold-register FSM.  When case_a is active and
    // the icache delivers a fresh word simultaneously, we accept it (to free the
    // icache from S_RESP) and park it in the pending buffer.  The next cycle the
    // pending buffer is treated as a virtual memory response.

    // The effective memory response: either the pending buffer or the icache.
    logic        eff_resp_valid;
    logic [31:0] eff_resp_data;
    logic [31:0] eff_resp_pc;

    always_comb begin
        if (pend_valid) begin
            eff_resp_valid = 1'b1;
            eff_resp_data  = pend_data;
            eff_resp_pc    = pend_pc;
        end else begin
            eff_resp_valid = imem_resp_valid;
            eff_resp_data  = imem_resp_data;
            eff_resp_pc    = ib_resp_pc;
        end
    end

    logic [15:0] cur_hw;        // current halfword under examination
    logic [31:0] cur_hw_pc;     // PC of that halfword

    always_comb begin
        if (hold_valid) begin
            cur_hw     = hold;
            cur_hw_pc  = hold_pc;
        end else if (init_offset) begin
            cur_hw     = eff_resp_data[31:16];
            cur_hw_pc  = eff_resp_pc + 32'd2;
        end else begin
            cur_hw     = eff_resp_data[15:0];
            cur_hw_pc  = eff_resp_pc;
        end
    end

    logic cur_is_compressed;
    assign cur_is_compressed = (cur_hw[1:0] != 2'b11);

    // =========================================================================
    // Combinational output multiplexer
    // =========================================================================
    // Determines what instruction (if any) is being presented this cycle.
    //
    // Four cases:
    //   A. HAVE_UPPER + compressed: instruction = expand(hold), no mem needed
    //   B. IDLE + compressed at current offset: instruction = expand(lower hw),
    //        needs mem response; after advance, saves upper hw to hold
    //   C. IDLE + 32-bit aligned (both halves in same word): instruction = word,
    //        needs mem response
    //   D. HAVE_UPPER + 32-bit spanning (lower half in hold, upper in next
    //        mem word): instruction = {data[15:0], hold}, needs mem response

    // Case A: we have a complete compressed instruction in hold
    logic case_a;
    assign case_a = hold_valid && (hold[1:0] != 2'b11);

    // Case D: hold has the lower half of a spanning 32-bit instruction
    logic case_d;
    assign case_d = hold_valid && (hold[1:0] == 2'b11);

    // Cases B/C: IDLE state, need memory (from icache or pending buffer)
    logic case_bc;
    assign case_bc = !hold_valid && eff_resp_valid && !ib_resp_discard && !flush;

    // Case B specifically: compressed at the active offset
    logic case_b;
    assign case_b = case_bc && cur_is_compressed;

    // Case C: full 32-bit instruction in the current word (not init_offset;
    // init_offset with 32-bit lower half is handled as "load hold", no output)
    logic case_c;
    assign case_c = case_bc && !cur_is_compressed && !init_offset;

    // init_offset load: IDLE + init_offset + 32-bit lower half → no output,
    // must consume word to load hold
    logic case_load_hold;
    assign case_load_hold = case_bc && !cur_is_compressed && init_offset;

    // =========================================================================
    // Output assignments
    // =========================================================================
    // mem_ready rules:
    //   - Only touches the REAL icache response (imem_resp_valid/imem_resp_ready).
    //   - When pend_valid is set, the icache word was ALREADY consumed; no new
    //     icache handshake is needed this cycle.
    //   - case_a: icache word (if present) is absorbed into pend buffer; accept it.
    always_comb begin
        instr_valid     = 1'b0;
        instr_data      = 32'h00000013; // NOP
        orig_instr      = 32'h00000013; // NOP
        instr_pc        = 32'h0;
        is_compressed   = 1'b0;
        mem_ready       = 1'b0;

        if (flush) begin
            // Flush: drain icache and pending buffer; hold will be cleared
            mem_ready   = imem_resp_valid;
            instr_valid = 1'b0;
        end else if (case_a) begin
            // Hold contains a complete compressed instruction.
            // If the icache delivers the next word simultaneously, accept it into
            // the pending buffer so the icache S_RESP state can advance.
            instr_valid   = 1'b1;
            instr_data    = expand_c(hold);
            orig_instr    = {16'h0, hold};  // original 16-bit encoding, zero-extended
            instr_pc      = hold_pc;
            is_compressed = 1'b1;
            // Accept the icache response (if any) so it can park in pend buffer.
            // pend_valid words are already in the buffer — never re-accept them.
            mem_ready     = (!pend_valid && imem_resp_valid) ? consume_en : 1'b0;
        end else if (case_d) begin
            // Hold has lower half of spanning 32-bit; need upper from eff_resp
            if (eff_resp_valid && !ib_resp_discard) begin
                instr_valid   = 1'b1;
                instr_data    = {eff_resp_data[15:0], hold[15:0]};
                orig_instr    = {eff_resp_data[15:0], hold[15:0]};  // always 32-bit
                instr_pc      = hold_pc;
                is_compressed = 1'b0;
                // Consume from pend or icache
                mem_ready     = pend_valid ? 1'b0 : consume_en;
            end else if (eff_resp_valid && ib_resp_discard) begin
                // Stale response after flush (e.g. post-WFI): consume and discard
                mem_ready = pend_valid ? 1'b0 : 1'b1;
            end
        end else if (case_b) begin
            // Compressed instruction at current offset
            instr_valid   = 1'b1;
            instr_data    = expand_c(cur_hw);
            orig_instr    = {16'h0, cur_hw};  // original 16-bit encoding, zero-extended
            instr_pc      = cur_hw_pc;
            is_compressed = 1'b1;
            mem_ready     = pend_valid ? 1'b0 : consume_en;
        end else if (case_c) begin
            // Full 32-bit instruction in current word (aligned, !init_offset)
            instr_valid   = 1'b1;
            instr_data    = eff_resp_data;
            orig_instr    = eff_resp_data;  // unchanged
            instr_pc      = eff_resp_pc;
            is_compressed = 1'b0;
            mem_ready     = pend_valid ? 1'b0 : consume_en;
        end else if (case_load_hold) begin
            // init_offset + 32-bit lower half: consume to load hold, no output
            instr_valid   = 1'b0;
            mem_ready     = pend_valid ? 1'b0 : consume_en;
        end else begin
            // IDLE, no valid response (or discarding)
            if (imem_resp_valid && ib_resp_discard) begin
                // Discard: consume but don't present
                mem_ready = 1'b1;
            end
        end
    end

    // =========================================================================
    // Sequential state update
    // =========================================================================
    // "consume" for the effective response means: either pend is consumed (if
    // pend_valid) or the icache word is consumed (mem_ready && consume_en).
    // Helper: eff_consumed — the eff_resp was accepted by the pipeline this cycle.
    logic eff_consumed;
    assign eff_consumed = eff_resp_valid &&
                          (pend_valid ? consume_en
                                      : (mem_ready && consume_en));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hold_valid  <= 1'b0;
            hold        <= 16'h0;
            hold_pc     <= 32'h0;
            init_offset <= 1'b0;
            pend_valid  <= 1'b0;
            pend_data   <= 32'h0;
            pend_pc     <= 32'h0;
        end else if (flush) begin
            // On flush: clear all buffered state; set init_offset from target PC[1]
            hold_valid  <= 1'b0;
            init_offset <= flush_pc[1];
            pend_valid  <= 1'b0;
        end else begin
            // ---------------------------------------------------------------
            // Pending buffer management
            // ---------------------------------------------------------------
            // Load pend: case_a is active, consume_en allows presenting hold,
            // and a fresh icache word has arrived (not already in pend).
            if (case_a && consume_en && imem_resp_valid && !pend_valid) begin
                pend_valid <= 1'b1;
                pend_data  <= imem_resp_data;
                pend_pc    <= ib_resp_pc;
            end
            // Drain pend: eff_consumed with pend active
            else if (pend_valid && eff_consumed) begin
                pend_valid <= 1'b0;
            end

            // ---------------------------------------------------------------
            // Case A: compressed instruction from hold consumed by pipeline
            // ---------------------------------------------------------------
            if (case_a && consume_en) begin
                hold_valid <= 1'b0;
            end

            // ---------------------------------------------------------------
            // Case D: spanning 32-bit instruction consumed
            // ---------------------------------------------------------------
            if (case_d && eff_resp_valid && eff_consumed) begin
                if (ib_resp_discard) begin
                    // Stale response: discard upper half, clear hold entirely
                    hold_valid <= 1'b0;
                end else begin
                    // eff_resp_data[31:16] is the next halfword to inspect.
                    // Always save it to hold — whether compressed or 32-bit lower half.
                    hold       <= eff_resp_data[31:16];
                    hold_pc    <= hold_pc + 32'd4; // spanning instr was 32-bit
                    hold_valid <= 1'b1;
                end
            end

            // ---------------------------------------------------------------
            // Case B: compressed at lower halfword consumed
            // ---------------------------------------------------------------
            if (case_b && eff_consumed) begin
                if (init_offset) begin
                    // We consumed eff_resp_data[31:16] — the upper halfword.
                    // The lower halfword ([15:0]) belongs to a different (earlier)
                    // instruction that was skipped.  Nothing left in this word
                    // to buffer; wait for the next fetch.
                    hold_valid  <= 1'b0;
                    init_offset <= 1'b0;
                end else begin
                    // We consumed eff_resp_data[15:0] — save the upper halfword.
                    hold       <= eff_resp_data[31:16];
                    hold_pc    <= cur_hw_pc + 32'd2;
                    hold_valid <= 1'b1;
                    init_offset <= 1'b0;
                end
            end

            // ---------------------------------------------------------------
            // Case C: full 32-bit instruction consumed
            // ---------------------------------------------------------------
            if (case_c && eff_consumed) begin
                hold_valid  <= 1'b0;
                init_offset <= 1'b0;
            end

            // ---------------------------------------------------------------
            // Case load_hold: init_offset + 32-bit lower half
            // ---------------------------------------------------------------
            if (case_load_hold && eff_consumed) begin
                hold       <= eff_resp_data[31:16];
                hold_pc    <= eff_resp_pc + 32'd2;
                hold_valid <= 1'b1;
                init_offset <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire

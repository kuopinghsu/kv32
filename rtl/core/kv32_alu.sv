// ============================================================================
// File: kv32_alu.sv
// Project: KV32 RISC-V Processor
// Description: RISC-V 32-bit Arithmetic Logic Unit
//
// Performs arithmetic and logical operations for the processor core.
// Supports all RV32I base instructions plus M extension (multiply/divide).
//
// Operations:
//   - Arithmetic: ADD, SUB, MUL, MULH, DIV, REM
//   - Logical: AND, OR, XOR
//   - Shift: SLL, SRL, SRA
//   - Comparison: SLT, SLTU
//
// Features:
//   - Multiply: configurable via FAST_MUL parameter
//     - FAST_MUL=1: combinatorial (single cycle, larger area)
//     - FAST_MUL=0: serial shift-and-add, (32 - CLZ(|multiplier|)) cycles
//   - Divide: configurable via FAST_DIV parameter
//     - FAST_DIV=1: combinatorial (single cycle, larger area)
//     - FAST_DIV=0: serial left-shift restoring divider, variable latency:
//                   (32 - CLZ(|dividend|)) cycles, 0 for divide-by-zero /
//                   signed overflow, minimum 1 cycle for small dividends.
//   - Signed and unsigned variants
// ============================================================================

`ifdef SYNTHESIS
import kv32_pkg::*;
`endif

module kv32_alu #(
    parameter FAST_MUL = 1, // 1=combinatorial multiply, 0=serial multiplier
    parameter FAST_DIV = 1  // 1=combinatorial divide, 0=serial divider
)(
    input  logic        clk,
    input  logic        rst_n,
`ifndef SYNTHESIS
    input  alu_op_e     alu_op,
`else
    input  logic [4:0]  alu_op,    // alu_op_e (synthesis: logic [4:0])
`endif
    input  logic [31:0] operand_a,
    input  logic [31:0] operand_b,
    output logic [31:0] result,
    output logic        ready
);
`ifndef SYNTHESIS
    import kv32_pkg::*;
`endif

    // ========================================================================
    // Multiplication Logic (configurable)
    // ========================================================================
    logic [31:0] result_mul_lo;     // MUL  (lower 32 bits of product)
    logic [31:0] result_mulh_hi;    // MULH (upper 32 bits, signed x signed)
    logic [31:0] result_mulhsu_hi;  // MULHSU (upper 32, signed x unsigned)
    logic [31:0] result_mulhu_hi;   // MULHU (upper 32, unsigned x unsigned)
    logic        mul_ready;

    generate
        if (FAST_MUL == 1) begin : gen_fast_mul
            // Combinatorial multiply (single cycle, larger area)
            logic [63:0] result_mul;
            logic [63:0] result_mulu;
            logic [63:0] result_mulsu;

            assign result_mul   = $signed  ({{32{operand_a[31]}}, operand_a}) *
                                  $signed  ({{32{operand_b[31]}}, operand_b});
            assign result_mulu  = $unsigned({{32{1'b0}},          operand_a}) *
                                  $unsigned({{32{1'b0}},          operand_b});
            assign result_mulsu = $signed  ({{32{operand_a[31]}}, operand_a}) *
                                  $unsigned({{32{1'b0}},          operand_b});

            assign result_mul_lo    = result_mul[31:0];
            assign result_mulh_hi   = result_mul[63:32];
            assign result_mulhsu_hi = result_mulsu[63:32];
            assign result_mulhu_hi  = result_mulu[63:32];
            assign mul_ready = 1'b1;

            // Lower 32 bits of unsigned/mixed products are not read;
            // only the upper half is needed for MULH/MULHSU/MULHU.
            logic _unused_mul;
            assign _unused_mul = &{1'b0, result_mulu[31:0], result_mulsu[31:0]};

        end else begin : gen_serial_mul
            // Serial shift-and-add multiplier with CLZ-based early termination.
            //
            // Key properties:
            //   - Works with the MAGNITUDE of both operands; sign fix-up is
            //     applied at the last iteration (MULH/MULHSU only).
            //   - MUL (lower 32 bits) is identical for signed/unsigned so A and
            //     B are always treated as unsigned for MUL.
            //   - Uses CLZ(|B|) to skip leading zero bits of |B|.
            //   - Latency: (32 - CLZ(|B|)) cycles.
            //       B = 0          -> 0 iterations (instant-complete)
            //       B = 1          -> 1 iteration
            //       B = 0xFFFFFFFF -> 32 iterations

            // ---- state registers ----------------------------------------
            logic [5:0]  mul_count;    // current iteration index (0-based)
            logic [5:0]  mul_total;    // total iterations = 32 - CLZ(|B|)
            logic [63:0] mul_a_shift;  // |A| left-shifted each cycle
            logic [31:0] mul_b_reg;    // |B| right-shifted each cycle
            logic [63:0] mul_acc;      // running partial-product sum
            logic        mul_valid;    // pulses for one cycle when done
            logic        mul_active;   // high during iterative computation
            logic        mul_neg;      // final product needs negation
            logic [63:0] mul_result;   // latched 64-bit product (sign-corrected)

            // ---- combinatorial helpers ----------------------------------
            logic        is_mul_op;
            logic        is_signed_a_mul, is_signed_b_mul;
            // MUL:    lower 32 bits identical for signed/unsigned -> unsigned
            // MULH:   signed(A) x signed(B)
            // MULHSU: signed(A) x unsigned(B)
            // MULHU:  unsigned(A) x unsigned(B)
            assign is_mul_op       = (alu_op == ALU_MUL   || alu_op == ALU_MULH  ||
                                      alu_op == ALU_MULHSU || alu_op == ALU_MULHU);
            assign is_signed_a_mul = (alu_op == ALU_MULH || alu_op == ALU_MULHSU);
            assign is_signed_b_mul = (alu_op == ALU_MULH);

            logic [31:0] abs_a_mul, abs_b_mul;
            assign abs_a_mul = (is_signed_a_mul && operand_a[31]) ? (~operand_a + 1) : operand_a;
            assign abs_b_mul = (is_signed_b_mul && operand_b[31]) ? (~operand_b + 1) : operand_b;

            // CLZ of |B| -- returns 32 when |B| == 0.
            // Iterate LOW->HIGH so the highest set bit wins (last assignment).
            logic [5:0] clz_b_mul;
            always_comb begin
                clz_b_mul = 6'd32;
                for (int i = 0; i <= 31; i++)
                    if (abs_b_mul[i]) clz_b_mul = 6'(31 - i);
            end

            // One combinatorial iteration step (reads current FF values)
            logic [63:0] mul_next_acc;
            logic [63:0] mul_next_a_shift;
            logic [31:0] mul_next_b_reg;
            assign mul_next_acc     = mul_b_reg[0] ? (mul_acc + mul_a_shift) : mul_acc;
            assign mul_next_a_shift = mul_a_shift << 1;
            assign mul_next_b_reg   = mul_b_reg >> 1;

            // ---- sequential state machine --------------------------------
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    mul_count   <= 6'd0;
                    mul_total   <= 6'd0;
                    mul_a_shift <= 64'd0;
                    mul_b_reg   <= 32'd0;
                    mul_acc     <= 64'd0;
                    mul_valid   <= 1'b0;
                    mul_active  <= 1'b0;
                    mul_neg     <= 1'b0;
                    mul_result  <= 64'd0;
                end else begin
                    mul_valid <= 1'b0;  // default: pulse for one cycle only

                    if (is_mul_op && !mul_active && !mul_valid && clz_b_mul != 6'd32) begin
                        // ---- START cycle (B != 0) --------------------------------
                        // B==0: instant-complete; result=0 from combinatorial mux;
                        //       no SM invocation needed.
                        mul_total   <= 6'd32 - clz_b_mul;
                        mul_count   <= 6'd0;
                        mul_a_shift <= {32'd0, abs_a_mul};
                        mul_b_reg   <= abs_b_mul;
                        mul_acc     <= 64'd0;
                        mul_neg     <= (is_signed_a_mul && operand_a[31]) ^
                                       (is_signed_b_mul && operand_b[31]);
                        mul_active  <= 1'b1;
                    end else if (mul_active) begin
                        // ---- ITERATION step -----------------------------
                        if (mul_count + 1 >= mul_total) begin
                            // Last iteration -- apply sign fixup and latch.
                            mul_result <= mul_neg ? (~mul_next_acc + 1) : mul_next_acc;
                            mul_valid  <= 1'b1;
                            mul_active <= 1'b0;
                        end else begin
                            mul_acc     <= mul_next_acc;
                            mul_a_shift <= mul_next_a_shift;
                            mul_b_reg   <= mul_next_b_reg;
                            mul_count   <= mul_count + 1;
                        end
                    end
                end
            end

            `ifdef DEBUG
            always_ff @(posedge clk) begin
                if (rst_n) begin
                    if (is_mul_op && !mul_active && !mul_valid && clz_b_mul != 6'd32) begin
                        `DEBUG2(`DBG_GRP_ALU, ("[MUL_START] alu_op=%0d a=%h b=%h abs_a=%h abs_b=%h clz_b=%0d total=%0d neg=%b",
                                 alu_op, operand_a, operand_b,
                                 abs_a_mul, abs_b_mul, clz_b_mul, 6'd32 - clz_b_mul,
                                 (is_signed_a_mul && operand_a[31]) ^ (is_signed_b_mul && operand_b[31])));
                    end
                    if (mul_valid) begin
                        `DEBUG2(`DBG_GRP_ALU, ("[MUL_DONE] mul_result=%h alu_op=%0d",
                                 mul_result, alu_op));
                    end
                end
            end
            `endif // DEBUG

            // ---- result signals -----------------------------------------
            // Use the latched SM result only while the SM is active or has
            // just completed (mul_valid).  When B==0 (no SM invoked), return
            // 0 combinatorially -- mirroring how the divider handles div-by-
            // zero results without going through the iterative engine.
            logic use_mul_result;
            assign use_mul_result   = mul_active || mul_valid;
            assign result_mul_lo    = use_mul_result ? mul_result[31:0]  : 32'd0;
            assign result_mulh_hi   = use_mul_result ? mul_result[63:32] : 32'd0;
            assign result_mulhsu_hi = use_mul_result ? mul_result[63:32] : 32'd0;
            assign result_mulhu_hi  = use_mul_result ? mul_result[63:32] : 32'd0;

            // ---- ready signal -------------------------------------------
            // While mul_active is set, live clz_b_mul can change (forwarding
            // expiry makes operand_b drift to 0) and would falsely signal
            // B==0 releasing the stall.  Guard with !mul_active.
            assign mul_ready = !is_mul_op ||
                               (!mul_active && (clz_b_mul == 6'd32 || mul_valid));

        end
    endgenerate

    // ========================================================================
    // Division and Remainder Logic (configurable)
    // ========================================================================
    logic [31:0] result_div;
    logic [31:0] result_divu;
    logic [31:0] result_rem;
    logic [31:0] result_remu;
    logic        div_ready;

    generate
        if (FAST_DIV == 1) begin : gen_fast_div
            // Combinatorial divide (single cycle, larger area)
            // Handles divide by zero and signed overflow per RISC-V spec
            assign result_div  = (operand_b == 32'h0) ? 32'hffffffff :
                                 ((operand_a == 32'h80000000) && (operand_b == 32'hffffffff)) ?
                                 32'h80000000 :
                                 $signed($signed(operand_a) / $signed(operand_b));
            assign result_divu = (operand_b == 32'h0) ? 32'hffffffff :
                                 $unsigned($unsigned(operand_a) / $unsigned(operand_b));
            assign result_rem  = (operand_b == 32'h0) ? operand_a :
                                 ((operand_a == 32'h80000000) && (operand_b == 32'hffffffff)) ?
                                 32'h0 :
                                 $signed($signed(operand_a) % $signed(operand_b));
            assign result_remu = (operand_b == 32'h0) ? operand_a :
                                 $unsigned($unsigned(operand_a) % $unsigned(operand_b));
            assign div_ready = 1'b1;

        end else begin : gen_serial_div
            // Serial left-shift restoring divider with early termination.
            //
            // Key properties:
            //   - Works with the MAGNITUDE of both operands (sign fix-up is
            //     applied combinatorially at the result mux below).
            //   - Pre-normalises the dividend by shifting it left by CLZ(|A|)
            //     so that the MSB is always at bit 31 going into the loop.
            //   - This means only (32 - CLZ(|A|)) iterations are needed:
            //       A = 0          → 0 iterations (instant-complete)
            //       A = 1          → 1 iteration
            //       A = 0x7FFFFFFF → 31 iterations
            //       A = 0x80000000 → 32 iterations (signed overflow case)
            //   - Divide-by-zero and signed overflow are detected combinatorially
            //     and bypass the iterative path entirely (0 stall cycles).
            //
            // Latency: (32 - CLZ(|A|)) cycles for normal division.

            // ---- state registers ----------------------------------------
            logic [5:0]  div_count;   // current iteration index (0-based)
            logic [5:0]  div_total;   // total iterations = 32 - CLZ(|A|)
            logic [31:0] div_q;       // dividend → becomes quotient
            logic [31:0] div_r;       // partial remainder → becomes remainder
            logic [31:0] div_abs_b;   // latched |divisor|
            logic        div_valid;   // high from completion until pipeline advances
            logic        div_active;  // high during iterative computation
            logic        div_neg_q;   // quotient needs sign flip (signed div)
            logic        div_neg_r;   // remainder needs sign flip (signed rem)
            // Latched snapshots of edge-case flags and dividend for the result
            // mux. The live operand_a/b signals can change via forwarding while
            // the div instruction is stalled in EX; we must use the values that
            // were present when the instruction first entered EX.
            logic        div_by_zero_lat;
            logic        div_signed_ovf_lat;
            logic [31:0] div_operand_a_lat; // for REM/REMU(x,0) = x
            // Final latched quotient/remainder (after sign fixup).  These are
            // written on the last iteration step and held until the instruction
            // advances out of EX, so the result mux always reads stable values.
            logic [31:0] div_result_q;    // holds quot_signed at completion
            logic [31:0] div_result_r;    // holds rem_signed  at completion

            // ---- combinatorial helpers for the START cycle ---------------
            // These read alu_op / operand_* which are stable while EX stalls.
            logic        is_div_op;
            logic        is_signed_div;
            assign is_div_op     = (alu_op == ALU_DIV  || alu_op == ALU_DIVU ||
                                    alu_op == ALU_REM  || alu_op == ALU_REMU);
            assign is_signed_div = (alu_op == ALU_DIV  || alu_op == ALU_REM);

            // Magnitude of dividend and divisor
            logic [31:0] abs_a, abs_b;
            assign abs_a = (is_signed_div && operand_a[31]) ? (~operand_a + 1) : operand_a;
            assign abs_b = (is_signed_div && operand_b[31]) ? (~operand_b + 1) : operand_b;

            // Count leading zeros of |dividend| — determines iteration count.
            // Returns 32 when abs_a == 0.
            // Iterate LOW→HIGH so the highest set bit wins (last assignment).
            logic [5:0] clz_a;
            always_comb begin
                clz_a = 6'd32;
                for (int i = 0; i <= 31; i++)
                    if (abs_a[i]) clz_a = 6'(31 - i);
            end

            // Special cases that bypass the iterative path
            logic div_by_zero, signed_ovf;
            assign div_by_zero  = (operand_b == 32'h0);
            assign signed_ovf   = (operand_a == 32'h80000000) &&
                                  (operand_b == 32'hffffffff);

            // One iteration step (combinatorial read from current FF state)
            // r_trial = {div_r[30:0], div_q[31]}  — shift partial remainder
            //           left and bring in next dividend bit from div_q MSB.
            logic [32:0] r_trial;
            logic        q_bit;       // quotient bit produced this iteration
            logic [31:0] next_q, next_r; // next-cycle quotient/remainder
            assign r_trial = {div_r[31:0], div_q[31]};
            assign q_bit   = (r_trial >= {1'b0, div_abs_b});
            assign next_q  = {div_q[30:0], q_bit ? 1'b1 : 1'b0};
            assign next_r  = q_bit ? r_trial[31:0] - div_abs_b : r_trial[31:0];

            // ---- sequential state machine --------------------------------
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    div_count           <= 6'd0;
                    div_total           <= 6'd0;
                    div_q               <= 32'd0;
                    div_r               <= 32'd0;
                    div_abs_b           <= 32'd0;
                    div_valid           <= 1'b0;
                    div_active          <= 1'b0;
                    div_neg_q           <= 1'b0;
                    div_neg_r           <= 1'b0;
                    div_by_zero_lat     <= 1'b0;
                    div_signed_ovf_lat  <= 1'b0;
                    div_operand_a_lat   <= 32'd0;
                    div_result_q        <= 32'd0;
                    div_result_r        <= 32'd0;
                end else begin
                    div_valid <= 1'b0;   // default: pulse for one cycle only

                    if (is_div_op && !div_active && !div_valid) begin
                        // ---- START cycle --------------------------------
                        // div_by_zero / signed_ovf bypass: div_ready is already
                        // 1 this cycle (combinatorial), so the pipeline does NOT
                        // stall and we don't need to start the algorithm.
                        if (!div_by_zero && !signed_ovf) begin
                            div_total <= 6'd32 - clz_a;    // 0..32
                            div_count           <= 6'd0;
                            // Pre-normalise: shift |A| so its MSB is at bit 31.
                            // With total iterations this will produce the correct
                            // quotient in div_q[total-1:0] (i.e. div_q directly).
                            div_q               <= abs_a << clz_a;
                            div_r               <= 32'd0;
                            div_abs_b           <= abs_b;
                            div_neg_q           <= is_signed_div && (operand_a[31] ^ operand_b[31]);
                            div_neg_r           <= is_signed_div && operand_a[31];
                            // Latch snapshot: operand_a/b can change via
                            // forwarding while EX stalls during iteration.
                            div_by_zero_lat     <= div_by_zero;
                            div_signed_ovf_lat  <= signed_ovf;
                            div_operand_a_lat   <= operand_a;
                            if (clz_a == 6'd32) begin
                                // Dividend is 0 → result is trivially 0. Done.
                                div_result_q <= 32'd0;
                                div_result_r <= 32'd0;
                                div_valid    <= 1'b1;
                            end else begin
                                div_active <= 1'b1;
                            end
                        end

                    end else if (div_active) begin
                        // ---- ITERATION step -----------------------------
                        div_q  <= next_q;
                        div_r  <= next_r;

                        if (div_count + 1 >= div_total) begin
                            // Last iteration — latch signed result and signal done.
                            div_result_q <= div_neg_q ? (~next_q + 1) : next_q;
                            div_result_r <= div_neg_r ? (~next_r + 1) : next_r;
                            div_valid    <= 1'b1;
                            div_active   <= 1'b0;
                        end else begin
                            div_count    <= div_count + 1;
                        end
                    end
                end
            end

            `ifdef DEBUG
            // Trace divider startup and completion to aid debugging.
            always_ff @(posedge clk) begin
                if (rst_n) begin
                    if (is_div_op && !div_active && !div_valid &&
                        !div_by_zero && !signed_ovf) begin
                        `DEBUG2(`DBG_GRP_ALU, ("[DIV_START] alu_op=%0d a=%h b=%h abs_a=%h abs_b=%h clz=%0d total=%0d q_init=%h neg_q=%b neg_r=%b",
                                 alu_op, operand_a, operand_b,
                                 abs_a, abs_b, clz_a, 6'd32 - clz_a,
                                 abs_a << clz_a,
                                 is_signed_div && (operand_a[31] ^ operand_b[31]),
                                 is_signed_div && operand_a[31]));
                    end
                    if (div_valid) begin
                        `DEBUG2(`DBG_GRP_ALU, ("[DIV_DONE] div_q=%h div_r=%h div_result_q=%h div_result_r=%h neg_q=%b neg_r=%b alu_op=%0d",
                                 div_q, div_r, div_result_q, div_result_r, div_neg_q, div_neg_r, alu_op));
                    end
                end
            end
            `endif // DEBUG

            // ---- result mux (with sign fixup and spec-defined edge cases) --
            // Sign fixup is applied combinatorially so that the corrected
            // value is visible in the same cycle div_valid pulses.
            // IMPORTANT: Use the LATCHED snapshot flags whenever the iterative
            // algorithm is or was running (div_active || div_valid), because the
            // live operand_a/b wires can be overwritten by forwarding while the
            // div instruction is stalled in EX.
            logic        use_latched;
            assign use_latched = div_active || div_valid;

            logic        eff_by_zero, eff_signed_ovf;
            logic [31:0] eff_operand_a;
            assign eff_by_zero    = use_latched ? div_by_zero_lat    : div_by_zero;
            assign eff_signed_ovf = use_latched ? div_signed_ovf_lat : signed_ovf;
            assign eff_operand_a  = use_latched ? div_operand_a_lat  : operand_a;

            assign result_div  = eff_by_zero    ? 32'hffffffff :
                                 eff_signed_ovf ? 32'h80000000 : div_result_q;
            assign result_divu = eff_by_zero    ? 32'hffffffff : div_result_q;
            assign result_rem  = eff_by_zero    ? eff_operand_a :
                                 eff_signed_ovf ? 32'h0         : div_result_r;
            assign result_remu = eff_by_zero    ? eff_operand_a : div_result_r;

            // ---- ready signal --------------------------------------------
            // Ready immediately when:
            //   • No divide op is present, OR
            //   • It is a divide-by-zero / signed-overflow (result from mux,
            //     no iterative computation needed), OR
            //   • The iterative computation just finished (div_valid == 1).
            //
            // IMPORTANT: While div_active is set (mid-computation), the live
            // operand_b signal can change due to forwarding expiry (e.g., the
            // instruction that wrote rs2 retires from WB and the forwarded
            // value reverts to a stale register value).  If operand_b drifted
            // to 0 the live div_by_zero would go high and falsely release the
            // stall.  Guard against this by NEVER signalling ready while the
            // iterative engine is running (div_active == 1).
            assign div_ready = !is_div_op ||
                               (!div_active && (div_by_zero || signed_ovf || div_valid));

        end
    endgenerate

    // ========================================================================
    // Output Mux and Ready Signal
    // ========================================================================
    always_comb begin
        case (alu_op)
            ALU_ADD:    result = operand_a + operand_b;
            ALU_SUB:    result = operand_a - operand_b;
            ALU_SLL:    result = operand_a << operand_b[4:0];
            ALU_SLT:    result = ($signed(operand_a) < $signed(operand_b)) ? 32'd1 : 32'd0;
            ALU_SLTU:   result = (operand_a < operand_b) ? 32'd1 : 32'd0;
            ALU_XOR:    result = operand_a ^ operand_b;
            ALU_SRL:    result = operand_a >> operand_b[4:0];
            ALU_SRA:    result = $signed(operand_a) >>> operand_b[4:0];
            ALU_OR:     result = operand_a | operand_b;
            ALU_AND:    result = operand_a & operand_b;
            ALU_MUL:    result = result_mul_lo;
            ALU_MULH:   result = result_mulh_hi;
            ALU_MULHSU: result = result_mulhsu_hi;
            ALU_MULHU:  result = result_mulhu_hi;
            ALU_DIV:    result = result_div;
            ALU_DIVU:   result = result_divu;
            ALU_REM:    result = result_rem;
            ALU_REMU:   result = result_remu;
            default:    result = 32'd0;
        endcase
    end

    // Ready signal: all multi-cycle units must complete before advancing
    assign ready = div_ready && mul_ready;

    // Suppress unused-signal warnings: clk/rst_n are only referenced by serial
    // multiply/divide blocks; when both FAST_MUL=1 and FAST_DIV=1 those blocks
    // are optimised away, leaving these ports unused.
    logic _unused_clk;
    assign _unused_clk = &{1'b0, clk, rst_n};

endmodule


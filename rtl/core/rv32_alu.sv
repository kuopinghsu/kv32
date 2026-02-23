// ============================================================================
// File: rv32_alu.sv
// Project: RV32 RISC-V Processor
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
//   - Multiply: fully combinatorial (single cycle)
//   - Divide: configurable via FAST_DIV parameter
//     - FAST_DIV=1: combinatorial (single cycle, larger area)
//     - FAST_DIV=0: serial left-shift restoring divider, variable latency:
//                   (32 - CLZ(|dividend|)) cycles, 0 for divide-by-zero /
//                   signed overflow, minimum 1 cycle for small dividends.
//   - Signed and unsigned variants
// ============================================================================

module rv32_alu #(
    parameter FAST_DIV = 1  // 1=combinatorial divide, 0=serial divider
)(
    input  logic        clk,
    input  logic        rst_n,
    input  alu_op_e     alu_op,
    input  logic [31:0] operand_a,
    input  logic [31:0] operand_b,
    output logic [31:0] result,
    output logic        ready
);

    import rv32_pkg::*;

    // Multiply results (combinatorial)
    logic [63:0] result_mul;
    logic [63:0] result_mulu;
    logic [63:0] result_mulsu;

    assign result_mul   = $signed  ({{32{operand_a[31]}}, operand_a}) *
                          $signed  ({{32{operand_b[31]}}, operand_b});
    assign result_mulu  = $unsigned({{32{1'b0}},          operand_a}) *
                          $unsigned({{32{1'b0}},          operand_b});
    assign result_mulsu = $signed  ({{32{operand_a[31]}}, operand_a}) *
                          $unsigned({{32{1'b0}},          operand_b});

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
            assign r_trial = {div_r[30:0], div_q[31]};
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
                        `DGB2(("[DIV_START] alu_op=%0d a=%h b=%h abs_a=%h abs_b=%h clz=%0d total=%0d q_init=%h neg_q=%b neg_r=%b",
                                 alu_op, operand_a, operand_b,
                                 abs_a, abs_b, clz_a, 6'd32 - clz_a,
                                 abs_a << clz_a,
                                 is_signed_div && (operand_a[31] ^ operand_b[31]),
                                 is_signed_div && operand_a[31]));
                    end
                    if (div_valid) begin
                        `DBG2(("[DIV_DONE] div_q=%h div_r=%h div_result_q=%h div_result_r=%h neg_q=%b neg_r=%b alu_op=%0d",
                                 div_q, div_r, div_result_q, div_result_r, div_neg_q, div_neg_r, alu_op));
                    end
                end
            end
            `endif

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
            ALU_MUL:    result = result_mul[31:0];
            ALU_MULH:   result = result_mul[63:32];
            ALU_MULHSU: result = result_mulsu[63:32];
            ALU_MULHU:  result = result_mulu[63:32];
            ALU_DIV:    result = result_div;
            ALU_DIVU:   result = result_divu;
            ALU_REM:    result = result_rem;
            ALU_REMU:   result = result_remu;
            default:    result = 32'd0;
        endcase
    end

    // Ready signal: always ready except when serial divider is active
    assign ready = div_ready;

endmodule

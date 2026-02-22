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
//     - FAST_DIV=0: serial restoring divider (33 cycles, smaller area)
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
            // Serial restoring divider (33 cycles, smaller area)
            logic [4:0]  div_count;
            logic [63:0] div_quotient;
            logic [63:0] div_remainder;
            logic        div_valid;
            logic        div_active;
            logic        div_is_signed;

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    div_count     <= 5'd0;
                    div_quotient  <= 64'd0;
                    div_remainder <= 64'd0;
                    div_valid     <= 1'b0;
                    div_active    <= 1'b0;
                    div_is_signed <= 1'b0;
                end else begin
                    div_valid <= 1'b0;

                    if ((alu_op == ALU_DIV || alu_op == ALU_DIVU ||
                         alu_op == ALU_REM || alu_op == ALU_REMU) && !div_active) begin
                        div_active     <= 1'b1;
                        div_count      <= 5'd0;
                        div_quotient   <= {32'd0, operand_a};
                        div_remainder  <= 64'd0;
                        div_is_signed  <= (alu_op == ALU_DIV || alu_op == ALU_REM);
                    end else if (div_active) begin
                        if (div_count < 5'd32) begin
                            div_remainder <= {div_remainder[62:0], div_quotient[63]};
                            div_quotient  <= {div_quotient[62:0], 1'b0};

                            if (div_remainder[62:31] >= operand_b) begin
                                div_remainder[62:31] <= div_remainder[62:31] - operand_b;
                                div_quotient[0]      <= 1'b1;
                            end

                            div_count <= div_count + 1;
                        end else begin
                            div_valid  <= 1'b1;
                            div_active <= 1'b0;
                        end
                    end
                end
            end

            // Handle divide by zero and signed overflow
            logic div_by_zero;
            logic signed_overflow;
            assign div_by_zero     = (operand_b == 32'h0);
            assign signed_overflow = (operand_a == 32'h80000000) && (operand_b == 32'hffffffff);

            assign result_div  = div_by_zero ? 32'hffffffff :
                                 (signed_overflow ? 32'h80000000 : div_quotient[31:0]);
            assign result_divu = div_by_zero ? 32'hffffffff : div_quotient[31:0];
            assign result_rem  = div_by_zero ? operand_a :
                                 (signed_overflow ? 32'h0 : div_remainder[31:0]);
            assign result_remu = div_by_zero ? operand_a : div_remainder[31:0];
            assign div_ready   = div_valid || !div_active;

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

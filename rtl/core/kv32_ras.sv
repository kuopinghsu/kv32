// ============================================================================
// File: kv32_ras.sv
// Project: KV32 RISC-V Processor
// Description: Return Address Stack (RAS)
// ============================================================================

module kv32_ras #(
    parameter int unsigned RAS_DEPTH = 8
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        push_en,
    input  logic [31:0] push_data,

    input  logic        pop_en,

    output logic [31:0] top,
    output logic        valid
);
    localparam int unsigned COUNT_W = $clog2(RAS_DEPTH + 1);
    localparam int unsigned INDEX_W = (RAS_DEPTH > 1) ? $clog2(RAS_DEPTH) : 1;

    logic [31:0] stack [0:RAS_DEPTH-1];
    logic [COUNT_W-1:0] count;
    logic [INDEX_W-1:0] top_idx;

    integer i;

    assign valid = (count != '0);

    always_comb begin
        if (valid) begin
            top_idx = count[INDEX_W-1:0] - 1'b1;
            top = stack[top_idx];
        end else begin
            top_idx = '0;
            top = 32'd0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= '0;
            for (i = 0; i < RAS_DEPTH; i = i + 1) begin
                stack[i] <= 32'd0;
            end
        end else begin
            case ({push_en, pop_en})
                2'b10: begin
                    if (count < COUNT_W'(RAS_DEPTH)) begin
                        stack[count[INDEX_W-1:0]] <= push_data;
                        count <= count + 1'b1;
                    end else begin
                        stack[RAS_DEPTH-1] <= push_data;
                    end
                end
                2'b01: begin
                    if (count != '0) begin
                        count <= count - 1'b1;
                    end
                end
                2'b11: begin
                    if (count == '0) begin
                        stack[0] <= push_data;
                        count <= {{(COUNT_W-1){1'b0}}, 1'b1};
                    end else begin
                        // Pop old top while keeping depth constant by writing new top.
                        stack[count[INDEX_W-1:0] - 1'b1] <= push_data;
                    end
                end
                default: begin
                end
            endcase
        end
    end

endmodule

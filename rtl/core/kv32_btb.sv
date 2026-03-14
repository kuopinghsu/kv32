// ============================================================================
// File: kv32_btb.sv
// Project: KV32 RISC-V Processor
// Description: Direct-Mapped Branch Target Buffer (BTB)
// ============================================================================

module kv32_btb #(
    parameter int unsigned BTB_SIZE = 32
) (
    input  logic        clk,
    input  logic        rst_n,

    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] read_pc,
    output logic        hit,
    output logic [31:0] target,
    output logic        is_return,
    output logic        is_uncond,

    input  logic        update_en,
    input  logic [31:0] update_pc,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [31:0] update_target,
    input  logic        update_is_return,
    input  logic        update_is_uncond
);
    localparam int unsigned INDEX_W = $clog2(BTB_SIZE);
    // Use halfword-granularity addressing: index uses bits [INDEX_W:1] so that
    // adjacent halfword instructions (e.g., 0x100 and 0x102) map to different
    // BTB entries rather than aliasing to the same aligned-word slot.
    localparam int unsigned TAG_W   = 31 - INDEX_W;

    logic [TAG_W-1:0] tag_mem      [0:BTB_SIZE-1];
    logic [31:0]      target_mem   [0:BTB_SIZE-1];
    logic             valid_mem    [0:BTB_SIZE-1];
    logic             is_return_mem[0:BTB_SIZE-1];
    logic             is_uncond_mem[0:BTB_SIZE-1];

    logic [INDEX_W-1:0] read_idx;
    logic [TAG_W-1:0]   read_tag;
    logic [INDEX_W-1:0] update_idx;
    logic [TAG_W-1:0]   update_tag;

    integer i;

    assign read_idx   = read_pc[INDEX_W:1];
    assign read_tag   = read_pc[31:INDEX_W+1];
    assign update_idx = update_pc[INDEX_W:1];
    assign update_tag = update_pc[31:INDEX_W+1];

    always_comb begin
        hit       = valid_mem[read_idx] && (tag_mem[read_idx] == read_tag);
        target    = target_mem[read_idx];
        is_return = is_return_mem[read_idx];
        is_uncond = is_uncond_mem[read_idx];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < BTB_SIZE; i = i + 1) begin
                valid_mem[i]     <= 1'b0;
                tag_mem[i]       <= '0;
                target_mem[i]    <= 32'd0;
                is_return_mem[i] <= 1'b0;
                is_uncond_mem[i] <= 1'b0;
            end
        end else if (update_en) begin
            valid_mem[update_idx]     <= 1'b1;
            tag_mem[update_idx]       <= update_tag;
            target_mem[update_idx]    <= update_target;
            is_return_mem[update_idx] <= update_is_return;
            is_uncond_mem[update_idx] <= update_is_uncond;
        end
    end

endmodule

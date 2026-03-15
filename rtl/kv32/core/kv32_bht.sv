// ============================================================================
// File: kv32_bht.sv
// Project: KV32 RISC-V Processor
// Description: 2-bit Saturating Counter Branch History Table (BHT)
// ============================================================================

module kv32_bht #(
    parameter int unsigned BHT_SIZE = 64
) (
    input  logic        clk,
    input  logic        rst_n,

    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] read_pc,
    output logic        pred_taken,

    input  logic        update_en,
    input  logic [31:0] update_pc,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic        actual_taken
);
    localparam int unsigned INDEX_W = $clog2(BHT_SIZE);
    // Halfword-granularity index: include bit[1] so instructions at adjacent
    // halfword offsets map to different BHT counters.

    logic [1:0] ctr_mem [0:BHT_SIZE-1];
    logic [INDEX_W-1:0] read_idx;
    logic [INDEX_W-1:0] update_idx;

    integer i;

    assign read_idx   = read_pc[INDEX_W:1];
    assign update_idx = update_pc[INDEX_W:1];

    assign pred_taken = ctr_mem[read_idx][1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < BHT_SIZE; i = i + 1) begin
                ctr_mem[i] <= 2'b01;  // Weakly not-taken
            end
        end else if (update_en) begin
            if (actual_taken) begin
                if (ctr_mem[update_idx] != 2'b11) begin
                    ctr_mem[update_idx] <= ctr_mem[update_idx] + 2'b01;
                end
            end else if (ctr_mem[update_idx] != 2'b00) begin
                ctr_mem[update_idx] <= ctr_mem[update_idx] - 2'b01;
            end
        end
    end

endmodule

// ============================================================================
// File: generic_sram_1rw.sv
// Project: KV32 RISC-V Processor
// Description: Generic synthesizable single-port 1R/1W SRAM model
//
// Used by synthesis flows when no technology hard macro is selected.
// Behavior:
//   - Synchronous write on clk rising edge when ce=1 and we=1
//   - Synchronous read  on clk rising edge when ce=1 and we=0
//   - Read-during-write keeps previous rdata value (NO_CHANGE style)
// ============================================================================

module generic_sram_1rw #(
    parameter int DEPTH = 256,
    parameter int WIDTH = 32
) (
    input  logic                     clk,
    input  logic                     ce,
    input  logic                     we,
    input  logic [$clog2(DEPTH)-1:0] addr,
    input  logic [WIDTH-1:0]         wdata,
    output logic [WIDTH-1:0]         rdata
);

    logic [WIDTH-1:0] mem [0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (ce) begin
            if (we) begin
                mem[addr] <= wdata;
                rdata     <= rdata;
            end else begin
                rdata <= mem[addr];
            end
        end
    end

endmodule

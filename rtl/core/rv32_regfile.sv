// ============================================================================
// File: rv32_regfile.sv
// Project: RV32 RISC-V Processor
// Description: RISC-V 32-bit Register File
//
// Implements the 32 general-purpose registers specified by RISC-V ISA:
//   - x0 (zero): Hardwired to constant 0
//   - x1-x31: General purpose registers
//
// Features:
//   - 2 read ports for source operands (rs1, rs2)
//   - 1 write port for destination (rd)
//   - Synchronous write, asynchronous read
//   - x0 returns 0 regardless of write attempts
// ============================================================================

module rv32_regfile (
    input  logic        clk,
    input  logic        rst_n,

    // Read ports
    input  logic [4:0]  rs1_addr,
    output logic [31:0] rs1_data,
    input  logic [4:0]  rs2_addr,
    output logic [31:0] rs2_data,

    // Write port
    input  logic        we,
    input  logic [4:0]  rd_addr,
    input  logic [31:0] rd_data,

    // Debug read port (for debugger access)
    input  logic [4:0]  dbg_addr,
    output logic [31:0] dbg_data,

    // Debug write port (for debugger access)
    input  logic        dbg_we,
    input  logic [4:0]  dbg_waddr,
    input  logic [31:0] dbg_wdata
);

    logic [31:0] regs [31:1];  // x0 is hardwired to 0

    // Read ports (combinational with write forwarding)
    // If reading the same register being written, forward the write data
    assign rs1_data = (we && (rs1_addr == rd_addr) && (rd_addr != 5'd0)) ? rd_data :
                      (rs1_addr == 5'd0) ? 32'd0 : regs[rs1_addr];
    assign rs2_data = (we && (rs2_addr == rd_addr) && (rd_addr != 5'd0)) ? rd_data :
                      (rs2_addr == 5'd0) ? 32'd0 : regs[rs2_addr];

    // Debug read port (combinational)
    assign dbg_data = (dbg_addr == 5'd0) ? 32'd0 : regs[dbg_addr];

    // Write port (sequential)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 1; i < 32; i++) begin
                regs[i] <= 32'd0;
            end
        end else begin
            // Normal write from pipeline
            if (we && rd_addr != 5'd0) begin
                regs[rd_addr] <= rd_data;
            end
            // Debug write (has priority when CPU is halted)
            if (dbg_we && dbg_waddr != 5'd0) begin
                regs[dbg_waddr] <= dbg_wdata;
            end
        end
    end

endmodule

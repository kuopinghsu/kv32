// ============================================================================
// File: axi_monitor.sv
// Project: KV32 RISC-V Processor
// Description: AXI4-Lite Write-Channel Monitor for tohost Detection
//
// Passively snoops the AXI write bus to detect writes to the HTIF tohost
// address.  When a non-zero value is written to tohost the simulation is
// terminated via the sim_request_exit DPI call, exactly as before but
// without coupling the logic to the memory model.
//
// Protocol notes (AXI4-Lite, as implemented by axi_memory):
//   - AW handshake always precedes W handshake (axi_awready is deasserted
//     while a write address is already buffered in axi_memory).
//   - Therefore we simply latch the address on the AW handshake and check
//     it on the subsequent W handshake.
// ============================================================================

module axi_monitor (
    input logic        clk,
    input logic        rst_n,

    // AXI4-Lite write channel (observe only — no outputs driven)
    input logic [31:0] axi_awaddr,
    input logic        axi_awvalid,
    input logic        axi_awready,

    input logic [31:0] axi_wdata,
    input logic [3:0]  axi_wstrb,
    input logic        axi_wvalid,
    input logic        axi_wready
);

    // DPI imports
    import "DPI-C" function int  get_tohost_addr();
    import "DPI-C" function void sim_request_exit(input int exit_code);

    // -------------------------------------------------------------------------
    // Latch tohost address once after reset
    // -------------------------------------------------------------------------
    logic [31:0] tohost_addr;
    logic        tohost_addr_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tohost_addr       <= 32'h0;
            tohost_addr_valid <= 1'b0;
        end else if (!tohost_addr_valid) begin
            tohost_addr       <= get_tohost_addr();
            tohost_addr_valid <= 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Buffer the write address from the AW handshake.
    // axi_memory accepts AW only when no address is pending, so AW and W
    // handshakes are never simultaneous — the AW latch is always valid when
    // the W handshake fires.
    // -------------------------------------------------------------------------
    logic [31:0] aw_addr_buf;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_addr_buf <= 32'h0;
        end else if (axi_awvalid && axi_awready) begin
            aw_addr_buf <= axi_awaddr;
        end
    end

    // -------------------------------------------------------------------------
    // tohost detection: fires on the W handshake
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (tohost_addr_valid && tohost_addr != 32'h0 &&
            axi_wvalid && axi_wready) begin
            if ((aw_addr_buf & ~32'h3) == (tohost_addr & ~32'h3)) begin
                $display("[TOHOST] Write detected: addr=0x%08x data=0x%08x",
                         aw_addr_buf, axi_wdata);
                if (axi_wdata != 32'h0) begin
                    automatic int exit_code = (axi_wdata >> 1) & 32'h7FFFFFFF;
                    $display("\n[EXIT] tohost write: exit code = %0d\n", exit_code);
                    sim_request_exit(exit_code);
                end
            end
        end
    end

    // axi_wstrb is present on the bus but the monitor only checks the data value
    logic _unused_ok_monitor;
    assign _unused_ok_monitor = &{1'b0, axi_wstrb};

endmodule

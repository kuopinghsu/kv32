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
// Protocol notes (AXI4, as implemented by axi_memory):
//   - AW handshake always precedes W handshake (axi_awready is deasserted
//     while a write address is already buffered in axi_memory).
//   - For multi-beat burst writes (e.g. cache line evictions), the AW channel
//     carries the burst BASE address once.  The actual per-beat write address
//     is base + beat_cnt*4 (INCR, 4-byte words).  The monitor must track this
//     beat count to avoid false positives on words other than tohost that
//     happen to share the same cache line.
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
    // Buffer the write address from the AW handshake, and track the beat
    // count within the current burst.  Per-beat address = aw_addr_buf + cnt*4
    // (INCR burst, 4-byte aligned words).  Resets on each new AW handshake.
    // -------------------------------------------------------------------------
    logic [31:0] aw_addr_buf;
    logic [3:0]  w_beat_cnt;    // supports up to 16-beat bursts (cache: 8)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_addr_buf <= 32'h0;
            w_beat_cnt  <= '0;
        end else begin
            if (axi_awvalid && axi_awready) begin
                aw_addr_buf <= axi_awaddr;
                w_beat_cnt  <= '0;          // reset beat counter on new burst
            end else if (axi_wvalid && axi_wready) begin
                w_beat_cnt  <= w_beat_cnt + 1'b1;
            end
        end
    end

    // Actual word address for the current W beat (INCR, 4-byte aligned)
    logic [31:0] w_beat_addr;
    assign w_beat_addr = aw_addr_buf + {26'b0, w_beat_cnt, 2'b00};

    // -------------------------------------------------------------------------
    // tohost detection: fires on the W handshake only when the per-beat
    // address exactly matches the tohost word address.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (tohost_addr_valid && tohost_addr != 32'h0 &&
            axi_wvalid && axi_wready) begin
            if ((w_beat_addr & ~32'h3) == (tohost_addr & ~32'h3)) begin
                $display("[TOHOST] Write detected: addr=0x%08x data=0x%08x",
                         w_beat_addr, axi_wdata);
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

// ============================================================================
// File: axi_clint.sv
// Project: KV32 RISC-V Processor
// Description: AXI4-Lite Core Local Interruptor (CLINT)
//
// Provides memory-mapped timer functionality for RISC-V core.
// Implements the standard RISC-V CLINT specification for time and timer
// interrupts.
//
// Register Map:
//   0x0000: MSIP (Machine Software Interrupt Pending)
//   0x4000: MTIMECMP Low (Timer Compare Register)
//   0x4004: MTIMECMP High
//   0xBFF8: MTIME Low (Current Time)
//   0xBFFC: MTIME High
//
// Features:
//   - 64-bit real-time counter (MTIME)
//   - 64-bit compare register (MTIMECMP)
//   - Timer interrupt generation when MTIME >= MTIMECMP
// ============================================================================

module axi_clint (
    input  logic        clk,
    input  logic        rst_n,

    // AXI4-Lite interface
    input  logic [31:0] axi_awaddr,
    input  logic        axi_awvalid,
    output logic        axi_awready,

    input  logic [31:0] axi_wdata,
    input  logic [3:0]  axi_wstrb,
    input  logic        axi_wvalid,
    output logic        axi_wready,

    output logic [1:0]  axi_bresp,
    output logic        axi_bvalid,
    input  logic        axi_bready,

    input  logic [31:0] axi_araddr,
    input  logic        axi_arvalid,
    output logic        axi_arready,

    output logic [31:0] axi_rdata,
    output logic [1:0]  axi_rresp,
    output logic        axi_rvalid,
    input  logic        axi_rready,

    // Interrupt outputs
    output logic        timer_irq,
    output logic        software_irq

`ifndef SYNTHESIS
    // When trace_mode is asserted, mtime advances only on instruction
    // retirement (retire_instr=1) instead of every clock cycle.  This makes
    // mtime read-values identical to the software simulator, which also
    // increments mtime once per retired instruction.
    // When core_sleep_i is asserted (WFI clock-gated), no instructions
    // retire, so mtime must advance on the wall clock to allow timer wakeup.
   ,input  logic        trace_mode,
    input  logic        retire_instr,
    input  logic        core_sleep_i,
    // Bypass: directly update CLINT registers from a retiring store so that
    // register side-effects (e.g. MSIP) take effect on the very cycle the
    // store retires, matching the software-simulator's single-cycle latency.
    input  logic        trace_store_valid,   // retiring store in WB (retire_instr && mem_write_wb)
    input  logic [31:0] trace_store_addr,    // store effective address
    input  logic [31:0] trace_store_data,    // raw store word data
    input  logic [3:0]  trace_store_strb     // store byte-enable mask
`endif
);

    // CLINT register offsets
    localparam MSIP_OFFSET      = 16'h0000;
    localparam MTIMECMP_OFFSET  = 16'h4000;
    localparam MTIME_OFFSET     = 16'hBFF8;

    // CLINT registers
    logic [31:0] msip;
    logic [63:0] mtime;
    logic [63:0] mtimecmp;

    // Timer counter + AXI write update — single always_ff block so mtime has
    // exactly one driver.  (Multiple always_ff blocks driving overlapping bits
    // of the same variable via non-blocking assigns are a Verilator blind spot:
    // whole-var vs part-select writes are not cross-checked for overlap.)
    //
    // Priority: AXI write > increment.  A firmware write to MTIME_OFFSET
    // atomically replaces the relevant bytes on the same clock edge; the
    // increment is suppressed for those bytes only on the write cycle.
    //
    // Trace-mode: mtime advances once per retired instruction so that its
    // value is independent of CPI and matches the software simulator exactly.
    // Exception: when the core is sleeping (WFI; core_sleep_i=1) no
    // instructions retire, so fall back to wall-clock ticking.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mtime <= 64'd0;
        end else begin
            // Default: increment mtime (gated in trace mode)
`ifndef SYNTHESIS
            if (!trace_mode || retire_instr || core_sleep_i)
`endif
                mtime <= mtime + 64'd1;

            // AXI write to MTIME takes priority over the increment for the
            // written bytes.  Use axi_awaddr[15:0] directly so that
            // write_addr_offset (declared later) is not referenced out-of-order.
            if (axi_awvalid && axi_wvalid &&
                axi_awaddr[15:0] == MTIME_OFFSET) begin
                if (axi_wstrb[0]) mtime[7:0]   <= axi_wdata[7:0];
                if (axi_wstrb[1]) mtime[15:8]  <= axi_wdata[15:8];
                if (axi_wstrb[2]) mtime[23:16] <= axi_wdata[23:16];
                if (axi_wstrb[3]) mtime[31:24] <= axi_wdata[31:24];
            end
            if (axi_awvalid && axi_wvalid &&
                axi_awaddr[15:0] == MTIME_OFFSET + 16'd4) begin
                if (axi_wstrb[0]) mtime[39:32] <= axi_wdata[7:0];
                if (axi_wstrb[1]) mtime[47:40] <= axi_wdata[15:8];
                if (axi_wstrb[2]) mtime[55:48] <= axi_wdata[23:16];
                if (axi_wstrb[3]) mtime[63:56] <= axi_wdata[31:24];
            end
        end
    end

    // Interrupt generation
    // In trace mode use the same mtime view the software simulator has: it
    // ticks mtime BEFORE executing each instruction, so its effective value is
    // (retire_count + retire_instr) where retire_instr=1 when the current
    // instruction being retired would also be the one that tips mtime over the
    // threshold.  Adding retire_instr here makes irq fire in the SAME cycle
    // as the retirement that crosses the threshold, matching SIM exactly.
`ifndef SYNTHESIS
    assign timer_irq = trace_mode ? ((mtime + {63'd0, retire_instr}) >= mtimecmp)
                                  : (mtime >= mtimecmp);
`else
    assign timer_irq = (mtime >= mtimecmp);
`endif

`ifndef SYNTHESIS
    // In trace mode, software_irq must fire on the same cycle that a
    // retiring store writes msip[0]=1 so that the pipeline stalls the
    // NOT-YET-RETIRED instructions (those still in MEM/later stages).
    // Combinationally bypass the registered msip so the irq_pending
    // signal reaches the core before the WB→WB pipeline register load.
    logic msip_eff;
    always_comb begin
        if (trace_mode && trace_store_valid && trace_store_addr[15:0] == MSIP_OFFSET)
            msip_eff = trace_store_data[0];
        else
            msip_eff = msip[0];
    end
    assign software_irq = msip_eff;
`else
    assign software_irq = msip[0];
`endif

`ifndef SYNTHESIS
    // In trace mode mtime advances once per retired instruction, but the
    // software simulator ticks BEFORE executing each instruction, so it
    // sees instret+1.  The correction mirrors kv32_csr.sv:
    //   mtime + retire_instr + 1
    // where retire_instr accounts for the instruction now in WB (same clock
    // as this AR acceptance) and +1 for the load instruction itself.
    logic [63:0] mtime_trace_rd;
    assign mtime_trace_rd = mtime + {63'd0, retire_instr} + 64'd1;
`endif

    // Debug: Track software_irq changes, mtime/mtimecmp during sleep
    `ifdef DEBUG
`ifndef SYNTHESIS
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ;
        else if (core_sleep_i) begin
            `DEBUG2(`DBG_GRP_CLINT, ("[CLINT] sleeping: mtime=%0d mtimecmp=%0d timer_irq=%b trace=%b",
                   mtime, mtimecmp, timer_irq, trace_mode));
        end
    end
`endif

    logic prev_software_irq;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_software_irq <= 1'b0;
        end else begin
            prev_software_irq <= software_irq;
            if (software_irq != prev_software_irq) begin
                `DEBUG2(`DBG_GRP_CLINT, ("software_irq changed: %b -> %b (msip[0]=%b)",
                       prev_software_irq, software_irq, msip[0]));
            end
        end
    end
    `endif

    // ========================================================================
    // AXI4-Lite Interface - Simple register access (always ready)
    // ========================================================================
    // Since CLINT registers are simple flip-flops with no access latency,
    // we can keep ready signals always high for optimal performance.

    assign axi_awready = 1'b1;  // Always ready to accept write address
    assign axi_wready  = 1'b1;  // Always ready to accept write data
    assign axi_arready = 1'b1;  // Always ready to accept read address

    logic [15:0] write_addr_offset;
    logic [15:0] read_addr_offset;

    assign write_addr_offset = axi_awaddr[15:0];
    assign read_addr_offset  = axi_araddr[15:0];

    // Only the three defined register locations are valid.
    // Any other offset is out-of-range → AXI SLVERR (2'b10)
    wire wr_addr_valid = (write_addr_offset == MSIP_OFFSET)              ||
                         (write_addr_offset == MTIMECMP_OFFSET)          ||
                         (write_addr_offset == MTIMECMP_OFFSET + 16'd4)  ||
                         (write_addr_offset == MTIME_OFFSET)             ||
                         (write_addr_offset == MTIME_OFFSET   + 16'd4);
    wire rd_addr_valid  = (read_addr_offset  == MSIP_OFFSET)              ||
                          (read_addr_offset  == MTIMECMP_OFFSET)          ||
                          (read_addr_offset  == MTIMECMP_OFFSET + 16'd4)  ||
                          (read_addr_offset  == MTIME_OFFSET)             ||
                          (read_addr_offset  == MTIME_OFFSET   + 16'd4);

    // ========================================================================
    // Write Channel (AW + W → B)
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_bresp       <= 2'b00;
            axi_bvalid      <= 1'b0;
            msip            <= 32'd0;
            mtimecmp        <= 64'hFFFF_FFFF_FFFF_FFFF;
        end else begin
            // Handle write response
            if (axi_bvalid && axi_bready) begin
                axi_bvalid <= 1'b0;
                `DEBUG2(`DBG_GRP_CLINT, ("Write response consumed"));
            end

`ifndef SYNTHESIS
            // Trace-mode bypass: when a store retires in the WB stage, apply
            // it to CLINT registers immediately (same cycle), matching the
            // software simulator's zero-latency store model.  This keeps
            // software-interrupt timing in sync with the SW sim without
            // needing store-buffer / AXI bus timing to match.
            // Only MSIP is bypassed; mtime/mtimecmp are excluded to avoid
            // conflicts with the mtime increment logic and because timer IRQ
            // timing is already correct via the retire_instr formula.
            if (trace_mode && trace_store_valid && trace_store_addr[15:0] == MSIP_OFFSET) begin
                msip <= trace_store_data;
                `DEBUG1(("[CLINT] TRACE bypass MSIP write: 0x%h -> 0x%h addr=0x%h",
                       msip, trace_store_data, trace_store_addr));
            end
`endif

            // Accept write when both AW and W channels are valid
            if (axi_awvalid && axi_wvalid && axi_awready && axi_wready) begin
                `DEBUG2(`DBG_GRP_CLINT, ("Write transaction: addr=0x%h data=0x%h strb=0x%h",
                       axi_awaddr, axi_wdata, axi_wstrb));

                // Write to CLINT registers
                case (write_addr_offset)
                    MSIP_OFFSET: begin
                        msip <= axi_wdata;
                        `DEBUG2(`DBG_GRP_CLINT, ("Writing MSIP: 0x%h -> 0x%h", msip, axi_wdata));
                    end
                    MTIMECMP_OFFSET: begin
                        if (axi_wstrb[0]) mtimecmp[7:0]   <= axi_wdata[7:0];
                        if (axi_wstrb[1]) mtimecmp[15:8]  <= axi_wdata[15:8];
                        if (axi_wstrb[2]) mtimecmp[23:16] <= axi_wdata[23:16];
                        if (axi_wstrb[3]) mtimecmp[31:24] <= axi_wdata[31:24];
                    end
                    MTIMECMP_OFFSET + 16'd4: begin
                        if (axi_wstrb[0]) mtimecmp[39:32] <= axi_wdata[7:0];
                        if (axi_wstrb[1]) mtimecmp[47:40] <= axi_wdata[15:8];
                        if (axi_wstrb[2]) mtimecmp[55:48] <= axi_wdata[23:16];
                        if (axi_wstrb[3]) mtimecmp[63:56] <= axi_wdata[31:24];
                    end
                    MTIME_OFFSET: begin
                        // mtime writes are handled in the mtime always_ff block above;
                        // only the write response (bresp/bvalid) is handled here.
                    end
                    MTIME_OFFSET + 16'd4: begin
                        // same as above
                    end
                    default: begin
                        // Ignore writes to undefined addresses
                    end
                endcase

                // Generate write response
                axi_bresp  <= wr_addr_valid ? 2'b00 : 2'b10;  // OKAY or SLVERR
                axi_bvalid <= 1'b1;
            end
        end
    end

    // ========================================================================
    // Read Channel (AR → R)
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_rdata      <= 32'h0;
            axi_rresp      <= 2'b00;
            axi_rvalid     <= 1'b0;
        end else begin
            // Handle read response
            if (axi_rvalid && axi_rready) begin
                axi_rvalid <= 1'b0;
                `DEBUG2(`DBG_GRP_CLINT, ("Read response consumed"));
            end

            // Accept read when AR channel is valid
            if (axi_arvalid && axi_arready) begin
                `DEBUG2(`DBG_GRP_CLINT, ("Read transaction: addr=0x%h", axi_araddr));

                // Read from CLINT registers
                case (read_addr_offset)
                    MSIP_OFFSET:             axi_rdata <= msip;
                    MTIMECMP_OFFSET:         axi_rdata <= mtimecmp[31:0];
                    MTIMECMP_OFFSET + 16'd4: axi_rdata <= mtimecmp[63:32];
`ifndef SYNTHESIS
                    // In trace mode mtime is gated to advance once per retired
                    // instruction.  The software simulator ticks mtime BEFORE
                    // executing each instruction, so it effectively reads
                    // (instret+1) while the RTL reads (instret).  Adding 1 here
                    // closes that off-by-one so both traces are identical.
                    MTIME_OFFSET:            axi_rdata <= trace_mode ? mtime_trace_rd[31:0]  : mtime[31:0];
                    MTIME_OFFSET + 16'd4:    axi_rdata <= trace_mode ? mtime_trace_rd[63:32] : mtime[63:32];
`else
                    MTIME_OFFSET:            axi_rdata <= mtime[31:0];
                    MTIME_OFFSET + 16'd4:    axi_rdata <= mtime[63:32];
`endif
                    default:                 axi_rdata <= 32'd0;
                endcase

                // Generate read response
                axi_rresp  <= rd_addr_valid ? 2'b00 : 2'b10;  // OKAY or SLVERR
                axi_rvalid <= 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    // Lint sink (debug only): upper address bits and trace strobe are not used
    // in this implementation; excluded from synthesis to avoid dead-logic warnings.
    logic _unused_ok;
    assign _unused_ok = &{1'b0, trace_store_strb,
                                axi_awaddr[31:16], axi_araddr[31:16],
                                trace_store_addr[31:16]};
`endif // SYNTHESIS

endmodule


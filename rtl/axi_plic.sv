// ============================================================================
// File: axi_plic.sv
// Project: KV32 RISC-V Processor
// Description: Platform-Level Interrupt Controller (PLIC)
//
// Implements a simplified RISC-V PLIC supporting:
//   - Up to NUM_IRQ (1..31) external interrupt sources
//   - 1 hart target context (hart 0, M-mode)
//   - Per-source 3-bit priority (0 = never interrupt; 1..7 = active)
//   - Global priority threshold per context (interrupt fires if
//     best-pending-priority > threshold)
//   - Standard claim/complete protocol
//
// Memory Map (offsets from base address 0x0C00_0000):
//   Offset           Description
//   0x000000         Source 0 priority    (reserved, always reads 0)
//   0x000004 * i     Source i priority    (i = 1..NUM_IRQ, 3-bit)
//   0x001000         Interrupt pending    bits [NUM_IRQ:1] (read-only)
//   0x002000         Interrupt enable     bits [NUM_IRQ:1] for context 0
//   0x200000         Priority threshold   for context 0 (3-bit)
//   0x200004         Claim / Complete     for context 0
//
// Interrupt Flow:
//   - Pending bit[i] is set   whenever irq_src[i] is asserted (level)
//   - Pending bit[i] is kept  while the interrupt is claimed (read claim)
//   - Pending bit[i] is cleared when complete is written AND irq_src[i] = 0
//   - If irq_src[i] is still high after complete, pending is immediately re-set
//
// The irq output is asserted when at least one enabled pending interrupt
// has a priority strictly greater than the threshold.
//
// All unrecognised addresses return 0 on read and are silently ignored on write,
// with SLVERR (2'b10) AXI response to signal the out-of-range access.
// ============================================================================

module axi_plic #(
    parameter int NUM_IRQ = 7    // Interrupt sources 1..NUM_IRQ (max 31)
)(
    input  logic        clk,
    input  logic        rst_n,

    // AXI4-Lite interface (full 32-bit address; base = 0x0C00_0000)
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

    // Interrupt source inputs (1-indexed; [0] is unused / tied to 0)
    input  logic [NUM_IRQ:0] irq_src,

    // Interrupt output to core (external_irq / MEI)
    output logic        irq
);

    // -----------------------------------------------------------------------
    // PLIC registers
    // -----------------------------------------------------------------------
    logic [3:0]  priority_r [1:NUM_IRQ];   // Per-source priority (4-bit, matches PLIC_PRIO_BITS=4)
    logic        enable_r   [1:NUM_IRQ];   // Per-source enable for context 0
    logic [3:0]  threshold_r;              // Threshold for context 0
    logic        pending_r  [1:NUM_IRQ];   // Interrupt pending bits

    // Whether the source is currently claimed (between claim read and complete)
    logic        claimed_r  [1:NUM_IRQ];

    // -----------------------------------------------------------------------
    // Claim logic: find the highest-priority enabled pending interrupt
    // Lower source ID wins on priority tie (iterate high-to-low, >= keeps
    // lower IDs when they are encountered last in the sweep).
    // -----------------------------------------------------------------------
    logic [3:0]  best_pri;
    logic [4:0]  claim_id;   // 0 = no interrupt

    always_comb begin
        best_pri = 4'h0;
        claim_id = 5'h0;
        for (int i = NUM_IRQ; i >= 1; i--) begin
            // Exclude claimed sources (between claim read and complete write)
            if (enable_r[i] && pending_r[i] && !claimed_r[i] &&
                (priority_r[i] > threshold_r)) begin
                if (priority_r[i] >= best_pri) begin
                    best_pri = priority_r[i];
                    claim_id = 5'(i);
                end
            end
        end
    end

    assign irq = (claim_id != 5'h0);

    // -----------------------------------------------------------------------
    // Pending / complete logic
    // -----------------------------------------------------------------------
    // complete_wr: write to claim/complete register  (do_write, offset 0x200004)
    logic        do_write;
    logic        complete_wr;
    logic [25:0] aw_off;                   // registered write offset
    logic [31:0] wr_src_idx;               // write src index = aw_off[14:2] (32-bit to match int NUM_IRQ comparisons)
    logic [31:0] rd_src_idx;               // read src index = ar_addr_latch[14:2] (32-bit to match int NUM_IRQ comparisons)

    logic [31:0] aw_addr_latch;            // forward declaration
    logic [31:0] ar_addr_latch;            // forward declaration
    always_comb aw_off     = aw_addr_latch[25:0];
    always_comb wr_src_idx = 32'(aw_off[14:2]);
    always_comb rd_src_idx = 32'(ar_addr_latch[14:2]);

    // Latch write address and data
    logic [31:0] w_data_latch;
    logic [3:0]  w_strb_latch;
    logic        aw_recv, w_recv;

    assign do_write    = aw_recv && w_recv && (!axi_bvalid || axi_bready);
    assign complete_wr = do_write && (aw_off == 26'h200004);

    // -----------------------------------------------------------------------
    // AXI address validity (SLVERR for out-of-range offsets)
    // -----------------------------------------------------------------------
    // Valid write offsets:
    //   Priority regs : off[25:15]==0, src index 1..NUM_IRQ  (off = 4*src)
    //   Enable word   : 0x002000
    //   Threshold     : 0x200000
    //   Claim/Complete: 0x200004
    logic wr_addr_valid;
    always_comb begin : plic_wr_addr_check
        wr_addr_valid = (aw_off == 26'h002000)                        ||  // Enable
                        (aw_off == 26'h200000)                        ||  // Threshold
                        (aw_off == 26'h200004)                        ||  // Complete
                        (aw_off[25:15] == '0 && wr_src_idx >= 1 && wr_src_idx <= NUM_IRQ); // Priority
    end

    // Valid read offsets:
    //   Priority regs : off[25:15]==0, src index 0..NUM_IRQ  (src 0 always reads 0)
    //   Pending bits  : 0x001000
    //   Enable word   : 0x002000
    //   Threshold     : 0x200000
    //   Claim         : 0x200004
    logic rd_addr_valid;
    always_comb begin : plic_rd_addr_check
        rd_addr_valid = (ar_addr_latch[25:0] == 26'h001000)                        ||  // Pending
                        (ar_addr_latch[25:0] == 26'h002000)                        ||  // Enable
                        (ar_addr_latch[25:0] == 26'h200000)                        ||  // Threshold
                        (ar_addr_latch[25:0] == 26'h200004)                        ||  // Claim
                        (ar_addr_latch[25:15] == '0 && rd_src_idx <= NUM_IRQ); // Priority
    end

    // Claim side-effect: asserted when the claim register is being read
    logic ar_claim_read;
    assign ar_claim_read = ar_recv && (ar_addr_latch[25:0] == 26'h200004);

    // Pending update
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 1; i <= NUM_IRQ; i++) pending_r[i] <= 1'b0;
            for (int i = 1; i <= NUM_IRQ; i++) claimed_r[i] <= 1'b0;
        end else begin
            for (int i = 1; i <= NUM_IRQ; i++) begin
                // Level-triggered: pending is set whenever irq_src is high.
                if (irq_src[i])
                    pending_r[i] <= 1'b1;

                // Disabling a source immediately clears its pending and claimed
                // bits — matching Spike plic.cc context_enable_write() behaviour.
                // This assignment is AFTER the irq_src set so disable wins when
                // both happen in the same cycle.
                if (do_write && (aw_off == 26'h002000) && enable_r[i] && !w_data_latch[i]) begin
                    pending_r[i] <= 1'b0;
                    claimed_r[i] <= 1'b0;
                end

                // Complete: clear claimed; clear pending if source no longer
                // asserted (re-asserted sources stay pending for next claim).
                if (complete_wr && (w_data_latch[4:0] == 5'(i))) begin
                    claimed_r[i] <= 1'b0;
                    if (!irq_src[i])
                        pending_r[i] <= 1'b0;
                end
            end
            // Claim side-effect: set claimed_r when claim register is read
            // (merged here from a separate block to fix multi-driver CDFG2G-622)
            if (ar_claim_read && !axi_rvalid) begin
                for (int i = 1; i <= NUM_IRQ; i++) begin
                    if (claim_id == 5'(i))
                        claimed_r[i] <= 1'b1;
                end
            end
        end
    end

    // -----------------------------------------------------------------------
    // AXI write channel
    // -----------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_recv       <= 1'b0;
            w_recv        <= 1'b0;
            aw_addr_latch <= '0;
            w_data_latch  <= '0;
            w_strb_latch  <= '0;
            axi_awready   <= 1'b1;
            axi_wready    <= 1'b1;
            axi_bvalid    <= 1'b0;
            axi_bresp     <= 2'b00;
        end else begin
            // Accept AW
            if (axi_awvalid && axi_awready) begin
                aw_recv       <= 1'b1;
                aw_addr_latch <= axi_awaddr;
                axi_awready   <= 1'b0;
            end
            // Accept W
            if (axi_wvalid && axi_wready) begin
                w_recv       <= 1'b1;
                w_data_latch <= axi_wdata;
                w_strb_latch <= axi_wstrb;
                axi_wready   <= 1'b0;
            end
            // Issue B when both channels received
            if (do_write) begin
                axi_bvalid <= 1'b1;
                axi_bresp  <= wr_addr_valid ? 2'b00 : 2'b10;  // OKAY or SLVERR
            end
            // Clear after B handshake
            if (axi_bvalid && axi_bready) begin
                axi_bvalid  <= 1'b0;
                aw_recv     <= 1'b0;
                w_recv      <= 1'b0;
                axi_awready <= 1'b1;
                axi_wready  <= 1'b1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Register write dispatch
    // -----------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 1; i <= NUM_IRQ; i++) priority_r[i] <= 4'h0;
            for (int i = 1; i <= NUM_IRQ; i++) enable_r[i]   <= 1'b0;
            threshold_r <= 4'h0;
        end else if (do_write) begin
            // Byte-enable masked write helper (only lower 4 bits used for
            // priority/threshold; full 32-bit for enable word and claim/complete)
            if (aw_off == 26'h200000) begin
                // Threshold
                if (w_strb_latch[0]) threshold_r <= w_data_latch[3:0];
            end else if (aw_off == 26'h002000) begin
                // Enable word (sources 1..min(NUM_IRQ,31))
                for (int i = 1; i <= NUM_IRQ && i <= 31; i++)
                    if (w_strb_latch[i/8]) enable_r[i] <= w_data_latch[i];
            end else if (aw_off[25:15] == '0) begin
                // Priority registers: aw_off[14:2] = source index
                if (wr_src_idx >= 1 && wr_src_idx <= NUM_IRQ)
                    if (w_strb_latch[0]) priority_r[wr_src_idx] <= w_data_latch[3:0];
            end
            // offset 0x200004 (complete) is handled in pending logic above
        end
    end

    // -----------------------------------------------------------------------
    // AXI read channel
    // -----------------------------------------------------------------------
    logic        ar_recv;
    logic [31:0] rd_data;

    // Build pending word
    logic [31:0] pending_word;
    always_comb begin
        pending_word = 32'h0;
        for (int i = 1; i <= NUM_IRQ; i++)
            pending_word[i] = pending_r[i];
    end

    // Build enable word
    logic [31:0] enable_word;
    always_comb begin
        enable_word = 32'h0;
        for (int i = 1; i <= NUM_IRQ; i++)
            enable_word[i] = enable_r[i];
    end

    // Read data mux (combinational, uses latched ar address)
    always_comb begin
        rd_data = 32'h0;
        if (ar_addr_latch[25:0] == 26'h001000) begin
            rd_data = pending_word;
        end else if (ar_addr_latch[25:0] == 26'h002000) begin
            rd_data = enable_word;
        end else if (ar_addr_latch[25:0] == 26'h200000) begin
            rd_data = {28'h0, threshold_r};
        end else if (ar_addr_latch[25:0] == 26'h200004) begin
            // Claim: return ID of best pending interrupt; side-effect handled below
            rd_data = {27'h0, claim_id};
        end else if (ar_addr_latch[25:15] == '0) begin
            // Priority register
            if (rd_src_idx == 0)
                rd_data = 32'h0;
            else if (rd_src_idx >= 1 && rd_src_idx <= NUM_IRQ)
                rd_data = {28'h0, priority_r[rd_src_idx]};
        end
    end

    // (ar_claim_read declared above, before the pending update block)
    // (Claim side-effect always_ff removed; logic merged into pending update block above)

    // Latched AR address (declared earlier as forward declaration)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_recv       <= 1'b0;
            ar_addr_latch <= '0;
            axi_arready   <= 1'b1;
            axi_rvalid    <= 1'b0;
            axi_rdata     <= '0;
            axi_rresp     <= 2'b00;
        end else begin
            if (axi_arvalid && axi_arready) begin
                ar_recv       <= 1'b1;
                ar_addr_latch <= axi_araddr;
                axi_arready   <= 1'b0;
            end
            if (ar_recv && (!axi_rvalid || axi_rready)) begin
                axi_rvalid  <= 1'b1;
                axi_rdata   <= rd_data;
                axi_rresp   <= rd_addr_valid ? 2'b00 : 2'b10;  // OKAY or SLVERR
                ar_recv     <= 1'b0;
                axi_arready <= 1'b1;
            end
            if (axi_rvalid && axi_rready)
                axi_rvalid <= 1'b0;
        end
    end

`ifndef SYNTHESIS
    // Lint sink (debug only): upper address bits are the PLIC base decoded by
    // the crossbar; this module only uses bits [25:0].
    logic _unused_ok;
    assign _unused_ok = &{1'b0, aw_addr_latch[31:26], ar_addr_latch[31:26]};
`endif // SYNTHESIS

endmodule


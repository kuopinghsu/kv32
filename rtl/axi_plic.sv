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
// with OKAY (2'b00) AXI response in both cases.
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
    logic [2:0]  priority_r [1:NUM_IRQ];   // Per-source priority (3-bit)
    logic        enable_r   [1:NUM_IRQ];   // Per-source enable for context 0
    logic [2:0]  threshold_r;              // Threshold for context 0
    logic        pending_r  [1:NUM_IRQ];   // Interrupt pending bits

    // Whether the source is currently claimed (between claim read and complete)
    logic        claimed_r  [1:NUM_IRQ];

    // -----------------------------------------------------------------------
    // Claim logic: find the highest-priority enabled pending interrupt
    // Lower source ID wins on priority tie (iterate high-to-low, >= keeps
    // lower IDs when they are encountered last in the sweep).
    // -----------------------------------------------------------------------
    logic [2:0]  best_pri;
    logic [4:0]  claim_id;   // 0 = no interrupt

    always_comb begin
        best_pri = 3'h0;
        claim_id = 5'h0;
        for (int i = NUM_IRQ; i >= 1; i--) begin
            if (enable_r[i] && pending_r[i] && (priority_r[i] > threshold_r)) begin
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
    logic [25:0] ar_off;                   // registered read offset

    always_comb aw_off = aw_addr_latch[25:0];

    // Latch write address and data
    logic [31:0] aw_addr_latch;
    logic [31:0] w_data_latch;
    logic [3:0]  w_strb_latch;
    logic        aw_recv, w_recv;

    assign do_write  = aw_recv && w_recv && (!axi_bvalid || axi_bready);
    assign complete_wr = do_write && (aw_off == 26'h200004);

    // Pending update
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 1; i <= NUM_IRQ; i++) pending_r[i] <= 1'b0;
            for (int i = 1; i <= NUM_IRQ; i++) claimed_r[i] <= 1'b0;
        end else begin
            for (int i = 1; i <= NUM_IRQ; i++) begin
                // Level-triggered: pending is set whenever irq_src is high
                if (irq_src[i])
                    pending_r[i] <= 1'b1;

                // Claim: mark as claimed so it is not re-presented until complete
                if (complete_wr && !do_write) begin
                    // No action here; claim_read handled separately
                end

                // Complete: clear pending if source is no longer asserted
                if (complete_wr && (w_data_latch[4:0] == 5'(i)))
                    claimed_r[i] <= 1'b0;

                // Clear pending on complete + source low
                if (complete_wr && (w_data_latch[4:0] == 5'(i)) && !irq_src[i])
                    pending_r[i] <= 1'b0;
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
                axi_bresp  <= 2'b00;
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
            for (int i = 1; i <= NUM_IRQ; i++) priority_r[i] <= 3'h0;
            for (int i = 1; i <= NUM_IRQ; i++) enable_r[i]   <= 1'b0;
            threshold_r <= 3'h0;
        end else if (do_write) begin
            // Byte-enable masked write helper (only lower 3 bits used for
            // priority/threshold; full 32-bit for enable word and claim/complete)
            automatic logic [25:0] off = aw_off;
            if (off == 26'h200000) begin
                // Threshold
                if (w_strb_latch[0]) threshold_r <= w_data_latch[2:0];
            end else if (off == 26'h002000) begin
                // Enable word (sources 1..min(NUM_IRQ,31))
                for (int i = 1; i <= NUM_IRQ && i <= 31; i++)
                    if (w_strb_latch[i/8]) enable_r[i] <= w_data_latch[i];
            end else if (off[25:15] == '0) begin
                // Priority registers: off[14:2] = source index
                automatic int src = int'(off[14:2]);
                if (src >= 1 && src <= NUM_IRQ)
                    if (w_strb_latch[0]) priority_r[src] <= w_data_latch[2:0];
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
        automatic logic [25:0] off = ar_addr_latch[25:0];
        rd_data = 32'h0;
        if (off == 26'h001000) begin
            rd_data = pending_word;
        end else if (off == 26'h002000) begin
            rd_data = enable_word;
        end else if (off == 26'h200000) begin
            rd_data = {29'h0, threshold_r};
        end else if (off == 26'h200004) begin
            // Claim: return ID of best pending interrupt; side-effect handled below
            rd_data = {27'h0, claim_id};
        end else if (off[25:15] == '0) begin
            // Priority register
            automatic int src = int'(off[14:2]);
            if (src == 0)
                rd_data = 32'h0;
            else if (src >= 1 && src <= NUM_IRQ)
                rd_data = {29'h0, priority_r[src]};
        end
    end

    // Claim side-effect: set claimed_r when claim register is read
    logic ar_claim_read;
    assign ar_claim_read = ar_recv && (ar_addr_latch[25:0] == 26'h200004);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 1; i <= NUM_IRQ; i++) begin
                // claimed_r reset handled in pending block
            end
        end else begin
            // Set claimed on claim read (fires once per read beat)
            if (ar_claim_read && axi_rvalid && !axi_rready) begin
                // will be captured on the cycle the read is accepted
            end
            if (ar_claim_read && (!axi_rvalid)) begin
                // Claim: mark source as claimed
                for (int i = 1; i <= NUM_IRQ; i++) begin
                    if (claim_id == 5'(i))
                        claimed_r[i] <= 1'b1;
                end
            end
        end
    end

    // Latched AR address
    logic [31:0] ar_addr_latch;

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
                axi_rresp   <= 2'b00;
                ar_recv     <= 1'b0;
                axi_arready <= 1'b1;
            end
            if (axi_rvalid && axi_rready)
                axi_rvalid <= 1'b0;
        end
    end

endmodule

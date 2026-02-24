// ============================================================================
// File: axi_arbiter.sv
// Project: RV32 RISC-V Processor
// Description: AXI4 Dual-Master Arbiter
//
// Arbitrates AXI4 transactions between two masters:
//   - Master 0: Instruction memory (read-only)
//   - Master 1: Data memory (read/write)
//
// Features:
//   - Independent AR and R channel arbitration for pipelined operation
//   - Direct AW/W/B channel forwarding from Master 1 (only write master)
//   - Fair round-robin arbitration with parking optimization
//   - ID tracking for multiple outstanding transactions
//   - Configurable outstanding transaction depth
// ============================================================================

`ifdef SYNTHESIS
import rv32_pkg::*;
import axi_pkg::*;
`endif
module axi_arbiter #(
    parameter int OUTSTANDING_DEPTH = 4  // Max outstanding transactions per master
) (
    input  logic        clk,
    input  logic        rst_n,

    // Master 0 (Instruction memory - Read Only) with ID support
    input  logic [31:0]              m0_axi_araddr,
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] m0_axi_arid,
    input  logic [7:0]               m0_axi_arlen,
    input  logic [2:0]               m0_axi_arsize,
    input  logic [1:0]               m0_axi_arburst,
    input  logic                     m0_axi_arvalid,
    output logic                     m0_axi_arready,
    output logic [31:0]              m0_axi_rdata,
    output logic [1:0]               m0_axi_rresp,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] m0_axi_rid,
    output logic                     m0_axi_rlast,
    output logic                     m0_axi_rvalid,
    input  logic                     m0_axi_rready,

    // Master 1 (Data memory - Read/Write) with ID support
    input  logic [31:0]              m1_axi_awaddr,
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] m1_axi_awid,
    input  logic                     m1_axi_awvalid,
    output logic                     m1_axi_awready,
    input  logic [31:0]              m1_axi_wdata,
    input  logic [3:0]               m1_axi_wstrb,
    input  logic                     m1_axi_wvalid,
    output logic                     m1_axi_wready,
    output logic [1:0]               m1_axi_bresp,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] m1_axi_bid,
    output logic                     m1_axi_bvalid,
    input  logic                     m1_axi_bready,
    input  logic [31:0]              m1_axi_araddr,
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] m1_axi_arid,
    input  logic                     m1_axi_arvalid,
    output logic                     m1_axi_arready,
    output logic [31:0]              m1_axi_rdata,
    output logic [1:0]               m1_axi_rresp,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] m1_axi_rid,
    output logic                     m1_axi_rvalid,
    input  logic                     m1_axi_rready,

    // Slave (to interconnect) with ID support
    output logic [31:0]              s_axi_awaddr,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] s_axi_awid,
    output logic                     s_axi_awvalid,
    input  logic                     s_axi_awready,
    output logic [31:0]              s_axi_wdata,
    output logic [3:0]               s_axi_wstrb,
    output logic                     s_axi_wvalid,
    input  logic                     s_axi_wready,
    input  logic [1:0]               s_axi_bresp,
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] s_axi_bid,
    input  logic                     s_axi_bvalid,
    output logic                     s_axi_bready,
    output logic [31:0]              s_axi_araddr,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] s_axi_arid,
    output logic [7:0]               s_axi_arlen,
    output logic [2:0]               s_axi_arsize,
    output logic [1:0]               s_axi_arburst,
    output logic                     s_axi_arvalid,
    input  logic                     s_axi_arready,
    input  logic [31:0]              s_axi_rdata,
    input  logic [1:0]               s_axi_rresp,
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] s_axi_rid,
    input  logic                     s_axi_rlast,
    input  logic                     s_axi_rvalid,
    output logic                     s_axi_rready
);
`ifndef SYNTHESIS
    import rv32_pkg::*;
    import axi_pkg::*;
`endif

    // State for AR channel arbitration
    // Track outstanding AR transactions per master to allow bursts
    localparam int MAX_CONSECUTIVE_AR = 2;  // Allow 2 consecutive ARs before switching
    logic [$clog2(MAX_CONSECUTIVE_AR+1):0] m0_ar_count;  // ARs from M0 since last switch
    logic [$clog2(MAX_CONSECUTIVE_AR+1):0] m1_ar_count;  // ARs from M1 since last switch

    // ========================================================================
    // Write channels: Forward directly from Master 1 (only master that writes)
    // ID signals are passed through unchanged
    // ========================================================================
    assign s_axi_awaddr  = m1_axi_awaddr;
    assign s_axi_awid    = m1_axi_awid;
    assign s_axi_awvalid = m1_axi_awvalid;
    assign m1_axi_awready = s_axi_awready;

    assign s_axi_wdata   = m1_axi_wdata;
    assign s_axi_wstrb   = m1_axi_wstrb;
    assign s_axi_wvalid  = m1_axi_wvalid;
    assign m1_axi_wready  = s_axi_wready;

    assign m1_axi_bresp  = s_axi_bresp;
    assign m1_axi_bid    = s_axi_bid;
    assign m1_axi_bvalid = s_axi_bvalid;
    assign s_axi_bready  = m1_axi_bready;

    // ========================================================================
    // AR Channel: Independent arbitration for read address
    // Priority: Data (M1) > Instruction (M0)
    // Parks at current state when no requests (no IDLE state)
    // ========================================================================
    typedef enum logic {
        AR_MASTER0,
        AR_MASTER1
    } ar_state_e;

    ar_state_e ar_state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_state <= AR_MASTER0;  // Default to M0 (instruction fetch)
            m0_ar_count <= '0;
            m1_ar_count <= '0;
        end else begin
            case (ar_state)
                AR_MASTER0: begin
                    // Count AR handshakes from M0
                    if (m0_axi_arvalid && m0_axi_arready) begin
                        m0_ar_count <= m0_ar_count + 1'b1;
                        `DEBUG2(("AR Arbiter: M0 AR complete count=%0d", m0_ar_count + 1));
                    end

                    // Switch conditions:
                    // 1. M1 has request and M0 is idle
                    // 2. M1 has request and M0 reached max consecutive count
                    if (m1_axi_arvalid) begin
                        if (!m0_axi_arvalid ||
                            (m0_axi_arvalid && m0_axi_arready && m0_ar_count + 1'b1 >= MAX_CONSECUTIVE_AR)) begin
                            ar_state <= AR_MASTER1;
                            m0_ar_count <= '0;  // Reset M0 count
                            `DEBUG2(("AR Arbiter: M0 -> M1 (count=%0d)", m0_ar_count));
                        end
                    end
                end

                AR_MASTER1: begin
                    // Count AR handshakes from M1
                    if (m1_axi_arvalid && m1_axi_arready) begin
                        m1_ar_count <= m1_ar_count + 1'b1;
                        `DEBUG2(("AR Arbiter: M1 AR complete count=%0d", m1_ar_count + 1));
                    end

                    // Switch conditions:
                    // 1. M0 has request and M1 is idle
                    // 2. M0 has request and M1 reached max consecutive count
                    if (m0_axi_arvalid) begin
                        if (!m1_axi_arvalid ||
                            (m1_axi_arvalid && m1_axi_arready && m1_ar_count + 1'b1 >= MAX_CONSECUTIVE_AR)) begin
                            ar_state <= AR_MASTER0;
                            m1_ar_count <= '0;  // Reset M1 count
                            `DEBUG2(("AR Arbiter: M1 -> M0 (count=%0d)", m1_ar_count));
                        end
                    end
                end

                default: ar_state <= AR_MASTER0;
            endcase
        end
    end

    // Mux AR channel outputs with ID - Encode master_id in MSB of ID
    always_comb begin
        // Default: no activity
        s_axi_araddr   = 32'h0;
        s_axi_arid     = '0;
        s_axi_arlen    = 8'h0;
        s_axi_arsize   = 3'b010;   // 4 bytes
        s_axi_arburst  = 2'b01;   // INCR
        s_axi_arvalid  = 1'b0;
        m0_axi_arready = 1'b0;
        m1_axi_arready = 1'b0;

        case (ar_state)
            AR_MASTER0: begin
                s_axi_araddr  = m0_axi_araddr;
                s_axi_arid    = {1'b0, m0_axi_arid[axi_pkg::AXI_ID_WIDTH-2:0]};  // MSB=0 for M0
                s_axi_arlen   = m0_axi_arlen;
                s_axi_arsize  = m0_axi_arsize;
                s_axi_arburst = m0_axi_arburst;
                s_axi_arvalid = m0_axi_arvalid;
                m0_axi_arready = s_axi_arready;
            end

            AR_MASTER1: begin
                s_axi_araddr  = m1_axi_araddr;
                s_axi_arid    = {1'b1, m1_axi_arid[axi_pkg::AXI_ID_WIDTH-2:0]};  // MSB=1 for M1
                // M1 (data) always issues single-beat transfers
                s_axi_arlen   = 8'h0;
                s_axi_arsize  = 3'b010;
                s_axi_arburst = 2'b01;
                s_axi_arvalid = m1_axi_arvalid;
                m1_axi_arready = s_axi_arready;
            end

            default: begin
                // Do nothing, defaults already set above
            end
        endcase
    end

    // ========================================================================
    // R Channel: Route based on response ID encoding
    // Master ID encoded in MSB of ID by AR channel logic
    // ========================================================================
`ifdef DEBUG
    // Track outstanding read transactions for debug only
    typedef struct packed {
        logic master_id;  // 0=M0, 1=M1
        logic [axi_pkg::AXI_ID_WIDTH-1:0] transaction_id;
    } read_tracking_t;

    read_tracking_t read_master_fifo [0:OUTSTANDING_DEPTH*2-1];
    logic [$clog2(OUTSTANDING_DEPTH*2):0] read_fifo_wr_ptr;
    logic [$clog2(OUTSTANDING_DEPTH*2):0] read_fifo_rd_ptr;
    logic [$clog2(OUTSTANDING_DEPTH*2):0] read_fifo_count;

    assign read_fifo_count = read_fifo_wr_ptr - read_fifo_rd_ptr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_fifo_wr_ptr <= '0;
            read_fifo_rd_ptr <= '0;
        end else begin
            // Push to FIFO when AR handshake completes
            if ((m0_axi_arvalid && m0_axi_arready) || (m1_axi_arvalid && m1_axi_arready)) begin
                read_tracking_t entry;
                entry.master_id = (m1_axi_arvalid && m1_axi_arready) ? 1'b1 : 1'b0;
                entry.transaction_id = entry.master_id ? m1_axi_arid : m0_axi_arid;

                read_master_fifo[read_fifo_wr_ptr[$clog2(OUTSTANDING_DEPTH*2)-1:0]] <= entry;
                read_fifo_wr_ptr <= read_fifo_wr_ptr + 1;
                `DEBUG2(("Arbiter: AR FIFO push master=%0d id=%0d", entry.master_id, entry.transaction_id));
            end

            // Pop from FIFO when R handshake completes
            if (s_axi_rvalid && s_axi_rready) begin
                read_fifo_rd_ptr <= read_fifo_rd_ptr + 1;
                `DEBUG2(("Arbiter: R FIFO pop id=%0d", s_axi_rid));
            end
        end
    end
`endif

    // Mux R channel outputs with ID - Decode master_id from MSB of response ID
    // Route based on ID, not FIFO - slave handles outstanding tracking
    always_comb begin
        // Default: no activity
        s_axi_rready  = 1'b0;
        m0_axi_rdata  = 32'h0;
        m0_axi_rresp  = 2'b00;
        m0_axi_rid    = '0;
        m0_axi_rlast  = 1'b0;
        m0_axi_rvalid = 1'b0;
        m1_axi_rdata  = 32'h0;
        m1_axi_rresp  = 2'b00;
        m1_axi_rid    = '0;
        m1_axi_rvalid = 1'b0;

        // Decode master ID from MSB of response ID
        if (s_axi_rvalid) begin
            if (s_axi_rid[axi_pkg::AXI_ID_WIDTH-1]) begin  // MSB=1 -> M1
                m1_axi_rdata  = s_axi_rdata;
                m1_axi_rresp  = s_axi_rresp;
                m1_axi_rid    = {1'b0, s_axi_rid[axi_pkg::AXI_ID_WIDTH-2:0]};  // Strip master bit
                m1_axi_rvalid = 1'b1;
                s_axi_rready  = m1_axi_rready;
            end else begin  // MSB=0 -> M0
                m0_axi_rdata  = s_axi_rdata;
                m0_axi_rresp  = s_axi_rresp;
                m0_axi_rid    = {1'b0, s_axi_rid[axi_pkg::AXI_ID_WIDTH-2:0]};  // Strip master bit
                m0_axi_rlast  = s_axi_rlast;
                m0_axi_rvalid = 1'b1;
                s_axi_rready  = m0_axi_rready;
            end
        end
    end

    // ========================================================================
    // AXI4 Protocol Assertions
    // ========================================================================
    // Define ASSERTION by default (can be disabled with +define+NO_ASSERTION)
`ifndef NO_ASSERTION
`ifndef ASSERTION
`define ASSERTION
`endif
`endif // NO_ASSERTION

`ifdef ASSERTION

    // Master 0 (Instruction) Read Address Channel
    property p_m0_arvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (m0_axi_arvalid && !m0_axi_arready) |=> $stable(m0_axi_arvalid);
    endproperty
    assert property (p_m0_arvalid_stable)
        else $error("[AXI_ARBITER] M0 ARVALID must remain stable until ARREADY");

    property p_m0_araddr_stable;
        @(posedge clk) disable iff (!rst_n)
        (m0_axi_arvalid && !m0_axi_arready) |=> $stable(m0_axi_araddr);
    endproperty
    assert property (p_m0_araddr_stable)
        else $error("[AXI_ARBITER] M0 ARADDR must remain stable while ARVALID is high");

    property p_m0_arid_stable;
        @(posedge clk) disable iff (!rst_n)
        (m0_axi_arvalid && !m0_axi_arready) |=> $stable(m0_axi_arid);
    endproperty
    assert property (p_m0_arid_stable)
        else $error("[AXI_ARBITER] M0 ARID must remain stable while ARVALID is high");

    // Master 1 (Data) Write Address Channel
    property p_m1_awvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (m1_axi_awvalid && !m1_axi_awready) |=> $stable(m1_axi_awvalid);
    endproperty
    assert property (p_m1_awvalid_stable)
        else $error("[AXI_ARBITER] M1 AWVALID must remain stable until AWREADY");

    property p_m1_awaddr_stable;
        @(posedge clk) disable iff (!rst_n)
        (m1_axi_awvalid && !m1_axi_awready) |=> $stable(m1_axi_awaddr);
    endproperty
    assert property (p_m1_awaddr_stable)
        else $error("[AXI_ARBITER] M1 AWADDR must remain stable while AWVALID is high");

    property p_m1_awid_stable;
        @(posedge clk) disable iff (!rst_n)
        (m1_axi_awvalid && !m1_axi_awready) |=> $stable(m1_axi_awid);
    endproperty
    assert property (p_m1_awid_stable)
        else $error("[AXI_ARBITER] M1 AWID must remain stable while AWVALID is high");

    // Master 1 Write Data Channel
    property p_m1_wvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (m1_axi_wvalid && !m1_axi_wready) |=> $stable(m1_axi_wvalid);
    endproperty
    assert property (p_m1_wvalid_stable)
        else $error("[AXI_ARBITER] M1 WVALID must remain stable until WREADY");

    property p_m1_wdata_stable;
        @(posedge clk) disable iff (!rst_n)
        (m1_axi_wvalid && !m1_axi_wready) |=> $stable(m1_axi_wdata);
    endproperty
    assert property (p_m1_wdata_stable)
        else $error("[AXI_ARBITER] M1 WDATA must remain stable while WVALID is high");

    property p_m1_wstrb_stable;
        @(posedge clk) disable iff (!rst_n)
        (m1_axi_wvalid && !m1_axi_wready) |=> $stable(m1_axi_wstrb);
    endproperty
    assert property (p_m1_wstrb_stable)
        else $error("[AXI_ARBITER] M1 WSTRB must remain stable while WVALID is high");

    // Master 1 Read Address Channel
    property p_m1_arvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (m1_axi_arvalid && !m1_axi_arready) |=> $stable(m1_axi_arvalid);
    endproperty
    assert property (p_m1_arvalid_stable)
        else $error("[AXI_ARBITER] M1 ARVALID must remain stable until ARREADY");

    property p_m1_araddr_stable;
        @(posedge clk) disable iff (!rst_n)
        (m1_axi_arvalid && !m1_axi_arready) |=> $stable(m1_axi_araddr);
    endproperty
    assert property (p_m1_araddr_stable)
        else $error("[AXI_ARBITER] M1 ARADDR must remain stable while ARVALID is high");

    property p_m1_arid_stable;
        @(posedge clk) disable iff (!rst_n)
        (m1_axi_arvalid && !m1_axi_arready) |=> $stable(m1_axi_arid);
    endproperty
    assert property (p_m1_arid_stable)
        else $error("[AXI_ARBITER] M1 ARID must remain stable while ARVALID is high");

    // Slave Interface - Propagated from Masters
    property p_s_awvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (s_axi_awvalid && !s_axi_awready) |=> $stable(s_axi_awvalid);
    endproperty
    assert property (p_s_awvalid_stable)
        else $error("[AXI_ARBITER] Slave AWVALID must remain stable until AWREADY");

    property p_s_wvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (s_axi_wvalid && !s_axi_wready) |=> $stable(s_axi_wvalid);
    endproperty
    assert property (p_s_wvalid_stable)
        else $error("[AXI_ARBITER] Slave WVALID must remain stable until WREADY");

    property p_s_arvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (s_axi_arvalid && !s_axi_arready) |=> $stable(s_axi_arvalid);
    endproperty
    assert property (p_s_arvalid_stable)
        else $error("[AXI_ARBITER] Slave ARVALID must remain stable until ARREADY");

    // Arbitration Fairness - No starvation
    // Note: Range delays not yet fully supported in Verilator --timing mode
    // property p_m0_arvalid_eventually_granted;
    //     @(posedge clk) disable iff (!rst_n)
    //     (m0_axi_arvalid && ar_state == AR_M1) |-> ##[1:8] m0_axi_arready;
    // endproperty
    // assert property (p_m0_arvalid_eventually_granted)
    //     else $warning("[AXI_ARBITER] M0 AR request not granted within 8 cycles - possible starvation");

    // property p_m1_arvalid_eventually_granted;
    //     @(posedge clk) disable iff (!rst_n)
    //     (m1_axi_arvalid && ar_state == AR_M0) |-> ##[1:8] m1_axi_arready;
    // endproperty
    // assert property (p_m1_arvalid_eventually_granted)
    //     else $warning("[AXI_ARBITER] M1 AR request not granted within 8 cycles - possible starvation");

    // X/Z Detection
    property p_m0_no_x_arvalid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(m0_axi_arvalid);
    endproperty
    assert property (p_m0_no_x_arvalid)
        else $error("[AXI_ARBITER] X/Z detected on m0_axi_arvalid");

    property p_m0_no_x_rready;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(m0_axi_rready);
    endproperty
    assert property (p_m0_no_x_rready)
        else $error("[AXI_ARBITER] X/Z detected on m0_axi_rready");

    property p_m1_no_x_awvalid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(m1_axi_awvalid);
    endproperty
    assert property (p_m1_no_x_awvalid)
        else $error("[AXI_ARBITER] X/Z detected on m1_axi_awvalid");

    property p_m1_no_x_wvalid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(m1_axi_wvalid);
    endproperty
    assert property (p_m1_no_x_wvalid)
        else $error("[AXI_ARBITER] X/Z detected on m1_axi_wvalid");

    property p_m1_no_x_arvalid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(m1_axi_arvalid);
    endproperty
    assert property (p_m1_no_x_arvalid)
        else $error("[AXI_ARBITER] X/Z detected on m1_axi_arvalid");

    property p_m1_no_x_bready;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(m1_axi_bready);
    endproperty
    assert property (p_m1_no_x_bready)
        else $error("[AXI_ARBITER] X/Z detected on m1_axi_bready");

    property p_m1_no_x_rready;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(m1_axi_rready);
    endproperty
    assert property (p_m1_no_x_rready)
        else $error("[AXI_ARBITER] X/Z detected on m1_axi_rready");

    // ID Encoding Correctness
    property p_id_msb_encoding;
        @(posedge clk) disable iff (!rst_n)
        (s_axi_arvalid && ar_state == AR_MASTER0) |-> (s_axi_arid[axi_pkg::AXI_ID_WIDTH-1] == 1'b0);
    endproperty
    assert property (p_id_msb_encoding)
        else $error("[AXI_ARBITER] M0 request must have MSB=0 in ID");

    property p_id_msb_encoding_m1;
        @(posedge clk) disable iff (!rst_n)
        (s_axi_arvalid && ar_state == AR_MASTER1) |-> (s_axi_arid[axi_pkg::AXI_ID_WIDTH-1] == 1'b1);
    endproperty
    assert property (p_id_msb_encoding_m1)
        else $error("[AXI_ARBITER] M1 request must have MSB=1 in ID");

`endif // ASSERTION

endmodule

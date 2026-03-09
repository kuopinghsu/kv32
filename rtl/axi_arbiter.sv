// ============================================================================
// File: axi_arbiter.sv
// Project: KV32 RISC-V Processor
// Description: AXI4 Tri-Master Arbiter
//
// Arbitrates AXI4 transactions between three masters:
//   - Master 0: Instruction memory (read-only)
//   - Master 1: Data memory (read/write)
//   - Master 2: DMA engine (read/write)
//
// Features:
//   - Independent AR channel: 3-way round-robin (M0->M1->M2->M0)
//   - Write channels: M1/M2 arbitration (M1 priority); M0 is read-only
//   - AXI ID encoding: bits[3:2] encode master
//       2'b00=M0, 2'b10=M1, 2'b01=M2; bits[1:0]=per-master txn ID
//   - Configurable outstanding transaction depth
// ============================================================================

`ifdef SYNTHESIS
import kv32_pkg::*;
import axi_pkg::*;
`endif

module axi_arbiter #(
    parameter int OUTSTANDING_DEPTH = 4
) (
    input  logic        clk,
    input  logic        rst_n,

    // Master 0 (Instruction memory - Read Only)
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

    // Master 1 (Data memory - Read/Write)
    input  logic [31:0]              m1_axi_awaddr,
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] m1_axi_awid,
    input  logic [7:0]               m1_axi_awlen,
    input  logic [2:0]               m1_axi_awsize,
    input  logic [1:0]               m1_axi_awburst,
    input  logic                     m1_axi_awvalid,
    output logic                     m1_axi_awready,
    input  logic [31:0]              m1_axi_wdata,
    input  logic [3:0]               m1_axi_wstrb,
    input  logic                     m1_axi_wlast,
    input  logic                     m1_axi_wvalid,
    output logic                     m1_axi_wready,
    output logic [1:0]               m1_axi_bresp,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] m1_axi_bid,
    output logic                     m1_axi_bvalid,
    input  logic                     m1_axi_bready,
    input  logic [31:0]              m1_axi_araddr,
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] m1_axi_arid,
    input  logic [7:0]               m1_axi_arlen,
    input  logic [2:0]               m1_axi_arsize,
    input  logic [1:0]               m1_axi_arburst,
    input  logic                     m1_axi_arvalid,
    output logic                     m1_axi_arready,
    output logic [31:0]              m1_axi_rdata,
    output logic [1:0]               m1_axi_rresp,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] m1_axi_rid,
    output logic                     m1_axi_rlast,
    output logic                     m1_axi_rvalid,
    input  logic                     m1_axi_rready,

    // Master 2 (DMA - Read/Write)
    input  logic [31:0]              m2_axi_awaddr,
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] m2_axi_awid,
    input  logic [7:0]               m2_axi_awlen,
    input  logic [2:0]               m2_axi_awsize,
    input  logic [1:0]               m2_axi_awburst,
    input  logic                     m2_axi_awvalid,
    output logic                     m2_axi_awready,
    input  logic [31:0]              m2_axi_wdata,
    input  logic [3:0]               m2_axi_wstrb,
    input  logic                     m2_axi_wlast,
    input  logic                     m2_axi_wvalid,
    output logic                     m2_axi_wready,
    output logic [1:0]               m2_axi_bresp,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] m2_axi_bid,
    output logic                     m2_axi_bvalid,
    input  logic                     m2_axi_bready,
    input  logic [31:0]              m2_axi_araddr,
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] m2_axi_arid,
    input  logic [7:0]               m2_axi_arlen,
    input  logic [2:0]               m2_axi_arsize,
    input  logic [1:0]               m2_axi_arburst,
    input  logic                     m2_axi_arvalid,
    output logic                     m2_axi_arready,
    output logic [31:0]              m2_axi_rdata,
    output logic [1:0]               m2_axi_rresp,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] m2_axi_rid,
    output logic                     m2_axi_rlast,
    output logic                     m2_axi_rvalid,
    input  logic                     m2_axi_rready,

    // Slave (to interconnect)
    output logic [31:0]              s_axi_awaddr,
    output logic [7:0]               s_axi_awlen,
    output logic [2:0]               s_axi_awsize,
    output logic [1:0]               s_axi_awburst,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] s_axi_awid,
    output logic                     s_axi_awvalid,
    input  logic                     s_axi_awready,
    output logic [31:0]              s_axi_wdata,
    output logic [3:0]               s_axi_wstrb,
    output logic                     s_axi_wlast,
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
    import kv32_pkg::*;
    import axi_pkg::*;
`endif

    // ========================================================================
    // Write Channel Arbitration: M1 (DMEM) vs M2 (DMA); M1 has priority
    // ========================================================================
    typedef enum logic { W_IDLE_M1, W_IDLE_M2 } w_grant_e;
    w_grant_e w_grant;
    logic     w_active;

    logic w_grant_m1_next, w_grant_m2_next;
    assign w_grant_m1_next = m1_axi_awvalid;
    assign w_grant_m2_next = m2_axi_awvalid && !m1_axi_awvalid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_grant  <= W_IDLE_M1;
            w_active <= 1'b0;
        end else begin
            if (s_axi_bvalid && s_axi_bready) begin
                // B complete: transition directly to a new transaction if one
                // is being accepted in the same cycle, otherwise go idle.
                // This mirrors the axi_xbar B+AW simultaneous handling and
                // prevents w_active_is_m1 from briefly de-asserting (which
                // would drop s_axi_wvalid) when B and the next AW coincide.
                if (w_grant_m1_next && s_axi_awready) begin
                    w_grant  <= W_IDLE_M1;
                    w_active <= 1'b1;
                end else if (w_grant_m2_next && s_axi_awready) begin
                    w_grant  <= W_IDLE_M2;
                    w_active <= 1'b1;
                end else begin
                    w_active <= 1'b0;
                end
            end else if (!w_active) begin
                if (w_grant_m1_next && s_axi_awready) begin
                    w_grant  <= W_IDLE_M1;
                    w_active <= 1'b1;
                end else if (w_grant_m2_next && s_axi_awready) begin
                    w_grant  <= W_IDLE_M2;
                    w_active <= 1'b1;
                end
            end
        end
    end

    // AW channel mux
    always_comb begin
        s_axi_awaddr   = '0;
        s_axi_awid     = '0;
        s_axi_awlen    = 8'h0;
        s_axi_awsize   = 3'b010;
        s_axi_awburst  = 2'b01;
        s_axi_awvalid  = 1'b0;
        m1_axi_awready = 1'b0;
        m2_axi_awready = 1'b0;

        if (!w_active) begin
            if (w_grant_m1_next) begin
                s_axi_awaddr   = m1_axi_awaddr;
                s_axi_awid     = {2'b10, m1_axi_awid[axi_pkg::AXI_ID_WIDTH-3:0]};
                s_axi_awlen    = m1_axi_awlen;
                s_axi_awsize   = m1_axi_awsize;
                s_axi_awburst  = m1_axi_awburst;
                s_axi_awvalid  = 1'b1;
                m1_axi_awready = s_axi_awready;
            end else if (w_grant_m2_next) begin
                s_axi_awaddr   = m2_axi_awaddr;
                s_axi_awid     = {2'b01, m2_axi_awid[axi_pkg::AXI_ID_WIDTH-3:0]};
                s_axi_awlen    = m2_axi_awlen;
                s_axi_awsize   = m2_axi_awsize;
                s_axi_awburst  = m2_axi_awburst;
                s_axi_awvalid  = 1'b1;
                m2_axi_awready = s_axi_awready;
            end
        end else begin
            if (w_grant == W_IDLE_M1) begin
                s_axi_awaddr   = m1_axi_awaddr;
                s_axi_awid     = {2'b10, m1_axi_awid[axi_pkg::AXI_ID_WIDTH-3:0]};
                s_axi_awlen    = m1_axi_awlen;
                s_axi_awsize   = m1_axi_awsize;
                s_axi_awburst  = m1_axi_awburst;
                s_axi_awvalid  = m1_axi_awvalid;
                m1_axi_awready = s_axi_awready;
            end else begin
                s_axi_awaddr   = m2_axi_awaddr;
                s_axi_awid     = {2'b01, m2_axi_awid[axi_pkg::AXI_ID_WIDTH-3:0]};
                s_axi_awlen    = m2_axi_awlen;
                s_axi_awsize   = m2_axi_awsize;
                s_axi_awburst  = m2_axi_awburst;
                s_axi_awvalid  = m2_axi_awvalid;
                m2_axi_awready = s_axi_awready;
            end
        end
    end

    // W channel mux
    logic w_active_is_m1;
    assign w_active_is_m1 = (!w_active && w_grant_m1_next) ||
                             ( w_active && w_grant == W_IDLE_M1);

    always_comb begin
        s_axi_wdata   = '0;
        s_axi_wstrb   = '0;
        s_axi_wlast   = 1'b0;
        s_axi_wvalid  = 1'b0;
        m1_axi_wready = 1'b0;
        m2_axi_wready = 1'b0;

        if (w_active_is_m1) begin
            s_axi_wdata   = m1_axi_wdata;
            s_axi_wstrb   = m1_axi_wstrb;
            s_axi_wlast   = m1_axi_wlast;
            s_axi_wvalid  = m1_axi_wvalid;
            m1_axi_wready = s_axi_wready;
        end else if ((!w_active && w_grant_m2_next) || (w_active && w_grant == W_IDLE_M2)) begin
            s_axi_wdata   = m2_axi_wdata;
            s_axi_wstrb   = m2_axi_wstrb;
            s_axi_wlast   = m2_axi_wlast;
            s_axi_wvalid  = m2_axi_wvalid;
            m2_axi_wready = s_axi_wready;
        end
    end

    // B channel demux
    always_comb begin
        s_axi_bready  = 1'b0;
        m1_axi_bresp  = 2'b00; m1_axi_bid = '0; m1_axi_bvalid = 1'b0;
        m2_axi_bresp  = 2'b00; m2_axi_bid = '0; m2_axi_bvalid = 1'b0;
        if (s_axi_bvalid) begin
            if (s_axi_bid[axi_pkg::AXI_ID_WIDTH-1:axi_pkg::AXI_ID_WIDTH-2] == 2'b10) begin
                m1_axi_bresp  = s_axi_bresp;
                m1_axi_bid    = {{(axi_pkg::AXI_ID_WIDTH-2){1'b0}}, s_axi_bid[axi_pkg::AXI_ID_WIDTH-3:0]};
                m1_axi_bvalid = 1'b1;
                s_axi_bready  = m1_axi_bready;
            end else begin
                m2_axi_bresp  = s_axi_bresp;
                m2_axi_bid    = {{(axi_pkg::AXI_ID_WIDTH-2){1'b0}}, s_axi_bid[axi_pkg::AXI_ID_WIDTH-3:0]};
                m2_axi_bvalid = 1'b1;
                s_axi_bready  = m2_axi_bready;
            end
        end
    end

    // ========================================================================
    // AR Channel: 3-way round-robin (M0 -> M1 -> M2 -> M0)
    // ========================================================================
    localparam int MAX_CONSECUTIVE_AR = 2;
    logic [$clog2(MAX_CONSECUTIVE_AR+1):0] m0_ar_count;
    logic [$clog2(MAX_CONSECUTIVE_AR+1):0] m1_ar_count;
    logic [$clog2(MAX_CONSECUTIVE_AR+1):0] m2_ar_count;

    typedef enum logic [1:0] {
        AR_MASTER0 = 2'd0,
        AR_MASTER1 = 2'd1,
        AR_MASTER2 = 2'd2
    } ar_state_e;

    ar_state_e ar_state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_state    <= AR_MASTER0;
            m0_ar_count <= '0;
            m1_ar_count <= '0;
            m2_ar_count <= '0;
        end else begin
            case (ar_state)
                AR_MASTER0: begin
                    if (m0_axi_arvalid && m0_axi_arready) m0_ar_count <= m0_ar_count + 1'b1;
                    if (m1_axi_arvalid || m2_axi_arvalid) begin
                        if (!m0_axi_arvalid ||
                            (m0_axi_arvalid && m0_axi_arready &&
                             m0_ar_count + 1'b1 >= MAX_CONSECUTIVE_AR[$clog2(MAX_CONSECUTIVE_AR+1):0])) begin
                            ar_state    <= m1_axi_arvalid ? AR_MASTER1 : AR_MASTER2;
                            m0_ar_count <= '0;
                        end
                    end
                end
                AR_MASTER1: begin
                    if (m1_axi_arvalid && m1_axi_arready) m1_ar_count <= m1_ar_count + 1'b1;
                    if (m2_axi_arvalid || m0_axi_arvalid) begin
                        if (!m1_axi_arvalid ||
                            (m1_axi_arvalid && m1_axi_arready &&
                             m1_ar_count + 1'b1 >= MAX_CONSECUTIVE_AR[$clog2(MAX_CONSECUTIVE_AR+1):0])) begin
                            ar_state    <= m2_axi_arvalid ? AR_MASTER2 : AR_MASTER0;
                            m1_ar_count <= '0;
                        end
                    end
                end
                AR_MASTER2: begin
                    if (m2_axi_arvalid && m2_axi_arready) m2_ar_count <= m2_ar_count + 1'b1;
                    if (m0_axi_arvalid || m1_axi_arvalid) begin
                        if (!m2_axi_arvalid ||
                            (m2_axi_arvalid && m2_axi_arready &&
                             m2_ar_count + 1'b1 >= MAX_CONSECUTIVE_AR[$clog2(MAX_CONSECUTIVE_AR+1):0])) begin
                            ar_state    <= m0_axi_arvalid ? AR_MASTER0 : AR_MASTER1;
                            m2_ar_count <= '0;
                        end
                    end
                end
                default: ar_state <= AR_MASTER0;
            endcase
        end
    end

    // AR mux — ID bits[3:2]: M0=2'b00, M1=2'b10, M2=2'b01
    always_comb begin
        s_axi_araddr   = 32'h0;
        s_axi_arid     = '0;
        s_axi_arlen    = 8'h0;
        s_axi_arsize   = 3'b010;
        s_axi_arburst  = 2'b01;
        s_axi_arvalid  = 1'b0;
        m0_axi_arready = 1'b0;
        m1_axi_arready = 1'b0;
        m2_axi_arready = 1'b0;

        case (ar_state)
            AR_MASTER0: begin
                s_axi_araddr   = m0_axi_araddr;
                s_axi_arid     = {2'b00, m0_axi_arid[axi_pkg::AXI_ID_WIDTH-3:0]};
                s_axi_arlen    = m0_axi_arlen;
                s_axi_arsize   = m0_axi_arsize;
                s_axi_arburst  = m0_axi_arburst;
                s_axi_arvalid  = m0_axi_arvalid;
                m0_axi_arready = s_axi_arready;
            end
            AR_MASTER1: begin
                s_axi_araddr   = m1_axi_araddr;
                s_axi_arid     = {2'b10, m1_axi_arid[axi_pkg::AXI_ID_WIDTH-3:0]};
                s_axi_arlen    = m1_axi_arlen;
                s_axi_arsize   = m1_axi_arsize;
                s_axi_arburst  = m1_axi_arburst;
                s_axi_arvalid  = m1_axi_arvalid;
                m1_axi_arready = s_axi_arready;
            end
            AR_MASTER2: begin
                s_axi_araddr   = m2_axi_araddr;
                s_axi_arid     = {2'b01, m2_axi_arid[axi_pkg::AXI_ID_WIDTH-3:0]};
                s_axi_arlen    = m2_axi_arlen;
                s_axi_arsize   = m2_axi_arsize;
                s_axi_arburst  = m2_axi_arburst;
                s_axi_arvalid  = m2_axi_arvalid;
                m2_axi_arready = s_axi_arready;
            end
            default: ;
        endcase
    end

    // ========================================================================
    // R Channel: demux by rid[3:2]   2'b00->M0, 2'b10->M1, 2'b01->M2
    // ========================================================================
    always_comb begin
        s_axi_rready  = 1'b0;
        m0_axi_rdata  = 32'h0; m0_axi_rresp = 2'b00; m0_axi_rid = '0;
        m0_axi_rlast  = 1'b0;  m0_axi_rvalid = 1'b0;
        m1_axi_rdata  = 32'h0; m1_axi_rresp = 2'b00; m1_axi_rid = '0;
        m1_axi_rlast  = 1'b0;  m1_axi_rvalid = 1'b0;
        m2_axi_rdata  = 32'h0; m2_axi_rresp = 2'b00; m2_axi_rid = '0;
        m2_axi_rlast  = 1'b0;  m2_axi_rvalid = 1'b0;

        if (s_axi_rvalid) begin
            case (s_axi_rid[axi_pkg::AXI_ID_WIDTH-1:axi_pkg::AXI_ID_WIDTH-2])
                2'b10: begin
                    m1_axi_rdata  = s_axi_rdata;
                    m1_axi_rresp  = s_axi_rresp;
                    m1_axi_rid    = {{(axi_pkg::AXI_ID_WIDTH-2){1'b0}}, s_axi_rid[axi_pkg::AXI_ID_WIDTH-3:0]};
                    m1_axi_rlast  = s_axi_rlast;
                    m1_axi_rvalid = 1'b1;
                    s_axi_rready  = m1_axi_rready;
                end
                2'b01: begin
                    m2_axi_rdata  = s_axi_rdata;
                    m2_axi_rresp  = s_axi_rresp;
                    m2_axi_rid    = {{(axi_pkg::AXI_ID_WIDTH-2){1'b0}}, s_axi_rid[axi_pkg::AXI_ID_WIDTH-3:0]};
                    m2_axi_rlast  = s_axi_rlast;
                    m2_axi_rvalid = 1'b1;
                    s_axi_rready  = m2_axi_rready;
                end
                default: begin
                    m0_axi_rdata  = s_axi_rdata;
                    m0_axi_rresp  = s_axi_rresp;
                    m0_axi_rid    = {{(axi_pkg::AXI_ID_WIDTH-2){1'b0}}, s_axi_rid[axi_pkg::AXI_ID_WIDTH-3:0]};
                    m0_axi_rlast  = s_axi_rlast;
                    m0_axi_rvalid = 1'b1;
                    s_axi_rready  = m0_axi_rready;
                end
            endcase
        end
    end

    // ========================================================================
    // AXI4 Protocol Assertions
    // ========================================================================
`ifndef NO_ASSERTION
`ifndef ASSERTION
`define ASSERTION
`endif
`endif // NO_ASSERTION

`ifdef ASSERTION

    // M0 AR channel stability
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

    // M1 AW/W/AR channel stability
    property p_m1_awvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (m1_axi_awvalid && !m1_axi_awready) |=> $stable(m1_axi_awvalid);
    endproperty
    assert property (p_m1_awvalid_stable)
        else $error("[AXI_ARBITER] M1 AWVALID must remain stable until AWREADY");

    property p_m1_wvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (m1_axi_wvalid && !m1_axi_wready) |=> $stable(m1_axi_wvalid);
    endproperty
    assert property (p_m1_wvalid_stable)
        else $error("[AXI_ARBITER] M1 WVALID must remain stable until WREADY");

    property p_m1_arvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (m1_axi_arvalid && !m1_axi_arready) |=> $stable(m1_axi_arvalid);
    endproperty
    assert property (p_m1_arvalid_stable)
        else $error("[AXI_ARBITER] M1 ARVALID must remain stable until ARREADY");

    // M2 AW/W/AR channel stability
    property p_m2_awvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (m2_axi_awvalid && !m2_axi_awready) |=> $stable(m2_axi_awvalid);
    endproperty
    assert property (p_m2_awvalid_stable)
        else $error("[AXI_ARBITER] M2 AWVALID must remain stable until AWREADY");

    property p_m2_wvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (m2_axi_wvalid && !m2_axi_wready) |=> $stable(m2_axi_wvalid);
    endproperty
    assert property (p_m2_wvalid_stable)
        else $error("[AXI_ARBITER] M2 WVALID must remain stable until WREADY");

    property p_m2_arvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (m2_axi_arvalid && !m2_axi_arready) |=> $stable(m2_axi_arvalid);
    endproperty
    assert property (p_m2_arvalid_stable)
        else $error("[AXI_ARBITER] M2 ARVALID must remain stable until ARREADY");

    // Slave channel stability
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

    // ID encoding correctness
    property p_id_enc_m0;
        @(posedge clk) disable iff (!rst_n)
        (s_axi_arvalid && ar_state == AR_MASTER0) |->
            (s_axi_arid[axi_pkg::AXI_ID_WIDTH-1:axi_pkg::AXI_ID_WIDTH-2] == 2'b00);
    endproperty
    assert property (p_id_enc_m0)
        else $error("[AXI_ARBITER] M0 AR ID bits[3:2] must be 2'b00");

    property p_id_enc_m1;
        @(posedge clk) disable iff (!rst_n)
        (s_axi_arvalid && ar_state == AR_MASTER1) |->
            (s_axi_arid[axi_pkg::AXI_ID_WIDTH-1:axi_pkg::AXI_ID_WIDTH-2] == 2'b10);
    endproperty
    assert property (p_id_enc_m1)
        else $error("[AXI_ARBITER] M1 AR ID bits[3:2] must be 2'b10");

    property p_id_enc_m2;
        @(posedge clk) disable iff (!rst_n)
        (s_axi_arvalid && ar_state == AR_MASTER2) |->
            (s_axi_arid[axi_pkg::AXI_ID_WIDTH-1:axi_pkg::AXI_ID_WIDTH-2] == 2'b01);
    endproperty
    assert property (p_id_enc_m2)
        else $error("[AXI_ARBITER] M2 AR ID bits[3:2] must be 2'b01");

`ifndef SYNTHESIS
    // Lint sink (debug only): upper 2 bits of master request IDs are not propagated;
    // the arbiter encodes the master index in those bits on its output ID.
    logic _unused_ok;
    assign _unused_ok = &{1'b0, m0_axi_arid[3:2], m1_axi_awid[3:2], m1_axi_arid[3:2],
                                m2_axi_awid[3:2], m2_axi_arid[3:2]};
`endif // SYNTHESIS

`endif // ASSERTION

endmodule


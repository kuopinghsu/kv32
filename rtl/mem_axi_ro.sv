// ============================================================================
// File: mem_axi_ro.sv
// Project: KV32 RISC-V Processor
// Description: Memory Interface to AXI4 Bridge (Read-Only)
//
// Converts simple memory-mapped interface to AXI4 read protocol.
// Optimized read-only version used for instruction memory interface.
// Only AR and R channels are used (no write channels).
//
// Features:
//   - Read-only operation
//   - Multiple outstanding transactions (configurable depth)
//   - AXI ID tracking for transaction ordering
//   - Configurable address and data widths
//   - Error response propagation
// ============================================================================

`ifdef SYNTHESIS
import kv32_pkg::*;
import axi_pkg::*;
`endif

module mem_axi_ro #(
`ifndef SYNTHESIS
    parameter string BRIDGE_NAME = "AXI_BRIDGE_RO",
`endif
    parameter int    OUTSTANDING_DEPTH = 4  // Max outstanding transactions (2-16)
) (
    input  logic        clk,
    input  logic        rst_n,

    // 3-channel memory interface (slave) - Read-only
    input  logic        mem_req_valid,
    input  logic [31:0] mem_req_addr,
    output logic        mem_req_ready,

    output logic        mem_resp_valid,
    output logic [31:0] mem_resp_data,
    output logic        mem_resp_error,
    input  logic        mem_resp_ready,

    // AXI4 interface (master) - AR and R channels only with ID support
    output logic [31:0]              axi_araddr,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] axi_arid,
    output logic                     axi_arvalid,
    input  logic                     axi_arready,

    input  logic [31:0]              axi_rdata,
    input  logic [1:0]               axi_rresp,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] axi_rid,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic                     axi_rvalid,
    output logic                     axi_rready
);
`ifndef SYNTHESIS
    import kv32_pkg::*;
    import axi_pkg::*;
`endif

    // ========================================================================
    // Transaction tracking
    // ========================================================================
    localparam int ID_WIDTH = axi_pkg::AXI_ID_WIDTH;

    // Use constant ID to enforce in-order responses (no reorder buffer)
    localparam logic [ID_WIDTH-1:0] CONST_ID = '0;

    // ========================================================================
    // AR Channel (Read Address) - Zero-latency combinational pass-through
    // ========================================================================
    // Performance rationale:
    //   The original design registered axi_arvalid, adding +1 cycle from
    //   mem_req_valid to AXI AR acceptance.  With MEM_READ_LATENCY=1 this
    //   made the round-trip 2+ cycles, preventing IB_DEPTH=2 from sustaining
    //   1 fetch/cycle.  Even with the combinational bypass, the AXI path
    //   (arbiter + crossbar) adds 2 effective cycles, so IB_DEPTH=4 is used.
    //
    //   Here axi_arvalid is driven combinationally: when axi_arready=1, the
    //   request is accepted the same cycle it is presented.  A fall-through
    //   skid buffer (ar_buf) absorbs the one cycle where axi_arready=0.
    //
    //   With this change and axi_rvalid bypass below, the effective fetch
    //   round-trip is 2 cycles (AXI arbiter + crossbar + 1-cycle RAM), so
    //   IB_DEPTH=4 (power-of-2) is needed to avoid FIFO aliasing at full depth.
    // ========================================================================

    logic [31:0] ar_buf_addr;
    logic        ar_buf_valid;
    logic [31:0] ar_buf_addr_next;
    logic        ar_buf_valid_next;

    // Skid buffer: captures requests that cannot go directly to AXI AR this cycle
    // because axi_arready=0.  The buffer holds at most one pending address.
    always_comb begin
        ar_buf_valid_next = ar_buf_valid;
        ar_buf_addr_next  = ar_buf_addr;
        if (ar_buf_valid && axi_arready) begin
            // Buffer drained
            ar_buf_valid_next = 1'b0;
        end else if (!ar_buf_valid && axi_arvalid && !axi_arready && mem_req_valid && mem_req_ready) begin
            // AR channel stalled AND new request coming in - buffer it
            ar_buf_valid_next = 1'b1;
            ar_buf_addr_next  = mem_req_addr;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_buf_valid <= 1'b0;
            ar_buf_addr  <= 32'h0;
        end else begin
            ar_buf_valid <= ar_buf_valid_next;
            ar_buf_addr  <= ar_buf_addr_next;
            if (ar_buf_valid_next && !ar_buf_valid)
                `DEBUG2(`DBG_GRP_AXI, ("%s: AR buffered addr=0x%h", BRIDGE_NAME, ar_buf_addr_next));
            if (ar_buf_valid && !ar_buf_valid_next)
                `DEBUG2(`DBG_GRP_AXI, ("%s: AR buffer drained", BRIDGE_NAME));
        end
    end

    // Combinational AXI AR outputs - zero latency from request to bus
    // Priority: skid buffer contents go first (FIFO order preservation)
    assign axi_arvalid = ar_buf_valid || (mem_req_valid && mem_req_ready && !ar_buf_valid);
    assign axi_araddr  = ar_buf_valid ? ar_buf_addr : mem_req_addr;
    assign axi_arid    = CONST_ID;

    // Track outstanding read transactions (AR accepted → waiting for R)
    logic [$clog2(OUTSTANDING_DEPTH+1):0] read_outstanding_count;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_outstanding_count <= '0;
        end else begin
            case ({axi_arvalid && axi_arready, axi_rvalid && axi_rready})
                2'b10: read_outstanding_count <= read_outstanding_count + 1; // AR accept
                2'b01: read_outstanding_count <= read_outstanding_count - 1; // R receive
                default: ; // Both or neither
            endcase
        end
    end

    // read_fifo_full: total slots occupied (in-flight + buffered)
    // The ar_buf counts as 1 pending request that hasn't hit AXI yet.
    logic [$clog2(OUTSTANDING_DEPTH+2):0] total_requests;
    logic read_fifo_full;
    assign total_requests = ($bits(total_requests))'(read_outstanding_count) +
                            ($bits(total_requests))'(ar_buf_valid);
    assign read_fifo_full = (total_requests >= ($bits(total_requests))'(OUTSTANDING_DEPTH));

    // ========================================================================
    // mem_req_ready: Can accept new request when:
    //   1. AR channel can take it (arready=1 and no skid buffer) OR skid buf empty
    //   2. Total outstanding does not exceed depth
    // ========================================================================
    logic ar_can_accept;
    assign ar_can_accept = !ar_buf_valid;   // skid buffer must be empty to accept
    assign mem_req_ready = ar_can_accept && !read_fifo_full;

    // ========================================================================
    // R Channel (Read Data) - bypass FIFO on empty for zero-latency response
    // ========================================================================
    // Performance rationale:
    //   The original design always pushed axi_rdata into a registered FIFO,
    //   adding +1 cycle before mem_resp_valid could rise.  When the FIFO is
    //   empty and the core is ready to consume, we bypass by forwarding
    //   axi_rdata directly as mem_resp_valid/data, accepting on the same cycle.
    //   This eliminates the store-then-load latency for the common case.
    //   When the FIFO already has entries (core is stalled), responses still
    //   enter the FIFO to preserve ordering.
    // ========================================================================
    // Response FIFO as flat arrays (synthesis-compatible)
    logic [31:0] fifo_data [0:OUTSTANDING_DEPTH-1];
    logic        fifo_error[0:OUTSTANDING_DEPTH-1];
    logic [$clog2(OUTSTANDING_DEPTH):0] resp_wr_ptr;
    logic [$clog2(OUTSTANDING_DEPTH):0] resp_rd_ptr;
    logic [$clog2(OUTSTANDING_DEPTH):0] resp_count;
    logic resp_fifo_empty;
    logic resp_fifo_full;

    logic resp_push;    // AXI R data pushed into FIFO
    logic resp_bypass;  // AXI R data bypasses FIFO directly to core

    assign resp_fifo_empty = (resp_count == 0);
    assign resp_fifo_full  = (resp_count >= ($bits(resp_count))'(OUTSTANDING_DEPTH));

    // Bypass condition: FIFO empty AND core can consume immediately
    assign resp_bypass = axi_rvalid && resp_fifo_empty && mem_resp_ready;
    // Push to FIFO when response arrives but cannot bypass (FIFO not empty or core stalled)
    assign resp_push   = axi_rvalid && !resp_bypass;
    assign axi_rready  = !resp_fifo_full;  // Always ready unless FIFO full

    // Core-facing response: bypass has priority over FIFO
    assign mem_resp_valid = axi_rvalid && resp_fifo_empty ? 1'b1 :  // bypass path
                            (resp_count > 0);                        // FIFO path
    assign mem_resp_data  = (axi_rvalid && resp_fifo_empty) ? axi_rdata :
                            fifo_data[resp_rd_ptr[$clog2(OUTSTANDING_DEPTH)-1:0]];
    assign mem_resp_error = (axi_rvalid && resp_fifo_empty) ? (axi_rresp != 2'b00) :
                            fifo_error[resp_rd_ptr[$clog2(OUTSTANDING_DEPTH)-1:0]];

    logic resp_pop;
    assign resp_pop = mem_resp_valid && mem_resp_ready && !resp_fifo_empty;

    // FIFO management
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_wr_ptr <= '0;
            resp_rd_ptr <= '0;
            resp_count  <= '0;
        end else begin
            if (resp_push) begin
                fifo_data [resp_wr_ptr[$clog2(OUTSTANDING_DEPTH)-1:0]] <= axi_rdata;
                fifo_error[resp_wr_ptr[$clog2(OUTSTANDING_DEPTH)-1:0]] <= (axi_rresp != 2'b00);
                resp_wr_ptr <= resp_wr_ptr + 1'b1;
                `DEBUG2(`DBG_GRP_AXI, ("%s: R FIFO push data=0x%h resp=%0d count=%0d", BRIDGE_NAME, axi_rdata, axi_rresp, resp_count + 1));
            end
            if (resp_pop) begin
                resp_rd_ptr <= resp_rd_ptr + 1'b1;
                `DEBUG2(`DBG_GRP_AXI, ("%s: mem_resp FIFO consumed count=%0d", BRIDGE_NAME, resp_count - 1));
            end
            if (resp_bypass)
                `DEBUG2(`DBG_GRP_AXI, ("%s: mem_resp BYPASS data=0x%h", BRIDGE_NAME, axi_rdata));

            case ({resp_push, resp_pop})
                2'b10: resp_count <= resp_count + 1'b1;
                2'b01: resp_count <= resp_count - 1'b1;
                default: ;
            endcase
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

    // AR Channel (Read Address)
    property p_arvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_arvalid && !axi_arready) |=> $stable(axi_arvalid);
    endproperty
    assert property (p_arvalid_stable)
        else $error("[%s] ARVALID must remain stable until ARREADY", BRIDGE_NAME);

    property p_araddr_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_arvalid && !axi_arready) |=> $stable(axi_araddr);
    endproperty
    assert property (p_araddr_stable)
        else $error("[%s] ARADDR must remain stable while ARVALID is high", BRIDGE_NAME);

    property p_arid_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_arvalid && !axi_arready) |=> $stable(axi_arid);
    endproperty
    assert property (p_arid_stable)
        else $error("[%s] ARID must remain stable while ARVALID is high", BRIDGE_NAME);

    property p_arid_constant;
        @(posedge clk) disable iff (!rst_n)
        axi_arvalid |-> (axi_arid == CONST_ID);
    endproperty
    assert property (p_arid_constant)
        else $error("[%s] ARID must be constant (0x%h)", BRIDGE_NAME, CONST_ID);

    // R Channel (Read Data)
    // Note: RREADY is allowed to change per AXI spec, so no stability assertion needed
    // The response FIFO provides backpressure through axi_rready signal

    // Outstanding Transaction Bounds
    property p_read_outstanding_bounds;
        @(posedge clk) disable iff (!rst_n)
        read_outstanding_count <= ($bits(read_outstanding_count))'(OUTSTANDING_DEPTH);
    endproperty
    assert property (p_read_outstanding_bounds)
        else $error("[%s] Read outstanding count exceeded limit: %0d > %0d",
                    BRIDGE_NAME, read_outstanding_count, OUTSTANDING_DEPTH);

    property p_total_requests_bounds;
        @(posedge clk) disable iff (!rst_n)
        total_requests <= ($bits(total_requests))'(OUTSTANDING_DEPTH + 1);  // outstanding + at most 1 skid buf
    endproperty
    assert property (p_total_requests_bounds)
        else $error("[%s] Total requests exceeded limit: %0d", BRIDGE_NAME, total_requests);

    // Response FIFO Integrity
    property p_resp_fifo_no_overflow;
        @(posedge clk) disable iff (!rst_n)
        (axi_rvalid && axi_rready) |-> !resp_fifo_full;
    endproperty
    assert property (p_resp_fifo_no_overflow)
        else $error("[%s] Response FIFO overflow detected", BRIDGE_NAME);

    // Note: mem_resp can be valid via bypass (resp_count=0 but axi_rvalid=1), so
    // underflow check must exclude the bypass path
    property p_resp_fifo_no_underflow;
        @(posedge clk) disable iff (!rst_n)
        (resp_pop) |-> (resp_count > 0);
    endproperty
    assert property (p_resp_fifo_no_underflow)
        else $error("[%s] Response FIFO underflow detected", BRIDGE_NAME);

    property p_resp_count_bounds;
        @(posedge clk) disable iff (!rst_n)
        resp_count <= ($bits(resp_count))'(OUTSTANDING_DEPTH);
    endproperty
    assert property (p_resp_count_bounds)
        else $error("[%s] Response FIFO count exceeded: %0d > %0d",
                    BRIDGE_NAME, resp_count, OUTSTANDING_DEPTH);

    // X/Z Detection
    property p_no_x_mem_req_valid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(mem_req_valid);
    endproperty
    assert property (p_no_x_mem_req_valid)
        else $error("[%s] X/Z detected on mem_req_valid", BRIDGE_NAME);

    property p_no_x_mem_resp_ready;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(mem_resp_ready);
    endproperty
    assert property (p_no_x_mem_resp_ready)
        else $error("[%s] X/Z detected on mem_resp_ready", BRIDGE_NAME);

    property p_no_x_axi_arready;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(axi_arready);
    endproperty
    assert property (p_no_x_axi_arready)
        else $error("[%s] X/Z detected on axi_arready", BRIDGE_NAME);

    property p_no_x_axi_rvalid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(axi_rvalid);
    endproperty
    assert property (p_no_x_axi_rvalid)
        else $error("[%s] X/Z detected on axi_rvalid", BRIDGE_NAME);

    // Memory Interface Protocol
    property p_mem_req_ready_stable;
        @(posedge clk) disable iff (!rst_n)
        (mem_req_valid && !mem_req_ready) |=> mem_req_valid;
    endproperty
    assert property (p_mem_req_ready_stable)
        else $warning("[%s] mem_req_valid deasserted before mem_req_ready", BRIDGE_NAME);

    // mem_resp stability: only applies when sourced from FIFO (bypass is always consumed immediately)
    property p_mem_resp_stable;
        @(posedge clk) disable iff (!rst_n)
        (mem_resp_valid && !mem_resp_ready && !resp_fifo_empty) |=> $stable(mem_resp_data) && $stable(mem_resp_error);
    endproperty
    assert property (p_mem_resp_stable)
        else $error("[%s] mem_resp signals must remain stable until mem_resp_ready", BRIDGE_NAME);

`endif // ASSERTION

endmodule


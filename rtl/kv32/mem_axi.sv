// ============================================================================
// File: mem_axi.sv
// Project: KV32 RISC-V Processor
// Description: Memory Interface to AXI4 Bridge (Read/Write)
//
// Converts simple memory-mapped interface to AXI4 protocol.
// Supports both read and write operations with byte-level write strobes.
// Used for data memory interface from the processor core.
//
// Features:
//   - All 5 AXI channels operate independently for maximum throughput
//   - Multiple outstanding transactions (configurable depth)
//   - AXI ID tracking for transaction ordering
//   - Configurable address and data widths
//   - Byte-enable support via write strobes
//   - Error response propagation
// ============================================================================

`ifdef SYNTHESIS
import kv32_pkg::*;
import axi_pkg::*;
`endif

module mem_axi #(
`ifndef SYNTHESIS
    parameter string BRIDGE_NAME = "AXI_BRIDGE",
`endif
    parameter int    OUTSTANDING_DEPTH = 4  // Max outstanding transactions (2-16)
) (
    input  logic        clk,
    input  logic        rst_n,

    // 3-channel memory interface (slave)
    input  logic        mem_req_valid,
    input  logic [31:0] mem_req_addr,
    input  logic [3:0]  mem_req_we,      // 4'h0 = read, non-zero = write
    input  logic [31:0] mem_req_wdata,
    output logic        mem_req_ready,

    output logic        mem_resp_valid,
    output logic [31:0] mem_resp_data,
    output logic        mem_resp_error,
    output logic        mem_resp_is_write, // 1=B response (store complete), 0=R response (load data)
    input  logic        mem_resp_ready,

    // AXI4 interface (master) - 5 independent channels with ID support
    output logic [31:0]              axi_awaddr,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] axi_awid,
    output logic                     axi_awvalid,
    input  logic                     axi_awready,

    output logic [31:0]              axi_wdata,
    output logic [3:0]               axi_wstrb,
    output logic                     axi_wvalid,
    input  logic                     axi_wready,

    input  logic [1:0]               axi_bresp,
    /* verilator lint_off UNUSEDSIGNAL */  // Upper bits unused: bridge uses low ID_BITS as slot index
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] axi_bid,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic                     axi_bvalid,
    output logic                     axi_bready,

    output logic [31:0]              axi_araddr,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] axi_arid,
    output logic                     axi_arvalid,
    input  logic                     axi_arready,

    input  logic [31:0]              axi_rdata,
    input  logic [1:0]               axi_rresp,
    /* verilator lint_off UNUSEDSIGNAL */  // Upper bits unused: bridge uses low ID_BITS as slot index
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] axi_rid,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic                     axi_rlast,   // Always 1 for single-beat; checked by assertion
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
    localparam int ID_BITS  = $clog2(OUTSTANDING_DEPTH);  // Bits needed to index slots

    logic is_read_req;
    logic is_write_req;

    assign is_read_req  = mem_req_valid && (mem_req_we == 4'h0);
    assign is_write_req = mem_req_valid && (mem_req_we != 4'h0);

    // Per-transaction IDs — each outstanding read/write gets a unique ID
    // (low ID_BITS bits of a wrapping counter, used as slot index)
    logic [ID_BITS-1:0] rd_issue_id;   // ARID assigned to next issued read
    logic [ID_BITS-1:0] wr_issue_id;   // AWID assigned to next issued write

    // Transaction counters (used for outstanding-bounds assertions only)
    logic [$clog2(OUTSTANDING_DEPTH):0] read_outstanding_count;
    logic [$clog2(OUTSTANDING_DEPTH):0] write_outstanding_count;

    // ========================================================================
    // Read response slots — indexed by ARID
    // ========================================================================
    logic [31:0] rd_slot_data [0:OUTSTANDING_DEPTH-1];
    logic        rd_slot_error[0:OUTSTANDING_DEPTH-1];
    logic        rd_slot_valid[0:OUTSTANDING_DEPTH-1];  // Response arrived for this slot

    // ========================================================================
    // Write response slots — indexed by AWID
    // ========================================================================
    logic        wr_slot_error[0:OUTSTANDING_DEPTH-1];
    logic        wr_slot_valid[0:OUTSTANDING_DEPTH-1];  // B response arrived

    // ========================================================================
    // Order FIFO — records issue order (read vs write + ID) for in-order delivery
    // ========================================================================
    localparam int ORDER_DEPTH = OUTSTANDING_DEPTH * 2;

    logic                  order_is_write[0:ORDER_DEPTH-1];
    logic [ID_BITS-1:0]    order_id      [0:ORDER_DEPTH-1];
    logic [$clog2(ORDER_DEPTH):0] order_wr_ptr;
    logic [$clog2(ORDER_DEPTH):0] order_rd_ptr;
    logic [$clog2(ORDER_DEPTH):0] order_count;
    logic order_fifo_full;

    assign order_fifo_full = (int'(order_count) >= ORDER_DEPTH);

    // Head-of-order-FIFO signals (combinational)
    logic                order_head_is_write;
    logic [ID_BITS-1:0]  order_head_id;

    assign order_head_is_write = order_is_write[order_rd_ptr[$clog2(ORDER_DEPTH)-1:0]];
    assign order_head_id       = order_id      [order_rd_ptr[$clog2(ORDER_DEPTH)-1:0]];

    // Slots are "full" when the next-to-issue slot still holds an unconsumed response
    logic read_fifo_full;
    logic write_fifo_full;

    assign read_fifo_full  = rd_slot_valid[rd_issue_id];
    assign write_fifo_full = wr_slot_valid[wr_issue_id];

    // ========================================================================
    // AR Channel (Read Address) - Use per-transaction rd_issue_id
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_arvalid <= 1'b0;
            axi_araddr  <= 32'h0;
            axi_arid    <= '0;
            rd_issue_id <= '0;
        end else begin
            if (is_read_req && mem_req_ready && !axi_arvalid) begin
                // Launch read request on AR channel with current slot ID
                axi_arvalid <= 1'b1;
                axi_araddr  <= mem_req_addr;
                axi_arid    <= ID_WIDTH'(rd_issue_id);
                `DEBUG2(`DBG_GRP_AXI, ("%s: AR launch addr=0x%h id=%0d", BRIDGE_NAME, mem_req_addr, rd_issue_id));
            end else if (axi_arvalid && axi_arready) begin
                // AR handshake complete — advance to next slot ID
                axi_arvalid <= 1'b0;
                rd_issue_id <= rd_issue_id + 1'd1;
                `DEBUG2(`DBG_GRP_AXI, ("%s: AR accepted id=%0d", BRIDGE_NAME, rd_issue_id));
            end
        end
    end

    // Track outstanding read transactions
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

    // ========================================================================
    // R Channel (Read Data) - Receives responses indexed by RID
    // ========================================================================
    // axi_rready: ready when the slot for the incoming RID is free
    assign axi_rready = !rd_slot_valid[axi_rid[ID_BITS-1:0]];

    // ========================================================================
    // AW Channel (Write Address) - Use per-transaction wr_issue_id
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_awvalid <= 1'b0;
            axi_awaddr  <= 32'h0;
            axi_awid    <= '0;
            wr_issue_id <= '0;
        end else begin
            if (is_write_req && mem_req_ready && !axi_awvalid) begin
                // Launch write address on AW channel with current slot ID
                axi_awvalid <= 1'b1;
                axi_awaddr  <= mem_req_addr;
                axi_awid    <= ID_WIDTH'(wr_issue_id);
                `DEBUG2(`DBG_GRP_AXI, ("%s: AW launch addr=0x%h id=%0d", BRIDGE_NAME, mem_req_addr, wr_issue_id));
            end else if (axi_awvalid && axi_awready) begin
                // AW handshake complete — advance to next slot ID
                axi_awvalid <= 1'b0;
                wr_issue_id <= wr_issue_id + 1'd1;
                `DEBUG2(`DBG_GRP_AXI, ("%s: AW accepted id=%0d", BRIDGE_NAME, wr_issue_id));
            end
        end
    end

    // Track outstanding write transactions
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_outstanding_count <= '0;
        end else begin
            case ({axi_awvalid && axi_awready, axi_bvalid && axi_bready})
                2'b10: write_outstanding_count <= write_outstanding_count + 1; // AW accept
                2'b01: write_outstanding_count <= write_outstanding_count - 1; // B receive
                default: ; // Both or neither
            endcase
        end
    end

    // ========================================================================
    // W Channel (Write Data) - Independent operation
    // Note: W channel doesn't have ID in AXI4, relies on ordering
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_wvalid <= 1'b0;
            axi_wdata  <= 32'h0;
            axi_wstrb  <= 4'h0;
        end else begin
            if (is_write_req && mem_req_ready && !axi_wvalid) begin
                // Launch write data on W channel (same time as AW)
                axi_wvalid <= 1'b1;
                axi_wdata  <= mem_req_wdata;
                axi_wstrb  <= mem_req_we;
                `DEBUG2(`DBG_GRP_AXI, ("%s: W launch data=0x%h strb=0x%h", BRIDGE_NAME, mem_req_wdata, mem_req_we));
            end else if (axi_wvalid && axi_wready) begin
                // W handshake complete
                axi_wvalid <= 1'b0;
                `DEBUG2(`DBG_GRP_AXI, ("%s: W accepted", BRIDGE_NAME));
            end else if (axi_wvalid && !axi_wready) begin
                `DEBUG2(`DBG_GRP_AXI, ("%s: W waiting for wready", BRIDGE_NAME));
            end
        end
    end

    // axi_bready: ready when the write slot for the incoming BID is free.
    // R and B now use independent slot arrays so they can be accepted simultaneously.
    assign axi_bready = !wr_slot_valid[axi_bid[ID_BITS-1:0]];

    // ========================================================================
    // mem_req_ready: Can accept new request when channels and slots have space
    // ========================================================================
    assign mem_req_ready = !axi_arvalid && !axi_awvalid && !axi_wvalid &&
                           !read_fifo_full && !write_fifo_full && !order_fifo_full;

    always_ff @(posedge clk) begin
        if (mem_req_valid && !mem_req_ready) begin
            `DEBUG2(`DBG_GRP_AXI, ("%s: mem_req BLOCKED arvalid=%b awvalid=%b wvalid=%b rd_full=%b wr_full=%b ord_full=%b",
                   BRIDGE_NAME, axi_arvalid, axi_awvalid, axi_wvalid, read_fifo_full, write_fifo_full, order_fifo_full));
        end
    end

    // ========================================================================
    // mem_resp: Deliver in issue order using the order FIFO head
    // ========================================================================
    logic head_resp_ready;
    assign head_resp_ready = (order_count > 0) &&
                             (order_head_is_write ? wr_slot_valid[order_head_id]
                                                  : rd_slot_valid[order_head_id]);

    assign mem_resp_valid    = head_resp_ready;
    assign mem_resp_data     = head_resp_ready && !order_head_is_write
                               ? rd_slot_data [order_head_id] : '0;
    assign mem_resp_error    = head_resp_ready
                               ? (order_head_is_write ? wr_slot_error[order_head_id]
                                                      : rd_slot_error[order_head_id])
                               : 1'b0;
    assign mem_resp_is_write = head_resp_ready && order_head_is_write;

    // ========================================================================
    // Read response slot management
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < OUTSTANDING_DEPTH; i++) begin
                rd_slot_valid[i] <= 1'b0;
                rd_slot_data[i]  <= '0;
                rd_slot_error[i] <= 1'b0;
            end
        end else begin
            // Receive: store R response at slot indexed by RID
            if (axi_rvalid && axi_rready) begin
                rd_slot_data [axi_rid[ID_BITS-1:0]] <= axi_rdata;
                rd_slot_error[axi_rid[ID_BITS-1:0]] <= (axi_rresp != 2'b00);
                rd_slot_valid[axi_rid[ID_BITS-1:0]] <= 1'b1;
                `DEBUG2(`DBG_GRP_AXI, ("%s: R slot[%0d] filled data=0x%h resp=%0d", BRIDGE_NAME, axi_rid[ID_BITS-1:0], axi_rdata, axi_rresp));
            end
            // Consume: clear slot when delivered to core
            if (mem_resp_valid && mem_resp_ready && !order_head_is_write) begin
                rd_slot_valid[order_head_id] <= 1'b0;
                `DEBUG2(`DBG_GRP_AXI, ("%s: R slot[%0d] consumed", BRIDGE_NAME, order_head_id));
            end
        end
    end

    // ========================================================================
    // Write response slot management
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < OUTSTANDING_DEPTH; i++) begin
                wr_slot_valid[i] <= 1'b0;
                wr_slot_error[i] <= 1'b0;
            end
        end else begin
            // Receive: store B response at slot indexed by BID
            if (axi_bvalid && axi_bready) begin
                wr_slot_error[axi_bid[ID_BITS-1:0]] <= (axi_bresp != 2'b00);
                wr_slot_valid[axi_bid[ID_BITS-1:0]] <= 1'b1;
                `DEBUG2(`DBG_GRP_AXI, ("%s: B slot[%0d] filled bresp=%0d", BRIDGE_NAME, axi_bid[ID_BITS-1:0], axi_bresp));
            end
            // Consume: clear slot when delivered to core
            if (mem_resp_valid && mem_resp_ready && order_head_is_write) begin
                wr_slot_valid[order_head_id] <= 1'b0;
                `DEBUG2(`DBG_GRP_AXI, ("%s: B slot[%0d] consumed", BRIDGE_NAME, order_head_id));
            end
        end
    end

    // ========================================================================
    // Order FIFO management (tracks mixed read/write issue order)
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            order_wr_ptr <= '0;
            order_rd_ptr <= '0;
            order_count  <= '0;
        end else begin
            // Push: record issued transaction (mem_req_ready implies !axi_ar/awvalid)
            if (is_read_req && mem_req_ready) begin
                order_is_write[order_wr_ptr[$clog2(ORDER_DEPTH)-1:0]] <= 1'b0;
                order_id      [order_wr_ptr[$clog2(ORDER_DEPTH)-1:0]] <= rd_issue_id;
                order_wr_ptr <= order_wr_ptr + 1'b1;
                `DEBUG2(`DBG_GRP_AXI, ("%s: order push READ  id=%0d", BRIDGE_NAME, rd_issue_id));
            end else if (is_write_req && mem_req_ready) begin
                order_is_write[order_wr_ptr[$clog2(ORDER_DEPTH)-1:0]] <= 1'b1;
                order_id      [order_wr_ptr[$clog2(ORDER_DEPTH)-1:0]] <= wr_issue_id;
                order_wr_ptr <= order_wr_ptr + 1'b1;
                `DEBUG2(`DBG_GRP_AXI, ("%s: order push WRITE id=%0d", BRIDGE_NAME, wr_issue_id));
            end

            // Pop: advance head when core consumes response
            if (mem_resp_valid && mem_resp_ready) begin
                order_rd_ptr <= order_rd_ptr + 1'b1;
                `DEBUG2(`DBG_GRP_AXI, ("%s: order pop  %s id=%0d", BRIDGE_NAME, order_head_is_write ? "WRITE" : "READ ", order_head_id));
            end

            case ({(is_read_req || is_write_req) && mem_req_ready, mem_resp_valid && mem_resp_ready})
                2'b10: order_count <= order_count + 1'b1;
                2'b01: order_count <= order_count - 1'b1;
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

    property p_arid_in_range;
        @(posedge clk) disable iff (!rst_n)
        axi_arvalid |-> (int'(axi_arid) < OUTSTANDING_DEPTH);
    endproperty
    assert property (p_arid_in_range)
        else $error("[%s] ARID 0x%h out of range (max %0d)", BRIDGE_NAME, axi_arid, OUTSTANDING_DEPTH-1);

    // AW Channel (Write Address)
    property p_awvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_awvalid && !axi_awready) |=> $stable(axi_awvalid);
    endproperty
    assert property (p_awvalid_stable)
        else $error("[%s] AWVALID must remain stable until AWREADY", BRIDGE_NAME);

    property p_awaddr_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_awvalid && !axi_awready) |=> $stable(axi_awaddr);
    endproperty
    assert property (p_awaddr_stable)
        else $error("[%s] AWADDR must remain stable while AWVALID is high", BRIDGE_NAME);

    property p_awid_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_awvalid && !axi_awready) |=> $stable(axi_awid);
    endproperty
    assert property (p_awid_stable)
        else $error("[%s] AWID must remain stable while AWVALID is high", BRIDGE_NAME);

    property p_awid_in_range;
        @(posedge clk) disable iff (!rst_n)
        axi_awvalid |-> (int'(axi_awid) < OUTSTANDING_DEPTH);
    endproperty
    assert property (p_awid_in_range)
        else $error("[%s] AWID 0x%h out of range (max %0d)", BRIDGE_NAME, axi_awid, OUTSTANDING_DEPTH-1);

    // W Channel (Write Data)
    property p_wvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_wvalid && !axi_wready) |=> $stable(axi_wvalid);
    endproperty
    assert property (p_wvalid_stable)
        else $error("[%s] WVALID must remain stable until WREADY", BRIDGE_NAME);

    property p_wdata_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_wvalid && !axi_wready) |=> $stable(axi_wdata);
    endproperty
    assert property (p_wdata_stable)
        else $error("[%s] WDATA must remain stable while WVALID is high", BRIDGE_NAME);

    property p_wstrb_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_wvalid && !axi_wready) |=> $stable(axi_wstrb);
    endproperty
    assert property (p_wstrb_stable)
        else $error("[%s] WSTRB must remain stable while WVALID is high", BRIDGE_NAME);

    property p_wstrb_valid;
        @(posedge clk) disable iff (!rst_n)
        axi_wvalid |-> (axi_wstrb != 4'h0);
    endproperty
    assert property (p_wstrb_valid)
        else $error("[%s] WSTRB must not be zero during write", BRIDGE_NAME);

    // Write Channel Coordination
    property p_aw_w_together;
        @(posedge clk) disable iff (!rst_n)
        (is_write_req && mem_req_ready) |=> (axi_awvalid && axi_wvalid);
    endproperty
    assert property (p_aw_w_together)
        else $error("[%s] AW and W channels must be launched together", BRIDGE_NAME);

    // R Channel (Read Data)
    property p_rready_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_rvalid && !axi_rready) |=> axi_rready;
    endproperty
    assert property (p_rready_stable)
        else $error("[%s] RREADY must be asserted when FIFO not full", BRIDGE_NAME);

    // Outstanding Transaction Bounds
    property p_read_outstanding_bounds;
        @(posedge clk) disable iff (!rst_n)
        int'(read_outstanding_count) <= OUTSTANDING_DEPTH;
    endproperty
    assert property (p_read_outstanding_bounds)
        else $error("%s: Read outstanding count exceeded: %0d > %0d",
                    BRIDGE_NAME, read_outstanding_count, OUTSTANDING_DEPTH);

    property p_write_outstanding_bounds;
        @(posedge clk) disable iff (!rst_n)
        int'(write_outstanding_count) <= OUTSTANDING_DEPTH;
    endproperty
    assert property (p_write_outstanding_bounds)
        else $error("%s: Write outstanding count exceeded: %0d > %0d",
                    BRIDGE_NAME, write_outstanding_count, OUTSTANDING_DEPTH);

    property p_resp_slot_no_overflow_r;
        @(posedge clk) disable iff (!rst_n)
        (axi_rvalid && axi_rready) |-> !rd_slot_valid[axi_rid[ID_BITS-1:0]];
    endproperty
    assert property (p_resp_slot_no_overflow_r)
        else $error("[%s] R slot[%0d] overflow: response arrived before slot was cleared",
                    BRIDGE_NAME, axi_rid[ID_BITS-1:0]);

    property p_resp_slot_no_overflow_b;
        @(posedge clk) disable iff (!rst_n)
        (axi_bvalid && axi_bready) |-> !wr_slot_valid[axi_bid[ID_BITS-1:0]];
    endproperty
    assert property (p_resp_slot_no_overflow_b)
        else $error("[%s] B slot[%0d] overflow: response arrived before slot was cleared",
                    BRIDGE_NAME, axi_bid[ID_BITS-1:0]);

    property p_resp_order_no_underflow;
        @(posedge clk) disable iff (!rst_n)
        (mem_resp_valid && mem_resp_ready) |-> (order_count > 0);
    endproperty
    assert property (p_resp_order_no_underflow)
        else $error("[%s] Order FIFO underflow detected", BRIDGE_NAME);

    property p_resp_order_count_bounds;
        @(posedge clk) disable iff (!rst_n)
        int'(order_count) <= ORDER_DEPTH;
    endproperty
    assert property (p_resp_order_count_bounds)
        else $error("[%s] Order FIFO count exceeded: %0d > %0d",
                    BRIDGE_NAME, order_count, ORDER_DEPTH);

    // Mutual Exclusivity
    property p_read_write_mutex;
        @(posedge clk) disable iff (!rst_n)
        !(is_read_req && is_write_req);
    endproperty
    assert property (p_read_write_mutex)
        else $error("[%s] Read and write requests cannot be simultaneous", BRIDGE_NAME);

    property p_rb_mutex;
        @(posedge clk) disable iff (!rst_n)
        !(axi_rvalid && axi_bvalid && axi_rready && axi_bready &&
          (axi_rid[ID_BITS-1:0] == axi_bid[ID_BITS-1:0]));
    endproperty
    assert property (p_rb_mutex)
        else $warning("[%s] R and B responses accepted simultaneously with same slot index", BRIDGE_NAME);

    // X/Z Detection
    property p_no_x_mem_req_valid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(mem_req_valid);
    endproperty
    assert property (p_no_x_mem_req_valid)
        else $error("[%s] X/Z detected on mem_req_valid", BRIDGE_NAME);

    property p_no_x_mem_req_we;
        @(posedge clk) disable iff (!rst_n)
        mem_req_valid |-> !$isunknown(mem_req_we);
    endproperty
    assert property (p_no_x_mem_req_we)
        else $error("[%s] X/Z detected on mem_req_we", BRIDGE_NAME);

    property p_no_x_mem_resp_ready;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(mem_resp_ready);
    endproperty
    assert property (p_no_x_mem_resp_ready)
        else $error("[%s] X/Z detected on mem_resp_ready", BRIDGE_NAME);

    property p_no_x_axi_awready;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(axi_awready);
    endproperty
    assert property (p_no_x_axi_awready)
        else $error("[%s] X/Z detected on axi_awready", BRIDGE_NAME);

    property p_no_x_axi_wready;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(axi_wready);
    endproperty
    assert property (p_no_x_axi_wready)
        else $error("[%s] X/Z detected on axi_wready", BRIDGE_NAME);

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

    property p_no_x_axi_bvalid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(axi_bvalid);
    endproperty
    assert property (p_no_x_axi_bvalid)
        else $error("[%s] X/Z detected on axi_bvalid", BRIDGE_NAME);

    // Memory Interface Protocol
    property p_mem_req_stable;
        @(posedge clk) disable iff (!rst_n)
        (mem_req_valid && !mem_req_ready) |=> mem_req_valid && $stable(mem_req_addr) && $stable(mem_req_we) && $stable(mem_req_wdata);
    endproperty
    assert property (p_mem_req_stable)
        else $error("[%s] mem_req signals must remain stable until mem_req_ready", BRIDGE_NAME);

    property p_mem_resp_stable;
        @(posedge clk) disable iff (!rst_n)
        (mem_resp_valid && !mem_resp_ready) |=> $stable(mem_resp_data) && $stable(mem_resp_error);
    endproperty
    assert property (p_mem_resp_stable)
        else $error("[%s] mem_resp signals must remain stable until mem_resp_ready", BRIDGE_NAME);

    // Single-beat bridge: every read response must be the last (and only) beat.
    property p_rlast_single_beat;
        @(posedge clk) disable iff (!rst_n)
        axi_rvalid |-> axi_rlast;
    endproperty
    assert property (p_rlast_single_beat)
        else $error("[%s] axi_rlast must be 1 for single-beat read response", BRIDGE_NAME);

`endif // ASSERTION

endmodule


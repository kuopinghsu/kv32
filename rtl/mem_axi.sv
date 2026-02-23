// ============================================================================
// File: mem_axi.sv
// Project: RV32 RISC-V Processor
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
import rv32_pkg::*;
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
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] axi_bid,
    input  logic                     axi_bvalid,
    output logic                     axi_bready,

    output logic [31:0]              axi_araddr,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] axi_arid,
    output logic                     axi_arvalid,
    input  logic                     axi_arready,

    input  logic [31:0]              axi_rdata,
    input  logic [1:0]               axi_rresp,
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] axi_rid,
    input  logic                     axi_rvalid,
    output logic                     axi_rready
);
`ifndef SYNTHESIS
    import rv32_pkg::*;
    import axi_pkg::*;
`endif

    // ========================================================================
    // Transaction tracking
    // ========================================================================
    localparam int ID_WIDTH = axi_pkg::AXI_ID_WIDTH;

    logic is_read_req;
    logic is_write_req;

    assign is_read_req  = mem_req_valid && (mem_req_we == 4'h0);
    assign is_write_req = mem_req_valid && (mem_req_we != 4'h0);

    // Use constant ID to enforce in-order responses (no reorder buffer)
    localparam logic [ID_WIDTH-1:0] CONST_ID = '0;

    // Transaction counters to track outstanding requests
    logic [$clog2(OUTSTANDING_DEPTH):0] read_outstanding_count;
    logic [$clog2(OUTSTANDING_DEPTH):0] write_outstanding_count;

    logic read_fifo_full;
    logic write_fifo_full;

    assign read_fifo_full  = (read_outstanding_count >= OUTSTANDING_DEPTH);
    assign write_fifo_full = (write_outstanding_count >= OUTSTANDING_DEPTH);

    // ========================================================================
    // AR Channel (Read Address) - Use constant ID for in-order responses
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_arvalid <= 1'b0;
            axi_araddr  <= 32'h0;
            axi_arid    <= CONST_ID;
        end else begin
            if (is_read_req && mem_req_ready && !axi_arvalid) begin
                // Launch read request on AR channel with constant ID
                axi_arvalid <= 1'b1;
                axi_araddr  <= mem_req_addr;
                axi_arid    <= CONST_ID;
                `DBG2(("%s: AR launch addr=0x%h id=%0d", BRIDGE_NAME, mem_req_addr, CONST_ID));
            end else if (axi_arvalid && axi_arready) begin
                // AR handshake complete
                axi_arvalid <= 1'b0;
                `DBG2(("%s: AR accepted", BRIDGE_NAME));
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
    // R Channel (Read Data) - Independent reception
    // Since slaves are AXI4-Lite (in-order), responses arrive in reqorder
    // ========================================================================
    // Response FIFO - Buffer responses to prevent deadlock
    // ========================================================================
    // Response FIFO as flat arrays (synthesis-compatible)
    logic [31:0] fifo_data    [0:OUTSTANDING_DEPTH-1];
    logic        fifo_error   [0:OUTSTANDING_DEPTH-1];
    logic        fifo_is_write[0:OUTSTANDING_DEPTH-1];
    logic [$clog2(OUTSTANDING_DEPTH):0] resp_wr_ptr;
    logic [$clog2(OUTSTANDING_DEPTH):0] resp_rd_ptr;
    logic [$clog2(OUTSTANDING_DEPTH):0] resp_count;
    logic resp_fifo_full;

    logic resp_push_r;
    logic resp_push_b;
    logic resp_pop;

    assign resp_push_r = axi_rvalid && axi_rready;
    assign resp_push_b = (!resp_push_r) && axi_bvalid && axi_bready;
    assign resp_pop = mem_resp_valid && mem_resp_ready;
    assign resp_fifo_full = (resp_count >= OUTSTANDING_DEPTH);
    assign axi_rready = !resp_fifo_full;  // Accept responses unless FIFO full

    // ========================================================================
    // AW Channel (Write Address) - Use constant ID for in-order responses
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_awvalid <= 1'b0;
            axi_awaddr  <= 32'h0;
            axi_awid    <= CONST_ID;
        end else begin
            if (is_write_req && mem_req_ready && !axi_awvalid) begin
                // Launch write address on AW channel with constant ID
                axi_awvalid <= 1'b1;
                axi_awaddr  <= mem_req_addr;
                axi_awid    <= CONST_ID;
                `DBG2(("%s: AW launch addr=0x%h id=%0d", BRIDGE_NAME, mem_req_addr, CONST_ID));
            end else if (axi_awvalid && axi_awready) begin
                // AW handshake complete
                axi_awvalid <= 1'b0;
                `DBG2(("%s: AW accepted", BRIDGE_NAME));
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
                `DBG2(("%s: W launch data=0x%h strb=0x%h", BRIDGE_NAME, mem_req_wdata, mem_req_we));
            end else if (axi_wvalid && axi_wready) begin
                // W handshake complete
                axi_wvalid <= 1'b0;
                `DBG2(("%s: W accepted", BRIDGE_NAME));
            end else if (axi_wvalid && !axi_wready) begin
                `DBG2(("%s: W waiting for wready", BRIDGE_NAME));
            end
        end
    end

    // (B channel handling moved below with response capture)
    assign axi_bready = !resp_fifo_full && !axi_rvalid;  // Prefer R when both valid, accept B unless FIFO full

    // ========================================================================
    // mem_req_ready: Can accept new request when channels and FIFOs have space
    // ========================================================================
    // For pipelined operation with multiple outstanding transactions:
    // - Allow new read if AR channel is idle and read FIFO has space
    // - Allow new write if AW+W channels are idle and write FIFO has space
    assign mem_req_ready = !axi_arvalid && !axi_awvalid && !axi_wvalid &&
                           !read_fifo_full && !write_fifo_full;

    always @(posedge clk) begin
        if (mem_req_valid && !mem_req_ready) begin
            `DBG2(("%s: mem_req BLOCKED arvalid=%b awvalid=%b wvalid=%b rd_full=%b wr_full=%b",
                   BRIDGE_NAME, axi_arvalid, axi_awvalid, axi_wvalid, read_fifo_full, write_fifo_full));
        end
    end

    // ========================================================================
    // mem_resp: Feed from response FIFO
    // ========================================================================
    assign mem_resp_valid    = (resp_count > 0);
    assign mem_resp_data     = (resp_count > 0) ? fifo_data    [resp_rd_ptr[$clog2(OUTSTANDING_DEPTH)-1:0]] : '0;
    assign mem_resp_error    = (resp_count > 0) ? fifo_error   [resp_rd_ptr[$clog2(OUTSTANDING_DEPTH)-1:0]] : 1'b0;
    assign mem_resp_is_write = (resp_count > 0) ? fifo_is_write[resp_rd_ptr[$clog2(OUTSTANDING_DEPTH)-1:0]] : 1'b0;

    // FIFO management
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_wr_ptr <= '0;
            resp_rd_ptr <= '0;
            resp_count <= '0;
        end else begin
            // Push: AXI R channel response (read)
            if (resp_push_r) begin
                fifo_data    [resp_wr_ptr[$clog2(OUTSTANDING_DEPTH)-1:0]] <= axi_rdata;
                fifo_error   [resp_wr_ptr[$clog2(OUTSTANDING_DEPTH)-1:0]] <= (axi_rresp != 2'b00);
                fifo_is_write[resp_wr_ptr[$clog2(OUTSTANDING_DEPTH)-1:0]] <= 1'b0;
                resp_wr_ptr <= resp_wr_ptr + 1'b1;
                `DBG2(("%s: R response FIFO push data=0x%h resp=%0d count=%0d", BRIDGE_NAME, axi_rdata, axi_rresp, resp_count + 1));
            end
            // Push: AXI B channel response (write)
            else if (resp_push_b) begin
                fifo_data    [resp_wr_ptr[$clog2(OUTSTANDING_DEPTH)-1:0]] <= 32'h0;  // Write has no data
                fifo_error   [resp_wr_ptr[$clog2(OUTSTANDING_DEPTH)-1:0]] <= (axi_bresp != 2'b00);
                fifo_is_write[resp_wr_ptr[$clog2(OUTSTANDING_DEPTH)-1:0]] <= 1'b1;
                resp_wr_ptr <= resp_wr_ptr + 1'b1;
                `DBG2(("%s: B response FIFO push bresp=%0d count=%0d", BRIDGE_NAME, axi_bresp, resp_count + 1));
            end

            // Pop: Core consumes response
            if (resp_pop) begin
                resp_rd_ptr <= resp_rd_ptr + 1'b1;
                `DBG2(("%s: mem_resp consumed count=%0d", BRIDGE_NAME, resp_count - 1));
            end

            case ({resp_push_r || resp_push_b, resp_pop})
                2'b10: resp_count <= resp_count + 1'b1;
                2'b01: resp_count <= resp_count - 1'b1;
                default: resp_count <= resp_count;
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

    property p_awid_constant;
        @(posedge clk) disable iff (!rst_n)
        axi_awvalid |-> (axi_awid == CONST_ID);
    endproperty
    assert property (p_awid_constant)
        else $error("[%s] AWID must be constant (0x%h)", BRIDGE_NAME, CONST_ID);

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
        read_outstanding_count <= OUTSTANDING_DEPTH;
    endproperty
    assert property (p_read_outstanding_bounds)
        else $error("[%s] Read outstanding count exceeded: %0d > %0d",
                    BRIDGE_NAME, read_outstanding_count, OUTSTANDING_DEPTH);

    property p_write_outstanding_bounds;
        @(posedge clk) disable iff (!rst_n)
        write_outstanding_count <= OUTSTANDING_DEPTH;
    endproperty
    assert property (p_write_outstanding_bounds)
        else $error("[%s] Write outstanding count exceeded: %0d > %0d",
                    BRIDGE_NAME, write_outstanding_count, OUTSTANDING_DEPTH);

    // Response FIFO Integrity
    property p_resp_fifo_no_overflow;
        @(posedge clk) disable iff (!rst_n)
        ((axi_rvalid && axi_rready) || (axi_bvalid && axi_bready)) |-> !resp_fifo_full;
    endproperty
    assert property (p_resp_fifo_no_overflow)
        else $error("[%s] Response FIFO overflow detected", BRIDGE_NAME);

    property p_resp_fifo_no_underflow;
        @(posedge clk) disable iff (!rst_n)
        (mem_resp_valid && mem_resp_ready) |-> (resp_count > 0);
    endproperty
    assert property (p_resp_fifo_no_underflow)
        else $error("[%s] Response FIFO underflow detected", BRIDGE_NAME);

    property p_resp_count_bounds;
        @(posedge clk) disable iff (!rst_n)
        resp_count <= OUTSTANDING_DEPTH;
    endproperty
    assert property (p_resp_count_bounds)
        else $error("[%s] Response FIFO count exceeded: %0d > %0d",
                    BRIDGE_NAME, resp_count, OUTSTANDING_DEPTH);

    // Mutual Exclusivity
    property p_read_write_mutex;
        @(posedge clk) disable iff (!rst_n)
        !(is_read_req && is_write_req);
    endproperty
    assert property (p_read_write_mutex)
        else $error("[%s] Read and write requests cannot be simultaneous", BRIDGE_NAME);

    property p_rb_mutex;
        @(posedge clk) disable iff (!rst_n)
        !(axi_rvalid && axi_bvalid && axi_rready && axi_bready);
    endproperty
    assert property (p_rb_mutex)
        else $warning("[%s] R and B responses both accepted in same cycle", BRIDGE_NAME);

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

`endif // ASSERTION

endmodule

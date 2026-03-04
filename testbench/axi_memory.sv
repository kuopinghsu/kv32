// ============================================================================
// File: axi_memory.sv
// Project: KV32 RISC-V Processor
// Description: AXI4-Lite External Memory Module for Testbench
//
// Configurable AXI memory supporting single-port or dual-port operation.
// Features pipelined architecture for performance.
// Default configuration: 2MB RAM at 0x8000_0000 with 1-cycle latency.
// Debug logging is controlled via the DBG_GRP_AXIMEM debug group (bit 16).
// Enable with: make DEBUG=2 DEBUG_GROUP=0x10000 rtl-<test>
// ============================================================================

module axi_memory #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter MEM_SIZE = 2 * 1024 * 1024,   // 2MB
    parameter BASE_ADDR = 32'h80000000,     // Base address for memory mapping
    parameter MEM_READ_LATENCY = 1,         // Read latency in cycles (1 to 16)
    parameter MEM_WRITE_LATENCY = 1,        // Write latency in cycles (1 to 16)
    parameter MEM_DUAL_PORT = 1,            // 1=Dual-port (best performance), 0=One-port (with arbitration)
    parameter MAX_OUTSTANDING_READS = 16,   // Maximum outstanding read requests (independent of latency)
    parameter MAX_OUTSTANDING_WRITES = 16   // Maximum outstanding write requests (independent of latency)
) (
    input  logic                    clk,
    input  logic                    rst_n,

    // AXI4-Lite Slave Interface
    // Write Address Channel
    input  logic [ADDR_WIDTH-1:0]   axi_awaddr,
    input  logic [7:0]              axi_awlen,
    input  logic [2:0]              axi_awsize,
    input  logic [1:0]              axi_awburst,
    input  logic                    axi_awvalid,
    output logic                    axi_awready,

    // Write Data Channel
    input  logic [DATA_WIDTH-1:0]   axi_wdata,
    input  logic [3:0]              axi_wstrb,
    input  logic                    axi_wlast,
    input  logic                    axi_wvalid,
    output logic                    axi_wready,

    // Write Response Channel
    output logic [1:0]              axi_bresp,
    output logic                    axi_bvalid,
    input  logic                    axi_bready,

    // Read Address Channel
    input  logic [ADDR_WIDTH-1:0]   axi_araddr,
    input  logic [7:0]              axi_arlen,
    input  logic [2:0]              axi_arsize,
    input  logic [1:0]              axi_arburst,
    input  logic                    axi_arvalid,
    output logic                    axi_arready,

    // Read Data Channel
    output logic [DATA_WIDTH-1:0]   axi_rdata,
    output logic [1:0]              axi_rresp,
    output logic                    axi_rlast,
    output logic                    axi_rvalid,
    input  logic                    axi_rready
);

    import kv32_pkg::*;

    // Memory array
    logic [7:0] mem [MEM_SIZE];

    // Initialize memory to zero (matches software simulator behavior)
    initial begin
        for (int i = 0; i < MEM_SIZE; i++) begin
            mem[i] = 8'h00;
        end
    end

    // ============================================================================
    // Statistics Tracking
    // ============================================================================
    int unsigned stat_ar_requests;        // Total AR (read address) channel handshakes
    int unsigned stat_r_responses;        // Total R (read data) channel handshakes
    int unsigned stat_aw_requests;        // Total AW (write address) channel handshakes
    int unsigned stat_w_data;             // Total W (write data) channel handshakes (beats)
    int unsigned stat_w_expected;         // Expected W beats: sum of (awlen+1) per AW transaction
    int unsigned stat_b_responses;        // Total B (write response) channel handshakes
    int unsigned stat_outstanding_reads;  // Current outstanding read requests
    int unsigned stat_outstanding_writes; // Current outstanding write requests
    int unsigned stat_max_outstanding_reads;  // Maximum outstanding reads observed
    int unsigned stat_max_outstanding_writes; // Maximum outstanding writes observed

    // Request tracking for outstanding limit enforcement
    int unsigned current_outstanding_reads;   // Current inflight read requests
    int unsigned current_outstanding_writes;  // Current inflight write requests
    logic read_limit_reached;
    logic write_limit_reached;

    assign read_limit_reached = (current_outstanding_reads >= MAX_OUTSTANDING_READS);
    assign write_limit_reached = (current_outstanding_writes >= MAX_OUTSTANDING_WRITES);

    // Initialize statistics
    initial begin
        stat_ar_requests = 0;
        stat_r_responses = 0;
        stat_aw_requests = 0;
        stat_w_data = 0;
        stat_w_expected = 0;
        stat_b_responses = 0;
        stat_outstanding_reads = 0;
        stat_outstanding_writes = 0;
        stat_max_outstanding_reads = 0;
        stat_max_outstanding_writes = 0;
        current_outstanding_reads = 0;
        current_outstanding_writes = 0;
    end

    // ============================================================================
    // State Representation for Backward Compatibility
    // ============================================================================
    // Legacy state signal for testbench compatibility
    // Encoding: 0=IDLE, 1=WRITE_WAIT, 2=WRITE_RESP, 3=READ_WAIT, 4=READ_DATA
    logic [2:0] state;

    always_comb begin
        if (write_pipe[0].valid) begin
            state = 3'd2;  // WRITE_RESP
        end else if (write_addr_valid || (axi_awvalid && axi_awready)) begin
            state = 3'd1;  // WRITE_WAIT
        end else if (read_pipe[0].valid) begin
            state = 3'd4;  // READ_DATA
        end else if (axi_arvalid && axi_arready) begin
            state = 3'd3;  // READ_WAIT
        end else begin
            state = 3'd0;  // IDLE
        end
    end

    // ============================================================================
    // Pipeline Stage Structure
    // ============================================================================

    // Write pipeline stages (includes address and data acceptance)
    typedef struct packed {
        logic [ADDR_WIDTH-1:0] addr;
        logic [DATA_WIDTH-1:0] data;
        logic [3:0]            strb;
        logic [1:0]            resp;
        logic                  valid;
    } write_pipeline_t;

    // Read pipeline stages
    typedef struct packed {
        logic [ADDR_WIDTH-1:0] addr;
        logic [DATA_WIDTH-1:0] data;
        logic [1:0]            resp;
        logic                  is_last;  // rlast flag (last beat of a burst)
        logic                  valid;
    } read_pipeline_t;

    // Pipeline depth is max of latency values and outstanding support (minimum 2 to avoid Verilator warnings)
    // To support multiple outstanding with low latency, pipeline depth must be >= outstanding limit
    localparam MAX_WRITE_STAGES = (MEM_WRITE_LATENCY > MAX_OUTSTANDING_WRITES) ?
                                   ((MEM_WRITE_LATENCY > 16) ? 16 : MEM_WRITE_LATENCY) :
                                   ((MAX_OUTSTANDING_WRITES < 2) ? 2 : MAX_OUTSTANDING_WRITES);
    localparam MAX_READ_STAGES = (MEM_READ_LATENCY > MAX_OUTSTANDING_READS) ?
                                  ((MEM_READ_LATENCY > 16) ? 16 : MEM_READ_LATENCY) :
                                  ((MAX_OUTSTANDING_READS < 2) ? 2 : MAX_OUTSTANDING_READS);

    write_pipeline_t write_pipe [MAX_WRITE_STAGES];
    read_pipeline_t  read_pipe  [MAX_READ_STAGES];

    // One-port arbitration signals (only used when DUAL_PORT=0)
    logic arb_write_grant;
    logic arb_read_grant;
    logic arb_last_grant_was_write;  // For fair arbitration

    // Pipeline control signals
    logic write_pipe_busy;
    logic read_pipe_busy;
    logic write_can_accept;
    logic read_can_accept;

    // ============================================================================
    // Write Channel Logic (Pipelined)
    // ============================================================================

    // Write address and data acceptance
    logic write_addr_accepted;
    logic write_data_accepted;
    logic [ADDR_WIDTH-1:0] write_addr_reg;
    logic write_addr_valid;
    logic [1:0] wr_burst_type;   // Captured burst type for address increment logic
    logic       wr_burst_err;    // Any beat had an out-of-range address

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_addr_reg   <= '0;
            write_addr_valid <= 1'b0;
            wr_burst_type    <= 2'b01;
            wr_burst_err     <= 1'b0;
            stat_aw_requests <= 0;
            stat_outstanding_writes <= 0;
            stat_b_responses <= 0;            current_outstanding_writes <= 0;        end else begin
            // Handle AW acceptance
            if (axi_awvalid && axi_awready) begin
                write_addr_reg   <= axi_awaddr;
                write_addr_valid <= 1'b1;
                wr_burst_type    <= axi_awburst;
                wr_burst_err     <= 1'b0;
                stat_aw_requests <= stat_aw_requests + 1;
                stat_w_expected  <= stat_w_expected + (32'(axi_awlen) + 1);
                `DEBUG2(`DBG_GRP_AXIMEM, ("[WR] Write addr accepted addr=0x%h awlen=%0d",
                         axi_awaddr, axi_awlen));
            end else if (write_addr_valid && axi_wvalid && write_can_accept) begin
                // Track out-of-range address
                if (write_addr_reg < BASE_ADDR || write_addr_reg >= (BASE_ADDR + MEM_SIZE))
                    wr_burst_err <= 1'b1;
                if (axi_wlast) begin
                    write_addr_valid <= 1'b0;  // Clear only on last beat
                end else begin
                    // Advance address for INCR bursts
                    if (wr_burst_type == 2'b01)
                        write_addr_reg <= write_addr_reg + 4;
                end
                `DEBUG2(`DBG_GRP_AXIMEM, ("[WR] Write data accepted addr=0x%h data=0x%h strb=0x%h wlast=%b",
                         write_addr_reg, axi_wdata, axi_wstrb, axi_wlast));
            end

            // Handle simultaneous AW and B
            case ({(axi_awvalid && axi_awready), (axi_bvalid && axi_bready)})
                2'b10: begin  // AW only
                    stat_outstanding_writes <= stat_outstanding_writes + 1;
                    current_outstanding_writes <= current_outstanding_writes + 1;
                end
                2'b01: begin  // B only
                    stat_b_responses <= stat_b_responses + 1;
                    if (stat_outstanding_writes > 0) begin
                        stat_outstanding_writes <= stat_outstanding_writes - 1;
                    end
                    if (current_outstanding_writes > 0) begin
                        current_outstanding_writes <= current_outstanding_writes - 1;
                    end
                end
                2'b11: begin  // Both AW and B
                    stat_b_responses <= stat_b_responses + 1;
                    // Outstanding stays the same
                end
                default: begin  // Neither
                    // No change to outstanding
                end
            endcase

            // Update max outstanding writes
            if (stat_outstanding_writes > stat_max_outstanding_writes) begin
                stat_max_outstanding_writes <= stat_outstanding_writes;
            end
        end
    end

    // Track W channel handshakes
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_w_data <= 0;
        end else begin
            if (axi_wvalid && axi_wready) begin
                stat_w_data <= stat_w_data + 1;
            end
        end
    end

    // Write pipeline full detection
    // Pipeline busy only affects internal processing, not acceptance
    assign write_pipe_busy = (MEM_WRITE_LATENCY == 1) ?
                             (write_pipe[0].valid && !axi_bready) :  // Latency=1: busy if stage 0 full and not consumed
                             (write_pipe[MEM_WRITE_LATENCY-1].valid);  // Latency>1: busy if input stage full
    assign write_can_accept = MEM_DUAL_PORT ? !write_pipe_busy : (arb_write_grant && !write_pipe_busy);

    // AXI write ready signals - accept if outstanding limit not reached AND pipeline can process
    assign axi_awready = !write_addr_valid && write_can_accept && !write_limit_reached;
    assign axi_wready = write_addr_valid && write_can_accept;

    // Write pipeline advancement
    //
    // For MEM_WRITE_LATENCY == 1: stage[0] is input+output (unchanged behaviour).
    //
    // For MEM_WRITE_LATENCY > 1: stage[MEM_WRITE_LATENCY-1] is the ENTRY stage
    // (new writes land here, write_pipe_busy watches this stage); stages shift
    // downward each cycle (stage[i] → stage[i-1]) whenever the downstream stage
    // is empty; B-response is generated from stage[0].
    //
    // This ensures exactly one B-response per accepted write and gives the
    // correct MEM_WRITE_LATENCY cycles of delay between AW-accept and B-valid.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < MAX_WRITE_STAGES; i++) begin
                write_pipe[i].valid <= 1'b0;
                write_pipe[i].addr  <= '0;
                write_pipe[i].data  <= '0;
                write_pipe[i].strb  <= '0;
                write_pipe[i].resp  <= 2'b00;
            end
        end else begin
            // Debug: Monitor write pipeline state
            `ifdef DEBUG_LEVEL_2
            if (|((`DEBUG_GROUP >> `DBG_GRP_AXIMEM) & 32'h1)) begin
                static logic prev_write_addr_valid = 1'b0;
                static logic prev_write_pipe0_valid = 1'b0;
                if (write_addr_valid != prev_write_addr_valid || write_pipe[0].valid != prev_write_pipe0_valid) begin
                    $display("[AXIMEM] [WR] write_addr_valid=%b write_pipe[0].valid=%b axi_bvalid=%b axi_bready=%b",
                             write_addr_valid, write_pipe[0].valid, axi_bvalid, axi_bready);
                    prev_write_addr_valid = write_addr_valid;
                    prev_write_pipe0_valid = write_pipe[0].valid;
                end
            end
            `endif

            if (MEM_WRITE_LATENCY == 1) begin
                // ── Latency-1: stage[0] is both input and output ──────────
                // Accept new write OR drain on B-accept (mutually exclusive
                // because write_can_accept already checks !write_pipe_busy).
                if (write_addr_valid && axi_wvalid && write_can_accept && axi_wlast) begin
                    write_pipe[0].valid <= 1'b1;
                    write_pipe[0].addr  <= write_addr_reg;
                    write_pipe[0].data  <= axi_wdata;
                    write_pipe[0].strb  <= axi_wstrb;
                    write_pipe[0].resp  <= (wr_burst_err ||
                                            write_addr_reg < BASE_ADDR ||
                                            write_addr_reg >= (BASE_ADDR + MEM_SIZE))
                                          ? 2'b10 : 2'b00;
                end else if (write_pipe[0].valid && axi_bready) begin
                    write_pipe[0].valid <= 1'b0;
                end
            end else begin
                // ── Latency > 1: shift-register pipeline ──────────────────
                //
                // Stage[0]  — output: drain on B-accept, else load from [1]
                if (write_pipe[0].valid && axi_bready) begin
                    write_pipe[0].valid <= 1'b0;
                end else if (!write_pipe[0].valid && write_pipe[1].valid) begin
                    write_pipe[0] <= write_pipe[1];
                end

                // Stages[1 .. MEM_WRITE_LATENCY-2] — middle shift stages
                for (int i = 1; i < MEM_WRITE_LATENCY - 1; i++) begin
                    if (write_pipe[i].valid && !write_pipe[i-1].valid) begin
                        // Downstream is empty → shift out; stage[i-1] loads
                        // our value in its own non-blocking assignment above.
                        write_pipe[i].valid <= 1'b0;
                    end else if (!write_pipe[i].valid && write_pipe[i+1].valid) begin
                        // We are empty and upstream has data → shift in.
                        write_pipe[i] <= write_pipe[i+1];
                    end
                    // else: hold (occupied + downstream occupied, or empty + no upstream)
                end

                // Stage[MEM_WRITE_LATENCY-1] — entry stage
                // write_pipe_busy watches this stage; axi_awready/wready go
                // low when it is occupied.
                if (write_pipe[MEM_WRITE_LATENCY-1].valid &&
                    !write_pipe[MEM_WRITE_LATENCY-2].valid) begin
                    // Shift out to the stage below; clear the entry stage so
                    // the next write can be accepted one cycle later.
                    write_pipe[MEM_WRITE_LATENCY-1].valid <= 1'b0;
                end else if (!write_pipe[MEM_WRITE_LATENCY-1].valid &&
                             write_addr_valid && axi_wvalid &&
                             write_can_accept && axi_wlast) begin
                    // Accept new write into the entry stage.
                    write_pipe[MEM_WRITE_LATENCY-1].valid <= 1'b1;
                    write_pipe[MEM_WRITE_LATENCY-1].addr  <= write_addr_reg;
                    write_pipe[MEM_WRITE_LATENCY-1].data  <= axi_wdata;
                    write_pipe[MEM_WRITE_LATENCY-1].strb  <= axi_wstrb;
                    write_pipe[MEM_WRITE_LATENCY-1].resp  <= (wr_burst_err ||
                                                              write_addr_reg < BASE_ADDR ||
                                                              write_addr_reg >= (BASE_ADDR + MEM_SIZE))
                                                            ? 2'b10 : 2'b00;
                end

                // Stages >= MEM_WRITE_LATENCY are unused; keep them clear.
                for (int i = MEM_WRITE_LATENCY; i < MAX_WRITE_STAGES; i++) begin
                    write_pipe[i].valid <= 1'b0;
                end
            end
        end
    end

    // Memory write operation (at appropriate pipeline stage)
    always_ff @(posedge clk) begin
        if (MEM_WRITE_LATENCY == 1) begin
            // Single cycle write: perform immediately in stage 0
            // Check address bounds directly to avoid race condition with write_pipe[0].resp

            if (write_addr_valid && axi_wvalid && write_can_accept &&
                (write_addr_reg >= BASE_ADDR && write_addr_reg < (BASE_ADDR + MEM_SIZE))) begin
                automatic logic [31:0] base_addr = ((write_addr_reg - BASE_ADDR) & (MEM_SIZE - 1)) & ~32'h3;
                if (axi_wstrb[0]) mem[base_addr] <= axi_wdata[7:0];
                if (axi_wstrb[1]) mem[(base_addr + 1) & (MEM_SIZE-1)] <= axi_wdata[15:8];
                if (axi_wstrb[2]) mem[(base_addr + 2) & (MEM_SIZE-1)] <= axi_wdata[23:16];
                if (axi_wstrb[3]) mem[(base_addr + 3) & (MEM_SIZE-1)] <= axi_wdata[31:24];

                `DEBUG2(`DBG_GRP_AXIMEM, ("[WR] addr=0x%08x data=0x%08x strb=0x%x [bytes: %02x %02x %02x %02x]",
                         write_addr_reg, axi_wdata, axi_wstrb,
                         axi_wstrb[0] ? axi_wdata[7:0] : 8'hXX,
                         axi_wstrb[1] ? axi_wdata[15:8] : 8'hXX,
                         axi_wstrb[2] ? axi_wdata[23:16] : 8'hXX,
                         axi_wstrb[3] ? axi_wdata[31:24] : 8'hXX));
            end
        end else begin
            // Multi-cycle write: write each beat immediately as it is accepted;
            // the pipeline is only used to delay the B response by MEM_WRITE_LATENCY
            // cycles.  Previously this block only committed the *last* beat (wlast)
            // stored in write_pipe[MEM_WRITE_LATENCY-1], silently dropping every
            // intermediate beat of a multi-beat burst.
            if (write_addr_valid && axi_wvalid && write_can_accept &&
                (write_addr_reg >= BASE_ADDR && write_addr_reg < (BASE_ADDR + MEM_SIZE))) begin
                automatic logic [31:0] base_addr = ((write_addr_reg - BASE_ADDR) & (MEM_SIZE - 1)) & ~32'h3;
                if (axi_wstrb[0]) mem[base_addr] <= axi_wdata[7:0];
                if (axi_wstrb[1]) mem[(base_addr + 1) & (MEM_SIZE-1)] <= axi_wdata[15:8];
                if (axi_wstrb[2]) mem[(base_addr + 2) & (MEM_SIZE-1)] <= axi_wdata[23:16];
                if (axi_wstrb[3]) mem[(base_addr + 3) & (MEM_SIZE-1)] <= axi_wdata[31:24];

                `DEBUG2(`DBG_GRP_AXIMEM, ("[WR] addr=0x%08x data=0x%08x strb=0x%x [bytes: %02x %02x %02x %02x]",
                         write_addr_reg, axi_wdata, axi_wstrb,
                         axi_wstrb[0] ? axi_wdata[7:0] : 8'hXX,
                         axi_wstrb[1] ? axi_wdata[15:8] : 8'hXX,
                         axi_wstrb[2] ? axi_wdata[23:16] : 8'hXX,
                         axi_wstrb[3] ? axi_wdata[31:24] : 8'hXX));
            end
        end
    end

    // Write response channel
    assign axi_bvalid = write_pipe[0].valid;
    assign axi_bresp = write_pipe[0].resp;

    // ============================================================================
    // Read Channel Logic (Pipelined)
    // ============================================================================

    // Read pipeline full detection
    // Count how many stages are occupied
    logic [$clog2(MAX_READ_STAGES)+1:0] read_stages_occupied;
    always_comb begin
        read_stages_occupied = 0;
        for (int i = 0; i < MAX_READ_STAGES; i++) begin
            if (read_pipe[i].valid) read_stages_occupied++;
        end
    end

    // Pipeline can accept if not all stages are full
    assign read_pipe_busy = (32'(read_stages_occupied) >= MAX_READ_STAGES);
    assign read_can_accept = MEM_DUAL_PORT ? !read_pipe_busy : (arb_read_grant && !read_pipe_busy);

    // Combinatorial insert_pos: lowest-indexed pipeline stage available for a new
    // beat after accounting for shift destinations this cycle.
    //
    // A stage is available only if:
    //   (a) it is currently empty (valid == 0), AND
    //   (b) the shift logic will NOT place data into it this very cycle.
    //
    // This is the same computation that the always_ff beat-load block uses, but
    // exposed as a continuous signal so that axi_arready can be gated on it.
    // Without this guard, arready can be asserted when all free stages are shift
    // destinations (insert_pos == -1), causing the AR data beat to be silently
    // dropped and the burst to start from the wrong (second-beat) address.
    logic        read_pipe_has_slot;  // true when insert_pos_comb >= 0
    int          insert_pos_comb;
    always_comb begin
        automatic logic shift_gate_open_c;
        shift_gate_open_c  = !read_pipe[0].valid || axi_rready;
        insert_pos_comb    = -1;
        for (int i = MAX_READ_STAGES-1; i >= 0; i--) begin
            automatic logic shift_dst_c;
            shift_dst_c = shift_gate_open_c &&
                          (i < MAX_READ_STAGES-1) && read_pipe[i+1].valid;
            if (!read_pipe[i].valid && !shift_dst_c)
                insert_pos_comb = i;
        end
        read_pipe_has_slot = (insert_pos_comb >= 0);
    end

    // ============================================================================
    // Burst Expansion State Machine
    // ============================================================================
    // When an AR with arlen>0 is accepted, the subsequent (arlen) beats are
    // generated internally without a new AR handshake.
    logic        burst_active;        // A multi-beat burst is being expanded
    logic [31:0] burst_addr;          // Current burst word address
    logic [7:0]  burst_remaining;     // Remaining beats to issue (after first)
    logic [1:0]  burst_type;          // Captured arburst (INCR or WRAP)
    logic [7:0]  burst_total_len;     // Captured arlen
    logic [31:0] burst_wrap_mask;     // Wrap boundary mask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            burst_active    <= 1'b0;
            burst_addr      <= '0;
            burst_remaining <= '0;
            burst_type      <= '0;
            burst_total_len <= '0;
            burst_wrap_mask <= '0;
        end else begin
            if (axi_arvalid && axi_arready && axi_arlen != 8'h0) begin
                // New burst: record parameters, first beat is issued by pipeline logic
                burst_active    <= 1'b1;
                burst_type      <= axi_arburst;
                burst_total_len <= axi_arlen;
                // Wrap mask: (arlen+1) * 4 bytes - wraps at cache-line boundary
                burst_wrap_mask <= 32'((int'(axi_arlen) + 1) * 4 - 1);
                // Address of second beat (increment from first)
                if (axi_arburst == 2'b10) begin  // WRAP
                    // Word-increment within the wrap window
                    automatic logic [31:0] wrap_mask_v;
                    wrap_mask_v = 32'((int'(axi_arlen) + 1) * 4 - 1);
                    burst_addr <= (axi_araddr & ~wrap_mask_v) |
                                  ((axi_araddr + 32'd4) & wrap_mask_v);
                end else begin  // INCR
                    burst_addr <= axi_araddr + 32'd4;
                end
                burst_remaining <= axi_arlen;  // beats remaining after first
            end else if (burst_active && !read_pipe_busy && read_pipe_has_slot) begin
                // Issue the next burst beat when pipeline has space
                burst_remaining <= burst_remaining - 8'h1;
                if (burst_remaining == 8'h1) begin
                    burst_active <= 1'b0;  // last beat being issued now
                end
                // Advance address
                if (burst_type == 2'b10) begin  // WRAP
                    burst_addr <= (burst_addr & ~burst_wrap_mask) |
                                  ((burst_addr + 32'd4) & burst_wrap_mask);
                end else begin  // INCR
                    burst_addr <= burst_addr + 32'd4;
                end
            end
        end
    end

    // Pipeline can accept new AR only when not expanding a burst AND a pipeline
    // slot is truly available (not just !read_pipe_busy, which can be true even
    // when insert_pos == -1 because all free stages are shift destinations).
    assign axi_arready = !read_limit_reached && !read_pipe_busy && !burst_active && read_pipe_has_slot;
    // Track AR/R channel handshakes and outstanding reads
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_ar_requests <= 0;
            stat_r_responses <= 0;
            stat_outstanding_reads <= 0;
            current_outstanding_reads <= 0;
        end else begin
            // Handle simultaneous AR and R
            case ({(axi_arvalid && axi_arready), (axi_rvalid && axi_rready)})
                2'b10: begin  // AR only
                    stat_ar_requests <= stat_ar_requests + 1;
                    stat_outstanding_reads <= stat_outstanding_reads + 1;
                    current_outstanding_reads <= current_outstanding_reads + 1;
                end
                2'b01: begin  // R only
                    stat_r_responses <= stat_r_responses + 1;
                    if (stat_outstanding_reads > 0) begin
                        stat_outstanding_reads <= stat_outstanding_reads - 1;
                    end
                    if (current_outstanding_reads > 0) begin
                        current_outstanding_reads <= current_outstanding_reads - 1;
                    end
                end
                2'b11: begin  // Both AR and R
                    stat_ar_requests <= stat_ar_requests + 1;
                    stat_r_responses <= stat_r_responses + 1;
                    // Outstanding stays the same
                end
                default: begin  // Neither
                    // No change
                end
            endcase

            // Update max outstanding reads
            if (stat_outstanding_reads > stat_max_outstanding_reads) begin
                stat_max_outstanding_reads <= stat_outstanding_reads;
            end
        end
    end
    // Read pipeline advancement - simplified shift register for outstanding request support
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < MAX_READ_STAGES; i++) begin
                read_pipe[i].valid <= 1'b0;
                read_pipe[i].addr <= '0;
                read_pipe[i].data <= '0;
                read_pipe[i].resp <= 2'b00;
            end
        end else begin
            // Find the lowest-numbered pipeline stage available for a new beat.
            //
            // A stage is available if:
            //   (a) it is currently empty (valid == 0), AND
            //   (b) the shift logic will NOT place data into it this very cycle.
            //
            // The shift fires when stage 0 is free or being consumed
            // (!read_pipe[0].valid || axi_rready).  When the shift gate is open,
            // every stage N where read_pipe[N+1].valid == 1 will receive
            // read_pipe[N+1]'s data via an NBA assignment.  We must not also
            // target stage N with a burst-load NBA, because in SystemVerilog the
            // last NBA to a variable in a time-step wins – and the burst-load
            // block comes BEFORE the shift block below, so the shift would
            // silently overwrite the newly inserted data, losing that beat.
            //
            // We compute the LOWEST free, non-shift-destination stage.
            automatic logic shift_gate_open;
            automatic int insert_pos;
            shift_gate_open = !read_pipe[0].valid || axi_rready;
            insert_pos = -1;
            for (int i = MAX_READ_STAGES-1; i >= 0; i--) begin
                // This stage will be written by the shift if the gate is open
                // and the stage above it currently holds valid data.
                automatic logic shift_dst;
                shift_dst = shift_gate_open &&
                            (i < MAX_READ_STAGES-1) && read_pipe[i+1].valid;
                // Accept this stage as insert_pos only when it is currently
                // empty AND the shift is not also writing to it.
                if (!read_pipe[i].valid && !shift_dst)
                    insert_pos = i;  // keep iterating; we want the LOWEST index
            end

            // Shift pipeline forward (toward stage 0)
            // Stage 0: consumed by master
            if (read_pipe[0].valid && axi_rready) begin
               read_pipe[0].valid <= 1'b0;
            end

            // Shift all stages forward if stage 0 consumed or empty
            if (!read_pipe[0].valid || axi_rready) begin
                for (int i = 0; i < MAX_READ_STAGES-1; i++) begin
                    if (read_pipe[i+1].valid) begin
                        read_pipe[i] <= read_pipe[i+1];
                        read_pipe[i+1].valid <= 1'b0;
                    end
                end
            end

            // Accept new request into available stage
            // Accepts both fresh AR handshakes (arvalid&&arready) and
            // burst continuation beats (burst_active && pipeline has space).
            if ((axi_arvalid && axi_arready) || (burst_active && !read_pipe_busy && read_pipe_has_slot)) begin
                automatic logic [31:0] raw_addr;
                automatic logic        this_is_last;
                automatic int          target_stage;
                raw_addr = (axi_arvalid && axi_arready) ? axi_araddr : burst_addr;
                // is_last: true when this is the final beat of the transaction
                if (axi_arvalid && axi_arready) begin
                    // Single-beat (arlen==0) or first beat of burst that has only 1 beat
                    this_is_last = (axi_arlen == 8'h0);
                end else begin
                    // Burst continuation: last when only 1 remaining beat left
                    this_is_last = (burst_remaining == 8'h1);
                end

                // For 1-cycle latency, go directly to output stage if it's becoming free
                // Otherwise, insert at the first free position
                if (MEM_READ_LATENCY == 1 && (!read_pipe[0].valid || axi_rready)) begin
                    target_stage = 0;
                end else begin
                    target_stage = insert_pos;
                end

                if (target_stage >= 0) begin
                    automatic logic [31:0] word_addr;
                    automatic logic [31:0] read_value;
                    word_addr  = (raw_addr - BASE_ADDR) & (MEM_SIZE - 1) & ~32'h3;
                    read_pipe[target_stage].valid   <= 1'b1;
                    read_pipe[target_stage].addr    <= raw_addr;
                    read_pipe[target_stage].is_last <= this_is_last;
                    if (raw_addr < BASE_ADDR || raw_addr >= (BASE_ADDR + MEM_SIZE)) begin
                        read_pipe[target_stage].resp <= 2'b10;
                        read_pipe[target_stage].data <= 32'hDEADBEEF;
                        `DEBUG2(`DBG_GRP_AXIMEM, ("[RD][ERROR] addr=0x%08x out of range [0x%08x - 0x%08x]",
                                 raw_addr, BASE_ADDR, BASE_ADDR + MEM_SIZE));
                    end else begin
                        read_value = {mem[(word_addr + 3) & (MEM_SIZE-1)],
                                     mem[(word_addr + 2) & (MEM_SIZE-1)],
                                     mem[(word_addr + 1) & (MEM_SIZE-1)],
                                     mem[word_addr]};
                        read_pipe[target_stage].resp <= 2'b00;
                        read_pipe[target_stage].data <= read_value;
                        `DEBUG2(`DBG_GRP_AXIMEM, ("[RD] addr=0x%08x data=0x%08x [bytes: %02x %02x %02x %02x]",
                                 raw_addr, read_value,
                                 mem[word_addr],
                                 mem[(word_addr + 1) & (MEM_SIZE-1)],
                                 mem[(word_addr + 2) & (MEM_SIZE-1)],
                                 mem[(word_addr + 3) & (MEM_SIZE-1)]));
                    end
                end
            end
        end
    end

    // Read data channel outputs
    assign axi_rvalid = read_pipe[0].valid;
    assign axi_rdata  = read_pipe[0].data;
    assign axi_rresp  = read_pipe[0].resp;
    assign axi_rlast  = read_pipe[0].valid && read_pipe[0].is_last;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // empty
        end else if (burst_active) begin
            `DEBUG2(`DBG_GRP_AXIMEM, ("[PIPE] rvalid=%b rdata=0x%08h burst_active=%b burst_remaining=%0d pipe_valid=%b pipe_data=0x%08h",
                axi_rvalid, axi_rdata, burst_active, burst_remaining, read_pipe[0].valid, read_pipe[0].data));
        end
    end

    // ============================================================================
    // One-Port Memory Arbitration (only used when DUAL_PORT=0)
    // ============================================================================

    generate
        if (!MEM_DUAL_PORT) begin : gen_oneport_arbiter
            // Request signals
            logic write_req;
            logic read_req;

            always_comb begin
                write_req = (write_addr_valid && axi_wvalid) || axi_awvalid;
                read_req = axi_arvalid;
            end

            // Fair round-robin arbitration between read and write
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    arb_write_grant <= 1'b0;
                    arb_read_grant <= 1'b0;
                    arb_last_grant_was_write <= 1'b0;
                end else begin
                    // Default: no grant
                    arb_write_grant <= 1'b0;
                    arb_read_grant <= 1'b0;

                    if (write_req && read_req) begin
                        // Both requesting: use fair arbitration
                        if (arb_last_grant_was_write) begin
                            arb_read_grant <= 1'b1;
                            arb_last_grant_was_write <= 1'b0;
                        end else begin
                            arb_write_grant <= 1'b1;
                            arb_last_grant_was_write <= 1'b1;
                        end
                    end else if (write_req) begin
                        arb_write_grant <= 1'b1;
                        arb_last_grant_was_write <= 1'b1;
                    end else if (read_req) begin
                        arb_read_grant <= 1'b1;
                        arb_last_grant_was_write <= 1'b0;
                    end
                end
            end
        end else begin : gen_dualport
            // Dual-port: always grant both
            assign arb_write_grant = 1'b1;
            assign arb_read_grant = 1'b1;
        end
    endgenerate

    // DPI-C exports for memory access from C++
    export "DPI-C" function mem_write_byte;
    export "DPI-C" function mem_read_byte;
    export "DPI-C" function mem_get_stat_ar_requests;
    export "DPI-C" function mem_get_stat_r_responses;
    export "DPI-C" function mem_get_stat_aw_requests;
    export "DPI-C" function mem_get_stat_w_data;
    export "DPI-C" function mem_get_stat_w_expected;
    export "DPI-C" function mem_get_stat_b_responses;
    export "DPI-C" function mem_get_stat_max_outstanding_reads;
    export "DPI-C" function mem_get_stat_max_outstanding_writes;

    function void mem_write_byte(input int addr, input byte data);
        // Mask address to fit within memory array (same as AXI access)
        automatic int masked_addr = addr & (MEM_SIZE - 1);
        if (masked_addr >= 0 && masked_addr < MEM_SIZE) begin
            mem[masked_addr] = data;
        end else begin
            `DEBUG2(`DBG_GRP_AXIMEM, ("[WR][ERROR] addr=0x%08x masked=0x%08x OUT OF RANGE", addr, masked_addr));
        end
    endfunction

    function byte mem_read_byte(input int addr);
        // Mask address to fit within memory array (same as AXI access)
        automatic int masked_addr = addr & (MEM_SIZE - 1);
        if (masked_addr >= 0 && masked_addr < MEM_SIZE) begin
            return mem[masked_addr];
        end else begin
            return 8'hFF;
        end
    endfunction

    // Statistics getter functions for DPI-C
    function int mem_get_stat_ar_requests();
        return stat_ar_requests;
    endfunction

    function int mem_get_stat_r_responses();
        return stat_r_responses;
    endfunction

    function int mem_get_stat_aw_requests();
        return stat_aw_requests;
    endfunction

    function int mem_get_stat_w_data();
        return stat_w_data;
    endfunction

    function int mem_get_stat_w_expected();
        return stat_w_expected;
    endfunction

    function int mem_get_stat_b_responses();
        return stat_b_responses;
    endfunction

    function int mem_get_stat_max_outstanding_reads();
        return stat_max_outstanding_reads;
    endfunction

    function int mem_get_stat_max_outstanding_writes();
        return stat_max_outstanding_writes;
    endfunction

    // Suppress unused signals that exist for backward compat, single-port mode, or future use
    logic _unused_ok_mem;
    assign _unused_ok_mem = &{1'b0, axi_awsize, axi_arsize, state,
                              arb_last_grant_was_write, read_can_accept,
                              write_addr_accepted, write_data_accepted,
                              burst_total_len};

endmodule

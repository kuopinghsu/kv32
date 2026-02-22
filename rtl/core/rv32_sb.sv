// ============================================================================
// RISC-V Store Buffer (SB)
// ============================================================================
//
// Purpose:
//   Buffers store operations to decouple the CPU from memory system latency.
//   Allows the processor to continue execution while stores complete in the
//   background, improving performance by hiding store latency.
//
// Key Features:
//   - FIFO-based in-order store completion
//   - Configurable depth for multiple outstanding stores
//   - Inflight tracking for issued but incomplete stores
//   - Flush mechanism for exception/branch handling
//   - Backpressure control to CPU via ready signal
//
// Design Rationale:
//   Without a store buffer, the CPU would stall on every store instruction
//   waiting for memory. The store buffer allows:
//   1. CPU to continue after initiating store (if buffer has space)
//   2. Stores to complete in background without blocking pipeline
//   3. Multiple stores to be outstanding simultaneously
//   4. In-order memory consistency (stores issue in program order)
//
// Memory Ordering:
//   Stores are issued to memory in FIFO order (program order) to maintain
//   memory consistency. The oldest buffered store is always issued first.
//
// State Machine:
//   Each buffer entry transitions through states:
//   1. INVALID: Entry is free
//   2. VALID: Entry contains store data, not yet sent to memory
//   3. INFLIGHT: Store sent to memory, waiting for response
//   4. Invalid again after response received
//
// Flush Handling:
//   On flush (exception/branch), all buffered stores are discarded because:
//   - They may be from speculative execution on wrong path
//   - Exception handler needs clean state
//   Note: Stores already in-flight may complete, but results are ignored
//
// ============================================================================

module rv32_sb #(
    parameter int DEPTH = 2,      // Number of stores that can be buffered
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // CPU-side interface (write from CPU)
    input  logic                  cpu_valid,
    input  logic [ADDR_WIDTH-1:0] cpu_addr,
    input  logic [DATA_WIDTH-1:0] cpu_data,
    input  logic [DATA_WIDTH/8-1:0] cpu_strb,
    output logic                  cpu_ready,

    // Memory-side interface (write to memory)
    output logic                  mem_valid,
    output logic [ADDR_WIDTH-1:0] mem_addr,
    output logic [DATA_WIDTH-1:0] mem_data,
    output logic [DATA_WIDTH/8-1:0] mem_strb,
    input  logic                  mem_ready,

    // Response interface
    input  logic                  resp_valid,
    input  logic                  resp_error,
    output logic                  resp_ready,

    // Flush control
    input  logic                  flush,

    // Status
    output logic [$clog2(DEPTH+1)-1:0] buffered_count,
    output logic                  store_pending
);
    import rv32_pkg::*;

    localparam int PTR_WIDTH = $clog2(DEPTH);
    localparam int CNT_WIDTH = $clog2(DEPTH+1);

    // ========================================================================
    // Store Entry Structure
    // ========================================================================
    //
    // Each buffer entry stores a complete store operation:
    //   - addr: Memory address to write to
    //   - data: Data value to write
    //   - strb: Byte enable strobes (1 bit per byte)
    //   - valid: Entry contains valid store data
    //   - inflight: Store has been issued to memory, awaiting response
    //
    // State transitions:
    //   INVALID (valid=0) -> VALID (valid=1, inflight=0) ->
    //   INFLIGHT (valid=1, inflight=1) -> INVALID (valid=0)
    // ========================================================================

    typedef struct packed {
        logic [ADDR_WIDTH-1:0]     addr;
        logic [DATA_WIDTH-1:0]     data;
        logic [DATA_WIDTH/8-1:0]   strb;
        logic                      valid;     // Entry contains pending store
        logic                      inflight;  // Sent to memory, waiting for ack
    } store_entry_t;

    // ========================================================================
    // Internal State
    // ========================================================================

    // Store buffer organized as circular FIFO
    store_entry_t buffer [0:DEPTH-1];

    // FIFO pointers:
    //   wr_ptr: Where next CPU store is written (tail of queue)
    //   rd_ptr: Oldest store, issued to memory (head of queue)
    logic [PTR_WIDTH-1:0] wr_ptr;
    logic [PTR_WIDTH-1:0] rd_ptr;

    // Number of valid entries currently in buffer
    logic [CNT_WIDTH-1:0] count;

    // Helper signals for assertions
    logic alloc, complete, issue;
    logic [CNT_WIDTH-1:0] inflight_count;

    assign alloc = cpu_valid && cpu_ready && !flush;
    assign complete = resp_valid && buffer[rd_ptr].valid;
    assign issue = mem_valid && mem_ready;

    // Count inflight entries
    always_comb begin
        inflight_count = '0;
        for (int i = 0; i < DEPTH; i++) begin
            if (buffer[i].valid && buffer[i].inflight) begin
                inflight_count = inflight_count + 1'b1;
            end
        end
    end

    // ========================================================================
    // Output Assignment Logic
    // ========================================================================

    assign buffered_count = count;
    assign store_pending = (count > 0);

    // cpu_ready: Can accept new store from CPU
    // Conditions:
    //   1. Buffer not full (count < DEPTH)
    //   2. Not in flush state (flush prevents new stores)
    assign cpu_ready = (count < CNT_WIDTH'(DEPTH)) && !flush;

    // can_issue: Can issue store to memory
    // Conditions:
    //   1. Entry at read pointer is valid (contains store data)
    //   2. Entry is not already inflight (prevents duplicate issue)
    // This ensures in-order issue: oldest store goes first
    logic can_issue;
    assign can_issue = buffer[rd_ptr].valid && !buffer[rd_ptr].inflight;

    // ========================================================================
    // Memory Interface
    // ========================================================================
    //
    // Always presents the oldest (head of queue) store to memory.
    // Memory can accept it when mem_ready asserts.
    // Response handling is always ready (resp_ready=1) to avoid backpressure.
    // ========================================================================

    assign mem_valid = can_issue;
    assign mem_addr = buffer[rd_ptr].addr;
    assign mem_data = buffer[rd_ptr].data;
    assign mem_strb = buffer[rd_ptr].strb;
    assign resp_ready = 1'b1;  // Always ready to accept responses

    // ========================================================================
    // Buffer Entry Allocation and State Management
    // ========================================================================
    //
    // Three concurrent operations can occur:
    //   1. CPU writes new store -> buffer[wr_ptr] becomes VALID
    //   2. Memory accepts store -> buffer[rd_ptr] becomes INFLIGHT
    //   3. Flush -> all entries become INVALID
    //
    // Priority: Flush takes precedence over allocation and issue
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            for (int i = 0; i < DEPTH; i++) begin
                buffer[i] <= '0;
            end
        end else begin
            // Operation 1: Allocate new entry when CPU writes
            // Only allocate if:
            //   - CPU has valid store (cpu_valid)
            //   - Buffer has space (cpu_ready)
            //   - Not flushing (flush would immediately invalidate)
            if (cpu_valid && cpu_ready && !flush) begin
                buffer[wr_ptr].addr <= cpu_addr;
                buffer[wr_ptr].data <= cpu_data;
                buffer[wr_ptr].strb <= cpu_strb;
                buffer[wr_ptr].valid <= 1'b1;
                buffer[wr_ptr].inflight <= 1'b0;
                if (PTR_WIDTH > 0) begin
                    wr_ptr <= wr_ptr + 1'b1;  // Advance tail pointer
                end
                `DBG2(("SB: Allocate entry wrptr=%0d addr=0x%h data=0x%h strb=0x%h",
                       wr_ptr, cpu_addr, cpu_data, cpu_strb));
            end

            // Operation 2: Mark entry as inflight when issued to memory
            // Condition: Memory accepts the store (handshake completes)
            if (mem_valid && mem_ready) begin
                buffer[rd_ptr].inflight <= 1'b1;
                `DBG2(("SB: Issue store rdptr=%0d addr=0x%h", rd_ptr, buffer[rd_ptr].addr));
            end

            // Operation 3: Flush - clear all entries
            // This happens on exceptions or branch mispredictions
            // All pending stores are discarded (may be from wrong execution path)
            if (flush) begin
                for (int i = 0; i < DEPTH; i++) begin
                    buffer[i].valid <= 1'b0;
                    buffer[i].inflight <= 1'b0;
                end
                `DBG2(("SB: Flush all entries"));
            end
        end
    end

    // ========================================================================
    // Buffer Entry Completion and Read Pointer Management
    // ========================================================================
    //
    // When memory completes a store (resp_valid), the entry at rd_ptr is:
    //   1. Marked invalid (freed)
    //   2. Read pointer advances to next entry
    //
    // Flush resets both pointers to synchronize and start fresh.
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= '0;
        end else begin
            // Complete entry when response arrives
            // resp_valid indicates memory system has finished the store
            // Valid check prevents spurious responses from affecting invalid entries
            if (resp_valid && buffer[rd_ptr].valid) begin
                buffer[rd_ptr].valid <= 1'b0;      // Free the entry
                buffer[rd_ptr].inflight <= 1'b0;   // Clear inflight flag
                if (PTR_WIDTH > 0) begin
                    rd_ptr <= rd_ptr + 1'b1;       // Advance head pointer
                end
                `DBG2(("SB: Complete store rdptr=%0d %s",
                       rd_ptr, resp_error ? "ERROR" : "OK"));
            end

            // Reset pointers on flush to start fresh
            // Both pointers reset to 0, making buffer empty
            if (flush) begin
                wr_ptr <= '0;
                rd_ptr <= '0;
            end
        end
    end

    // ========================================================================
    // Count Tracking
    // ========================================================================
    //
    // Maintains accurate count of valid entries in the buffer.
    // Used for:
    //   - cpu_ready decision (is buffer full?)
    //   - store_pending indication
    //   - Debug and performance monitoring
    //
    // Count changes when:
    //   - Alloc only: count++
    //   - Complete only: count--
    //   - Both or neither: count unchanged
    //   - Flush: count = 0
    //
    // Note: Flush takes priority over alloc/complete in same cycle
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= '0;
        end else begin
            if (flush) begin
                // Flush: reset count immediately
                count <= '0;
            end else begin
                // Update count based on concurrent events
                case ({alloc, complete})
                    2'b10: count <= count + 1'b1;  // Allocate only
                    2'b01: count <= count - 1'b1;  // Complete only
                    default: ; // Both or neither: no change
                endcase
            end
        end
    end

    // ========================================================================
    // Assertions for FIFO Integrity and Protocol Checking
    // ========================================================================
    // Define ASSERTION by default (can be disabled with +define+NO_ASSERTION)
`ifndef NO_ASSERTION
`ifndef ASSERTION
`define ASSERTION
`endif
`endif // NO_ASSERTION

`ifdef ASSERTION

    // FIFO Overflow Protection
    property p_no_overflow_allocate;
        @(posedge clk) disable iff (!rst_n)
        (cpu_valid && !flush && !cpu_ready) |-> (count >= CNT_WIDTH'(DEPTH));
    endproperty
    assert property (p_no_overflow_allocate)
        else $error("[SB] FIFO overflow: allocation attempt when buffer full");

    property p_count_bounds;
        @(posedge clk) disable iff (!rst_n)
        count <= CNT_WIDTH'(DEPTH);
    endproperty
    assert property (p_count_bounds)
        else $error("[SB] Count exceeded limit: %0d > %0d", count, DEPTH);

    property p_buffered_count_match;
        @(posedge clk) disable iff (!rst_n)
        buffered_count == count;
    endproperty
    assert property (p_buffered_count_match)
        else $error("[SB] buffered_count output does not match internal count");

    // FIFO Underflow Protection
    property p_no_underflow_issue;
        @(posedge clk) disable iff (!rst_n)
        mem_valid |-> buffer[rd_ptr].valid;
    endproperty
    assert property (p_no_underflow_issue)
        else $error("[SB] FIFO underflow: issue when entry invalid");

    property p_no_underflow_complete;
        @(posedge clk) disable iff (!rst_n)
        complete |-> count > 0;
    endproperty
    assert property (p_no_underflow_complete)
        else $error("[SB] FIFO underflow: completion when count=0");

    // Pointer Wraparound Safety (for DEPTH > 1)
    generate
        if (PTR_WIDTH > 0) begin : g_ptr_checks
            property p_wr_ptr_bounds;
                @(posedge clk) disable iff (!rst_n)
                wr_ptr < DEPTH;
            endproperty
            assert property (p_wr_ptr_bounds)
                else $error("[SB] Write pointer out of bounds: %0d >= %0d", wr_ptr, DEPTH);

            property p_rd_ptr_bounds;
                @(posedge clk) disable iff (!rst_n)
                rd_ptr < DEPTH;
            endproperty
            assert property (p_rd_ptr_bounds)
                else $error("[SB] Read pointer out of bounds: %0d >= %0d", rd_ptr, DEPTH);
        end
    endgenerate

    // State Transition Checks at Pointer Locations
    property p_alloc_creates_valid;
        @(posedge clk) disable iff (!rst_n)
        alloc |=> buffer[$past(wr_ptr)].valid && !buffer[$past(wr_ptr)].inflight;
    endproperty
    assert property (p_alloc_creates_valid)
        else $error("[SB] Allocation did not create valid (non-inflight) entry");

    // Note: Issue assertion accounts for flush which can clear inflight flag
    property p_issue_sets_inflight;
        @(posedge clk) disable iff (!rst_n)
        (issue && !flush) |=> buffer[$past(rd_ptr)].inflight;
    endproperty
    assert property (p_issue_sets_inflight)
        else $error("[SB] Issue (without flush) did not set inflight flag");

    property p_complete_invalidates;
        @(posedge clk) disable iff (!rst_n)
        (complete && !flush) |=> !buffer[$past(rd_ptr)].valid;
    endproperty
    assert property (p_complete_invalidates)
        else $error("[SB] Completion did not invalidate entry");

    // Count Consistency
    logic [CNT_WIDTH-1:0] actual_count;
    always_comb begin
        actual_count = '0;
        for (int i = 0; i < DEPTH; i++) begin
            if (buffer[i].valid) begin
                actual_count = actual_count + 1'b1;
            end
        end
    end

    property p_count_consistency;
        @(posedge clk) disable iff (!rst_n)
        count == actual_count;
    endproperty
    assert property (p_count_consistency)
        else $error("[SB] Count mismatch: counter=%0d, actual=%0d", count, actual_count);

    // Inflight Consistency
    property p_inflight_bounded;
        @(posedge clk) disable iff (!rst_n)
        inflight_count <= count;
    endproperty
    assert property (p_inflight_bounded)
        else $error("[SB] Inflight count exceeds total: %0d > %0d", inflight_count, count);

    // Flush Behavior
    property p_flush_resets_count;
        @(posedge clk) disable iff (!rst_n)
        flush |=> (count == 0);
    endproperty
    assert property (p_flush_resets_count)
        else $error("[SB] Flush did not reset count");

    property p_flush_resets_inflight;
        @(posedge clk) disable iff (!rst_n)
        flush |=> (inflight_count == 0);
    endproperty
    assert property (p_flush_resets_inflight)
        else $error("[SB] Flush did not reset inflight count");

    property p_flush_invalidates_all;
        @(posedge clk) disable iff (!rst_n)
        flush |=> (actual_count == 0);
    endproperty
    assert property (p_flush_invalidates_all)
        else $error("[SB] Flush did not invalidate all entries");

    generate
        if (PTR_WIDTH > 0) begin : g_flush_ptr_checks
            property p_flush_resets_pointers;
                @(posedge clk) disable iff (!rst_n)
                flush |=> (wr_ptr == 0) && (rd_ptr == 0);
            endproperty
            assert property (p_flush_resets_pointers)
                else $error("[SB] Flush did not reset pointers");
        end
    endgenerate

    // Ready Signal Consistency
    property p_cpu_ready_when_not_full;
        @(posedge clk) disable iff (!rst_n)
        (count < CNT_WIDTH'(DEPTH) && !flush) |-> cpu_ready;
    endproperty
    assert property (p_cpu_ready_when_not_full)
        else $error("[SB] cpu_ready=0 when buffer not full");

    property p_cpu_ready_zero_when_full;
        @(posedge clk) disable iff (!rst_n)
        (count >= CNT_WIDTH'(DEPTH)) |-> !cpu_ready;
    endproperty
    assert property (p_cpu_ready_zero_when_full)
        else $error("[SB] cpu_ready=1 when buffer full");

    property p_resp_ready_always_high;
        @(posedge clk) disable iff (!rst_n)
        resp_ready == 1'b1;
    endproperty
    assert property (p_resp_ready_always_high)
        else $error("[SB] resp_ready should always be 1");

    // mem_valid Behavior
    property p_mem_valid_needs_valid_entry;
        @(posedge clk) disable iff (!rst_n)
        mem_valid |-> buffer[rd_ptr].valid;
    endproperty
    assert property (p_mem_valid_needs_valid_entry)
        else $error("[SB] mem_valid asserted with invalid entry");

    property p_mem_valid_not_inflight;
        @(posedge clk) disable iff (!rst_n)
        mem_valid |-> !buffer[rd_ptr].inflight;
    endproperty
    assert property (p_mem_valid_not_inflight)
        else $error("[SB] mem_valid asserted for already inflight entry");

    property p_can_issue_implies_count;
        @(posedge clk) disable iff (!rst_n)
        can_issue |-> count > 0;
    endproperty
    assert property (p_can_issue_implies_count)
        else $error("[SB] can_issue asserted but count=0");

    // X/Z Detection
    property p_no_x_cpu_valid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(cpu_valid);
    endproperty
    assert property (p_no_x_cpu_valid)
        else $error("[SB] X/Z detected on cpu_valid");

    property p_no_x_cpu_ready;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(cpu_ready);
    endproperty
    assert property (p_no_x_cpu_ready)
        else $error("[SB] X/Z detected on cpu_ready");

    property p_no_x_mem_valid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(mem_valid);
    endproperty
    assert property (p_no_x_mem_valid)
        else $error("[SB] X/Z detected on mem_valid");

    property p_no_x_mem_ready;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(mem_ready);
    endproperty
    assert property (p_no_x_mem_ready)
        else $error("[SB] X/Z detected on mem_ready");

    property p_no_x_resp_valid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(resp_valid);
    endproperty
    assert property (p_no_x_resp_valid)
        else $error("[SB] X/Z detected on resp_valid");

    property p_no_x_flush;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(flush);
    endproperty
    assert property (p_no_x_flush)
        else $error("[SB] X/Z detected on flush");

`endif // ASSERTION

endmodule

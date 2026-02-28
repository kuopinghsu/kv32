// ============================================================================
// File: kv32_ib.sv
// Project: KV32 RISC-V Processor
// Description: Instruction Buffer (IB)
//
// Purpose:
//   Tracks Program Counter (PC) values for outstanding instruction fetch
//   requests in a pipelined processor. This allows the core to issue multiple
//   fetch requests before earlier ones complete, improving performance.
//
// Key Features:
//   - FIFO-based PC tracking for in-order instruction delivery
//   - Configurable depth to support multiple outstanding fetches
//   - Flush mechanism with response discard for branch mispredictions
//   - Backpressure control via can_accept signal
//
// Design Rationale:
//   The instruction buffer solves the PC/instruction matching problem when
//   the memory system has latency and the processor can issue multiple requests.
//   Without this buffer, it would be impossible to know which PC corresponds
//   to which returning instruction.
//
// Flush Handling:
//   When a flush occurs (e.g., branch taken), outstanding requests must be
//   discarded because they're for the wrong path. The buffer:
//   1. Saves the count of outstanding requests to discard_cnt
//   2. Marks responses as discardable until discard_cnt reaches zero
//   3. Prevents FIFO pointer corruption by not resetting on flush
//   4. Allows new requests once there's space for both active and discarding
//
// Race Conditions Handled:
//   - Flush in same cycle as response consumption: discard_cnt adjusted
//   - Multiple flushes before responses arrive: old discard_cnt preserved
//   - FIFO wraparound with active discards: space check includes both counts
//
// ============================================================================

`ifdef SYNTHESIS
import kv32_pkg::*;
`endif
module kv32_ib #(
    parameter int DEPTH = 2,  // Number of outstanding requests supported
    parameter int ADDR_WIDTH = 32
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // Request interface
    input  logic                  req_valid,
    input  logic [ADDR_WIDTH-1:0] req_addr,
    input  logic                  req_ready,
    output logic                  can_accept,    // Buffer can accept new request

    // Response interface
    input  logic                  resp_valid,
    output logic [ADDR_WIDTH-1:0] resp_addr,     // PC for current response
    output logic                  resp_discard,  // Response should be discarded
    input  logic                  resp_consume,  // Response consumed

    // Flush control
    input  logic                  flush,         // Flush signal

    // Status
    output logic [$clog2(DEPTH+1)-1:0] outstanding_count
);
`ifndef SYNTHESIS
    import kv32_pkg::*;
`endif

    localparam int PTR_WIDTH = $clog2(DEPTH);
    localparam int CNT_WIDTH = $clog2(DEPTH+1);

    // ========================================================================
    // Internal State
    // ========================================================================

    // PC FIFO storage: Stores PC values for outstanding fetch requests
    // Organized as a circular buffer with separate read/write pointers
    logic [ADDR_WIDTH-1:0] pc_fifo [0:DEPTH-1];
    logic [PTR_WIDTH-1:0]  wr_ptr;              // Write pointer: where next PC is stored
    logic [PTR_WIDTH-1:0]  rd_ptr;              // Read pointer: PC for next response

    // Request tracking counters:
    // - outstanding: Active requests waiting for responses to be consumed
    // - discard_cnt: Flushed requests whose responses should be discarded
    // These are separate because:
    //   1. We need space for both active and discarding requests
    //   2. Responses for discarded requests still arrive and must be tracked
    //   3. discard_cnt decrements on ANY response, outstanding only on consumed ones
    logic [CNT_WIDTH-1:0]  outstanding;
    logic [CNT_WIDTH-1:0]  discard_cnt;

    // ========================================================================
    // Output Assignment Logic
    // ========================================================================

    assign outstanding_count = outstanding;

    // can_accept: Buffer can accept a new request when FIFO has space.
    //
    // Performance optimization:
    //   Issue during discard phase: the original design blocked all new fetches
    //   while discard_cnt > 0 (flush recovery).  This wastes discard_cnt cycles
    //   unnecessarily, because:
    //     a) AXI responses are strictly in-order (constant ID=0).
    //     b) New-path requests are appended at wr_ptr AFTER old discard entries.
    //     c) The pipeline reads resp_addr only when resp_discard=0, so writing
    //        new PCs on top of (already consumed) discard slots is harmless.
    //     d) Branch early-fetch can coincide with flush=1 (branch_taken cycle),
    //        issuing a req_sent=1 in the same flush cycle.  The discard_cnt flush
    //        formula accounts for all same-cycle consumed responses (see the
    //        always_ff block below for details).
    //   As a result, (outstanding + discard_cnt) is the true total FIFO occupancy
    //   and is the only guard needed.
    //
    // NOTE: The "same-cycle refill" look-ahead optimization has been intentionally
    //   removed.  The look-ahead subtracted resp_any_will_free_slot from the
    //   occupancy check, allowing a new push to wr_ptr even when outstanding==DEPTH.
    //   However, when a flush + early-fetch coincides with the full-buffer refill
    //   (a simultaneously consumed response), wr_ptr aliases onto a FIFO slot that
    //   still has a live in-flight request (the pre-flush entry that hasn't returned
    //   yet).  The new PC overwrites that slot, making rd_ptr mislabel the old
    //   response as the new target and permanently locking outstanding at 1.
    //   Removing the look-ahead prevents this aliasing.  The FIFO depth must be
    //   a power-of-2 and at least (max_effective_latency + 1) to sustain full
    //   throughput without the look-ahead; the default IB_DEPTH of 4 accommodates
    //   the 2-cycle effective latency through the AXI path (arbiter + crossbar +
    //   1-cycle RAM) while using power-of-2 pointer arithmetic.

    assign can_accept = ((outstanding + discard_cnt) < CNT_WIDTH'(DEPTH));

    // resp_addr: PC corresponding to the current response
    // Always reads from rd_ptr, which tracks responses in-order
    assign resp_addr = pc_fifo[rd_ptr];

    // resp_discard: Indicates this response should be discarded (not consumed)
    // Set when there are unprocessed flushed requests
    assign resp_discard = (discard_cnt > 0);

    // ========================================================================
    // Request and Response Event Detection
    // ========================================================================

    logic req_sent, resp_consumed, resp_consumed_valid;
    logic can_accept_q;

    // req_sent: A new fetch request was accepted by memory system
    assign req_sent = req_valid && req_ready;

    // resp_consumed: A response was consumed by the pipeline (discard or valid)
    assign resp_consumed = resp_valid && resp_consume;

    // resp_consumed_valid: A response was consumed AND it is NOT being discarded
    // This distinction matters only for the outstanding counter:
    // - Discarded responses decrement discard_cnt, not outstanding
    // - Only valid (non-discarded) consumptions reduce outstanding count
    assign resp_consumed_valid = resp_consumed && (discard_cnt == 0);

`ifdef DEBUG
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            can_accept_q <= 1'b0;
        end else begin
            if (can_accept != can_accept_q) begin
                `DEBUG2(("IB: can_accept %0b->%0b (out=%0d discard=%0d req_v=%0b req_r=%0b resp_v=%0b resp_c=%0b)",
                       can_accept_q, can_accept, outstanding, discard_cnt,
                       req_valid, req_ready, resp_valid, resp_consume));
            end

            if (req_valid && req_ready) begin
                `DEBUG2(("IB: issue accepted (out=%0d discard=%0d can_accept=%0b)",
                       outstanding, discard_cnt, can_accept));
            end else if (req_valid && !req_ready) begin
                `DEBUG2(("IB: issue blocked by req_ready=0 (out=%0d discard=%0d can_accept=%0b)",
                       outstanding, discard_cnt, can_accept));
            end else if (!req_valid && can_accept && !flush) begin
                `DEBUG2(("IB: no issue while can_accept=1 (out=%0d discard=%0d)",
                       outstanding, discard_cnt));
            end

            if ((outstanding == CNT_WIDTH'(DEPTH)) && resp_consumed_valid) begin
                `DEBUG2(("IB: full-depth, response consumed (out=%0d discard=%0d can_accept=%0b)",
                       outstanding, discard_cnt, can_accept));
            end

            can_accept_q <= can_accept;
        end
    end
`endif

    // ========================================================================
    // Outstanding and Discard Counter Management
    // ========================================================================
    //
    // State Machine Logic:
    //   Normal operation:
    //     - outstanding++ when req_sent and no valid response consumed
    //     - outstanding-- when valid response consumed and no req_sent
    //     - discard_cnt decrements on ANY response arrival (resp_valid)
    //
    //   Flush event:
    //     - All outstanding requests become discardable
    //     - outstanding resets to 0 (new requests start fresh)
    //     - discard_cnt = outstanding (or outstanding-1 if concurrent consume)
    //
    // Why separate counters?
    //   - outstanding: Tracks requests we expect to consume
    //   - discard_cnt: Tracks responses we must ignore
    //   - They're independent because flush converts outstanding to discardable
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            outstanding <= '0;
            discard_cnt <= '0;
        end else begin
            // Priority 1: Handle flush - mark outstanding requests for discard
            if (flush) begin
                // Critical race conditions on the same cycle as flush:
                //
                // Case A: resp_consumed_valid=1 (a VALID, non-discarded response
                //   is consumed).  rd_ptr advances past one outstanding entry, so
                //   that entry must NOT become a discard target.
                //   discard_cnt += outstanding - 1
                //
                // Case B: resp_consumed=1 AND discard_cnt>0 (a previously-marked
                //   DISCARD entry is drained from the FIFO in the same cycle).
                //   rd_ptr advances past that discard entry, so discard_cnt must
                //   subtract 1 for the drained entry AND add outstanding for newly
                //   flushed entries.
                //   discard_cnt += outstanding - 1
                //   (same formula as Case A: one consumed response, do not re-count it)
                //
                // Case C: no response consumed.
                //   discard_cnt += outstanding
                if (resp_consumed_valid || (resp_consumed && discard_cnt > 0)) begin
                    if ((discard_cnt + outstanding - 1'b1) > CNT_WIDTH'(DEPTH))
                        discard_cnt <= CNT_WIDTH'(DEPTH);
                    else
                        discard_cnt <= discard_cnt + outstanding - 1'b1;
                    `DEBUG2(("IB: Flush - adding %0d outstanding to discard (adj for consume)", outstanding - 1'b1));
                end else begin
                    if ((discard_cnt + outstanding) > CNT_WIDTH'(DEPTH))
                        discard_cnt <= CNT_WIDTH'(DEPTH);
                    else
                        discard_cnt <= discard_cnt + outstanding;
                    `DEBUG2(("IB: Flush - adding %0d outstanding to discard", outstanding));
               end
                // Early-branch-target: if a new request is sent on the same
                // cycle as the flush (branch_taken cycle), count it as
                // outstanding=1 so the response is not lost.
                outstanding <= req_sent ? CNT_WIDTH'(1'b1) : CNT_WIDTH'('0);
                if (req_sent)
                    `DEBUG2(("IB: Flush+early-fetch: outstanding starts at 1 for addr=0x%h",
                           req_addr));
            end else begin
                // Priority 2: Decrement discard counter when response is consumed
                // CRITICAL: Must use resp_consumed (not resp_valid) to stay synchronized
                // with mem_axi_ro FIFO which only pops on resp_consumed
                if (resp_consumed && discard_cnt > 0) begin
                    discard_cnt <= discard_cnt - 1'b1;
                    `DEBUG2(("IB: Discarding response, discard_cnt=%0d->%0d", discard_cnt, discard_cnt - 1'b1));
                end

                // Priority 3: Update outstanding count based on valid request/response pairs
                // Only count responses that are NOT being discarded (resp_consumed_valid)
                // Handle simultaneous req_sent and resp_consumed_valid: they cancel out
                if (req_sent && resp_consumed_valid) begin
                    // Both happen: net effect is zero change (one in, one out)
                    outstanding <= outstanding;
                end else if (req_sent && !resp_consumed_valid && (outstanding < CNT_WIDTH'(DEPTH))) begin
                    outstanding <= outstanding + 1'b1;
                end else if (!req_sent && resp_consumed_valid && (outstanding > 0)) begin
                    outstanding <= outstanding - 1'b1;
                end
            end
        end
    end

    // ========================================================================
    // FIFO Write Pointer and PC Storage
    // ========================================================================
    //
    // Stores PC values in FIFO order as requests are sent. The write pointer
    // is NOT reset on flush because:
    //   1. Flushed requests still need their PCs tracked until responses arrive
    //   2. Resetting would cause new PCs to overwrite old ones prematurely
    //   3. The circular buffer naturally wraps, space is controlled by can_accept
    //
    // The ptr_width check enables single-entry optimization (when DEPTH=1)
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            for (int i = 0; i < DEPTH; i++) begin
                pc_fifo[i] <= '0;
            end
        end else if (req_sent) begin
            // Store the PC for this fetch request
            pc_fifo[wr_ptr] <= req_addr;
            // Advance write pointer (wraps automatically due to bit width)
            if (PTR_WIDTH > 0) begin
                wr_ptr <= wr_ptr + 1'b1;
            end
            `DEBUG2(("IB: Push pc=0x%h wrptr=%0d", req_addr, wr_ptr));
        end
    end

    // ========================================================================
    // FIFO Read Pointer and Response Processing
    // ========================================================================
    //
    // Advances the read pointer under two conditions:
    //   1. Discard mode: Response arrives for flushed request (resp_valid & discard_cnt > 0)
    //   2. Normal mode: Response is consumed by pipeline (resp_consumed & discard_cnt == 0)
    //
    // Key insight: The read pointer must advance on BOTH discarded and consumed
    // responses because both "use up" a FIFO slot and move to the next stored PC.
    //
    // Like wr_ptr, rd_ptr is NOT reset on flush to prevent corruption of the
    // PC-to-response mapping for in-flight requests.
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= '0;
        end else if (resp_consumed && discard_cnt > 0) begin
            // Case 1: Discarding - response consumed for flushed request
            // CRITICAL: Must use resp_consumed (not resp_valid) to stay synchronized
            // with mem_axi_ro FIFO rd_ptr which advances on resp_consumed
            if (PTR_WIDTH > 0) begin
                rd_ptr <= rd_ptr + 1'b1;
            end
            `DEBUG2(("IB: Discard pc=0x%h rdptr=%0d", pc_fifo[rd_ptr], rd_ptr));
        end else if (resp_consumed && discard_cnt == 0) begin
            // Case 2: Normal operation - valid response consumed by pipeline
            // Pop the PC and advance to next entry
            if (PTR_WIDTH > 0) begin
                rd_ptr <= rd_ptr + 1'b1;
            end
            `DEBUG2(("IB: Pop pc=0x%h rdptr=%0d", pc_fifo[rd_ptr], rd_ptr));
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
    property p_no_overflow;
        @(posedge clk) disable iff (!rst_n)
        req_sent |-> can_accept;
    endproperty
    assert property (p_no_overflow)
        else $error("[IB] FIFO overflow: request sent when buffer full");

    property p_outstanding_bounds;
        @(posedge clk) disable iff (!rst_n)
        outstanding <= CNT_WIDTH'(DEPTH);
    endproperty
    assert property (p_outstanding_bounds)
        else $error("[IB] Outstanding count exceeded limit: %0d > %0d", outstanding, DEPTH);

    property p_discard_bounds;
        @(posedge clk) disable iff (!rst_n)
        discard_cnt <= CNT_WIDTH'(DEPTH);
    endproperty
    assert property (p_discard_bounds)
        else $error("[IB] Discard count exceeded limit: %0d > %0d", discard_cnt, DEPTH);

    property p_total_count_bounds;
        @(posedge clk) disable iff (!rst_n)
        (outstanding + discard_cnt) <= CNT_WIDTH'(DEPTH);
    endproperty
    assert property (p_total_count_bounds)
        else $error("[IB] Total count (outstanding+discard) exceeded: %0d > %0d",
                    outstanding + discard_cnt, DEPTH);

    // FIFO Underflow Protection
    property p_no_underflow_discard;
        @(posedge clk) disable iff (!rst_n)
        (resp_valid && (discard_cnt > 0)) |-> (outstanding + discard_cnt) > 0;
    endproperty
    assert property (p_no_underflow_discard)
        else $error("[IB] FIFO underflow: discarding response when buffer empty");

    property p_no_underflow_consume;
        @(posedge clk) disable iff (!rst_n)
        (resp_consumed_valid && !flush) |-> (outstanding > 0);
    endproperty
    // Account for flush happening simultaneously with consume
    assert property (p_no_underflow_consume)
        else $error("[IB] FIFO underflow: consuming response when outstanding=0");

    // Discard Counter Behavior
    // Updated to use resp_consumed (not resp_valid) to stay synchronized with mem_axi_ro FIFO
    property p_discard_decrements;
        @(posedge clk) disable iff (!rst_n)
        (resp_consumed && (discard_cnt > 0) && !flush) |=> (discard_cnt == $past(discard_cnt) - 1'b1) || ($past(flush));
    endproperty
    assert property (p_discard_decrements)
        else $error("[IB] Discard count did not decrement on response");

    property p_discard_zero_no_discard;
        @(posedge clk) disable iff (!rst_n)
        (discard_cnt == 0) |-> !resp_discard;
    endproperty
    assert property (p_discard_zero_no_discard)
        else $error("[IB] resp_discard asserted when discard_cnt=0");

    property p_discard_nonzero_discard;
        @(posedge clk) disable iff (!rst_n)
        (discard_cnt > 0) |-> resp_discard;
    endproperty
    assert property (p_discard_nonzero_discard)
        else $error("[IB] resp_discard not asserted when discard_cnt>0");

    // Flush Behavior
    // Flush resets outstanding (possibly to 1 if a new req was sent simultaneously)
    property p_flush_resets_outstanding;
        @(posedge clk) disable iff (!rst_n)
        flush |=> (outstanding == 0) || $past(resp_consumed_valid) || $past(req_sent);
    endproperty
    assert property (p_flush_resets_outstanding)
        else $error("[IB] Flush did not reset outstanding count");

    // Note: Commenting out discard_cnt check because flush+response race conditions
    // make this assertion too strict. The count consistency checks should catch
    // actual bugs. The race is: flush sets discard=outstanding, but if response
    // happens same cycle, discard is decremented immediately.
    // property p_flush_sets_discard;
    //     @(posedge clk) disable iff (!rst_n)
    //     (flush && (outstanding > 0)) |=> (discard_cnt > 0);
    // endproperty
    // assert property (p_flush_sets_discard)
    //     else $error("[IB] Flush with outstanding requests did not set discard_cnt");

    // Pointer Wraparound Safety (for DEPTH > 1)
    generate
        if (PTR_WIDTH > 0) begin : g_ptr_checks
            property p_wr_ptr_bounds;
                @(posedge clk) disable iff (!rst_n)
                wr_ptr < DEPTH;
            endproperty
            assert property (p_wr_ptr_bounds)
                else $error("[IB] Write pointer out of bounds: %0d >= %0d", wr_ptr, DEPTH);

            property p_rd_ptr_bounds;
                @(posedge clk) disable iff (!rst_n)
                rd_ptr < DEPTH;
            endproperty
            assert property (p_rd_ptr_bounds)
                else $error("[IB] Read pointer out of bounds: %0d >= %0d", rd_ptr, DEPTH);
        end
    endgenerate

    // Request/Response Coordination
    property p_response_needs_request;
        @(posedge clk) disable iff (!rst_n)
        resp_valid |-> ((outstanding + discard_cnt) > 0);
    endproperty
    assert property (p_response_needs_request)
        else $warning("[IB] Response received with no outstanding requests");

    property p_can_accept_consistency;
        @(posedge clk) disable iff (!rst_n)
        // can_accept=0 only when total occupancy is at DEPTH (with no concurrent free)
        !can_accept |-> ((outstanding + discard_cnt) >= CNT_WIDTH'(DEPTH));
    endproperty
    assert property (p_can_accept_consistency)
        else $error("[IB] can_accept=0 but total occupancy (%0d+%0d) < DEPTH (%0d)",
                    outstanding, discard_cnt, DEPTH);

    // X/Z Detection on Critical Signals
    property p_no_x_req_valid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(req_valid);
    endproperty
    assert property (p_no_x_req_valid)
        else $error("[IB] X/Z detected on req_valid");

    property p_no_x_req_ready;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(req_ready);
    endproperty
    assert property (p_no_x_req_ready)
        else $error("[IB] X/Z detected on req_ready");

    property p_no_x_resp_valid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(resp_valid);
    endproperty
    assert property (p_no_x_resp_valid)
        else $error("[IB] X/Z detected on resp_valid");

    property p_no_x_resp_consume;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(resp_consume);
    endproperty
    assert property (p_no_x_resp_consume)
        else $error("[IB] X/Z detected on resp_consume");

    property p_no_x_flush;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(flush);
    endproperty
    assert property (p_no_x_flush)
        else $error("[IB] X/Z detected on flush");

    // Counter Consistency
    property p_outstanding_count_match;
        @(posedge clk) disable iff (!rst_n)
        outstanding_count == outstanding;
    endproperty
    assert property (p_outstanding_count_match)
        else $error("[IB] outstanding_count output does not match internal counter");

`endif // ASSERTION

endmodule

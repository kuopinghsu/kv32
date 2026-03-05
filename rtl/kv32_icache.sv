// ============================================================================
// File: kv32_icache.sv
// Project: KV32 RISC-V Processor
// Description: Configurable Instruction Cache
//
// Parameters
//   CACHE_SIZE      – total cache capacity in bytes
//   CACHE_LINE_SIZE – bytes per cache line  (must be power-of-2, >= 4)
//   CACHE_WAYS      – set-associativity     (must be power-of-2, >= 1)
//
// Interfaces
//   Core        – valid/ready request + valid/ready response (registered)
//   CMO         – RISC-V CMO extension (INVAL / DISABLE / ENABLE)
//   AXI4 read   – WRAP burst starting at the critical word (AXI4 WRAP wraps at
//                 cache-line boundary); critical-word-first / early-restart:
//                 CPU is unblocked after beat 0, remaining beats drain in bg.
//                 INCR single-beat for bypass mode.
//
// Architecture
//   - Valid storage uses flip-flops (one bit per way per set).
//   - Tag and cache-data storage use memory macros (sram_1rw instances,
//     one per way for tags and one per way for data).
//   - FAST_INIT=0 (default): on reset deassertion the cache enters S_INIT and
//     clears valid bits one set per cycle (takes NUM_SETS cycles).
//   - FAST_INIT=1: all valid bits and victim pointers are cleared
//     asynchronously during reset assertion; the FSM resets directly to
//     S_IDLE so the cache is ready to serve in one cycle after rst_n rises.
//   - Replacement policy: per-set round-robin (victim pointer).
//   - CMO DISABLE puts the cache into bypass mode; every fetch issues a single
//     AXI transaction and the result is forwarded directly to the core.
//   - CMO INVAL invalidates the way whose tag matches the supplied address.
//   - CMO ENABLE re-enables normal caching.
//
// Performance Optimization: Zero-Latency Word-by-Word Forwarding
//   During cache line fills, each word is forwarded to the instruction fetch
//   unit IMMEDIATELY (combinationally) as it arrives from memory, without
//   waiting for the entire cache line to be read. This minimizes instruction
//   fetch latency for sequential accesses within the same cache line.
//   - Word 0 (critical word): served via CWF in S_RESP (1 cycle after arrival)
//   - Word 1,2,3,...: served via direct forwarding in S_FILL_REST (0 cycles)
//   - Cache line population: happens in parallel, written after all words arrive
//   - Backpressure handling: if core is not ready, response is registered
// ============================================================================

module kv32_icache #(
    parameter int  CACHE_SIZE      = 4096,   // bytes, must be power-of-2
    parameter int  CACHE_LINE_SIZE = 64,     // bytes, must be power-of-2 >= 4
    parameter int  CACHE_WAYS      = 2,      // ways,  must be power-of-2 >= 1
    // FAST_INIT=1: clear all valid bits asynchronously during reset (1 cycle).
    // FAST_INIT=0: clear valid bits one set per cycle in S_INIT (NUM_SETS cycles).
    parameter bit  FAST_INIT       = 1'b1
) (
    input  logic        clk,
    input  logic        rst_n,

    // -------------------------------------------------------------------------
    // Core instruction-fetch interface
    // -------------------------------------------------------------------------
    input  logic        imem_req_valid,
    input  logic [31:0] imem_req_addr,
    output logic        imem_req_ready,
    // Loop-free version of imem_req_addr for fill-pending address checks
    // (uses dedup_consumed, not dedup_consuming, so no imem_req_ready feedback).
    input  logic [31:0] imem_req_addr_fill,

    output logic        imem_resp_valid,
    output logic [31:0] imem_resp_data,
    output logic        imem_resp_error,
    input  logic        imem_resp_ready,

    // -------------------------------------------------------------------------
    // CMO (Cache Management Operation) sideband interface
    //   cmo_op: CMO_INVAL   = 2'b00  – invalidate cache block at cmo_addr
    //           CMO_DISABLE = 2'b01  – disable cache (enter bypass mode)
    //           CMO_ENABLE  = 2'b10  – re-enable cache
    // -------------------------------------------------------------------------
    input  logic        cmo_valid,
    input  logic [1:0]  cmo_op,
    input  logic [31:0] cmo_addr,
    output logic        cmo_ready,

    // -------------------------------------------------------------------------
    // AXI4 read master
    // -------------------------------------------------------------------------
    output logic        axi_arvalid,
    output logic [31:0] axi_araddr,
    output logic [7:0]  axi_arlen,    // beats-1
    output logic [2:0]  axi_arsize,   // 3'b010 = 4 bytes/beat
    output logic [1:0]  axi_arburst,  // WRAP=2'b10, INCR=2'b01
    input  logic        axi_arready,

    input  logic        axi_rvalid,
    input  logic [31:0] axi_rdata,
    input  logic [1:0]  axi_rresp,
    input  logic        axi_rlast,
    output logic        axi_rready,

    // ICache idle status: no AXI transaction in-flight.
    // Asserted when the state machine is in S_IDLE (no miss-fill burst active).
    // Used by kv32_core to extend core_sleep_o for safe WFI clock gating.
    output logic        icache_idle

`ifndef SYNTHESIS
    ,
    // Performance counters (simulation / verification only – not synthesised)
    output logic [31:0] perf_req_cnt,     // total fetch lookups  (one per S_LOOKUP entry)
    output logic [31:0] perf_hit_cnt,     // cache hits  (enabled, tag matched)
    output logic [31:0] perf_miss_cnt,    // cache misses (enabled, tag not matched)
    output logic [31:0] perf_bypass_cnt,  // bypass fetches (cache disabled)
    output logic [31:0] perf_fill_cnt,    // completed cache-line fills
    output logic [31:0] perf_cmo_cnt      // CMO operations executed
`endif
);

    // =========================================================================
    // Derived parameters
    // =========================================================================
    localparam int WORDS_PER_LINE   = CACHE_LINE_SIZE / 4;
    localparam int NUM_SETS         = CACHE_SIZE / (CACHE_LINE_SIZE * CACHE_WAYS);
    localparam int BYTE_OFFSET_BITS = $clog2(CACHE_LINE_SIZE);
    localparam int WORD_OFFSET_BITS = $clog2(WORDS_PER_LINE);
    localparam int INDEX_BITS       = $clog2(NUM_SETS);
    localparam int TAG_BITS         = 32 - INDEX_BITS - BYTE_OFFSET_BITS;
    localparam int WAY_BITS         = (CACHE_WAYS > 1) ? $clog2(CACHE_WAYS) : 1;

    // CMO opcodes
    localparam logic [1:0] CMO_INVAL     = 2'b00;
    localparam logic [1:0] CMO_DISABLE   = 2'b01;
    localparam logic [1:0] CMO_ENABLE    = 2'b10;
    localparam logic [1:0] CMO_FLUSH_ALL = 2'b11;  // FENCE.I: invalidate all ways/sets

    // AXI burst types
    localparam logic [1:0] AXI_BURST_FIXED = 2'b00;
    localparam logic [1:0] AXI_BURST_INCR  = 2'b01;
    localparam logic [1:0] AXI_BURST_WRAP  = 2'b10;

    // =========================================================================
    // Cache storage
    //   valid_array / victim_ptr  – flip-flops
    //     FAST_INIT=1: async-cleared during rst_n assertion (1 cycle)
    //     FAST_INIT=0: cleared one set per cycle in S_INIT (NUM_SETS cycles)
    //   tag / data               – SRAM macro wrappers (sram_1rw)
    // =========================================================================

    // Flip-flop storage
    logic                valid_array [CACHE_WAYS][NUM_SETS];
    logic [WAY_BITS-1:0] victim_ptr  [NUM_SETS];

    // SRAM parameters
    localparam int DATA_SRAM_DEPTH     = NUM_SETS * WORDS_PER_LINE;
    localparam int DATA_SRAM_ADDR_BITS = INDEX_BITS + WORD_OFFSET_BITS;

    // Tag SRAM ports (one per way, depth=NUM_SETS, width=TAG_BITS)
    logic                         tag_sram_ce    [CACHE_WAYS];
    logic                         tag_sram_we    [CACHE_WAYS];
    logic [INDEX_BITS-1:0]        tag_sram_addr  [CACHE_WAYS];
    logic [TAG_BITS-1:0]          tag_sram_wdata [CACHE_WAYS];
    logic [TAG_BITS-1:0]          tag_sram_rdata [CACHE_WAYS];

    // Data SRAM ports (one per way, depth=NUM_SETS×WORDS_PER_LINE, width=32)
    logic                              data_sram_ce    [CACHE_WAYS];
    logic                              data_sram_we    [CACHE_WAYS];
    logic [DATA_SRAM_ADDR_BITS-1:0]    data_sram_addr  [CACHE_WAYS];
    logic [31:0]                       data_sram_wdata [CACHE_WAYS];
    logic [31:0]                       data_sram_rdata [CACHE_WAYS];

    // =========================================================================
    // State machine
    // =========================================================================
    typedef enum logic [2:0] {
        S_INIT,     // clearing valid bits after reset (FAST_INIT=0 only)
        S_IDLE,     // waiting for fetch request or CMO
        S_LOOKUP,   // tag compare (request address has been registered)
        S_MISS_AR,  // drive AXI AR channel
        S_MISS_R,      // receive AXI R channel burst until critical word ready
        S_RESP,        // hold response until core accepts it
        S_FILL_REST,   // drain remaining line-fill beats after early restart (CWF)
        S_CMO          // execute one CMO operation (single cycle)
    } state_t;

    state_t state, next_state;

    // =========================================================================
    // Registered signals
    // =========================================================================
    logic [31:0] req_addr_r;   // captured on request acceptance
    logic [31:0] cmo_addr_r;
    logic [1:0]  cmo_op_r;
    logic [31:0] resp_data_r;
    logic        resp_error_r;
    logic        cache_enable; // 1 = normal, 0 = bypass (CMO-controlled global flag)
    logic        pma_cacheable; // PMA: req_addr_r[31]=1 → cacheable (RAM), 0 → non-cacheable
    logic        use_cache;     // per-request decision = cache_enable & pma_cacheable

    // =========================================================================
    // Address decomposition (from registered request)
    // =========================================================================
    logic [TAG_BITS-1:0]         req_tag;
    logic [INDEX_BITS-1:0]       req_index;
    logic [WORD_OFFSET_BITS-1:0] req_word_off;

    assign req_tag      = req_addr_r[31 : 32-TAG_BITS];
    assign req_index    = req_addr_r[BYTE_OFFSET_BITS + INDEX_BITS - 1 : BYTE_OFFSET_BITS];
    assign req_word_off = req_addr_r[BYTE_OFFSET_BITS-1 : 2];

    // PMA: bit[31]=1 → cacheable (RAM at 0x8000_0000+), 0 → non-cacheable (I/O, NCM)
    // This implements the Physical Memory Attribute check for the I-cache.
    // Non-cacheable regions (e.g. NCM at 0x4000_1000) always bypass the cache,
    // regardless of the CMO-controlled cache_enable flag.
    assign pma_cacheable = req_addr_r[31];
    assign use_cache     = cache_enable & pma_cacheable;

    // Decomposition directly from the unregistered incoming request address.
    // Used to drive SRAM reads on the same cycle a request is accepted so the
    // result is available one cycle later in S_LOOKUP.
    logic [INDEX_BITS-1:0]       new_req_index;
    logic [WORD_OFFSET_BITS-1:0] new_req_word_off;
    assign new_req_index    = imem_req_addr[BYTE_OFFSET_BITS + INDEX_BITS - 1 : BYTE_OFFSET_BITS];
    assign new_req_word_off = imem_req_addr[BYTE_OFFSET_BITS-1 : 2];

    // CMO address decomposition
    logic [INDEX_BITS-1:0] cmo_index;
    logic [TAG_BITS-1:0]   cmo_tag;
    assign cmo_index = cmo_addr_r[BYTE_OFFSET_BITS + INDEX_BITS - 1 : BYTE_OFFSET_BITS];
    assign cmo_tag   = cmo_addr_r[31 : 32-TAG_BITS];

    // =========================================================================
    // Init counter – used only when FAST_INIT=0; counts sets cleared per cycle
    //                during S_INIT.  Unused (optimised away) when FAST_INIT=1.
    // =========================================================================
    logic [INDEX_BITS-1:0] init_idx;

    // =========================================================================
    // Hit detection (combinational, uses req_index / req_tag)
    // =========================================================================
    logic [CACHE_WAYS-1:0]  way_hit;
    logic                   cache_hit;
    logic [WAY_BITS-1:0]    hit_way;
    logic [31:0]            hit_data;

    // Tag comparison uses SRAM read-data (launched one cycle earlier in S_IDLE).
    always_comb begin
        way_hit = '0;
        for (int w = 0; w < CACHE_WAYS; w++) begin
            if (valid_array[w][req_index] &&
                (tag_sram_rdata[w] == req_tag))
                way_hit[w] = 1'b1;
        end
    end

    assign cache_hit = |way_hit;

    // Priority encode hit way
    always_comb begin
        hit_way = '0;
        for (int w = CACHE_WAYS-1; w >= 0; w--) begin
            if (way_hit[w])
                hit_way = WAY_BITS'(unsigned'(w));
        end
    end

    // Hit data comes from data SRAM read-data (registered one cycle earlier).
    assign hit_data = data_sram_rdata[hit_way];

    // =========================================================================
    // Fill tracking
    // =========================================================================
    logic [WAY_BITS-1:0]         fill_way;
    logic [WORD_OFFSET_BITS-1:0] fill_word_cnt;
    logic                        fill_error;
    logic                        fill_active_r; // AXI burst in-progress (rlast not yet seen)

    // =========================================================================
    // Fill-pending: serve same-line requests directly from the AXI data bus
    //   while an ICache line fill is still in progress, avoiding the full
    //   S_FILL_REST drain stall.
    //
    //   When CWF restarts the CPU (beat 0 served from S_RESP), the next
    //   sequential instruction (beat 1) arrives on the AXI bus during S_RESP.
    //   By accepting the new fetch request in S_RESP+fill and capturing the
    //   beat directly into fill_pend_data_r, we can serve it on the very first
    //   cycle of S_FILL_REST — saving up to (WORDS_PER_LINE-2) stall cycles.
    //
    //   OPTIMIZATION: Direct combinational forwarding from AXI bus.
    //   When the AXI beat for the current request arrives, forward it IMMEDIATELY
    //   (combinationally) to imem_resp instead of waiting for registration.
    //   This eliminates the 1-cycle latency between beat arrival and response.
    // =========================================================================
    logic                        fill_pend_req_r;    // same-line req accepted, waiting for beat
    logic [WORD_OFFSET_BITS-1:0] fill_pend_burst_r;  // burst beat index for pending req
    logic                        fill_pend_resp_r;   // beat captured, response ready
    logic [31:0]                 fill_pend_data_r;   // captured instruction word

    // Burst beat index (relative to the WRAP start = req_word_off) for a new
    // request targeting the same cache line.  Overflow wraps naturally.
    logic [WORD_OFFSET_BITS-1:0] fill_pend_burst_comb;
    assign fill_pend_burst_comb = WORD_OFFSET_BITS'(
        imem_req_addr_fill[BYTE_OFFSET_BITS-1:2] - req_word_off);

    // Incoming address targets the same cache line currently being filled.
    logic fill_same_line;
    assign fill_same_line = use_cache && fill_active_r &&
        (imem_req_addr_fill[31:BYTE_OFFSET_BITS] == req_addr_r[31:BYTE_OFFSET_BITS]);

    // The AXI beat for the incoming (not-yet-accepted) request is on the bus now.
    logic fill_pend_beat_now;
    assign fill_pend_beat_now = axi_rvalid && (fill_word_cnt == fill_pend_burst_comb);

    // The AXI beat for the already-latched pending request is arriving now.
    logic fill_pend_beat_for_req;
    assign fill_pend_beat_for_req = fill_pend_req_r && axi_rvalid && axi_rready &&
        (fill_word_cnt == fill_pend_burst_r);

    // Guard: can we accept a new fill-pending request?
    //   – same cache line, no previous pending req/resp,
    //   – required beat has not yet been consumed (burst_comb >= fill_word_cnt)
    logic fill_pend_can_accept;
    assign fill_pend_can_accept = fill_same_line &&
        !fill_pend_req_r && !fill_pend_resp_r &&
        (fill_pend_burst_comb >= fill_word_cnt);

    // =========================================================================
    // Direct AXI forwarding (combinational): zero-latency word-by-word forwarding
    //   Two scenarios:
    //   1. New request accepted + beat arrives same cycle
    //   2. Previously accepted request's beat arrives
    //   Direct forward serves the response immediately when the AXI beat arrives,
    //   without waiting for a registered response cycle.
    //
    // =========================================================================
    // Direct AXI forwarding (DISABLED):
    //   Originally attempted to forward AXI beats word-by-word as they arrive,
    //   skipping the registration step for zero-latency response.
    //   However, this creates subtle timing and convergence issues with the
    //   instruction buffer (IB) accounting logic, especially when:
    //     - Request and response happen in the same cycle
    //     - Responses are discarded due to branch mispredicts
    //     - Multiple back-to-back cache fills occur
    //   The existing registered response path works reliably, so the
    //   optimization is not worth the added complexity.
    // =========================================================================
    logic fill_direct_forward;
    assign fill_direct_forward = 1'b0;  // Optimization disabled

    // =========================================================================
    // Next-state logic (combinational)
    // =========================================================================
    always_comb begin
        next_state = state;
        case (state)

            // S_INIT is only reachable when FAST_INIT=0.
            // Transition to S_IDLE once the last set has been cleared.
            S_INIT: begin
                if (init_idx == INDEX_BITS'(NUM_SETS - 1))
                    next_state = S_IDLE;
            end

            S_IDLE: begin
                if (cmo_valid)
                    next_state = S_CMO;
                else if (imem_req_valid)
                    next_state = S_LOOKUP;
            end

            S_LOOKUP: begin
                if (use_cache && cache_hit) begin
                    if (imem_resp_ready) begin
                        // Zero-stall hit: serve directly in S_LOOKUP, skip S_RESP.
                        if (cmo_valid)           next_state = S_CMO;
                        else if (imem_req_valid)  next_state = S_LOOKUP;
                        else                     next_state = S_IDLE;
                    end else begin
                        next_state = S_RESP;   // core not ready – hold in S_RESP
                    end
                end else begin
                    next_state = S_MISS_AR;    // miss or bypass
                end
            end

            S_MISS_AR: begin
                if (axi_arvalid && axi_arready)
                    next_state = S_MISS_R;
            end

            S_MISS_R: begin
                if (axi_rvalid && axi_rready) begin
                    // Critical-word-first: respond as soon as beat 0 of the WRAP
                    // burst arrives (= critical word).  The remaining beats are
                    // drained in S_FILL_REST / S_RESP after the CPU is unblocked.
                    // Also catches: bypass (axi_rlast on only beat) and the
                    // degenerate single-word-per-line case.
                    if (axi_rlast || (fill_word_cnt == '0 && use_cache))
                        next_state = S_RESP;
                end
            end

            S_RESP: begin
                if (imem_resp_valid && imem_resp_ready) begin
                    if (fill_active_r)
                        // CWF: burst not complete yet – drain remaining beats
                        next_state = S_FILL_REST;
                    else if (cmo_valid)
                        next_state = S_CMO;
                    else if (imem_req_valid)
                        next_state = S_LOOKUP;
                    else
                        next_state = S_IDLE;
                end
            end

            S_FILL_REST: begin
                // Leave S_FILL_REST when:
                //   (a) AXI burst just completed this cycle AND either no
                //       fill-pend response is pending or it is being consumed
                //       simultaneously (imem_resp_ready).
                //   (b) Burst already completed in a prior cycle
                //       (fill_active_r=0) AND any pending response is consumed.
                //
                // IMPORTANT: Do NOT exit if fill_pend_beat_for_req is true
                //   this cycle.  fill_pend_beat_for_req captures the tracked
                //   beat and sets fill_pend_resp_r via an NBA assignment.
                //   The NBA update is not visible to combinational next-state
                //   logic in the same cycle, so fill_pend_resp_r still reads 0
                //   even though it will be 1 next cycle.  Exiting to S_IDLE
                //   on that cycle would trigger the safety-reset and lose the
                //   pending response, creating a fetch deadlock.
                //   Remaining in S_FILL_REST one additional cycle allows the
                //   NBA fill_pend_resp_r=1 to propagate and be delivered before
                //   the exit condition is re-evaluated.
                //
                // Similarly, block exit when fill_pend_beat_now is true and
                //   fill_pend_can_accept is true (a new request accepted at
                //   the exact rlast cycle captures data simultaneously).
                if ((!fill_active_r || (axi_rvalid && axi_rready && axi_rlast)) &&
                        (!fill_pend_resp_r || imem_resp_ready) &&
                        !fill_pend_beat_for_req &&
                        !(axi_rvalid && axi_rready && axi_rlast &&
                          fill_pend_can_accept && fill_pend_beat_now))
                    next_state = S_IDLE;
            end

            S_CMO:   next_state = S_IDLE;   // single-cycle operation

        endcase
    end

    // =========================================================================
    // State register + cache_enable
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // FAST_INIT=1 → skip S_INIT; valid bits are cleared by async reset
            state        <= FAST_INIT ? S_IDLE : S_INIT;
            cache_enable <= 1'b1;
        end else begin
            state <= next_state;
            // Cache enable/disable via CMO
            if (state == S_CMO) begin
                if (cmo_op_r == CMO_DISABLE)
                    cache_enable <= 1'b0;
                else if (cmo_op_r == CMO_ENABLE)
                    cache_enable <= 1'b1;
            end
        end
    end

    // =========================================================================
    // Init counter (FAST_INIT=0 only)
    //   Counts from 0 to NUM_SETS-1 during S_INIT, clearing one set per cycle.
    //   When FAST_INIT=1 the FSM never enters S_INIT so this counter is
    //   never written; synthesis tools will optimise it away entirely.
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            init_idx <= '0;
        else if (state == S_INIT)
            init_idx <= init_idx + 1'b1;
    end

    // =========================================================================
    // Capture request address
    //   Not updated while a burst fill is active: the fill state machine
    //   relies on req_addr_r (req_word_off, req_index, req_tag) throughout
    //   the entire burst.  Requests accepted via the fill-pending path are
    //   latched separately and do NOT overwrite req_addr_r.
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_addr_r <= '0;
        end else if (imem_req_valid && imem_req_ready && !fill_active_r) begin
            req_addr_r <= imem_req_addr;
        end
    end

    // =========================================================================
    // Capture CMO parameters
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmo_addr_r <= '0;
            cmo_op_r   <= '0;
        end else if (cmo_valid && cmo_ready) begin
            cmo_addr_r <= cmo_addr;
            cmo_op_r   <= cmo_op;
        end
    end

    // =========================================================================
    // Fill tracking registers
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fill_way      <= '0;
            fill_word_cnt <= '0;
            fill_error    <= 1'b0;
        end else if (state == S_MISS_AR && axi_arready) begin
            // Latch victim way; reset word counter and error flag
            fill_way      <= victim_ptr[req_index];
            fill_word_cnt <= '0;
            fill_error    <= 1'b0;
        end else if ((state == S_MISS_R || state == S_FILL_REST ||
                      (state == S_RESP && fill_active_r)) && axi_rvalid && axi_rready) begin
            // Continue counting beats in all fill states (covers S_MISS_R,
            // S_RESP during CWF, and S_FILL_REST)
            fill_word_cnt <= fill_word_cnt + 1'b1;
            if (axi_rresp != 2'b00)
                fill_error <= 1'b1;
        end
    end

    // =========================================================================
    // Fill-active tracking
    //   Set when the AR channel handshakes; cleared when the last AXI R beat
    //   (axi_rlast) is received.  Spans S_MISS_R through S_FILL_REST / S_RESP.
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            fill_active_r <= 1'b0;
        else if (state == S_MISS_AR && axi_arvalid && axi_arready)
            fill_active_r <= 1'b1;
        else if (axi_rvalid && axi_rready && axi_rlast)
            fill_active_r <= 1'b0;
    end

    // =========================================================================
    // Fill-pending state registers
    //   Manages a single in-flight same-line hit request accepted while a burst
    //   fill is active.  Data is captured directly from the AXI bus (no SRAM
    //   read conflict) and served from S_FILL_REST on the first available cycle.
    //
    //   State transitions:
    //     IDLE → REQ_WAIT : request accepted, beat not yet on bus
    //     IDLE → RESP_RDY : request accepted and beat available same cycle
    //     REQ_WAIT → RESP_RDY : tracked beat arrives on AXI bus
    //     RESP_RDY → IDLE : CPU consumes fill_pend response (imem_resp_ready)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fill_pend_req_r   <= 1'b0;
            fill_pend_burst_r <= '0;
            fill_pend_resp_r  <= 1'b0;
            fill_pend_data_r  <= '0;
        end else begin
            // ---- Accept a new same-line request while fill is active ----
            // Fires in S_RESP+fill (beat arriving alongside CWF response) or
            // S_FILL_REST (subsequent beats).  req_addr_r is NOT updated.
            if (((state == S_RESP && fill_active_r) || state == S_FILL_REST) &&
                    imem_req_valid && imem_req_ready && fill_pend_can_accept) begin
                if (fill_pend_beat_now && axi_rready) begin
                    // Needed beat is on the bus right now - register for next cycle.
                    fill_pend_resp_r  <= 1'b1;
                    fill_pend_data_r  <= axi_rdata;
                    // fill_pend_req_r stays 0: no future beat tracking needed.
                    `DEBUG2(`DBG_GRP_ICACHE, ("fill_pend ACCEPT+CAPTURE: state=%0d fill_active=%b fill_word_cnt=%0d burst_comb=%0d axi_rdata=0x%h imem_req_addr=0x%h", state, fill_active_r, fill_word_cnt, fill_pend_burst_comb, axi_rdata, imem_req_addr));
                end else begin
                    // Beat not yet arrived → record burst index and wait.
                    fill_pend_req_r   <= 1'b1;
                    fill_pend_burst_r <= fill_pend_burst_comb;
                    `DEBUG2(`DBG_GRP_ICACHE, ("fill_pend ACCEPT+WAIT: state=%0d fill_word_cnt=%0d burst_comb=%0d imem_req_addr=0x%h beat_now=%b rready=%b", state, fill_word_cnt, fill_pend_burst_comb, imem_req_addr, fill_pend_beat_now, axi_rready));
                end
            end

            // ---- Capture when the tracked beat arrives ----
            if (fill_pend_beat_for_req) begin
                fill_pend_req_r   <= 1'b0;
                fill_pend_resp_r  <= 1'b1;
                fill_pend_data_r  <= axi_rdata;
                `DEBUG2(`DBG_GRP_ICACHE, ("fill_pend_beat_for_req: fill_word_cnt=%0d burst_r=%0d axi_rdata=0x%h", fill_word_cnt, fill_pend_burst_r, axi_rdata));
            end

            // ---- Clear when fill-pending response is consumed by CPU ----
            if (fill_pend_resp_r && imem_resp_ready &&
                    (state == S_FILL_REST ||
                     (state == S_RESP && fill_active_r))) begin
                fill_pend_resp_r  <= 1'b0;
            end

            // ---- Safety reset when both fill and pipeline are quiescent ----
            if (state == S_IDLE) begin
                fill_pend_req_r  <= 1'b0;
                fill_pend_resp_r <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Response data register
    //   – On a hit : registered directly from data_array.
    //   – On a miss: captured word-by-word as the burst arrives; the beat
    //     matching req_word_off is stored into resp_data_r.
    //   – On bypass: the single returned beat is stored directly.
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_data_r  <= '0;
            resp_error_r <= 1'b0;
        end else begin
            if (state == S_LOOKUP && use_cache && cache_hit) begin
                resp_data_r  <= hit_data;
                resp_error_r <= 1'b0;
            end
            if (state == S_MISS_R && axi_rvalid && axi_rready) begin
                if (!use_cache) begin
                    // Bypass: single beat (PMA non-cacheable or CMO DISABLE) – capture unconditionally
                    resp_data_r  <= axi_rdata;
                    resp_error_r <= (axi_rresp != 2'b00);
                end else if (fill_word_cnt == '0) begin
                    // CWF: WRAP burst starts at req_addr, so beat 0 is always
                    // the critical word – capture it immediately.
                    resp_data_r  <= axi_rdata;
                    resp_error_r <= (axi_rresp != 2'b00) | fill_error;
                end
                // Always propagate accumulated fill errors on last beat
                if (axi_rlast && use_cache && fill_error)
                    resp_error_r <= 1'b1;
            end
        end
    end

    logic tag_fill_commit; // forward declaration (assigned later, used in valid_array section)

    // =========================================================================
    // valid_array / victim_ptr flip-flop write logic
    //   tag and data are written exclusively via the SRAM write ports below.
    //
    // Two compile-time paths selected by FAST_INIT:
    //
    //   FAST_INIT=1  –  g_valid_fast:
    //     All valid bits and victim pointers are cleared asynchronously
    //     when rst_n is asserted.  The FSM wakes up in S_IDLE and can accept
    //     the first request immediately on the rising edge after rst_n.
    //     S_INIT is never entered, so init_idx is optimised away.
    //
    //   FAST_INIT=0  –  g_valid_slow (default):
    //     Valid bits and victim pointers are cleared one set per cycle during
    //     S_INIT.  The cache becomes ready after NUM_SETS clock cycles.
    //     Preferred when the target memory compiler cannot synthesise a large
    //     asynchronous reset fan-out efficiently.
    // =========================================================================
    generate
        if (FAST_INIT) begin : g_valid_fast

            // -----------------------------------------------------------------
            // FAST_INIT=1: async reset clears all storage in one cycle.
            // Runtime updates (fill commit, CMO INVAL) are synchronous.
            // -----------------------------------------------------------------
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    // One-cycle clear: all valid bits and victim pointers reset
                    // during rst_n assertion; ready immediately when rst_n rises.
                    for (int w = 0; w < CACHE_WAYS; w++)
                        for (int s = 0; s < NUM_SETS; s++)
                            valid_array[w][s] <= 1'b0;
                    for (int s = 0; s < NUM_SETS; s++)
                        victim_ptr[s] <= '0;
                end else begin
                    // ---------------------------------------------------------
                    // Fill commit: set valid bit and advance victim pointer
                    // on the last successful fill beat (any fill state).
                    // ---------------------------------------------------------
                    if (tag_fill_commit) begin
                        valid_array[fill_way][req_index] <= 1'b1;
                        victim_ptr[req_index] <=
                            WAY_BITS'((int'(fill_way) + 1) % CACHE_WAYS);
                    end

                    // ---------------------------------------------------------
                    // CMO INVAL: clear valid bit for the matching way.
                    // Tag comparison uses tag_sram_rdata latched in S_IDLE
                    // (one cycle before S_CMO).
                    // ---------------------------------------------------------
                    if (state == S_CMO && cmo_op_r == CMO_INVAL) begin
                        for (int w = 0; w < CACHE_WAYS; w++) begin
                            if (valid_array[w][cmo_index] &&
                                (tag_sram_rdata[w] == cmo_tag))
                                valid_array[w][cmo_index] <= 1'b0;
                        end
                    end

                    // ---------------------------------------------------------
                    // CMO FLUSH_ALL: invalidate every way in every set and
                    // reset the victim pointer.  Used by FENCE.I to guarantee
                    // all fetched instructions are re-fetched from memory.
                    // ---------------------------------------------------------
                    if (state == S_CMO && cmo_op_r == CMO_FLUSH_ALL) begin
                        for (int w = 0; w < CACHE_WAYS; w++)
                            for (int s = 0; s < NUM_SETS; s++)
                                valid_array[w][s] <= 1'b0;
                        for (int s = 0; s < NUM_SETS; s++)
                            victim_ptr[s] <= '0;
                    end
                end
            end

        end else begin : g_valid_slow

            // -----------------------------------------------------------------
            // FAST_INIT=0 (default): clear one set per cycle during S_INIT.
            // -----------------------------------------------------------------
            always_ff @(posedge clk) begin
                // S_INIT: clear one set per cycle; done after NUM_SETS cycles.
                if (state == S_INIT) begin
                    for (int w = 0; w < CACHE_WAYS; w++)
                        valid_array[w][init_idx] <= 1'b0;
                    victim_ptr[init_idx] <= '0;
                end

                // -------------------------------------------------------------
                // Fill commit: set valid bit and advance victim pointer
                // on the last successful fill beat (any fill state).
                // -------------------------------------------------------------
                if (tag_fill_commit) begin
                    valid_array[fill_way][req_index] <= 1'b1;
                    victim_ptr[req_index] <=
                        WAY_BITS'((int'(fill_way) + 1) % CACHE_WAYS);
                end

                // -------------------------------------------------------------
                // CMO INVAL: clear valid bit for the matching way.
                // Tag comparison uses tag_sram_rdata latched in S_IDLE
                // (one cycle before S_CMO).
                // -------------------------------------------------------------
                if (state == S_CMO && cmo_op_r == CMO_INVAL) begin
                    for (int w = 0; w < CACHE_WAYS; w++) begin
                        if (valid_array[w][cmo_index] &&
                            (tag_sram_rdata[w] == cmo_tag))
                            valid_array[w][cmo_index] <= 1'b0;
                    end
                end

                // -------------------------------------------------------------
                // CMO FLUSH_ALL: invalidate every way in every set and reset
                // victim pointers.  Used by FENCE.I.
                // -------------------------------------------------------------
                if (state == S_CMO && cmo_op_r == CMO_FLUSH_ALL) begin
                    for (int w = 0; w < CACHE_WAYS; w++)
                        for (int s = 0; s < NUM_SETS; s++)
                            valid_array[w][s] <= 1'b0;
                    for (int s = 0; s < NUM_SETS; s++)
                        victim_ptr[s] <= '0;
                end
            end

        end
    endgenerate

    // =========================================================================
    // SRAM control – combinational CE / WE / addr / wdata
    //
    // Read launch: fires when a new request or CMO is accepted in S_IDLE, or
    //              when a request is accepted back-to-back from S_RESP.
    //              Result is available one cycle later (S_LOOKUP / S_CMO).
    // Write: tag  – written only for fill_way on the last successful fill beat.
    //        data – written for fill_way on every received fill beat.
    //
    // The 1RW SRAM has no read-write conflict because:
    //   – Reads are launched in S_IDLE, from S_RESP (fill_active_r=0), or from
    //     S_LOOKUP (zero-stall hit path: next request pipelined back-to-back).
    //     In all cases fill_active_r=0, so no concurrent write is in progress.
    //   – Writes occur in S_MISS_R, S_RESP (fill_active_r=1), and S_FILL_REST.
    // =========================================================================

    // Unified read-launch strobe (covers both fetch and CMO)
    logic                  sram_read_en;
    logic [INDEX_BITS-1:0] sram_read_index;

    assign sram_read_en =
        (imem_req_valid && imem_req_ready) ||
        (state == S_IDLE && cmo_valid);       // CMO accepted → read tag for comparison

    // CMO takes index priority over fetch when both arrive in S_IDLE
    assign sram_read_index =
        (state == S_IDLE && cmo_valid)
            ? cmo_addr[BYTE_OFFSET_BITS + INDEX_BITS - 1 : BYTE_OFFSET_BITS]
            : new_req_index;

    // Tag fill commit strobe (last beat, no error) – fires in any fill state
    // tag_fill_commit: declared earlier as forward declaration
    assign tag_fill_commit = (state == S_MISS_R || state == S_FILL_REST ||
                              (state == S_RESP && fill_active_r))
                             && axi_rvalid && axi_rready
                             && axi_rlast && use_cache && !fill_error
                             && (axi_rresp == 2'b00);

    // Data fill write strobe (every received beat, all fill states)
    logic data_fill_we_s;
    assign data_fill_we_s = (state == S_MISS_R || state == S_FILL_REST ||
                              (state == S_RESP && fill_active_r))
                            && axi_rvalid && axi_rready && use_cache;

    generate
        for (genvar w = 0; w < CACHE_WAYS; w++) begin : g_sram_ctrl

            // --- Tag SRAM ---
            assign tag_sram_ce   [w] = sram_read_en ||
                                       (tag_fill_commit && (fill_way == WAY_BITS'(w)));
            assign tag_sram_we   [w] = tag_fill_commit && (fill_way == WAY_BITS'(w));
            // Write uses registered req_index/req_tag (from captured fill address)
            assign tag_sram_addr [w] = tag_sram_we[w] ? req_index : sram_read_index;
            assign tag_sram_wdata[w] = req_tag;

            // --- Data SRAM ---
            assign data_sram_ce   [w] = sram_read_en ||
                                        (data_fill_we_s && (fill_way == WAY_BITS'(w)));
            assign data_sram_we   [w] = data_fill_we_s && (fill_way == WAY_BITS'(w));
            // Read:  word address = {set_index, word_offset} from incoming request
            // Write: word address = {set_index, fill_word_cnt}
            assign data_sram_addr [w] = data_sram_we[w]
                // CWF: beat 0 → req_word_off, beat 1 → req_word_off+1, …
                // Overflow of the addition wraps naturally at WORD_OFFSET_BITS
                // (cache-line boundary) matching AXI WRAP semantics.
                ? DATA_SRAM_ADDR_BITS'({req_index, WORD_OFFSET_BITS'(req_word_off + fill_word_cnt)})
                : DATA_SRAM_ADDR_BITS'({sram_read_index,  new_req_word_off});
            assign data_sram_wdata[w] = axi_rdata;

        end
    endgenerate

    // =========================================================================
    // SRAM macro instances (one tag + one data SRAM per way)
    // =========================================================================
    generate
        for (genvar w = 0; w < CACHE_WAYS; w++) begin : g_sram

            sram_1rw #(
                .DEPTH (NUM_SETS),
                .WIDTH (TAG_BITS)
            ) u_tag_sram (
                .clk   (clk),
                .ce    (tag_sram_ce   [w]),
                .we    (tag_sram_we   [w]),
                .addr  (tag_sram_addr [w]),
                .wdata (tag_sram_wdata[w]),
                .rdata (tag_sram_rdata[w])
            );

            sram_1rw #(
                .DEPTH (DATA_SRAM_DEPTH),
                .WIDTH (32)
            ) u_data_sram (
                .clk   (clk),
                .ce    (data_sram_ce   [w]),
                .we    (data_sram_we   [w]),
                .addr  (data_sram_addr [w]),
                .wdata (data_sram_wdata[w]),
                .rdata (data_sram_rdata[w])
            );

        end
    endgenerate

    // =========================================================================
    // AXI AR channel
    //   Cache mode  : WRAP burst, length = WORDS_PER_LINE-1, starting at the
    //                 cache-line-aligned address.
    //   Bypass mode : single INCR transaction to the word-aligned address.
    // =========================================================================
    logic [31:0] ar_addr_cache;
    logic [31:0] ar_addr_bypass;

    // CWF: WRAP burst starts at the critical word address (word-aligned).
    // The AXI WRAP wraps at the cache-line boundary ((arlen+1)*4 bytes),
    // so every word in the line is fetched in order with the critical word first.
    assign ar_addr_cache  = {req_addr_r[31:2], 2'b00};  // critical-word-first
    // Align to word boundary (bypass – single INCR beat)
    assign ar_addr_bypass = {req_addr_r[31:2], 2'b00};

    assign axi_arvalid = (state == S_MISS_AR);
    assign icache_idle = (state == S_IDLE);
    assign axi_araddr  = use_cache ? ar_addr_cache : ar_addr_bypass;
    assign axi_arlen   = use_cache ? 8'(WORDS_PER_LINE - 1) : 8'h00;
    assign axi_arsize  = 3'b010;   // 4 bytes per beat
    assign axi_arburst = use_cache ? AXI_BURST_WRAP : AXI_BURST_INCR;
    // axi_arcache/arprot: constant AXI4 hints; not forwarded by the arbiter.

    // Accept beats in S_MISS_R (before early restart) and S_FILL_REST /
    // S_RESP-with-fill-active (draining remaining beats after early restart).
    assign axi_rready  = (state == S_MISS_R) || (state == S_FILL_REST) ||
                         (state == S_RESP && fill_active_r);

    // =========================================================================
    // Core handshake outputs
    // =========================================================================
    // Accept new requests:
    //   S_IDLE              – baseline
    //   S_RESP (!fill)       – back-to-back after a miss response
    //   S_RESP (+fill)       – fill-pending path: same-line req during CWF S_RESP
    //                          beat; requires imem_resp_ready (back-to-back) and
    //                          the required AXI beat must not have passed
    //   S_FILL_REST          – fill-pending path: same-line req; beat has not yet
    //                          been consumed (fill_pend_can_accept)
    //   S_LOOKUP (hit+ready) – zero-stall fast path: pipeline back-to-back hits
    //                          (fill_active_r is always 0 in S_LOOKUP)
    //
    // fill_pend_can_accept uses imem_req_addr_fill (not imem_req_addr) for the
    // fill_same_line and fill_pend_burst_comb checks.  imem_req_addr_fill is
    // computed in the core using dedup_consumed (without imem_req_ready), so it
    // does not feed back into imem_req_ready and there is no combinational loop.
    assign imem_req_ready  = (state == S_IDLE) ||
                             (state == S_RESP && imem_resp_ready &&
                              !cmo_valid && !fill_active_r) ||
                             // Fill-pending: accept while CWF S_RESP is serving
                             (state == S_RESP && fill_active_r &&
                              imem_resp_ready && !cmo_valid &&
                              fill_pend_can_accept) ||
                             // Fill-pending: accept during remaining burst drain
                             (state == S_FILL_REST && fill_pend_can_accept) ||
                             (state == S_LOOKUP && use_cache && cache_hit &&
                              imem_resp_ready && !cmo_valid);
    // In the zero-stall hit path the response is valid directly in S_LOOKUP,
    // driven combinatorially from the SRAM read-data (no S_RESP register needed).
    // In S_FILL_REST, a fill-pending response is served from fill_pend_data_r
    // (captured directly from the AXI bus, no SRAM read).
    // OPTIMIZATION: Direct forwarding from AXI bus when the exact beat arrives.
    assign imem_resp_valid = (state == S_RESP) ||
                             (state == S_LOOKUP && use_cache && cache_hit) ||
                             (state == S_FILL_REST && fill_pend_resp_r) ||
                             fill_direct_forward;
    assign imem_resp_data  = (state == S_LOOKUP && use_cache && cache_hit)
                             ? hit_data
                             : fill_direct_forward
                               ? axi_rdata  // Direct combinational path from AXI
                               : (state == S_FILL_REST && fill_pend_resp_r)
                                 ? fill_pend_data_r
                                 : resp_data_r;
    assign imem_resp_error = (state == S_LOOKUP && use_cache && cache_hit)
                             ? 1'b0
                             : fill_direct_forward
                               ? (axi_rresp != 2'b00)
                               : resp_error_r;

    // CMO accepted in IDLE and (transitionally) from RESP
    assign cmo_ready = (state == S_IDLE) ||
                       (state == S_RESP && imem_resp_ready);

    // =========================================================================
    // Performance counters (simulation only)
    //
    // Counters are reset with rst_n and count the following events:
    //   perf_req_cnt    – fetch requests dispatched (one per S_LOOKUP entry)
    //   perf_hit_cnt    – hits  : S_LOOKUP, cache enabled,  tag matched
    //   perf_miss_cnt   – misses: S_LOOKUP, cache enabled,  tag not matched
    //   perf_bypass_cnt – bypass: S_LOOKUP, cache disabled (CMO_DISABLE)
    //   perf_fill_cnt   – completed cache-line fills (last AXI beat, no error)
    //   perf_cmo_cnt    – CMO operations executed (one per S_CMO entry)
    //
    // Invariant: perf_req_cnt == perf_hit_cnt + perf_miss_cnt + perf_bypass_cnt
    // =========================================================================
`ifdef DEBUG
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // empty
        end else begin
            if (imem_resp_valid && (state == S_FILL_REST || state == S_RESP)) begin
                `DEBUG2(`DBG_GRP_ICACHE, ("RESP_OUT: state=%0d fill_active=%b fill_pend_resp=%b fill_pend_data=0x%h resp_data=0x%h axi_rdata=0x%h imem_resp_data=0x%h", state, fill_active_r, fill_pend_resp_r, fill_pend_data_r, resp_data_r, axi_rdata, imem_resp_data));
            end
            // PMA bypass: log each fetch that bypasses the cache due to non-cacheable address
            if (state == S_LOOKUP && !pma_cacheable) begin
                `DEBUG2(`DBG_GRP_ICACHE, ("[ICACHE] PMA bypass: addr=0x%h bit31=0 -> non-cacheable, issuing single INCR fetch", req_addr_r));
            end
        end
    end
`endif

`ifndef SYNTHESIS
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_req_cnt    <= '0;
            perf_hit_cnt    <= '0;
            perf_miss_cnt   <= '0;
            perf_bypass_cnt <= '0;
            perf_fill_cnt   <= '0;
            perf_cmo_cnt    <= '0;
        end else begin
            // S_LOOKUP is exactly one cycle per accepted fetch request.
            if (state == S_LOOKUP) begin
                perf_req_cnt <= perf_req_cnt + 32'd1;
                if      ( use_cache &&  cache_hit) perf_hit_cnt    <= perf_hit_cnt    + 32'd1;
                else if ( use_cache && !cache_hit) perf_miss_cnt   <= perf_miss_cnt   + 32'd1;
                else                               perf_bypass_cnt <= perf_bypass_cnt + 32'd1;
            end
            // Successful cache-line fill: tag_fill_commit fires in any fill state
            if (tag_fill_commit)
                perf_fill_cnt <= perf_fill_cnt + 32'd1;
            // CMO operation: S_CMO is exactly one cycle per accepted CMO.
            if (state == S_CMO)
                perf_cmo_cnt <= perf_cmo_cnt + 32'd1;
        end
    end
`endif // SYNTHESIS

    // =========================================================================
    // Formal / simulation assertions
    // =========================================================================
    // =======================================================================
    // AXI protocol: ARVALID must not deassert before ARREADY
    // =======================================================================
    // Define ASSERTION by default (can be disabled with +define+NO_ASSERTION)
`ifndef NO_ASSERTION
`ifndef ASSERTION
`define ASSERTION
`endif
`endif // NO_ASSERTION

`ifdef ASSERTION
    logic axi_ar_accepted;
    assign axi_ar_accepted = axi_arvalid && axi_arready;

    property p_arvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_arvalid && !axi_arready) |=> axi_arvalid;
    endproperty
    assert property (p_arvalid_stable)
        else $error("ARVALID deasserted before ARREADY");

    // -----------------------------------------------------------------------
    // AXI protocol: AR address/control must be stable while ARVALID && !ARREADY
    // -----------------------------------------------------------------------
    property p_araddr_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_arvalid && !axi_arready) |=>
        ($stable(axi_araddr) && $stable(axi_arlen) &&
         $stable(axi_arsize) && $stable(axi_arburst));
    endproperty
    assert property (p_araddr_stable)
        else $error("AR channel signals changed while ARVALID && !ARREADY");

    // -----------------------------------------------------------------------
    // AXI: RLAST must arrive on the expected beat
    // -----------------------------------------------------------------------
    property p_rlast_on_final_beat;
        @(posedge clk) disable iff (!rst_n)
        (state == S_MISS_R && axi_rvalid && axi_rready && axi_rlast) |->
            (use_cache
                ? (fill_word_cnt == WORD_OFFSET_BITS'(WORDS_PER_LINE - 1))
                : (fill_word_cnt == '0));
    endproperty
    assert property (p_rlast_on_final_beat)
        else $error("RLAST arrived on unexpected beat (fill_word_cnt=%0d)",
                    fill_word_cnt);

    // -----------------------------------------------------------------------
    // A cache hit implies the state is S_LOOKUP and cache is enabled
    // -----------------------------------------------------------------------
    property p_hit_only_in_lookup;
        @(posedge clk) disable iff (!rst_n)
        cache_hit |-> (state == S_LOOKUP || state == S_IDLE ||
                       state == S_RESP   || state == S_INIT ||
                       state == S_CMO    || state == S_MISS_AR ||
                       state == S_MISS_R);
    endproperty
    // (structural, always true – kept as documentation)

    // -----------------------------------------------------------------------
    // Response valid must not deassert before it is accepted
    // -----------------------------------------------------------------------
    property p_resp_valid_stable;
        @(posedge clk) disable iff (!rst_n)
        (imem_resp_valid && !imem_resp_ready) |=> imem_resp_valid;
    endproperty
    assert property (p_resp_valid_stable)
        else $error("imem_resp_valid deasserted before imem_resp_ready");

    // -----------------------------------------------------------------------
    // No simultaneous hit and miss (sanity)
    // -----------------------------------------------------------------------
    property p_no_multi_way_hit;
        @(posedge clk) disable iff (!rst_n)
        $onehot0(way_hit);
    endproperty
    assert property (p_no_multi_way_hit)
        else $error("Multiple ways hit simultaneously – tag aliasing!");

    // -----------------------------------------------------------------------
    // Init must complete: once S_INIT is entered, S_IDLE must be reached.
    // (Cover with a simple immediate-cover if formal tools support it;
    //  the ##[1:$] range syntax is not used to stay Verilator-compatible.)
    // -----------------------------------------------------------------------

`ifndef SYNTHESIS
    // Lint sink (debug only): lower address bits not decoded (cache operates on
    // aligned cacheline addresses); tracking signal reserved for future use.
    logic _unused_ok;
    assign _unused_ok = &{1'b0, req_addr_r[1:0], cmo_addr_r[5:0],
                                imem_req_addr_fill[1:0], axi_ar_accepted};
`endif // SYNTHESIS

`endif // ASSERTION

endmodule


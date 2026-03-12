// ============================================================================
// File: kv32_dcache.sv
// Project: KV32 RISC-V Processor
// Description: Configurable Data Cache (Write-Back/Write-Through, Write-Allocate/No-Alloc)
//
// Parameters
//   DCACHE_SIZE        – total cache capacity in bytes
//   DCACHE_LINE_SIZE   – bytes per cache line (must be power-of-2, >= 4)
//   DCACHE_WAYS        – set associativity (must be power-of-2, >= 1)
//   DCACHE_WRITE_BACK  – 1=write-back, 0=write-through
//   DCACHE_WRITE_ALLOC – 1=write-allocate on miss, 0=no-alloc (bypass write miss)
//
// Interfaces
//   Core-side  – valid/ready request + valid/ready response (registered)
//   CMO        – RISC-V CMO extension (INVAL / FLUSH / CLEAN)
//   AXI4       – AR/R (WRAP burst fill, INCR single read bypass)
//                AW/W/B (INCR burst evict, INCR single write bypass/write-through)
//
// Architecture
//   - Valid/dirty bits stored in flip-flops (async-clear on reset → 1-cycle init)
//   - Tag and data in SRAM macro wrappers (sram_1rw, one per way)
//   - Pseudo-LRU per set (1 bit for 2-way; round-robin pointer for N-way)
//   - Critical-word-first AXI WRAP burst fills (first beat unblocks core,
//     remaining beats drain as background fill in S_FILL_REST)
//   - Dirty eviction uses INCR burst (full line write-back)
//   - CMO: FLUSH (WB dirty → memory then invalidate all),
//          CLEAN (WB dirty only), INVAL (invalidate matching line)
// ============================================================================

/**
 * @brief Configurable set-associative data cache with write-back/write-through.
 *
 * Supports RISC-V CMO (CBO.FLUSH / CBO.CLEAN / CBO.INVAL) and FENCE.I flush.
 * Physical-memory-attribute (PMA) bypass applied for non-cacheable addresses
 * (bit[31]=0). Critical-word-first AXI4 WRAP bursts for fills.
 *
 * @see kv32_core, kv32_soc
 * @ingroup rtl
 */
module kv32_dcache #(
    parameter int  DCACHE_SIZE        = 4096,  // bytes, must be power-of-2
    parameter int  DCACHE_LINE_SIZE   = 32,    // bytes, must be power-of-2 >= 4
    parameter int  DCACHE_WAYS        = 2,     // ways,  must be power-of-2 >= 1
    parameter bit  DCACHE_WRITE_BACK  = 1'b1,  // 1=write-back, 0=write-through
    parameter bit  DCACHE_WRITE_ALLOC = 1'b1   // 1=write-allocate, 0=no-alloc
) (
    input  logic        clk,
    input  logic        rst_n,

    // -------------------------------------------------------------------------
    // Core data-memory interface
    // -------------------------------------------------------------------------
    input  logic        core_req_valid,
    input  logic [31:0] core_req_addr,
    input  logic [3:0]  core_req_we,       // 4'b0000 = load, else byte-enable
    input  logic [31:0] core_req_wdata,
    output logic        core_req_ready,

    output logic        core_resp_valid,
    output logic [31:0] core_resp_data,
    output logic        core_resp_error,
    output logic        core_resp_is_write, // 1=store complete, 0=load data

    input  logic        core_resp_ready,

    // -------------------------------------------------------------------------
    // CMO (Cache Management Operation) sideband interface
    //   cmo_op: CMO_INVAL = 2'b00 – invalidate cache block at cmo_addr
    //           CMO_FLUSH = 2'b01 – write-back dirty + invalidate
    //           CMO_CLEAN = 2'b10 – write-back dirty only (keep valid)
    //           CMO_FLUSH_ALL = 2'b11 – flush entire cache (FENCE.I)
    // -------------------------------------------------------------------------
    input  logic        cmo_valid_i,
    input  logic [1:0]  cmo_op_i,
    input  logic [31:0] cmo_addr_i,
    output logic        cmo_ready_o,

    // -------------------------------------------------------------------------
    // AXI4 master (read + write channels with burst support)
    // -------------------------------------------------------------------------
    // Write address
    output logic        axi_awvalid,
    output logic [31:0] axi_awaddr,
    output logic [7:0]  axi_awlen,    // beats-1
    output logic [2:0]  axi_awsize,   // 3'b010 = 4 bytes
    output logic [1:0]  axi_awburst,  // INCR=2'b01
    input  logic        axi_awready,
    // Write data
    output logic        axi_wvalid,
    output logic [31:0] axi_wdata,
    output logic [3:0]  axi_wstrb,
    output logic        axi_wlast,
    input  logic        axi_wready,
    // Write response
    input  logic [1:0]  axi_bresp,
    input  logic        axi_bvalid,
    output logic        axi_bready,
    // Read address
    output logic        axi_arvalid,
    output logic [31:0] axi_araddr,
    output logic [7:0]  axi_arlen,    // beats-1
    output logic [2:0]  axi_arsize,   // 3'b010 = 4 bytes
    output logic [1:0]  axi_arburst,  // WRAP=2'b10 (fill), INCR=2'b01 (bypass)
    input  logic        axi_arready,
    // Read data
    input  logic [31:0] axi_rdata,
    input  logic [1:0]  axi_rresp,
    input  logic        axi_rlast,
    input  logic        axi_rvalid,
    output logic        axi_rready,

    // -------------------------------------------------------------------------
    // Control / Status
    // -------------------------------------------------------------------------
    input  logic        dcache_enable_i,  // 1 = cache enabled
    output logic        dcache_idle_o,    // FSM in S_IDLE (no AXI in-flight)

    // PMA (Physical Memory Attributes) from core CSRs
    // pmacfg byte: [7]=L(lock) [6:5]=rsvd [4:3]=A(match mode) [2]=X(I-cacheable) [1]=C(D-cacheable) [0]=B(bufferable)
    // pmaaddr: physaddr >> 2, NAPOT-encoded (same as RISC-V PMP convention)
    // Fallback when no region matches: legacy bit[31]=1 rule
    input  logic [1:0][31:0] pma_cfg_i,    // pmacfg0 (regions 0-3), pmacfg1 (regions 4-7)
    input  logic [7:0][31:0] pma_addr_i    // pmaaddr0-7

`ifndef SYNTHESIS
    ,
    // Performance counters (simulation only)
    output logic [31:0] perf_req_cnt,
    output logic [31:0] perf_hit_cnt,
    output logic [31:0] perf_miss_cnt,
    output logic [31:0] perf_bypass_cnt,
    output logic [31:0] perf_fill_cnt,
    output logic [31:0] perf_evict_cnt,
    output logic [31:0] perf_cmo_cnt
`endif
);

    // =========================================================================
    // Derived parameters
    // =========================================================================
    localparam int WORDS_PER_LINE   = DCACHE_LINE_SIZE / 4;
    localparam int NUM_SETS         = DCACHE_SIZE / (DCACHE_LINE_SIZE * DCACHE_WAYS);
    localparam int BYTE_OFFSET_BITS = $clog2(DCACHE_LINE_SIZE);
    localparam int WORD_OFFSET_BITS = $clog2(WORDS_PER_LINE);
    localparam int INDEX_BITS       = $clog2(NUM_SETS);
    localparam int TAG_BITS         = 32 - INDEX_BITS - BYTE_OFFSET_BITS;
    localparam int WAY_BITS         = (DCACHE_WAYS > 1) ? $clog2(DCACHE_WAYS) : 1;

    // AXI burst types
    localparam logic [1:0] AXI_BURST_INCR = 2'b01;
    localparam logic [1:0] AXI_BURST_WRAP = 2'b10;

    // CMO opcodes
    localparam logic [1:0] CMO_INVAL     = 2'b00;
    localparam logic [1:0] CMO_FLUSH     = 2'b01;  // WB dirty + invalidate
    localparam logic [1:0] CMO_CLEAN     = 2'b10;  // WB dirty only
    localparam logic [1:0] CMO_FLUSH_ALL = 2'b11;  // Flush entire cache (FENCE.I)

    // =========================================================================
    // Cache storage
    //   valid/dirty – flip-flops cleared async on rst_n (FAST_INIT style)
    //   tag/data    – SRAM macro wrappers
    // =========================================================================
    logic valid_array [DCACHE_WAYS][NUM_SETS];
    logic dirty_array [DCACHE_WAYS][NUM_SETS];
    logic [WAY_BITS-1:0] victim_ptr [NUM_SETS];  // round-robin replacement

    // SRAM parameters
    localparam int DATA_SRAM_DEPTH     = NUM_SETS * WORDS_PER_LINE;
    localparam int DATA_SRAM_ADDR_BITS = INDEX_BITS + WORD_OFFSET_BITS;

    // Tag SRAM ports (one per way)
    logic                      tag_sram_ce    [DCACHE_WAYS];
    logic                      tag_sram_we    [DCACHE_WAYS];
    logic [INDEX_BITS-1:0]     tag_sram_addr  [DCACHE_WAYS];
    logic [TAG_BITS-1:0]       tag_sram_wdata [DCACHE_WAYS];
    logic [TAG_BITS-1:0]       tag_sram_rdata [DCACHE_WAYS];

    // Data SRAM ports (one per way)
    logic                              data_sram_ce    [DCACHE_WAYS];
    logic                              data_sram_we    [DCACHE_WAYS];
    logic [DATA_SRAM_ADDR_BITS-1:0]    data_sram_addr  [DCACHE_WAYS];
    logic [31:0]                       data_sram_wdata [DCACHE_WAYS];
    logic [31:0]                       data_sram_rdata [DCACHE_WAYS];

    // =========================================================================
    // State machine
    // =========================================================================
    typedef enum logic [4:0] {
        S_IDLE,        // idle, waiting for request or CMO
        S_LOOKUP,      // tag compare (1 cycle after SRAM read)
        S_HIT_RD,      // cache hit, read response to core
        S_HIT_WR,      // cache hit, write to cache (+ write-through AXI if WT)
        S_WT_AW,       // write-through: drive AW channel
        S_WT_W,        // write-through: drive W channel
        S_WT_B,        // write-through: wait B response
        S_EVICT_AW,    // evict dirty line: drive AW
        S_EVICT_W,     // evict dirty line: drive W (multi-beat)
        S_EVICT_B,     // evict dirty line: wait B
        S_FILL_AR,     // drive AXI AR (WRAP fill)
        S_FILL_R,      // receive AXI R burst (CWF: first beat unblocks core)
        S_FILL_RESP,   // hold fill response until core accepts
        S_FILL_REST,   // drain remaining fill beats after CWF
        S_BYPASS_RD,   // non-cacheable load: single AXI AR/R
        S_BYPASS_WR_AW,// non-cacheable store AW
        S_BYPASS_WR_W, // non-cacheable store W
        S_BYPASS_WR_B, // non-cacheable store B
        S_CMO_SCAN,    // CMO: scan all sets/ways (for FLUSH_ALL)
        S_CMO_WB_AW,   // CMO: write-back dirty line AW
        S_CMO_WB_W,    // CMO: write-back dirty line W
        S_CMO_WB_B,    // CMO: write-back dirty line B
        S_CMO_DONE     // CMO complete: assert cmo_ready_o for one cycle
    } state_t;

    state_t state, next_state;

    // =========================================================================
    // Registered request signals
    // =========================================================================
    logic [31:0]  req_addr_r;
    logic [3:0]   req_we_r;
    logic [31:0]  req_wdata_r;
    logic         pma_cacheable; // PMA: per-request D-cacheable decision
    logic         use_dcache;     // per-request decision = dcache_enable & pma_cacheable

    // -------------------------------------------------------------------------
    // PMA checker: 8-region runtime-configurable Physical Memory Attributes
    // Priority: region 0 > 1 > ... > 7.  Fallback when no hit: bit[31] rule.
    // -------------------------------------------------------------------------
    localparam int unsigned KV_PMA_N = kv32_pkg::KV_PMA_NUM;

    logic [7:0]  pma_rcfg    [KV_PMA_N]; // per-region config byte
    logic [31:0] pma_tor_lo  [KV_PMA_N]; // TOR lower bound
    logic [31:0] pma_napot_m [KV_PMA_N]; // NAPOT mask = pmaaddr|(pmaaddr+1)
    logic        pma_rmatch  [KV_PMA_N]; // per-region match

    for (genvar ii = 0; ii < KV_PMA_N; ii++) begin : l_g_pma_cfg
        if (ii < 4) begin : g_cfg_lo
            assign pma_rcfg[ii] = pma_cfg_i[0][(ii*8) +: 8];
        end else begin : g_cfg_hi
            assign pma_rcfg[ii] = pma_cfg_i[1][((ii-4)*8) +: 8];
        end
    end

    for (genvar ii = 0; ii < KV_PMA_N; ii++) begin : l_g_pma_tor
        if (ii == 0) begin : g_tor_r0
            assign pma_tor_lo[0] = 32'h0;
        end else begin : g_tor_rn
            assign pma_tor_lo[ii] = {pma_addr_i[ii-1][29:0], 2'b00};
        end
    end

    for (genvar ii = 0; ii < KV_PMA_N; ii++) begin : l_g_pma_napot
        assign pma_napot_m[ii] = pma_addr_i[ii] | (pma_addr_i[ii] + 32'd1);
    end

    for (genvar ii = 0; ii < KV_PMA_N; ii++) begin : l_g_pma_match
        always_comb begin
            case (pma_rcfg[ii][4:3])
                2'b00:   pma_rmatch[ii] = 1'b0; // disabled
                2'b01:   pma_rmatch[ii] = (req_addr_r >= pma_tor_lo[ii]) &&
                                           (req_addr_r < {pma_addr_i[ii][29:0], 2'b00}); // TOR
                2'b10:   pma_rmatch[ii] = ({2'b00, req_addr_r[31:2]} == pma_addr_i[ii]); // NA4
                default: pma_rmatch[ii] = (({2'b00, req_addr_r[31:2]} & ~pma_napot_m[ii]) ==
                                           (pma_addr_i[ii] & ~pma_napot_m[ii])); // NAPOT
            endcase
        end
    end

    logic pma_hit;
    logic pma_attr_c; // D-cacheable attribute from matching region (cfg[1])
    always_comb begin
        pma_hit    = 1'b0;
        pma_attr_c = 1'b0;
        for (int jj = KV_PMA_N-1; jj >= 0; jj--) begin
            if (pma_rmatch[jj]) begin
                pma_hit    = 1'b1;
                pma_attr_c = pma_rcfg[jj][1]; // C bit
            end
        end
    end

    assign pma_cacheable = pma_hit ? pma_attr_c : req_addr_r[31];
    assign use_dcache    = dcache_enable_i & pma_cacheable;

    // Address decomposition from registered address
    logic [TAG_BITS-1:0]         req_tag;
    logic [INDEX_BITS-1:0]       req_index;
    logic [WORD_OFFSET_BITS-1:0] req_word_off;

    assign req_tag      = req_addr_r[31 : 32-TAG_BITS];
    assign req_index    = req_addr_r[BYTE_OFFSET_BITS + INDEX_BITS - 1 : BYTE_OFFSET_BITS];
    assign req_word_off = req_addr_r[BYTE_OFFSET_BITS-1 : 2];

    // Address decomposition from incoming (pre-register) address – for SRAM read launch
    logic [INDEX_BITS-1:0]       new_req_index;
    logic [WORD_OFFSET_BITS-1:0] new_req_word_off;
    assign new_req_index    = core_req_addr[BYTE_OFFSET_BITS + INDEX_BITS - 1 : BYTE_OFFSET_BITS];
    assign new_req_word_off = core_req_addr[BYTE_OFFSET_BITS-1 : 2];

    // =========================================================================
    // CMO registered signals
    // =========================================================================
    logic [31:0] cmo_addr_r;
    logic [1:0]  cmo_op_r;

    // CMO scan state: iterate sets and ways
    logic [INDEX_BITS-1:0] cmo_scan_set;
    logic [WAY_BITS-1:0]   cmo_scan_way;
    logic                  cmo_scan_done;

    logic [INDEX_BITS-1:0] cmo_index;
    logic [TAG_BITS-1:0]   cmo_tag;
    assign cmo_index = cmo_addr_r[BYTE_OFFSET_BITS + INDEX_BITS - 1 : BYTE_OFFSET_BITS];
    assign cmo_tag   = cmo_addr_r[31 : 32-TAG_BITS];

    // =========================================================================
    // Hit detection
    // =========================================================================
    logic [DCACHE_WAYS-1:0] way_hit;
    logic                   cache_hit;
    logic [WAY_BITS-1:0]    hit_way;
    logic [31:0]            hit_data;

    always_comb begin
        way_hit = '0;
        for (int w = 0; w < DCACHE_WAYS; w++) begin
            if (valid_array[w][req_index] &&
                (tag_sram_rdata[w] == req_tag))
                way_hit[w] = 1'b1;
        end
    end

    assign cache_hit = |way_hit;

    always_comb begin
        hit_way = '0;
        for (int w = DCACHE_WAYS-1; w >= 0; w--) begin
            if (way_hit[w])
                hit_way = WAY_BITS'(unsigned'(w));
        end
    end

    assign hit_data = data_sram_rdata[hit_way];

    // =========================================================================
    // Victim way (for miss eviction / fill)
    // =========================================================================
    logic [WAY_BITS-1:0] victim_way;
    logic                victim_dirty;

    assign victim_way   = victim_ptr[req_index];
    assign victim_dirty = DCACHE_WRITE_BACK && valid_array[victim_way][req_index] &&
                          dirty_array[victim_way][req_index];

    // =========================================================================
    // Fill / eviction tracking
    // =========================================================================
    logic [WAY_BITS-1:0]         fill_way;
    logic [TAG_BITS-1:0]         evict_tag_r;   // tag of evicted line
    logic [WORD_OFFSET_BITS-1:0] fill_word_cnt; // reused as evict beat counter
    logic [WORD_OFFSET_BITS-1:0] fill_req_word_off_r; // req_word_off saved at fill start
    logic                        fill_error;
    logic                        fill_active_r;  // AR accepted, burst in-flight
    logic                        bypass_ar_sent_r; // Bypass AR accepted; ARVALID must stay low until next request

    // =========================================================================
    // Fill-pending: serve same-line load requests from AXI data bus while a
    //   D-Cache line fill is still in progress (CWF beats 1+).
    //
    //   After the critical word (beat 0) unblocks the core, subsequent
    //   sequential loads to the same cache line would otherwise stall until
    //   S_FILL_REST drains and the line is re-read from SRAM in S_LOOKUP.
    //   By accepting the new load in S_FILL_REST (or S_FILL_RESP back-to-back)
    //   and capturing the matching AXI beat into fill_pend_data_r, we can serve
    //   it 1 cycle after arrival — saving (WORDS_PER_LINE-2) stall cycles.
    //
    //   Only same-line loads are accepted; stores wait for S_IDLE → S_HIT_WR.
    //   One in-flight fill_pend slot (mirrors kv32_icache.sv).
    // =========================================================================
    logic                        fill_pend_req_r;    // request latched, beat not yet arrived
    logic [WORD_OFFSET_BITS-1:0] fill_pend_burst_r;  // burst beat index for the pending request
    logic                        fill_pend_resp_r;   // beat captured, response ready to send
    logic [31:0]                 fill_pend_data_r;   // captured data from AXI bus
    logic                        fill_pend_error_r;  // error flag for captured beat

    // Burst beat index (relative to WRAP start = req_word_off) for a new request
    // targeting the same cache line.  Overflow wraps naturally at WORD_OFFSET_BITS.
    logic [WORD_OFFSET_BITS-1:0] fill_pend_burst_comb;
    assign fill_pend_burst_comb = WORD_OFFSET_BITS'(new_req_word_off - req_word_off);

    // Incoming address targets the same cache line currently being filled.
    logic fill_same_line;
    assign fill_same_line = use_dcache && fill_active_r &&
        (core_req_addr[31:BYTE_OFFSET_BITS] == req_addr_r[31:BYTE_OFFSET_BITS]);

    // The AXI beat for the incoming (not-yet-accepted) request is on the bus now.
    logic fill_pend_beat_now;
    assign fill_pend_beat_now = axi_rvalid && (fill_word_cnt == fill_pend_burst_comb);

    // The AXI beat for the already-latched pending request is arriving now.
    logic fill_pend_beat_for_req;
    assign fill_pend_beat_for_req = fill_pend_req_r && axi_rvalid && axi_rready &&
        (fill_word_cnt == fill_pend_burst_r);

    // Guard: can we accept a new fill-pending request?
    //   – same cache line, load only (no stores), no previous pending req/resp,
    //   – required beat has not yet been consumed (burst_comb >= fill_word_cnt)
    logic fill_pend_can_accept;
    assign fill_pend_can_accept = fill_same_line &&
        !fill_pend_req_r && !fill_pend_resp_r &&
        (core_req_we == 4'b0000) &&
        (fill_pend_burst_comb >= fill_word_cnt);

    // Eviction line base address: tag + index + 0 offset
    logic [31:0] evict_base_addr;
    assign evict_base_addr = {evict_tag_r,
                              req_index,
                              {BYTE_OFFSET_BITS{1'b0}}};

    // =========================================================================
    // Response data register (holds response until core accepts)
    // =========================================================================
    logic [31:0] resp_data_r;
    logic        resp_error_r;
    logic        resp_is_write_r;

    // =========================================================================
    // Next-state logic
    // =========================================================================
    always_comb begin
        next_state = state;
        case (state)

            S_IDLE: begin
                if (cmo_valid_i)
                    next_state = S_CMO_SCAN;
                else if (core_req_valid)
                    next_state = S_LOOKUP;
            end

            S_LOOKUP: begin
                if (use_dcache && cache_hit) begin
                    if (req_we_r != 4'b0000)
                        next_state = S_HIT_WR;
                    else begin
                        // Zero-stall hit-read: core_resp_valid fires combinatorially
                        // in S_LOOKUP.  If the core accepts it this cycle
                        // (core_resp_ready=1, which is always true when
                        // dmem_resp_ready=1'b1), go directly to S_IDLE to avoid
                        // sending a duplicate response in S_HIT_RD next cycle.
                        if (core_resp_ready)
                            next_state = S_IDLE;
                        else
                            next_state = S_HIT_RD;
                    end
                end else if (!use_dcache) begin
                    // Non-cacheable bypass
                    if (req_we_r != 4'b0000)
                        next_state = S_BYPASS_WR_AW;
                    else
                        next_state = S_BYPASS_RD;
                end else begin
                    // Cacheable miss
                    if (victim_dirty)
                        next_state = S_EVICT_AW;
                    else
                        next_state = S_FILL_AR;
                end
            end

            S_HIT_RD: begin
                if (core_resp_ready)
                    next_state = S_IDLE;
            end

            S_HIT_WR: begin
                // For write-through: also issue AXI write after cache update
                if (DCACHE_WRITE_BACK)
                    next_state = S_IDLE;
                else
                    next_state = S_WT_AW;
            end

            S_WT_AW: begin
                if (axi_awvalid && axi_awready) begin
                    // Single-beat WT: W is also presented in this state
                    if (axi_wvalid && axi_wready && axi_wlast)
                        next_state = S_WT_B;   // Both accepted simultaneously
                    else
                        next_state = S_WT_W;   // AW done, W still pending
                end
            end

            S_WT_W: begin
                if (axi_wvalid && axi_wready && axi_wlast)
                    next_state = S_WT_B;
            end

            S_WT_B: begin
                if (axi_bvalid && axi_bready)
                    next_state = S_IDLE;
            end

            S_EVICT_AW: begin
                if (axi_awvalid && axi_awready)
                    next_state = S_EVICT_W;
            end

            S_EVICT_W: begin
                if (axi_wvalid && axi_wready && axi_wlast)
                    next_state = S_EVICT_B;
            end

            S_EVICT_B: begin
                if (axi_bvalid)
                    next_state = S_FILL_AR;
            end

            S_FILL_AR: begin
                if (axi_arvalid && axi_arready)
                    next_state = S_FILL_R;
            end

            S_FILL_R: begin
                if (axi_rvalid && axi_rready) begin
                    // For loads: CWF – forward critical word at beat 0 immediately.
                    // For write-alloc stores: must wait for the full line (rlast) so
                    // fill_commit fires in S_FILL_R and resp_is_write_r is set to 1
                    // before we enter S_FILL_RESP.  Without this, the D-cache issues a
                    // resp with is_write=0 at beat-0 and the store buffer never receives
                    // its completion (resp_valid = dmem_resp_valid && dmem_resp_is_write),
                    // causing the store buffer to fill up and permanently stall the core.
                    if (axi_rlast ||
                        (fill_word_cnt == '0 &&
                         (req_we_r == 4'b0000 || !DCACHE_WRITE_ALLOC)))
                        next_state = S_FILL_RESP;
                end
            end

            S_FILL_RESP: begin
                if (core_resp_valid && core_resp_ready) begin
                    if (fill_active_r)
                        next_state = S_FILL_REST;
                    else if (cmo_valid_i)
                        next_state = S_CMO_SCAN;
                    else
                        // Always return to S_IDLE so that the SRAM is re-read for the
                        // next request and req_addr_r / req_we_r are correctly latched.
                        // The old fast-path FILL_RESP→S_LOOKUP skipped S_IDLE which
                        // left stale req_we_r from the fill and stale tag_sram_rdata,
                        // causing an infinite miss/evict loop.
                        next_state = S_IDLE;
                end
            end

            S_FILL_REST: begin
                // Stay until burst complete AND any fill-pend response has been consumed.
                //
                // Block exit when fill_pend_beat_for_req is true this cycle:
                //   The NBA update to fill_pend_resp_r=1 is invisible to combinational
                //   next-state logic in the same cycle, so exiting to S_IDLE on that
                //   cycle would lose the pending response and deadlock the core.
                if ((!fill_active_r || (axi_rvalid && axi_rready && axi_rlast)) &&
                        (!fill_pend_resp_r || core_resp_ready) &&
                        !fill_pend_beat_for_req)
                    next_state = S_IDLE;
            end

            S_BYPASS_RD: begin
                if (axi_arvalid && axi_arready)
                    next_state = S_BYPASS_RD; // wait for R
                if (axi_rvalid && axi_rready && axi_rlast) begin
                    if (core_resp_ready)
                        next_state = S_IDLE;
                    else
                        next_state = S_FILL_RESP; // reuse resp-hold state
                end
            end

            S_BYPASS_WR_AW: begin
                if (axi_awvalid && axi_awready) begin
                    // Single-beat bypass: W is also presented in this state
                    if (axi_wvalid && axi_wready && axi_wlast)
                        next_state = S_BYPASS_WR_B;  // Both accepted simultaneously
                    else
                        next_state = S_BYPASS_WR_W;  // AW done, W still pending
                end
            end

            S_BYPASS_WR_W: begin
                if (axi_wvalid && axi_wready && axi_wlast)
                    next_state = S_BYPASS_WR_B;
            end

            S_BYPASS_WR_B: begin
                if (axi_bvalid && axi_bready)
                    next_state = S_IDLE;
            end

            S_CMO_SCAN: begin
                // Check if current scan position has a dirty line to evict (FLUSH/CLEAN)
                // or just invalidate (INVAL/FLUSH)
                // For FLUSH_ALL / FLUSH / CLEAN — if current way is dirty → evict first
                // CMO_INVAL — skip eviction, just clear valid
                if (cmo_op_r == CMO_FLUSH_ALL || cmo_op_r == CMO_FLUSH || cmo_op_r == CMO_CLEAN) begin
                    // Check if this (set,way) is dirty
                    if (valid_array[cmo_scan_way][cmo_scan_set] &&
                        dirty_array[cmo_scan_way][cmo_scan_set])
                        next_state = S_CMO_WB_AW;
                    else
                        next_state = cmo_scan_done ? S_CMO_DONE : S_CMO_SCAN;
                end else begin
                    // INVAL — just scan and invalidate; no writeback needed
                    next_state = cmo_scan_done ? S_CMO_DONE : S_CMO_SCAN;
                end
            end

            S_CMO_WB_AW: begin
                if (axi_awvalid && axi_awready)
                    next_state = S_CMO_WB_W;
            end

            S_CMO_WB_W: begin
                if (axi_wvalid && axi_wready && axi_wlast)
                    next_state = S_CMO_WB_B;
            end

            S_CMO_WB_B: begin
                if (axi_bvalid && axi_bready)
                    next_state = cmo_scan_done ? S_CMO_DONE : S_CMO_SCAN;
            end

            S_CMO_DONE: next_state = S_IDLE;

            default: next_state = state;
        endcase
    end

    // =========================================================================
    // State register
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_IDLE;
        else
            state <= next_state;
    end

    // =========================================================================
    // Capture request
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_addr_r  <= '0;
            req_we_r    <= '0;
            req_wdata_r <= '0;
        end else if (core_req_valid && core_req_ready) begin
            req_addr_r  <= core_req_addr;
            req_we_r    <= core_req_we;
            req_wdata_r <= core_req_wdata;
        end
    end

    // =========================================================================
    // Capture CMO
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmo_addr_r <= '0;
            cmo_op_r   <= '0;
        end else if (cmo_valid_i && cmo_ready_o) begin
            cmo_addr_r <= cmo_addr_i;
            cmo_op_r   <= cmo_op_i;
        end
    end

    // =========================================================================
    // Fill/eviction tracking registers
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fill_way             <= '0;
            fill_word_cnt        <= '0;
            fill_req_word_off_r  <= '0;
            fill_error           <= 1'b0;
            evict_tag_r          <= '0;
        end else if (state == S_LOOKUP && !cache_hit && use_dcache) begin
            // Latch victim for eviction and save the original word offset for
            // the fill so that accepting a same-line fill-pending request later
            // (which updates req_addr_r / req_word_off) cannot corrupt the SRAM
            // write address for the remaining beats of this fill.
            fill_way            <= victim_way;
            evict_tag_r         <= tag_sram_rdata[victim_way];
            fill_error          <= 1'b0;
            fill_word_cnt       <= '0;
            fill_req_word_off_r <= req_word_off;
        end else if (state == S_CMO_SCAN &&
                     (cmo_op_r == CMO_FLUSH_ALL || cmo_op_r == CMO_FLUSH || cmo_op_r == CMO_CLEAN) &&
                     valid_array[cmo_scan_way][cmo_scan_set] &&
                     dirty_array[cmo_scan_way][cmo_scan_set]) begin
            // CMO wb: latch the eviction base for the current scan position
            fill_way    <= cmo_scan_way;
            fill_word_cnt <= '0;
        end else if ((state == S_FILL_R || (state == S_FILL_RESP && fill_active_r) || state == S_FILL_REST)
                      && axi_rvalid && axi_rready) begin
            fill_word_cnt <= fill_word_cnt + 1'b1;
            if (axi_rresp != 2'b00)
                fill_error <= 1'b1;
        end else if ((state == S_EVICT_W || state == S_CMO_WB_W) && axi_wvalid && axi_wready) begin
            // Use fill_word_cnt as the evict write beat counter
            fill_word_cnt <= fill_word_cnt + 1'b1;
        end else if (state == S_FILL_AR && axi_arready) begin
            fill_word_cnt <= '0;
        end else if (state == S_EVICT_AW || state == S_CMO_WB_AW) begin
            fill_word_cnt <= '0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            fill_active_r <= 1'b0;
        else if (state == S_FILL_AR && axi_arvalid && axi_arready)
            fill_active_r <= 1'b1;
        else if (axi_rvalid && axi_rready && axi_rlast)
            fill_active_r <= 1'b0;
    end

    // Track that the bypass AR has been accepted so ARVALID can deassert
    // (AXI spec: once ARVALID is asserted it must remain until ARREADY).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            bypass_ar_sent_r <= 1'b0;
        else if (state == S_BYPASS_RD && axi_arvalid && axi_arready)
            bypass_ar_sent_r <= 1'b1;
        else if (state != S_BYPASS_RD)
            bypass_ar_sent_r <= 1'b0;
    end

    // =========================================================================
    // Fill-pending state registers
    //   Manages a single in-flight same-line load request accepted while a
    //   burst fill is active (S_FILL_RESP back-to-back or S_FILL_REST).
    //   Data is captured directly from the AXI bus (no SRAM read conflict)
    //   and served via core_resp_valid in S_FILL_REST.
    //
    //   State transitions:
    //     IDLE → REQ_WAIT : request accepted, beat not yet on bus
    //     IDLE → RESP_RDY : request accepted and matching beat on bus same cycle
    //     REQ_WAIT → RESP_RDY : tracked beat arrives on AXI bus
    //     RESP_RDY → IDLE : core consumes fill_pend response (core_resp_ready)
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fill_pend_req_r    <= 1'b0;
            fill_pend_burst_r  <= '0;
            fill_pend_resp_r   <= 1'b0;
            fill_pend_data_r   <= '0;
            fill_pend_error_r  <= 1'b0;
        end else begin
            // ---- Accept a new same-line load request while fill is active ----
            // Fires in S_FILL_RESP+fill (back-to-back: primary resp consumed this
            // same cycle) or S_FILL_REST (subsequent beats already draining).
            if (((state == S_FILL_RESP && fill_active_r && core_resp_ready) ||
                  state == S_FILL_REST) &&
                    core_req_valid && core_req_ready && fill_pend_can_accept) begin
                if (fill_pend_beat_now && axi_rready) begin
                    // Needed beat is on the bus right now — register for next cycle.
                    fill_pend_resp_r  <= 1'b1;
                    fill_pend_data_r  <= axi_rdata;
                    fill_pend_error_r <= (axi_rresp != 2'b00);
                    // fill_pend_req_r stays 0: no future beat tracking needed.
                    `DEBUG2(`DBG_GRP_DCACHE, ("[DCACHE] fill_pend ACCEPT+CAPTURE: state=%0d fill_word_cnt=%0d burst_comb=%0d axi_rdata=0x%h addr=0x%h", state, fill_word_cnt, fill_pend_burst_comb, axi_rdata, core_req_addr));
                end else begin
                    // Beat not yet arrived → record burst index and wait.
                    fill_pend_req_r   <= 1'b1;
                    fill_pend_burst_r <= fill_pend_burst_comb;
                    `DEBUG2(`DBG_GRP_DCACHE, ("[DCACHE] fill_pend ACCEPT+WAIT: state=%0d fill_word_cnt=%0d burst_comb=%0d addr=0x%h", state, fill_word_cnt, fill_pend_burst_comb, core_req_addr));
                end
            end

            // ---- Capture when the tracked beat arrives ----
            if (fill_pend_beat_for_req) begin
                fill_pend_req_r   <= 1'b0;
                fill_pend_resp_r  <= 1'b1;
                fill_pend_data_r  <= axi_rdata;
                fill_pend_error_r <= (axi_rresp != 2'b00);
                `DEBUG2(`DBG_GRP_DCACHE, ("[DCACHE] fill_pend CAPTURE: fill_word_cnt=%0d burst_r=%0d axi_rdata=0x%h", fill_word_cnt, fill_pend_burst_r, axi_rdata));
            end

            // ---- Clear when fill-pending response is consumed by core ----
            if (fill_pend_resp_r && core_resp_ready &&
                    (state == S_FILL_REST ||
                     (state == S_FILL_RESP && fill_active_r))) begin
                fill_pend_resp_r <= 1'b0;
            end

            // ---- Safety reset when both fill and pipeline are quiescent ----
            if (state == S_IDLE) begin
                fill_pend_req_r  <= 1'b0;
                fill_pend_resp_r <= 1'b0;
            end
        end
    end

    // =========================================================================
    // valid/dirty/victim_ptr flip-flop writes
    // =========================================================================
    logic fill_commit;    // last successful fill beat → set valid, clear dirty
    logic evict_commit;   // eviction starts → will clear dirty (done when B arrives)

    assign fill_commit = (state == S_FILL_R || state == S_FILL_REST ||
                          (state == S_FILL_RESP && fill_active_r))
                         && axi_rvalid && axi_rready && axi_rlast
                         && use_dcache && !fill_error && (axi_rresp == 2'b00);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int w = 0; w < DCACHE_WAYS; w++)
                for (int s = 0; s < NUM_SETS; s++) begin
                    valid_array[w][s] <= 1'b0;
                    dirty_array[w][s] <= 1'b0;
                end
            for (int s = 0; s < NUM_SETS; s++)
                victim_ptr[s] <= '0;
        end else begin
            // Fill commit: mark valid (and clear dirty — fill from clean memory)
            if (fill_commit) begin
                valid_array[fill_way][req_index] <= 1'b1;
                dirty_array[fill_way][req_index] <= 1'b0;
                victim_ptr[req_index] <= WAY_BITS'((int'(fill_way) + 1) % DCACHE_WAYS);
            end

            // HIT write: set dirty (WB) or keep clean (WT)
            if (state == S_HIT_WR && DCACHE_WRITE_BACK) begin
                dirty_array[hit_way][req_index] <= 1'b1;
            end

            // WB miss-fill then write: set dirty
            if (fill_commit && req_we_r != 4'b0000 && DCACHE_WRITE_ALLOC && DCACHE_WRITE_BACK) begin
                dirty_array[fill_way][req_index] <= 1'b1;
            end

            // EVICT B response: clear dirty (line has been written back to memory)
            // Only for fill-eviction path (S_EVICT_B). CMO writebacks (S_CMO_WB_B) are
            // handled separately below with the correct cmo_scan_set index.
            if (state == S_EVICT_B && axi_bvalid && axi_bready) begin
                dirty_array[fill_way][req_index] <= 1'b0;
            end

            // CMO CLEAN after WB: clear dirty but leave valid (line stays cached, now clean)
            if (state == S_CMO_WB_B && axi_bvalid && axi_bready && cmo_op_r == CMO_CLEAN) begin
                dirty_array[cmo_scan_way][cmo_scan_set] <= 1'b0;
            end

            // CMO INVAL: target set/way
            if (state == S_CMO_SCAN && cmo_op_r == CMO_INVAL) begin
                for (int w = 0; w < DCACHE_WAYS; w++) begin
                    if (valid_array[w][cmo_index] && (tag_sram_rdata[w] == cmo_tag)) begin
                        valid_array[w][cmo_index] <= 1'b0;
                        dirty_array[w][cmo_index] <= 1'b0;
                    end
                end
            end

            // CMO FLUSH after WB: invalidate the line just written back
            if (state == S_CMO_WB_B && axi_bvalid && axi_bready &&
                (cmo_op_r == CMO_FLUSH || cmo_op_r == CMO_FLUSH_ALL)) begin
                valid_array[cmo_scan_way][cmo_scan_set] <= 1'b0;
                dirty_array[cmo_scan_way][cmo_scan_set] <= 1'b0;
            end

            // CMO FLUSH_ALL: invalidate all (done in S_CMO_DONE, not scan)
            if (state == S_CMO_DONE && cmo_op_r == CMO_FLUSH_ALL) begin
                for (int w = 0; w < DCACHE_WAYS; w++)
                    for (int s = 0; s < NUM_SETS; s++) begin
                        valid_array[w][s] <= 1'b0;
                        dirty_array[w][s] <= 1'b0;
                    end
                for (int s = 0; s < NUM_SETS; s++)
                    victim_ptr[s] <= '0;
            end

            // CMO INVAL/FLUSH target-line invalidate (non-scan-all CMOs)
            // For single-line CMO ops done via S_CMO_SCAN for the matching line
        end
    end

    // =========================================================================
    // CMO scan counter
    // =========================================================================
    // Advance after each non-WB scan cycle, or after WB completes
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmo_scan_set <= '0;
            cmo_scan_way <= '0;
        end else begin
            if (state == S_IDLE && next_state == S_CMO_SCAN) begin
                // Determine scan start
                if (cmo_op_i == CMO_FLUSH_ALL) begin
                    cmo_scan_set <= '0;
                    cmo_scan_way <= '0;
                end else begin
                    // Single-line CMO: start at the matching set
                    cmo_scan_set <= cmo_addr_i[BYTE_OFFSET_BITS + INDEX_BITS - 1 : BYTE_OFFSET_BITS];
                    cmo_scan_way <= '0;
                end
            end else if (state == S_CMO_SCAN && next_state == S_CMO_SCAN && !cmo_scan_done) begin
                // No WB needed for this position → advance
                if (int'(cmo_scan_way) == DCACHE_WAYS - 1) begin
                    cmo_scan_way <= '0;
                    cmo_scan_set <= cmo_scan_set + 1'b1;
                end else begin
                    cmo_scan_way <= cmo_scan_way + 1'b1;
                end
            end else if (state == S_CMO_WB_B && axi_bvalid && axi_bready) begin
                // After WB: advance to next position
                if (int'(cmo_scan_way) == DCACHE_WAYS - 1) begin
                    cmo_scan_way <= '0;
                    cmo_scan_set <= cmo_scan_set + 1'b1;
                end else begin
                    cmo_scan_way <= cmo_scan_way + 1'b1;
                end
            end
        end
    end

    // Determine if CMO scan is done
    always_comb begin
        if (cmo_op_r == CMO_FLUSH_ALL) begin
            cmo_scan_done = (cmo_scan_set == INDEX_BITS'(NUM_SETS - 1)) &&
                            (cmo_scan_way == WAY_BITS'(DCACHE_WAYS - 1));
        end else begin
            // Single-line CMO: done after scanning all ways of the target set
            cmo_scan_done = (cmo_scan_way == WAY_BITS'(DCACHE_WAYS - 1));
        end
    end

    // CMO write-back address: tag of the dirty line at (cmo_scan_set, cmo_scan_way)
    logic [31:0] cmo_wb_addr;
    assign cmo_wb_addr = {tag_sram_rdata[cmo_scan_way],
                          cmo_scan_set,
                          {BYTE_OFFSET_BITS{1'b0}}};

    // =========================================================================
    // SRAM control
    // =========================================================================
    // Read launch: when a new request is accepted (S_IDLE→S_LOOKUP) or
    // for CMO (to read current tags for comparison).
    logic                  sram_read_en;
    logic [INDEX_BITS-1:0] sram_read_index;
    logic [WORD_OFFSET_BITS-1:0] sram_read_word_off;

    assign sram_read_en = (state == S_IDLE && core_req_valid && !cmo_valid_i) ||
                          (state == S_IDLE && cmo_valid_i) ||
                          (state == S_CMO_SCAN);

    assign sram_read_index = (state == S_IDLE && cmo_valid_i)
        ? cmo_addr_i[BYTE_OFFSET_BITS + INDEX_BITS - 1 : BYTE_OFFSET_BITS]
        : (state == S_CMO_SCAN)
          ? cmo_scan_set
          : new_req_index;

    assign sram_read_word_off = new_req_word_off;

    // Fill write: write received AXI R beat into data SRAM
    logic data_fill_we;
    assign data_fill_we = (state == S_FILL_R || state == S_FILL_REST ||
                           (state == S_FILL_RESP && fill_active_r))
                          && axi_rvalid && axi_rready && use_dcache;

    // HIT write: write store data into data SRAM on hit
    logic data_hit_we;
    assign data_hit_we = (state == S_HIT_WR);

    // Tag fill commit
    logic tag_fill_commit;
    assign tag_fill_commit = fill_commit;

    // Eviction read: need to read data SRAM to send to AXI
    // We drive data_sram_ce/addr for the eviction read in S_EVICT_W/S_CMO_WB_W
    logic evict_read_en;
    logic [INDEX_BITS-1:0]       evict_read_index;
    logic [WORD_OFFSET_BITS-1:0] evict_read_word;

    // For eviction, read the next word to be sent (one cycle ahead)
    // In S_EVICT_AW/S_CMO_WB_AW: read word 0
    // In S_EVICT_W/S_CMO_WB_W: read word (evict_word_cnt+1) while sending evict_word_cnt
    logic [WORD_OFFSET_BITS-1:0] evict_send_word;
    assign evict_send_word = fill_word_cnt;  // reused counter for evict

    assign evict_read_en = (state == S_EVICT_AW) ||
                           (state == S_EVICT_W && axi_wvalid && axi_wready) ||
                           (state == S_CMO_WB_AW) ||
                           (state == S_CMO_WB_W && axi_wvalid && axi_wready);

    assign evict_read_index = (state == S_CMO_WB_AW || state == S_CMO_WB_W)
                              ? cmo_scan_set : req_index;

    assign evict_read_word = (state == S_EVICT_AW || state == S_CMO_WB_AW)
                             ? '0
                             : WORD_OFFSET_BITS'(evict_send_word + 1'b1);

    // CMO WB target way
    logic [WAY_BITS-1:0] wb_way;
    assign wb_way = (state == S_CMO_WB_AW || state == S_CMO_WB_W || state == S_CMO_WB_B)
                    ? cmo_scan_way : fill_way;

    // Write-alloc fill merge: at beat 0 of a write-alloc store fill, merge the
    // pending store bytes into the incoming AXI fill data.  Beat 0 of the WRAP
    // burst always lands at {req_index, req_word_off} (critical word), which is
    // exactly the word the store targets, so merging here is always correct.
    logic [31:0] fill_wr_merged;
    always_comb begin : l_fill_wr_merge
        fill_wr_merged = axi_rdata;
        if (req_we_r[0]) fill_wr_merged[ 7: 0] = req_wdata_r[ 7: 0];
        if (req_we_r[1]) fill_wr_merged[15: 8] = req_wdata_r[15: 8];
        if (req_we_r[2]) fill_wr_merged[23:16] = req_wdata_r[23:16];
        if (req_we_r[3]) fill_wr_merged[31:24] = req_wdata_r[31:24];
    end

    // SRAM CE/WE/addr/wdata
    for (genvar w = 0; w < DCACHE_WAYS; w++) begin : l_g_sram_ctrl

        // Tag SRAM
        assign tag_sram_ce   [w] = sram_read_en ||
                                   (tag_fill_commit && (fill_way == WAY_BITS'(w)));
        assign tag_sram_we   [w] = tag_fill_commit && (fill_way == WAY_BITS'(w));
        assign tag_sram_addr [w] = tag_sram_we[w] ? req_index : sram_read_index;
        assign tag_sram_wdata[w] = req_tag;

        // Data SRAM
        // Priority: hit-write > fill-write > evict-read > request-read
        assign data_sram_ce   [w] = sram_read_en ||
                                    (data_fill_we   && (fill_way == WAY_BITS'(w))) ||
                                    (data_hit_we    && (hit_way  == WAY_BITS'(w))) ||
                                    (evict_read_en  && (wb_way   == WAY_BITS'(w)));

        assign data_sram_we   [w] = (data_fill_we  && (fill_way == WAY_BITS'(w))) ||
                                    (data_hit_we   && (hit_way  == WAY_BITS'(w)));

        assign data_sram_addr [w] =
            (data_hit_we && hit_way == WAY_BITS'(w))
                ? DATA_SRAM_ADDR_BITS'({req_index, req_word_off})
                : (data_fill_we && fill_way == WAY_BITS'(w))
                    ? DATA_SRAM_ADDR_BITS'({req_index, WORD_OFFSET_BITS'(fill_req_word_off_r + fill_word_cnt)})
                    : (evict_read_en && wb_way == WAY_BITS'(w))
                        ? DATA_SRAM_ADDR_BITS'({evict_read_index, evict_read_word})
                        : DATA_SRAM_ADDR_BITS'({sram_read_index, sram_read_word_off});

        // Hit-write: byte-mask data into existing cache word (read-modify-write
        // using data_sram_rdata which held the previous read result for this way)
        logic [31:0] hit_wr_merged;
        always_comb begin : l_hit_wr_merge
            hit_wr_merged = data_sram_rdata[w];
            if (req_we_r[0]) hit_wr_merged[7:0]   = req_wdata_r[7:0];
            if (req_we_r[1]) hit_wr_merged[15:8]  = req_wdata_r[15:8];
            if (req_we_r[2]) hit_wr_merged[23:16] = req_wdata_r[23:16];
            if (req_we_r[3]) hit_wr_merged[31:24] = req_wdata_r[31:24];
        end

        // For write-alloc store fills, merge the store bytes into beat 0
        // (the critical word) so the filled line immediately contains the
        // correct store data without a separate read-modify-write cycle.
        assign data_sram_wdata[w] = data_hit_we ? hit_wr_merged :
            ((data_fill_we && (fill_way == WAY_BITS'(w)) &&
              req_we_r != 4'b0000 && DCACHE_WRITE_ALLOC &&
              fill_word_cnt == '0)
             ? fill_wr_merged : axi_rdata);
    end

    // =========================================================================
    // SRAM macro instances (byte-enable data SRAM)
    // =========================================================================
    for (genvar w = 0; w < DCACHE_WAYS; w++) begin : l_g_sram

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

    // =========================================================================
    // AXI: Read address channel (fills and bypass reads)
    // =========================================================================
    assign axi_arvalid = (state == S_FILL_AR) ||
                          (state == S_BYPASS_RD && !bypass_ar_sent_r);
    assign axi_araddr  = (state == S_FILL_AR)
                         ? {req_addr_r[31:2], 2'b00}     // CWF: start at critical word
                         : {req_addr_r[31:2], 2'b00};    // bypass: word-aligned
    assign axi_arlen   = (state == S_FILL_AR) ? 8'(WORDS_PER_LINE - 1) : 8'h00;
    assign axi_arsize  = 3'b010;
    assign axi_arburst = (state == S_FILL_AR) ? AXI_BURST_WRAP : AXI_BURST_INCR;

    assign axi_rready  = (state == S_FILL_R) ||
                         (state == S_FILL_REST) ||
                         (state == S_FILL_RESP && fill_active_r) ||
                         (state == S_BYPASS_RD);

    // =========================================================================
    // AXI: Write address channel (evict / write-through / bypass write)
    // =========================================================================
    assign axi_awvalid = (state == S_EVICT_AW) ||
                         (state == S_WT_AW) ||
                         (state == S_BYPASS_WR_AW) ||
                         (state == S_CMO_WB_AW);

    assign axi_awaddr  = (state == S_EVICT_AW) ? evict_base_addr :
                         (state == S_CMO_WB_AW) ? cmo_wb_addr :
                         /* WT/BYPASS */ {req_addr_r[31:2], 2'b00};

    assign axi_awlen   = (state == S_EVICT_AW || state == S_CMO_WB_AW)
                         ? 8'(WORDS_PER_LINE - 1) : 8'h00;
    assign axi_awsize  = 3'b010;
    assign axi_awburst = AXI_BURST_INCR;

    // =========================================================================
    // AXI: Write data channel
    // Eviction: send data SRAM words (read one cycle ahead in S_EVICT_AW/W)
    // WT/Bypass: send the pending store word
    // =========================================================================
    // Eviction data comes from SRAM (registered one cycle ahead)
    // For eviction we use data_sram_rdata[wb_way] (the read launched in prior cycle)
    // Since SRAM is 1RW synchronous, we need to read word N in cycle where we send word N

    // Registered evict/CMO_WB send way
    logic [WAY_BITS-1:0] wb_way_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) wb_way_r <= '0;
        else        wb_way_r <= wb_way;
    end

    logic [WORD_OFFSET_BITS-1:0] evict_wbeat_cnt;  // beat count for evict W channel
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            evict_wbeat_cnt <= '0;
        else if (state == S_EVICT_AW || state == S_CMO_WB_AW)
            evict_wbeat_cnt <= '0;
        else if ((state == S_EVICT_W || state == S_CMO_WB_W) && axi_wvalid && axi_wready)
            evict_wbeat_cnt <= evict_wbeat_cnt + 1'b1;
    end

    // For single-beat writes (WT / bypass), assert wvalid in the AW state too so that
    // AW and W are presented simultaneously.  Only burst evictions/CMO-WB need to keep
    // wvalid strictly in their own W state because SRAM data isn't ready yet.
    assign axi_wvalid  = (state == S_EVICT_W) ||
                         (state == S_WT_AW)  ||   // simultaneous with AW (single-beat)
                         (state == S_WT_W)   ||   // fallback if awready delayed
                         (state == S_BYPASS_WR_AW) ||  // simultaneous with AW
                         (state == S_BYPASS_WR_W) ||   // fallback if awready delayed
                         (state == S_CMO_WB_W);

    assign axi_wdata   = (state == S_EVICT_W || state == S_CMO_WB_W)
                         ? data_sram_rdata[wb_way_r]   // from SRAM (read in prior cycle)
                         : req_wdata_r;                // WT/bypass: pending store

    assign axi_wstrb   = (state == S_EVICT_W || state == S_CMO_WB_W)
                         ? 4'hF                        // full-word eviction
                         : req_we_r;                   // byte-enables for WT/bypass

    assign axi_wlast   = (state == S_EVICT_W || state == S_CMO_WB_W)
                         ? (evict_wbeat_cnt == WORD_OFFSET_BITS'(WORDS_PER_LINE - 1))
                         : 1'b1;                       // single-beat WT/bypass

    // =========================================================================
    // AXI: Write response channel
    // =========================================================================
    assign axi_bready  = (state == S_EVICT_B) || (state == S_WT_B) ||
                         (state == S_BYPASS_WR_B) || (state == S_CMO_WB_B);

    // =========================================================================
    // Response data register
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_data_r     <= '0;
            resp_error_r    <= 1'b0;
            resp_is_write_r <= 1'b0;
        end else begin
            // Hit read: capture from SRAM
            if (state == S_LOOKUP && use_dcache && cache_hit && req_we_r == 4'b0000) begin
                resp_data_r     <= hit_data;
                resp_error_r    <= 1'b0;
                resp_is_write_r <= 1'b0;
            end
            // Hit write response
            if (state == S_HIT_WR) begin
                resp_data_r     <= '0;
                resp_error_r    <= 1'b0;
                resp_is_write_r <= 1'b1;
            end
            // Fill: capture critical word (beat 0 of WRAP burst)
            if (state == S_FILL_R && axi_rvalid && axi_rready && fill_word_cnt == '0) begin
                resp_data_r     <= axi_rdata;
                resp_error_r    <= (axi_rresp != 2'b00);
                resp_is_write_r <= 1'b0;
            end
            // Fill error accumulation
            if ((state == S_FILL_R || state == S_FILL_REST ||
                 (state == S_FILL_RESP && fill_active_r))
                 && axi_rvalid && axi_rready && use_dcache && fill_error)
                resp_error_r <= 1'b1;
            // Bypass read: capture single-beat R
            if (state == S_BYPASS_RD && axi_rvalid && axi_rready && axi_rlast) begin
                resp_data_r     <= axi_rdata;
                resp_error_r    <= (axi_rresp != 2'b00);
                resp_is_write_r <= 1'b0;
            end
            // Bypass write: capture B response
            if (state == S_BYPASS_WR_B && axi_bvalid && axi_bready) begin
                resp_data_r     <= '0;
                resp_error_r    <= (axi_bresp != 2'b00);
                resp_is_write_r <= 1'b1;
            end
            // WT B response: store error
            if (state == S_WT_B && axi_bvalid && axi_bready) begin
                resp_error_r    <= (axi_bresp != 2'b00);
            end
            // Miss-write after fill: write-alloc path
            if (fill_commit && req_we_r != 4'b0000 && DCACHE_WRITE_ALLOC) begin
                resp_data_r     <= '0;
                resp_error_r    <= 1'b0;
                resp_is_write_r <= 1'b1;
            end
        end
    end

    // =========================================================================
    // Core handshake outputs
    // =========================================================================
    // Accept new requests:
    //   S_IDLE              – baseline
    //   S_FILL_RESP (+fill) – fill-pending: back-to-back; primary resp consumed
    //                         simultaneously (core_resp_ready) + same-line load
    //   S_FILL_REST         – fill-pending: drain phase; same-line load
    assign core_req_ready = ((state == S_IDLE) && !cmo_valid_i) ||
                            // Fill-pending back-to-back: primary resp consumed this cycle
                            (state == S_FILL_RESP && fill_active_r &&
                             core_resp_ready && fill_pend_can_accept && !cmo_valid_i) ||
                            // Fill-pending during burst drain
                            (state == S_FILL_REST && fill_pend_can_accept && !cmo_valid_i);

    // Response valid
    assign core_resp_valid =
        // Hit read: combinational in S_LOOKUP (zero-stall path when cache ready)
        (state == S_LOOKUP  && use_dcache && cache_hit && req_we_r == 4'b0000) ||
        // Hit write: response in S_HIT_WR (before WT AXI)
        (state == S_HIT_WR) ||
        // Fill resp registered
        (state == S_FILL_RESP) ||
        // Fill-pending: same-line load served directly from AXI bus (CWF beats 1+)
        (state == S_FILL_REST && fill_pend_resp_r) ||
        // Hit read fallback when registered
        (state == S_HIT_RD) ||
        // Bypass read: deliver response as soon as R data arrives (in-line path)
        (state == S_BYPASS_RD && axi_rvalid && axi_rready && axi_rlast) ||
        // Bypass write done
        (state == S_BYPASS_WR_B && axi_bvalid && axi_bready) ||
        // WT write done
        (state == S_WT_B && axi_bvalid && axi_bready);

    assign core_resp_data =
        (state == S_LOOKUP && use_dcache && cache_hit && req_we_r == 4'b0000)
        ? hit_data
        : (state == S_FILL_REST && fill_pend_resp_r)
          ? fill_pend_data_r    // CWF beat 1+: direct from AXI capture
          : (state == S_BYPASS_RD && axi_rvalid)
            ? axi_rdata         // Bypass read: forward directly from AXI bus
            : resp_data_r;

    assign core_resp_error =
        (state == S_LOOKUP && use_dcache && cache_hit && req_we_r == 4'b0000)
        ? 1'b0
        : (state == S_HIT_WR)
          ? 1'b0   // cache hit write: SRAM stores never fail
        : (state == S_FILL_REST && fill_pend_resp_r)
          ? fill_pend_error_r
          : (state == S_BYPASS_RD && axi_rvalid)
            ? (axi_rresp != 2'b00)
            : ((state == S_BYPASS_WR_B || state == S_WT_B) && axi_bvalid && axi_bready)
              ? (axi_bresp != 2'b00)   // inline: bypass/WT write SLVERR visible same cycle as core_resp_valid
              : resp_error_r;

    assign core_resp_is_write =
        (state == S_HIT_WR || state == S_BYPASS_WR_B || state == S_WT_B)
        ? 1'b1
        : (state == S_LOOKUP && use_dcache && cache_hit && req_we_r == 4'b0000)
          ? 1'b0    // load hit: always a read response, not a store completion
        : (state == S_BYPASS_RD)
          ? 1'b0    // bypass read: always a load response, never a write
        : (state == S_FILL_REST && fill_pend_resp_r)
          ? 1'b0    // fill-pend: always a load response
          : resp_is_write_r;

    // CMO ready
    assign cmo_ready_o = (state == S_IDLE);

    // D-cache idle: no AXI transaction in-flight
    assign dcache_idle_o = (state == S_IDLE);

    // =========================================================================
    // Debug messages
    // =========================================================================
`ifdef DEBUG
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
        end else begin
            if (state != next_state) begin
                `DEBUG2(`DBG_GRP_DCACHE, ("[DCACHE] state %0d -> %0d", state, next_state));
            end
            if (state == S_LOOKUP) begin
                if (use_dcache && cache_hit) begin
                    `DEBUG2(`DBG_GRP_DCACHE, ("[DCACHE] HIT addr=0x%h way=%0d %s",
                        req_addr_r, hit_way, (req_we_r != 4'b0000) ? "WR" : "RD"));
                end else if (use_dcache && !cache_hit) begin
                    `DEBUG2(`DBG_GRP_DCACHE, ("[DCACHE] MISS addr=0x%h we=0x%h victim_way=%0d dirty=%b",
                        req_addr_r, req_we_r, victim_way, victim_dirty));
                end else begin
                    `DEBUG2(`DBG_GRP_DCACHE, ("[DCACHE] BYPASS addr=0x%h %s",
                        req_addr_r, (req_we_r != 4'b0000) ? "WR" : "RD"));
                end
            end
            if (state == S_BYPASS_RD) begin
                `DEBUG2(`DBG_GRP_DCACHE, ("[DCACHE] S_BYPASS_RD: arvalid=%b arready=%b rvalid=%b rready=%b rlast=%b bypass_ar_sent=%b addr=0x%h",
                    axi_arvalid, axi_arready, axi_rvalid, axi_rready, axi_rlast, bypass_ar_sent_r, req_addr_r));
            end
            if (state == S_FILL_AR && axi_arvalid && axi_arready) begin
                `DEBUG2(`DBG_GRP_DCACHE, ("[DCACHE] FILL AR addr=0x%h len=%0d", axi_araddr, axi_arlen));
            end
            if (state == S_EVICT_AW && axi_awvalid && axi_awready) begin
                `DEBUG2(`DBG_GRP_DCACHE, ("[DCACHE] EVICT AW addr=0x%h len=%0d", axi_awaddr, axi_awlen));
            end
            if (fill_commit) begin
                `DEBUG2(`DBG_GRP_DCACHE, ("[DCACHE] FILL COMMIT way=%0d index=%0d tag=0x%h",
                    fill_way, req_index, req_tag));
            end
            if (state == S_IDLE && cmo_valid_i && cmo_ready_o) begin
                `DEBUG2(`DBG_GRP_DCACHE, ("[DCACHE] CMO ACCEPTED(IDLE) addr=0x%h set=%0d op=%0d",
                    cmo_addr_i,
                    cmo_addr_i[BYTE_OFFSET_BITS + INDEX_BITS - 1 : BYTE_OFFSET_BITS],
                    cmo_op_i));
            end
            if (state == S_CMO_DONE && cmo_valid_i && cmo_ready_o) begin
                `DEBUG2(`DBG_GRP_DCACHE, ("[DCACHE] CMO ACCEPTED(DONE) addr=0x%h set=%0d op=%0d",
                    cmo_addr_i,
                    cmo_addr_i[BYTE_OFFSET_BITS + INDEX_BITS - 1 : BYTE_OFFSET_BITS],
                    cmo_op_i));
            end
            if (state == S_CMO_SCAN) begin
                `DEBUG2(`DBG_GRP_DCACHE, ("[DCACHE] CMO_SCAN set=%0d way=%0d dirty=%b op=%0d",
                    cmo_scan_set, cmo_scan_way,
                    valid_array[cmo_scan_way][cmo_scan_set] &&
                    dirty_array[cmo_scan_way][cmo_scan_set],
                    cmo_op_r));
            end
            if (state == S_CMO_WB_AW && axi_awvalid && axi_awready) begin
                `DEBUG2(`DBG_GRP_DCACHE, ("[DCACHE] CMO_WB_AW addr=0x%h set=%0d way=%0d",
                    axi_awaddr, cmo_scan_set, cmo_scan_way));
            end
            if (state == S_CMO_DONE) begin
                `DEBUG2(`DBG_GRP_DCACHE, ("[DCACHE] CMO DONE op=%0d", cmo_op_r));
            end
        end
    end
`endif

    // =========================================================================
    // Performance counters (simulation only)
    // =========================================================================
`ifndef SYNTHESIS
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            perf_req_cnt    <= '0;
            perf_hit_cnt    <= '0;
            perf_miss_cnt   <= '0;
            perf_bypass_cnt <= '0;
            perf_fill_cnt   <= '0;
            perf_evict_cnt  <= '0;
            perf_cmo_cnt    <= '0;
        end else begin
            if (state == S_LOOKUP) begin
                perf_req_cnt <= perf_req_cnt + 32'd1;
                if (use_dcache && cache_hit)
                    perf_hit_cnt <= perf_hit_cnt + 32'd1;
                else if (use_dcache && !cache_hit)
                    perf_miss_cnt <= perf_miss_cnt + 32'd1;
                else
                    perf_bypass_cnt <= perf_bypass_cnt + 32'd1;
            end
            if (fill_commit)
                perf_fill_cnt <= perf_fill_cnt + 32'd1;
            if (state == S_EVICT_B && axi_bvalid && axi_bready)
                perf_evict_cnt <= perf_evict_cnt + 32'd1;
            if (state == S_CMO_DONE)
                perf_cmo_cnt <= perf_cmo_cnt + 32'd1;
        end
    end
`endif

    // =========================================================================
    // Debug probes: track set=55 operations (tohost @ 0x80010EE0 = {set=55,word=0})
    // Enable with:  make DEBUG=1 rtl-coremark
    // Filter:       make DEBUG=2 DEBUG_GROUP=0x40000 rtl-coremark
    // =========================================================================
`ifdef DEBUG
    always_ff @(posedge clk) begin : dbg_set55
        // Probe 1: any write to SRAM word-0 of set 55 (the tohost word position)
        for (int dbg_w = 0; dbg_w < DCACHE_WAYS; dbg_w++) begin
            if (data_sram_we[dbg_w] &&
                data_sram_addr[dbg_w] == DATA_SRAM_ADDR_BITS'({6'd55, 3'd0})) begin
                `DEBUG1(("[DCACHE-DBG] SRAM{55,0} way=%0d val=0x%08h hit=%b fill=%b cnt=%0d st=%0d req=0x%08h we=%b wdat=0x%08h fill_wo=%0d",
                    dbg_w, data_sram_wdata[dbg_w],
                    data_hit_we, data_fill_we, fill_word_cnt, state,
                    req_addr_r, req_we_r, req_wdata_r, fill_req_word_off_r));
            end
        end
        // Probe 2: every eviction beat from set=55 (shows what goes to AXI at tohost addr)
        if ((state == S_EVICT_W) && axi_wvalid && axi_wready &&
            req_index == 6'd55) begin
            `DEBUG1(("[DCACHE-DBG] EVICT55 beat=%0d data=0x%08h evict_base=0x%08h way=%0d",
                evict_wbeat_cnt, axi_wdata, evict_base_addr, wb_way_r));
        end
        // Probe 3: every fill beat into set=55 (shows what gets stored in SRAM)
        if (data_fill_we && req_index == 6'd55) begin
            `DEBUG1(("[DCACHE-DBG] FILL55 way=%0d cnt=%0d sram_val=0x%08h req=0x%08h we=%b wdat=0x%08h fill_wo=%0d",
                fill_way, fill_word_cnt, data_sram_wdata[fill_way],
                req_addr_r, req_we_r, req_wdata_r, fill_req_word_off_r));
        end
    end
`endif // DEBUG

    // =========================================================================
    // Formal / simulation assertions
    // =========================================================================
`ifndef NO_ASSERTION
`ifndef ASSERTION
`define ASSERTION
`endif
`endif

`ifdef ASSERTION

    property p_arvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_arvalid && !axi_arready) |=> axi_arvalid;
    endproperty
    assert property (p_arvalid_stable)
        else $error("[DCACHE] ARVALID deasserted before ARREADY");

    property p_awvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (axi_awvalid && !axi_awready) |=> axi_awvalid;
    endproperty
    assert property (p_awvalid_stable)
        else $error("[DCACHE] AWVALID deasserted before AWREADY");

    property p_rlast_on_final_beat_fill;
        @(posedge clk) disable iff (!rst_n)
        (state == S_FILL_R && axi_rvalid && axi_rready && axi_rlast) |->
            (fill_word_cnt == WORD_OFFSET_BITS'(WORDS_PER_LINE - 1));
    endproperty
    assert property (p_rlast_on_final_beat_fill)
        else $error("[DCACHE] RLAST arrived on unexpected fill beat (fill_word_cnt=%0d)", fill_word_cnt);

    property p_no_multi_way_hit;
        @(posedge clk) disable iff (!rst_n)
        // tag_sram_rdata is only consistent with req_index in S_LOOKUP (SRAM was
        // read at new_req_index in S_IDLE; all other states may drive a different
        // read address, e.g. cmo_scan_set during S_CMO_SCAN, causing false hits).
        (state == S_LOOKUP) |-> $onehot0(way_hit);
    endproperty
    assert property (p_no_multi_way_hit)
        else $error("[DCACHE] Multiple ways hit simultaneously – tag aliasing!");

    property p_dirty_only_if_valid;
        @(posedge clk) disable iff (!rst_n)
        (1'b1) |-> ($countones({dirty_array[0][0]}) == 0 ||
                    valid_array[0][0] == dirty_array[0][0]);
    endproperty
    // Note: full N-way check is complex; kept as documentation; enabled via formal tools

`ifndef SYNTHESIS
    logic _unused_ok;
    assign _unused_ok = &{1'b0, req_addr_r[1:0], cmo_addr_r[5:0],
                                evict_commit, axi_bresp};
    logic evict_commit_w;
    assign evict_commit_w = (state == S_EVICT_AW && axi_awvalid && axi_awready);
    assign evict_commit = evict_commit_w;
`endif

`endif // ASSERTION

endmodule

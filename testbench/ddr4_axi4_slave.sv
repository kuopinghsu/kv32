// ============================================================================
// File: ddr4_axi4_slave.sv
// Project: KV32 RISC-V Processor
// Description: DDR4 AXI4 Slave Interface Simulation Model
//
// Behavioural DDR4 memory model with a full AXI4 slave port.  Supports
// single-beat and burst transfers (INCR, FIXED, WRAP) with parameterisable
// memory density, data width, bank/row/column geometry, and DDR4 timing
// (CL, RCD, RP, RAS, etc.).  Intended for use in Verilator testbenches.
// ============================================================================

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */

module ddr4_axi4_slave #(
    //-------------------------------------------------------------------------
    // AXI4 Interface Parameters
    //-------------------------------------------------------------------------
    parameter AXI_ID_WIDTH      = 4,
    parameter AXI_ADDR_WIDTH    = 32,
    parameter AXI_DATA_WIDTH    = 32,
    parameter AXI_STRB_WIDTH    = AXI_DATA_WIDTH / 8,

    //-------------------------------------------------------------------------
    // DDR4 Memory Parameters
    //-------------------------------------------------------------------------
    parameter DDR4_DENSITY_GB   = 1,              // Memory density in GB (1, 2, 4, 8, 16)
    parameter DDR4_DQ_WIDTH     = 64,             // Data width (x4, x8, x16, x32, x64)
    parameter DDR4_BANKS        = 16,             // Number of banks (16 for DDR4)
    parameter DDR4_ROWS         = 65536,          // Number of rows per bank
    parameter DDR4_COLS         = 1024,           // Number of columns per row

    //-------------------------------------------------------------------------
    // DDR4 Speed Grade (MT/s).  All timing is derived from ddr4_axi4_pkg.
    // Supported values: 1600, 1866, 2133, 2400, 2666, 2933, 3200
    //-------------------------------------------------------------------------
    parameter int DDR4_SPEED_GRADE = 1600,

    //-------------------------------------------------------------------------
    // Clock Parameters
    // AXI_CLK_PERIOD_NS: period of aclk in nanoseconds (e.g. 10 for 100 MHz).
    // mclk is the asynchronous DDR4 memory clock.  Its frequency must be
    // DDR4_SPEED_GRADE/2 MHz (double-data-rate ⟹ half-rate clock).
    // Example: DDR4-2400 → mclk = 1200 MHz (tCK_mclk = 833 ps).
    //-------------------------------------------------------------------------
    parameter int AXI_CLK_PERIOD_NS = 10,            // aclk period (ns), default 100 MHz

    //-------------------------------------------------------------------------
    // Simulation Parameters
    //-------------------------------------------------------------------------
    parameter MEMORY_INIT_FILE  = "",             // Optional memory initialization file
    parameter ENABLE_TIMING_CHECK = 1,            // Enable DDR4 timing checks
    parameter ENABLE_TIMING_MODEL = 1,            // Enforce real DDR4 tRCD/CL/CWL/tWR delays
    parameter RANDOM_DELAY_EN   = 0,              // Enable random response delays
    parameter MAX_RANDOM_DELAY  = 10,             // Maximum random delay cycles
    parameter VERBOSE_MODE      = 1,              // Enable verbose logging
    parameter BASE_ADDR         = 32'h80000000,   // Base address of this memory in AXI address space
    parameter int SIM_MEM_DEPTH = 0,              // Non-zero: override density-derived depth (for simulation)

    //-------------------------------------------------------------------------
    // Outstanding Request Parameters
    //-------------------------------------------------------------------------
    parameter int MAX_OUTSTANDING = 16             // Maximum outstanding transactions per channel (1–256)
)(
    //-------------------------------------------------------------------------
    // Global Signals
    //-------------------------------------------------------------------------
    input  logic                        aclk,
    input  logic                        aresetn,
    input  logic                        mclk,        // Asynchronous DDR4 memory clock
    input  logic                        mresetn,     // Synchronous reset for mclk domain

    //-------------------------------------------------------------------------
    // AXI4 Write Address Channel
    //-------------------------------------------------------------------------
    input  logic [AXI_ID_WIDTH-1:0]     s_axi_awid,
    input  logic [AXI_ADDR_WIDTH-1:0]   s_axi_awaddr,
    input  logic [7:0]                  s_axi_awlen,
    input  logic [2:0]                  s_axi_awsize,
    input  logic [1:0]                  s_axi_awburst,
    input  logic                        s_axi_awlock,
    input  logic [3:0]                  s_axi_awcache,
    input  logic [2:0]                  s_axi_awprot,
    input  logic [3:0]                  s_axi_awqos,
    input  logic                        s_axi_awvalid,
    output logic                        s_axi_awready,

    //-------------------------------------------------------------------------
    // AXI4 Write Data Channel
    //-------------------------------------------------------------------------
    input  logic [AXI_DATA_WIDTH-1:0]   s_axi_wdata,
    input  logic [AXI_STRB_WIDTH-1:0]   s_axi_wstrb,
    input  logic                        s_axi_wlast,
    input  logic                        s_axi_wvalid,
    output logic                        s_axi_wready,

    //-------------------------------------------------------------------------
    // AXI4 Write Response Channel
    //-------------------------------------------------------------------------
    output logic [AXI_ID_WIDTH-1:0]     s_axi_bid,
    output logic [1:0]                  s_axi_bresp,
    output logic                        s_axi_bvalid,
    input  logic                        s_axi_bready,

    //-------------------------------------------------------------------------
    // AXI4 Read Address Channel
    //-------------------------------------------------------------------------
    input  logic [AXI_ID_WIDTH-1:0]     s_axi_arid,
    input  logic [AXI_ADDR_WIDTH-1:0]   s_axi_araddr,
    input  logic [7:0]                  s_axi_arlen,
    input  logic [2:0]                  s_axi_arsize,
    input  logic [1:0]                  s_axi_arburst,
    input  logic                        s_axi_arlock,
    input  logic [3:0]                  s_axi_arcache,
    input  logic [2:0]                  s_axi_arprot,
    input  logic [3:0]                  s_axi_arqos,
    input  logic                        s_axi_arvalid,
    output logic                        s_axi_arready,

    //-------------------------------------------------------------------------
    // AXI4 Read Data Channel
    //-------------------------------------------------------------------------
    output logic [AXI_ID_WIDTH-1:0]     s_axi_rid,
    output logic [AXI_DATA_WIDTH-1:0]   s_axi_rdata,
    output logic [1:0]                  s_axi_rresp,
    output logic                        s_axi_rlast,
    output logic                        s_axi_rvalid,
    input  logic                        s_axi_rready
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    import ddr4_axi4_pkg::*;

    localparam BYTES_PER_BEAT = AXI_DATA_WIDTH / 8;
    localparam ADDR_LSB = $clog2(BYTES_PER_BEAT);

    // Memory size calculation – use longint to avoid 32-bit overflow for ≥2 GB
    localparam longint MEM_SIZE_BYTES = longint'(DDR4_DENSITY_GB) * 1024 * 1024 * 1024;
    localparam longint MEM_DEPTH      = MEM_SIZE_BYTES / BYTES_PER_BEAT;
    localparam int     MEM_ADDR_WIDTH = $clog2(MEM_DEPTH);

    // Simulation depth override: keeps memory array small during verification
    localparam int ACTUAL_MEM_DEPTH = (SIM_MEM_DEPTH > 0) ? SIM_MEM_DEPTH : int'(MEM_DEPTH);

    //=========================================================================
    // DDR4 Real-Timing Localparams (Verilator-safe ternary chains)
    //=========================================================================
    // Clock period in picoseconds for the selected speed grade
    localparam int TCK_PS =
        (DDR4_SPEED_GRADE == 1600) ? 1250 :
        (DDR4_SPEED_GRADE == 1866) ? 1071 :
        (DDR4_SPEED_GRADE == 2133) ?  937 :
        (DDR4_SPEED_GRADE == 2400) ?  833 :
        (DDR4_SPEED_GRADE == 2666) ?  750 :
        (DDR4_SPEED_GRADE == 2933) ?  682 :
        (DDR4_SPEED_GRADE == 3200) ?  625 : 833; // default → DDR4-2400

    // CAS latency (read), cycles
    localparam int CL_CYC =
        (DDR4_SPEED_GRADE == 1600) ? 11 :
        (DDR4_SPEED_GRADE == 1866) ? 13 :
        (DDR4_SPEED_GRADE == 2133) ? 15 :
        (DDR4_SPEED_GRADE == 2400) ? 17 :
        (DDR4_SPEED_GRADE == 2666) ? 19 :
        (DDR4_SPEED_GRADE == 2933) ? 21 :
        (DDR4_SPEED_GRADE == 3200) ? 22 : 17;

    // CAS write latency, cycles
    localparam int CWL_CYC =
        (DDR4_SPEED_GRADE == 1600) ?  9 :
        (DDR4_SPEED_GRADE == 1866) ? 10 :
        (DDR4_SPEED_GRADE == 2133) ? 11 :
        (DDR4_SPEED_GRADE == 2400) ? 12 :
        (DDR4_SPEED_GRADE == 2666) ? 14 :
        (DDR4_SPEED_GRADE == 2933) ? 16 :
        (DDR4_SPEED_GRADE == 3200) ? 16 : 12;

    // Row-activate to CAS (tRCD = 14 ns, same for all supported grades)
    localparam int tRCD_CYC = (14 * 1000 + TCK_PS - 1) / TCK_PS;  // ceil(14 ns / tCK)
    // Row precharge (tRP = 14 ns)
    localparam int tRP_CYC  = (14 * 1000 + TCK_PS - 1) / TCK_PS;
    // Write recovery (tWR = 15 ns)
    localparam int tWR_CYC  = (15 * 1000 + TCK_PS - 1) / TCK_PS;

    // Composite latencies expressed in DDR4 mclk half-rate cycles.
    // mclk runs at DDR4_SPEED_GRADE/2 MHz, so tCK_mclk = TCK_PS*2 ps.
    // tRCD / CL / CWL / tWR are all defined in terms of the DDR4 data rate
    // (full-rate) cycles in the JEDEC spec, so they map 1-to-1 to mclk cycles.
    localparam int READ_LAT_CYC  = ENABLE_TIMING_MODEL ? (tRCD_CYC + CL_CYC)  : 1;
    localparam int WRITE_PRE_CYC = ENABLE_TIMING_MODEL ? (tRCD_CYC + CWL_CYC) : 1;
    localparam int WRITE_REC_CYC = ENABLE_TIMING_MODEL ? tWR_CYC               : 0;

    // Write-to-read turnaround: tWTR_L = max(4 nCK, 7.5 ns) for all supported grades
    // (7.5 ns / tCK is always ≥ 4 for the 1600–3200 MT/s range, so max() is omitted)
    localparam int tWTR_L_CYC    = ENABLE_TIMING_MODEL ? (7500 + TCK_PS - 1) / TCK_PS : 0;
    // Conservatively ceiling-round to ns for simulator-time window comparison
    localparam int tWTR_L_WIN_NS = ENABLE_TIMING_MODEL ? (tWTR_L_CYC * TCK_PS + 999) / 1000 : 0;

    // Refresh recovery: tRFC = 350 ns (matches pkg for all supported speed grades / 1–8 Gb)
    localparam int tRFC_CYC  = ENABLE_TIMING_MODEL ? (350 * 1000 + TCK_PS - 1) / TCK_PS : 0;
    // Refresh interval (tREFI = 7800 ns), in simulator ns units ($timescale 1ns/1ps)
    localparam int tREFI_NS  = 7800;

    // Four-activate window: per-speed-grade from JEDEC (matches pkg values)
    localparam int tFAW_NS   =
        (DDR4_SPEED_GRADE == 1600) ? 30 :
        (DDR4_SPEED_GRADE == 1866) ? 27 :
        (DDR4_SPEED_GRADE == 2133) ? 25 :
        (DDR4_SPEED_GRADE == 2400) ? 23 :
        (DDR4_SPEED_GRADE == 2666) ? 21 :
        (DDR4_SPEED_GRADE == 2933) ? 18 :
        (DDR4_SPEED_GRADE == 3200) ? 16 : 23;  // default → DDR4-2400
    localparam int tFAW_CYC  = ENABLE_TIMING_MODEL ? (tFAW_NS * 1000 + TCK_PS - 1) / TCK_PS : 0;

    // Page-hit latency: row already open — skip tRCD
    localparam int RD_HIT_CYC = ENABLE_TIMING_MODEL ? CL_CYC  : 1;
    localparam int WR_HIT_CYC = ENABLE_TIMING_MODEL ? CWL_CYC : 1;

    // DDR4 address-geometry bits for bank / row extraction
    localparam int COL_BITS      = $clog2(DDR4_COLS);    // column address bits
    localparam int BANK_BITS     = $clog2(DDR4_BANKS);   // bank address bits
    localparam int BANK_GRP_BITS = 2;                    // 4 bank groups → 2 bits

    // tRAS: minimum row-active time before precharge (ns). Per-grade from JEDEC.
    localparam int tRAS_NS =
        (DDR4_SPEED_GRADE == 1600) ? 35 :
        (DDR4_SPEED_GRADE == 1866) ? 34 :
        (DDR4_SPEED_GRADE == 2133) ? 33 : 32;   // 2400 / 2666 / 2933 / 3200

    // tRC: row cycle time = tRAS + tRP (min ACT-to-ACT same bank, ns). Per-grade from JEDEC.
    // Enforced IMPLICITLY: the page-miss path adds tRP_CYC AFTER the tRAS guard, so
    // the total stall from ACT1 to new ACT ≥ tRAS + tRP = tRC. No separate logic needed.
    localparam int tRC_NS =
        (DDR4_SPEED_GRADE == 1600) ? 49 :
        (DDR4_SPEED_GRADE == 1866) ? 48 :
        (DDR4_SPEED_GRADE == 2133) ? 47 : 46;   // 2400 / 2666 / 2933 / 3200

    // tRTP: read-to-precharge (8 ns, constant for all supported grades)
    localparam int tRTP_NS  = 8;
    localparam int tRTP_CYC = ENABLE_TIMING_MODEL ? (tRTP_NS  * 1000 + TCK_PS - 1) / TCK_PS : 0;

    // tCCD: CAS-to-CAS delay.  S = same bank group (4 nCK), L = different (5/6 nCK).
    localparam int tCCD_S_CYC = ENABLE_TIMING_MODEL ? 4 : 0;
    localparam int tCCD_L_CYC = ENABLE_TIMING_MODEL ? ((DDR4_SPEED_GRADE <= 2133) ? 5 : 6) : 0;

    // tWTR_S: write-to-read, same bank group (3 nCK — shorter than tWTR_L)
    localparam int tWTR_S_CYC    = ENABLE_TIMING_MODEL ? 3 : 0;
    localparam int tWTR_S_WIN_NS = ENABLE_TIMING_MODEL ? (tWTR_S_CYC * TCK_PS + 999) / 1000 : 0;

    // AXI clock period in picoseconds (for reference / verbose display)
    localparam int AXI_CLK_PERIOD_PS = AXI_CLK_PERIOD_NS * 1000;

    // AXI Burst Types
    localparam BURST_FIXED = 2'b00;
    localparam BURST_INCR  = 2'b01;
    localparam BURST_WRAP  = 2'b10;

    // AXI Response Types
    localparam RESP_OKAY   = 2'b00;
    localparam RESP_EXOKAY = 2'b01;
    localparam RESP_SLVERR = 2'b10;
    localparam RESP_DECERR = 2'b11;

    //=========================================================================
    // Memory Array
    //=========================================================================
    logic [AXI_DATA_WIDTH-1:0] memory [0:ACTUAL_MEM_DEPTH-1];

    //=========================================================================
    // Statistics Counters
    //=========================================================================
    typedef struct packed {
        longint unsigned total_read_transactions;
        longint unsigned total_write_transactions;
        longint unsigned total_read_bytes;
        longint unsigned total_write_bytes;
        longint unsigned single_read_count;
        longint unsigned single_write_count;
        longint unsigned burst_incr_read_count;
        longint unsigned burst_incr_write_count;
        longint unsigned burst_wrap_read_count;
        longint unsigned burst_wrap_write_count;
        longint unsigned burst_fixed_read_count;
        longint unsigned burst_fixed_write_count;
        longint unsigned read_latency_total;
        longint unsigned write_latency_total;
        longint unsigned min_read_latency;
        longint unsigned max_read_latency;
        longint unsigned min_write_latency;
        longint unsigned max_write_latency;
        longint unsigned address_errors;
        longint unsigned protocol_errors;
        longint unsigned total_clock_cycles;
        longint unsigned busy_cycles;
        time             sim_start_time;
        time             sim_end_time;
        // DDR4 timing event counters
        longint unsigned refresh_stall_count;
        longint unsigned page_miss_count;
        longint unsigned page_hit_count;
        longint unsigned wtr_stall_count;
        longint unsigned faw_stall_count;
        longint unsigned tRAS_stall_count;   // page-miss precharges stalled by tRAS
        longint unsigned tRTP_stall_count;   // page-miss reads stalled by tRTP
        longint unsigned tCCD_stall_count;   // CAS-to-CAS stalls
        // Outstanding-request counters
        longint unsigned max_outstanding_reads;
        longint unsigned max_outstanding_writes;
    } stats_t;

    stats_t stats;

    //=========================================================================
    // Outstanding-request FIFO helpers
    //    Each channel has a small circular FIFO that holds accepted address
    //    beats while the processing FSM is busy.  The FIFO entries carry the
    //    same fields that the FSM needs: id, addr, len, size, burst.
    //    Depth = MAX_OUTSTANDING.  awready / arready are suppressed when the
    //    corresponding FIFO is full.
    //=========================================================================
    localparam int FIFO_DEPTH = MAX_OUTSTANDING;          // power-of-2 not required

    // Write-address FIFO entry
    typedef struct packed {
        logic [AXI_ID_WIDTH-1:0]   id;
        logic [AXI_ADDR_WIDTH-1:0] addr;
        logic [7:0]                len;
        logic [2:0]                size;
        logic [1:0]                burst;
    } aw_entry_t;

    aw_entry_t aw_fifo   [0:FIFO_DEPTH-1];
    int        aw_wr_ptr;      // next write slot
    int        aw_rd_ptr;      // next read slot
    int        aw_count;       // entries present

    // Read-address FIFO entry (same fields)
    typedef struct packed {
        logic [AXI_ID_WIDTH-1:0]   id;
        logic [AXI_ADDR_WIDTH-1:0] addr;
        logic [7:0]                len;
        logic [2:0]                size;
        logic [1:0]                burst;
    } ar_entry_t;

    ar_entry_t ar_fifo   [0:FIFO_DEPTH-1];
    int        ar_wr_ptr;
    int        ar_rd_ptr;
    int        ar_count;

    //=========================================================================
    // Internal Signals - Write Path
    //=========================================================================
    typedef enum logic [2:0] {
        WR_IDLE,
        WR_ADDR_WAIT,   // wait for mclk-domain ack (write preamble)
        WR_ACK_CLR,     // wait for ack to deassert (4-phase phase-3)
        WR_DATA,
        WR_DELAY,       // wait for mclk-domain ack (write recovery)
        WR_RESP
    } wr_state_t;

    wr_state_t wr_state, wr_next_state;

    logic [AXI_ID_WIDTH-1:0]   wr_id_reg;
    logic [AXI_ADDR_WIDTH-1:0] wr_addr_reg;
    logic [7:0]                wr_len_reg;
    logic [2:0]                wr_size_reg;
    logic [1:0]                wr_burst_reg;
    logic [7:0]                wr_beat_cnt;
    logic [AXI_ADDR_WIDTH-1:0] wr_addr_next;
    logic [AXI_ADDR_WIDTH-1:0] wr_wrap_boundary;
    logic [AXI_ADDR_WIDTH-1:0] wr_wrap_size;
    time                       wr_start_time;
    // wr_delay_cnt removed – timing is counted in the mclk domain via CDC

    //=========================================================================
    // Internal Signals - Read Path
    //=========================================================================
    typedef enum logic [2:0] {
        RD_IDLE,
        RD_ADDR_WAIT,   // wait for mclk-domain ack (read latency)
        RD_ACK_CLR,     // wait for ack to deassert (4-phase phase-3)
        RD_DATA,
        RD_DELAY        // unused pipeline slot (kept for encoding)
    } rd_state_t;

    rd_state_t rd_state, rd_next_state;

    logic [AXI_ID_WIDTH-1:0]   rd_id_reg;
    logic [AXI_ADDR_WIDTH-1:0] rd_addr_reg;
    logic [7:0]                rd_len_reg;
    logic [2:0]                rd_size_reg;
    logic [1:0]                rd_burst_reg;
    logic [7:0]                rd_beat_cnt;
    logic [AXI_ADDR_WIDTH-1:0] rd_addr_next;
    logic [AXI_ADDR_WIDTH-1:0] rd_wrap_boundary;
    logic [AXI_ADDR_WIDTH-1:0] rd_wrap_size;
    time                       rd_start_time;
    // rd_delay_cnt removed – timing is counted in the mclk domain via CDC

    //=========================================================================
    // DDR4 Timing Model Signals
    //=========================================================================
    // Per-bank open-row tracker: 0 = closed; non-zero = (row_index + 1)
    int unsigned  bank_open_row [0:DDR4_BANKS-1];
    // tRAS: wall-clock time (ns) when each bank was last activated
    time          bank_act_time [0:DDR4_BANKS-1];
    // tRTP: wall-clock time (ns) of the last read CAS issued to each bank
    time          bank_last_rd_time [0:DDR4_BANKS-1];
    // tCCD: wall-clock time of the most recent CAS command (read or write)
    time          last_cas_time;
    // tCCD: bank group of the most recent CAS (for tCCD_S vs tCCD_L)
    int unsigned  last_cas_bank_grp;
    // Refresh scheduling — absolute simulator time (ns) of the next refresh
    time          next_refresh_time;
    // tWTR — simulator time (ns) when the last write response completed
    time          last_write_done_time;
    // tWTR: bank group of the most recently completed write (for tWTR_S vs tWTR_L)
    int unsigned  last_wr_bank_grp;
    // tFAW ring buffer: timestamps (ns) of the last ≤4 ACT commands
    time          faw_act_times [0:3];
    int unsigned  faw_head;         // next write slot (0–3)
    int unsigned  faw_entry_count;  // number of valid entries (0–4)

    //=========================================================================
    // Clock-Domain Crossing (aclk <-> mclk)
    //
    // Protocol (single-transaction handshake):
    //   aclk domain asserts ddr4_req (level) and loads ddr4_req_cycles with
    //   the number of DDR4 (mclk) cycles to wait.
    //   mclk domain sees the synchronized request, counts down, then pulses
    //   ddr4_ack (level).  aclk domain deasserts ddr4_req once it sees the
    //   synchronised ack; mclk domain deasserts ddr4_ack in response.
    //   This is a classic four-phase (req/ack) CDC handshake.
    //=========================================================================

    // --- aclk domain ---
    logic        wr_ddr4_req;       // write path: request DDR4 timing countdown
    logic        rd_ddr4_req;       // read path:  request DDR4 timing countdown
    logic        ddr4_req;          // combined req to mclk domain (write OR read)
    logic [9:0]  ddr4_req_cycles;   // mclk cycles to count (loaded with req)
    logic        ddr4_ack_sync1,    // 2-FF sync of mclk→aclk ack
                 ddr4_ack_aclk;

    // Combined request: only one path is active at a time (in-order slave)
    assign ddr4_req = wr_ddr4_req | rd_ddr4_req;

    // --- mclk domain ---
    logic        ddr4_req_sync1,    // 2-FF sync of aclk→mclk req
                 ddr4_req_mclk;
    logic        ddr4_ack;          // acknowledge: countdown complete
    logic [9:0]  mclk_cnt;          // mclk-domain countdown register
    logic [9:0]  mclk_cnt_load;     // latched copy of ddr4_req_cycles (mclk)
    // We also need to capture ddr4_req_cycles when req is first seen in mclk.
    // A two-stage sync on the cycles bus is acceptable because the bus is
    // stable for many aclk cycles before req is raised (written in WR_IDLE/
    // RD_IDLE before the state transition that raises req).
    logic [9:0]  ddr4_cyc_sync1 [0:1]; // two-stage bus synchroniser

    // -----------------------------------------------------------------------
    // 2-FF synchroniser: ddr4_req (aclk) → ddr4_req_mclk (mclk)
    // -----------------------------------------------------------------------
    always_ff @(posedge mclk or negedge mresetn) begin
        if (!mresetn) begin
            ddr4_req_sync1  <= 1'b0;
            ddr4_req_mclk   <= 1'b0;
            ddr4_cyc_sync1[0] <= '0;
            ddr4_cyc_sync1[1] <= '0;
        end else begin
            ddr4_req_sync1    <= ddr4_req;
            ddr4_req_mclk     <= ddr4_req_sync1;
            ddr4_cyc_sync1[0] <= ddr4_req_cycles;
            ddr4_cyc_sync1[1] <= ddr4_cyc_sync1[0];
        end
    end

    // -----------------------------------------------------------------------
    // 2-FF synchroniser: ddr4_ack (mclk) → ddr4_ack_aclk (aclk)
    // -----------------------------------------------------------------------
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            ddr4_ack_sync1 <= 1'b0;
            ddr4_ack_aclk  <= 1'b0;
        end else begin
            ddr4_ack_sync1 <= ddr4_ack;
            ddr4_ack_aclk  <= ddr4_ack_sync1;
        end
    end

    // -----------------------------------------------------------------------
    // mclk-domain: DDR4 timing countdown + ack generation
    // Four-phase handshake (req_mclk level ↑ → count → ack ↑ → req ↓ → ack ↓)
    // -----------------------------------------------------------------------
    typedef enum logic [1:0] {
        MC_IDLE,    // waiting for request from aclk domain
        MC_LOAD,    // latch cycle count (first cycle req is seen)
        MC_COUNT,   // counting down DDR4 cycles
        MC_ACK      // holding ack until req deasserts
    } mc_state_t;

    mc_state_t mc_state;

    always_ff @(posedge mclk or negedge mresetn) begin
        if (!mresetn) begin
            mc_state    <= MC_IDLE;
            mclk_cnt    <= '0;
            mclk_cnt_load <= '0;
            ddr4_ack    <= 1'b0;
        end else begin
            case (mc_state)
                MC_IDLE: begin
                    ddr4_ack <= 1'b0;
                    if (ddr4_req_mclk) begin
                        // Latch the synchronised cycle count and start
                        mclk_cnt_load <= ddr4_cyc_sync1[1];
                        mc_state      <= MC_LOAD;
                    end
                end

                MC_LOAD: begin
                    // Extra cycle so cnt_load is stable before countdown
                    mclk_cnt <= mclk_cnt_load;
                    mc_state <= MC_COUNT;
                end

                MC_COUNT: begin
                    if (mclk_cnt == 0) begin
                        ddr4_ack <= 1'b1;
                        mc_state <= MC_ACK;
                    end else begin
                        mclk_cnt <= mclk_cnt - 1;
                    end
                end

                MC_ACK: begin
                    // Hold ack until the aclk domain deasserts req
                    if (!ddr4_req_mclk) begin
                        ddr4_ack <= 1'b0;
                        mc_state <= MC_IDLE;
                    end
                end

                default: mc_state <= MC_IDLE;
            endcase
        end
    end

    //=========================================================================
    // Random Delay Generation
    //=========================================================================
    function automatic int get_random_delay();
        if (RANDOM_DELAY_EN)
            return $urandom_range(0, MAX_RANDOM_DELAY);
        else
            return 0;
    endfunction

    //=========================================================================
    // Address Calculation Functions
    //=========================================================================

    // Calculate next address for burst transactions
    function automatic [AXI_ADDR_WIDTH-1:0] calc_next_addr(
        input [AXI_ADDR_WIDTH-1:0] current_addr,
        input [2:0]                size,
        input [1:0]                burst,
        input [7:0]                len,
        input [AXI_ADDR_WIDTH-1:0] start_addr
    );
        logic [AXI_ADDR_WIDTH-1:0] size_bytes;
        logic [AXI_ADDR_WIDTH-1:0] aligned_addr;
        logic [AXI_ADDR_WIDTH-1:0] wrap_boundary;
        logic [AXI_ADDR_WIDTH-1:0] wrap_size;

        size_bytes = 1 << size;

        case (burst)
            BURST_FIXED: begin
                // Fixed burst - address stays the same
                calc_next_addr = current_addr;
            end

            BURST_INCR: begin
                // Incrementing burst - address increments by size
                calc_next_addr = current_addr + size_bytes;
            end

            BURST_WRAP: begin
                // Wrapping burst - address wraps at boundary
                wrap_size = size_bytes * (len + 1);
                wrap_boundary = (start_addr / wrap_size) * wrap_size;
                aligned_addr = current_addr + size_bytes;

                if (aligned_addr >= wrap_boundary + wrap_size)
                    calc_next_addr = wrap_boundary;
                else
                    calc_next_addr = aligned_addr;
            end

            default: begin
                calc_next_addr = current_addr + size_bytes;
            end
        endcase
    endfunction

    // Convert AXI address to memory index (subtract BASE_ADDR first)
    function automatic int unsigned addr_to_mem_index(
        input [AXI_ADDR_WIDTH-1:0] addr
    );
        addr_to_mem_index = int'((addr - BASE_ADDR) >> ADDR_LSB);
    endfunction

    // Check if address is valid (bounded by simulation array depth)
    function automatic logic is_valid_address(
        input [AXI_ADDR_WIDTH-1:0] addr
    );
        is_valid_address = (addr >= BASE_ADDR) &&
                           (int'((addr - BASE_ADDR) >> ADDR_LSB) < ACTUAL_MEM_DEPTH);
    endfunction

    //=========================================================================
    // Memory Initialization
    //=========================================================================
    initial begin
        // Initialize statistics
        stats = '0;
        stats.min_read_latency = '1;  // Set to max value
        stats.min_write_latency = '1;
        stats.sim_start_time = $time;

        // Initialize memory
        for (int i = 0; i < ACTUAL_MEM_DEPTH; i++) begin
            memory[i] = '0;
        end

        // Load initialization file if specified
        if (MEMORY_INIT_FILE != "") begin
            $readmemh(MEMORY_INIT_FILE, memory);
            if (VERBOSE_MODE)
                $display("[%0t] DDR4_MODEL: Loaded memory from file: %s", $time, MEMORY_INIT_FILE);
        end

        // Initialize outstanding-request FIFOs
        aw_wr_ptr = 0; aw_rd_ptr = 0; aw_count = 0;
        ar_wr_ptr = 0; ar_rd_ptr = 0; ar_count = 0;
        for (int i = 0; i < FIFO_DEPTH; i++) begin
            aw_fifo[i] = '0;
            ar_fifo[i] = '0;
        end

        // Initialize DDR4 timing model state
        for (int i = 0; i < DDR4_BANKS; i++) begin
            bank_open_row[i]     = 0;
            bank_act_time[i]     = 0;
            bank_last_rd_time[i] = 0;
        end
        next_refresh_time    = tREFI_NS;  // first refresh window at t = tREFI_NS
        last_write_done_time = 0;
        last_wr_bank_grp     = 0;
        last_cas_time        = 0;
        last_cas_bank_grp    = 0;
        for (int i = 0; i < 4; i++) faw_act_times[i] = 0;
        faw_head        = 0;
        faw_entry_count = 0;

        if (VERBOSE_MODE) begin
            ddr4_axi4_pkg::ddr4_timing_t t_;
            t_ = ddr4_axi4_pkg::get_ddr4_timing(ddr4_axi4_pkg::ddr4_speed_t'(DDR4_SPEED_GRADE));
            $display("[%0t] DDR4_MODEL: Initialized with following parameters:", $time);
            $display("  - Density: %0d GB", DDR4_DENSITY_GB);
            $display("  - Data Width: %0d bits", DDR4_DQ_WIDTH);
            $display("  - Banks: %0d", DDR4_BANKS);
            $display("  - Rows: %0d", DDR4_ROWS);
            $display("  - Columns: %0d", DDR4_COLS);
            $display("  - AXI Data Width: %0d bits", AXI_DATA_WIDTH);
            $display("  - Memory Depth: %0d entries", MEM_DEPTH);
            $display("  - Speed Grade: DDR4-%0d", DDR4_SPEED_GRADE);
            $display("  - CAS Latency (CL): %0d", t_.CL);
            $display("  - RAS to CAS Delay (tRCD): %0d ns", t_.tRCD);
            $display("  - Row Precharge (tRP): %0d ns", t_.tRP);
            $display("  --- Derived timing (DDR4 mclk domain) ---");
            $display("  - tRCD:         %0d cycles", tRCD_CYC);
            $display("  - tRP:          %0d cycles", tRP_CYC);
            $display("  - tWR:          %0d cycles", WRITE_REC_CYC);
            $display("  - CL:           %0d cycles", CL_CYC);
            $display("  - CWL:          %0d cycles", CWL_CYC);
            $display("  - READ_LAT:     %0d cycles  (tRCD + CL)", READ_LAT_CYC);
            $display("  - WRITE_PRE:    %0d cycles  (tRCD + CWL)", WRITE_PRE_CYC);
            $display("  - WRITE_REC:    %0d cycles  (tWR)", WRITE_REC_CYC);
            $display("  --- Clock domains ---");
            $display("  - aclk (AXI):   %0d MHz  (%0d ns period)", 1000/AXI_CLK_PERIOD_NS, AXI_CLK_PERIOD_NS);
            $display("  - mclk (DDR4):  %0d MHz  (half-rate, tCK=%0d ps)", DDR4_SPEED_GRADE/2, TCK_PS);
            $display("  - SIM_MEM_DEPTH:%0d entries", ACTUAL_MEM_DEPTH);
        end
    end

    //=========================================================================
    // Clock Cycle Counter
    //=========================================================================
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            stats.total_clock_cycles <= 0;
        end else begin
            stats.total_clock_cycles <= stats.total_clock_cycles + 1;
        end
    end

    //=========================================================================
    // Write State Machine
    //=========================================================================
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            wr_state <= WR_IDLE;
        end else begin
            wr_state <= wr_next_state;
        end
    end

    always_comb begin
        wr_next_state = wr_state;

        case (wr_state)
            WR_IDLE: begin
                // Dequeue next transaction from the write-address FIFO
                if (aw_count > 0)
                    wr_next_state = WR_ADDR_WAIT;
            end

            WR_ADDR_WAIT: begin
                // Wait for mclk domain to complete the write-preamble countdown
                // (tRCD + CWL cycles) and return ack via CDC synchroniser.
                if (ddr4_ack_aclk)
                    wr_next_state = WR_ACK_CLR;
            end

            WR_ACK_CLR: begin
                // Phase-3: req was deasserted; wait for ack to go low before
                // proceeding.  This completes the 4-phase handshake and ensures
                // ddr4_ack_aclk is low before we raise req again in WR_DATA.
                if (!ddr4_ack_aclk)
                    wr_next_state = WR_DATA;
            end

            WR_DATA: begin
                if (s_axi_wvalid && s_axi_wready && s_axi_wlast) begin
                    if (WRITE_REC_CYC > 0 || RANDOM_DELAY_EN)
                        wr_next_state = WR_DELAY;
                    else
                        wr_next_state = WR_RESP;
                end
            end

            WR_DELAY: begin
                // Wait for mclk domain to complete the write-recovery countdown
                // (tWR cycles) and return ack.
                if (ddr4_ack_aclk)
                    wr_next_state = WR_RESP;
            end

            WR_RESP: begin
                if (s_axi_bready)
                    wr_next_state = WR_IDLE;
            end

            default: wr_next_state = WR_IDLE;
        endcase
    end

    // -----------------------------------------------------------------------
    // Write-address FIFO: push (aclk, any cycle awvalid & awready & FIFO!full)
    //                     pop  (when WR FSM enters IDLE and FIFO non-empty)
    // awready is combinatorially driven from FIFO occupancy.
    // -----------------------------------------------------------------------
    always_comb begin
        s_axi_awready = (aw_count < FIFO_DEPTH);
    end

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            aw_wr_ptr <= 0;
            for (int i = 0; i < FIFO_DEPTH; i++) aw_fifo[i] <= '0;
        end else begin
            // Push: accept incoming AW beat whenever FIFO has space
            if (s_axi_awvalid && s_axi_awready) begin
                aw_fifo[aw_wr_ptr].id    <= s_axi_awid;
                aw_fifo[aw_wr_ptr].addr  <= s_axi_awaddr;
                aw_fifo[aw_wr_ptr].len   <= s_axi_awlen;
                aw_fifo[aw_wr_ptr].size  <= s_axi_awsize;
                aw_fifo[aw_wr_ptr].burst <= s_axi_awburst;
                aw_wr_ptr <= (aw_wr_ptr + 1) % FIFO_DEPTH;
            end
        end
    end

    // aw_count: incremented on AW push, decremented on FSM pop (simultaneous = no change)
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            aw_count <= 0;
        end else begin
            automatic logic push = s_axi_awvalid && s_axi_awready;
            automatic logic pop  = (wr_state == WR_IDLE) && (aw_count > 0);
            if (push && !pop)
                aw_count <= aw_count + 1;
            else if (!push && pop)
                aw_count <= aw_count - 1;
            // push && pop: count unchanged
        end
    end

    // ar_count: incremented on AR push, decremented on FSM pop
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            ar_count <= 0;
        end else begin
            automatic logic push = s_axi_arvalid && s_axi_arready;
            automatic logic pop  = (rd_state == RD_IDLE) && (ar_count > 0);
            if (push && !pop)
                ar_count <= ar_count + 1;
            else if (!push && pop)
                ar_count <= ar_count - 1;
        end
    end

    // Write Path Data Handling
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            wr_id_reg     <= '0;
            wr_addr_reg   <= '0;
            wr_len_reg    <= '0;
            wr_size_reg   <= '0;
            wr_burst_reg  <= '0;
            wr_beat_cnt   <= '0;
            wr_addr_next  <= '0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bid     <= '0;
            s_axi_bresp   <= RESP_OKAY;
            wr_ddr4_req   <= 1'b0;
            ddr4_req_cycles <= '0;
            aw_rd_ptr <= 0;
        end else begin
            case (wr_state)
                WR_IDLE: begin
                    s_axi_wready  <= 1'b0;
                    s_axi_bvalid  <= 1'b0;
                    wr_ddr4_req   <= 1'b0;

                    if (aw_count > 0) begin
                        // Pop next entry from write-address FIFO
                        wr_id_reg    <= aw_fifo[aw_rd_ptr].id;
                        wr_addr_reg  <= aw_fifo[aw_rd_ptr].addr;
                        wr_len_reg   <= aw_fifo[aw_rd_ptr].len;
                        wr_size_reg  <= aw_fifo[aw_rd_ptr].size;
                        wr_burst_reg <= aw_fifo[aw_rd_ptr].burst;
                        wr_beat_cnt  <= '0;
                        wr_addr_next <= aw_fifo[aw_rd_ptr].addr;
                        wr_start_time <= $time;
                        aw_rd_ptr    <= (aw_rd_ptr + 1) % FIFO_DEPTH;
                        // aw_count decrement is handled by the dedicated aw_count block above

                        // Raise request to mclk domain with write-preamble + timing penalties.
                        // The bus must be stable before req rises so mclk syncs it.
                        begin
                            automatic int unsigned b_idx;
                            automatic int unsigned r_idx;
                            automatic int unsigned pen;
                            automatic time         oldest_faw_t;

                            b_idx = (aw_fifo[aw_rd_ptr].addr >> (ADDR_LSB + COL_BITS)) & (DDR4_BANKS - 1);
                            r_idx = 1 + (aw_fifo[aw_rd_ptr].addr >> (ADDR_LSB + COL_BITS + BANK_BITS));

                            // Page hit: same row already open — skip tRCD
                            if (ENABLE_TIMING_MODEL && bank_open_row[b_idx] == r_idx) begin
                                pen = WR_HIT_CYC;
                                stats.page_hit_count <= stats.page_hit_count + 1;
                            end else begin
                                pen = WRITE_PRE_CYC;    // tRCD + CWL
                                // Page miss on open bank: must precharge first
                                if (ENABLE_TIMING_MODEL && bank_open_row[b_idx] != 0) begin
                                    pen = pen + tRP_CYC;
                                    // tRAS: ensure min row-active time before precharge
                                    if (bank_act_time[b_idx] > 0 &&
                                            ($time - bank_act_time[b_idx]) < time'(tRAS_NS)) begin
                                        pen = pen + int'(time'(tRAS_NS) -
                                                        ($time - bank_act_time[b_idx]))
                                                  * 1000 / TCK_PS + 1;
                                        stats.tRAS_stall_count <= stats.tRAS_stall_count + 1;
                                    end
                                end
                                stats.page_miss_count <= stats.page_miss_count + 1;
                            end

                            // tCCD_S/L: CAS-to-CAS spacing (write after any prior CAS)
                            if (ENABLE_TIMING_MODEL && last_cas_time > 0) begin
                                automatic int unsigned cas_bg = b_idx >> BANK_GRP_BITS;
                                automatic int tCCD_req = (cas_bg == last_cas_bank_grp) ?
                                                          tCCD_S_CYC : tCCD_L_CYC;
                                automatic int cas_ela = int'(($time - last_cas_time)
                                                             * 1000) / TCK_PS;
                                if (cas_ela < tCCD_req) begin
                                    pen = pen + tCCD_req - cas_ela;
                                    stats.tCCD_stall_count <= stats.tCCD_stall_count + 1;
                                end
                            end

                            // tFAW: if 4 ACTs have occurred within the last tFAW_NS, stall
                            if (ENABLE_TIMING_MODEL && faw_entry_count == 4) begin
                                oldest_faw_t = faw_act_times[faw_head & 3];
                                if (($time - oldest_faw_t) < time'(tFAW_NS)) begin
                                    pen = pen + int'(time'(tFAW_NS) - ($time - oldest_faw_t))
                                              * 1000 / TCK_PS + 1;
                                    stats.faw_stall_count <= stats.faw_stall_count + 1;
                                end
                            end

                            // Refresh: if tREFI window elapsed, inject tRFC recovery
                            if (ENABLE_TIMING_MODEL && $time >= next_refresh_time) begin
                                pen = pen + tRFC_CYC;
                                next_refresh_time <= next_refresh_time + time'(tREFI_NS);
                                stats.refresh_stall_count <= stats.refresh_stall_count + 1;
                            end

                            // Update per-bank open-row state, tFAW ring buffer, and timing trackers
                            bank_open_row[b_idx]    <= r_idx;
                            bank_act_time[b_idx]    <= $time;
                            faw_act_times[faw_head] <= $time;
                            faw_head                <= (faw_head + 1) & 3;
                            if (faw_entry_count < 4) faw_entry_count <= faw_entry_count + 1;
                            last_cas_time           <= $time;
                            last_cas_bank_grp       <= b_idx >> BANK_GRP_BITS;

                            ddr4_req_cycles <= 10'(pen) + 10'(RANDOM_DELAY_EN ? $urandom_range(0, MAX_RANDOM_DELAY) : 0);
                            wr_ddr4_req     <= 1'b1;

                            if (VERBOSE_MODE)
                                $display("[%0t] DDR4_MODEL: Write started - ID=%0d, ADDR=0x%h, LEN=%0d, BURST=%0d, cyc=%0d bank=%0d",
                                        $time, aw_fifo[aw_rd_ptr].id, aw_fifo[aw_rd_ptr].addr,
                                        aw_fifo[aw_rd_ptr].len, aw_fifo[aw_rd_ptr].burst, pen, b_idx);
                        end

                        // Update transaction statistics
                        stats.total_write_transactions <= stats.total_write_transactions + 1;
                        begin
                            automatic logic [1:0] cur_burst = aw_fifo[aw_rd_ptr].burst;
                            automatic logic [7:0] cur_len   = aw_fifo[aw_rd_ptr].len;
                            case (cur_burst)
                                BURST_FIXED: stats.burst_fixed_write_count <= stats.burst_fixed_write_count + 1;
                                BURST_INCR: begin
                                    if (cur_len == 0)
                                        stats.single_write_count <= stats.single_write_count + 1;
                                    else
                                        stats.burst_incr_write_count <= stats.burst_incr_write_count + 1;
                                end
                                BURST_WRAP: stats.burst_wrap_write_count <= stats.burst_wrap_write_count + 1;
                                default: ;
                            endcase
                        end
                    end
                end

                WR_ADDR_WAIT: begin
                    // Waiting for mclk-domain ack (tRCD + CWL complete).
                    // While the DDR4 countdown runs, FIFO keeps accepting new AW beats.
                    if (ddr4_ack_aclk)
                        wr_ddr4_req <= 1'b0;  // phase-2: req ↓
                end

                WR_ACK_CLR: begin
                    // Phase-3: hold req low, wait for ack to clear.
                    // Nothing to do here; transition is comb-only.
                end

                WR_DATA: begin
                    s_axi_wready <= 1'b1;

                    if (s_axi_wvalid && s_axi_wready) begin
                        // Write data to memory with byte strobes
                        if (is_valid_address(wr_addr_next)) begin
                            for (int i = 0; i < BYTES_PER_BEAT; i++) begin
                                if (s_axi_wstrb[i]) begin
                                    memory[addr_to_mem_index(wr_addr_next)][i*8 +: 8] <= s_axi_wdata[i*8 +: 8];
                                end
                            end

                            // Count bytes written
                            for (int i = 0; i < BYTES_PER_BEAT; i++) begin
                                if (s_axi_wstrb[i])
                                    stats.total_write_bytes <= stats.total_write_bytes + 1;
                            end

                            if (VERBOSE_MODE)
                                $display("[%0t] DDR4_MODEL: Write beat %0d - ADDR=0x%h, DATA=0x%h, STRB=0x%h",
                                        $time, wr_beat_cnt, wr_addr_next, s_axi_wdata, s_axi_wstrb);
                        end else begin
                            stats.address_errors <= stats.address_errors + 1;
                            if (VERBOSE_MODE)
                                $display("[%0t] DDR4_MODEL: ERROR - Write address out of range: 0x%h", $time, wr_addr_next);
                        end

                        wr_beat_cnt  <= wr_beat_cnt + 1;
                        wr_addr_next <= calc_next_addr(wr_addr_next, wr_size_reg, wr_burst_reg, wr_len_reg, wr_addr_reg);

                        if (s_axi_wlast) begin
                            s_axi_wready <= 1'b0;
                            if (WRITE_REC_CYC > 0 || RANDOM_DELAY_EN) begin
                                // Raise a new request to mclk domain for tWR recovery.
                                ddr4_req_cycles <= 10'(WRITE_REC_CYC) + 10'(RANDOM_DELAY_EN ? $urandom_range(0, MAX_RANDOM_DELAY) : 0);
                                wr_ddr4_req     <= 1'b1;
                            end
                        end
                    end
                end

                WR_DELAY: begin
                    // Waiting for write-recovery ack from mclk domain.
                    if (ddr4_ack_aclk)
                        wr_ddr4_req <= 1'b0;
                end

                WR_RESP: begin
                    s_axi_bvalid <= 1'b1;
                    s_axi_bid    <= wr_id_reg;
                    s_axi_bresp  <= is_valid_address(wr_addr_reg) ? RESP_OKAY : RESP_SLVERR;

                    if (s_axi_bready && s_axi_bvalid) begin
                        s_axi_bvalid <= 1'b0;
                        last_write_done_time <= $time;
                        last_wr_bank_grp     <= ((wr_addr_reg >> (ADDR_LSB + COL_BITS))
                                                 & (DDR4_BANKS - 1)) >> BANK_GRP_BITS;

                        // Calculate and update latency statistics
                        stats.write_latency_total <= stats.write_latency_total + ($time - wr_start_time);
                        if (($time - wr_start_time) < stats.min_write_latency)
                            stats.min_write_latency <= $time - wr_start_time;
                        if (($time - wr_start_time) > stats.max_write_latency)
                            stats.max_write_latency <= $time - wr_start_time;

                        if (VERBOSE_MODE)
                            $display("[%0t] DDR4_MODEL: Write completed - ID=%0d, Latency=%0t",
                                    $time, wr_id_reg, $time - wr_start_time);
                    end
                end
            endcase
        end
    end

    //=========================================================================
    // Read State Machine
    //=========================================================================
    // RLAST is combinatorial: asserted exactly during the last data beat so
    // it is valid alongside s_axi_rvalid with zero registration lag.
    assign s_axi_rlast = (rd_state == RD_DATA) && (rd_beat_cnt == rd_len_reg);

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            rd_state <= RD_IDLE;
        end else begin
            rd_state <= rd_next_state;
        end
    end

    // Read-address FIFO FSM comb: trigger on FIFO non-empty
    always_comb begin
        rd_next_state = rd_state;

        case (rd_state)
            RD_IDLE: begin
                if (ar_count > 0)
                    rd_next_state = RD_ADDR_WAIT;
            end

            RD_ADDR_WAIT: begin
                // Wait for mclk domain to complete tRCD + CL countdown.
                if (ddr4_ack_aclk)
                    rd_next_state = RD_ACK_CLR;
            end

            RD_ACK_CLR: begin
                // Phase-3: req was deasserted; wait for ack to go low.
                if (!ddr4_ack_aclk)
                    rd_next_state = RD_DATA;
            end

            RD_DELAY: begin
                // Unused – kept so encoding is stable. Falls through to IDLE.
                rd_next_state = RD_IDLE;
            end

            RD_DATA: begin
                if (s_axi_rready && s_axi_rvalid && s_axi_rlast)
                    rd_next_state = RD_IDLE;
            end

            default: rd_next_state = RD_IDLE;
        endcase
    end

    // -----------------------------------------------------------------------
    // Read-address FIFO: push on arvalid & arready; pop when RD FSM enters IDLE
    // -----------------------------------------------------------------------
    always_comb begin
        s_axi_arready = (ar_count < FIFO_DEPTH);
    end

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            ar_wr_ptr <= 0;
            for (int i = 0; i < FIFO_DEPTH; i++) ar_fifo[i] <= '0;
        end else begin
            // Push
            if (s_axi_arvalid && s_axi_arready) begin
                ar_fifo[ar_wr_ptr].id    <= s_axi_arid;
                ar_fifo[ar_wr_ptr].addr  <= s_axi_araddr;
                ar_fifo[ar_wr_ptr].len   <= s_axi_arlen;
                ar_fifo[ar_wr_ptr].size  <= s_axi_arsize;
                ar_fifo[ar_wr_ptr].burst <= s_axi_arburst;
                ar_wr_ptr <= (ar_wr_ptr + 1) % FIFO_DEPTH;
            end
        end
    end

    // Read Path Data Handling
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            rd_id_reg    <= '0;
            rd_addr_reg  <= '0;
            rd_len_reg   <= '0;
            rd_size_reg  <= '0;
            rd_burst_reg <= '0;
            rd_beat_cnt  <= '0;
            rd_addr_next <= '0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rid     <= '0;
            s_axi_rdata   <= '0;
            s_axi_rresp   <= RESP_OKAY;
            rd_ddr4_req   <= 1'b0;
            ar_rd_ptr <= 0;
        end else begin
            case (rd_state)
                RD_IDLE: begin
                    s_axi_rvalid  <= 1'b0;
                    rd_ddr4_req   <= 1'b0;

                    if (ar_count > 0) begin
                        // Pop next entry from read-address FIFO
                        rd_id_reg    <= ar_fifo[ar_rd_ptr].id;
                        rd_addr_reg  <= ar_fifo[ar_rd_ptr].addr;
                        rd_len_reg   <= ar_fifo[ar_rd_ptr].len;
                        rd_size_reg  <= ar_fifo[ar_rd_ptr].size;
                        rd_burst_reg <= ar_fifo[ar_rd_ptr].burst;
                        rd_beat_cnt  <= '0;
                        rd_addr_next <= ar_fifo[ar_rd_ptr].addr;
                        rd_start_time <= $time;
                        ar_rd_ptr    <= (ar_rd_ptr + 1) % FIFO_DEPTH;
                        // ar_count decrement is handled by the dedicated ar_count block above

                        // Raise request to mclk domain with read latency + timing penalties.
                        begin
                            automatic int unsigned b_idx;
                            automatic int unsigned r_idx;
                            automatic int unsigned pen;
                            automatic time         oldest_faw_t;

                            b_idx = (ar_fifo[ar_rd_ptr].addr >> (ADDR_LSB + COL_BITS)) & (DDR4_BANKS - 1);
                            r_idx = 1 + (ar_fifo[ar_rd_ptr].addr >> (ADDR_LSB + COL_BITS + BANK_BITS));

                            // Page hit: same row already open — skip tRCD
                            if (ENABLE_TIMING_MODEL && bank_open_row[b_idx] == r_idx) begin
                                pen = RD_HIT_CYC;
                                stats.page_hit_count <= stats.page_hit_count + 1;
                            end else begin
                                pen = READ_LAT_CYC;     // tRCD + CL
                                // Page miss on open bank: must precharge first
                                if (ENABLE_TIMING_MODEL && bank_open_row[b_idx] != 0) begin
                                    pen = pen + tRP_CYC;
                                    // tRAS: ensure min row-active time before precharge
                                    if (bank_act_time[b_idx] > 0 &&
                                            ($time - bank_act_time[b_idx]) < time'(tRAS_NS)) begin
                                        pen = pen + int'(time'(tRAS_NS) -
                                                        ($time - bank_act_time[b_idx]))
                                                  * 1000 / TCK_PS + 1;
                                        stats.tRAS_stall_count <= stats.tRAS_stall_count + 1;
                                    end
                                    // tRTP: read-to-precharge guard
                                    if (bank_last_rd_time[b_idx] > 0 &&
                                            ($time - bank_last_rd_time[b_idx]) < time'(tRTP_NS)) begin
                                        pen = pen + tRTP_CYC;
                                        stats.tRTP_stall_count <= stats.tRTP_stall_count + 1;
                                    end
                                end
                                stats.page_miss_count <= stats.page_miss_count + 1;
                            end

                            // tWTR: bank-group-aware write-to-read turnaround
                            if (ENABLE_TIMING_MODEL && last_write_done_time > 0) begin
                                automatic int unsigned rd_wtg = b_idx >> BANK_GRP_BITS;
                                if (rd_wtg == last_wr_bank_grp) begin
                                    // Same bank group: tWTR_S
                                    /* verilator lint_off UNSIGNED */
                                    if (($time - last_write_done_time) < time'(tWTR_S_WIN_NS)) begin
                                    /* verilator lint_on UNSIGNED */
                                        pen = pen + tWTR_S_CYC;
                                        stats.wtr_stall_count <= stats.wtr_stall_count + 1;
                                    end
                                end else begin
                                    // Different bank group: tWTR_L
                                    /* verilator lint_off UNSIGNED */
                                    if (($time - last_write_done_time) < time'(tWTR_L_WIN_NS)) begin
                                    /* verilator lint_on UNSIGNED */
                                        pen = pen + tWTR_L_CYC;
                                        stats.wtr_stall_count <= stats.wtr_stall_count + 1;
                                    end
                                end
                            end

                            // tCCD_S/L: CAS-to-CAS spacing (read after any prior CAS)
                            if (ENABLE_TIMING_MODEL && last_cas_time > 0) begin
                                automatic int unsigned cas_bg2 = b_idx >> BANK_GRP_BITS;
                                automatic int tCCD_req2 = (cas_bg2 == last_cas_bank_grp) ?
                                                           tCCD_S_CYC : tCCD_L_CYC;
                                automatic int cas_ela2 = int'(($time - last_cas_time)
                                                              * 1000) / TCK_PS;
                                if (cas_ela2 < tCCD_req2) begin
                                    pen = pen + tCCD_req2 - cas_ela2;
                                    stats.tCCD_stall_count <= stats.tCCD_stall_count + 1;
                                end
                            end

                            // tFAW: if 4 ACTs have occurred within the last tFAW_NS, stall
                            if (ENABLE_TIMING_MODEL && faw_entry_count == 4) begin
                                oldest_faw_t = faw_act_times[faw_head & 3];
                                if (($time - oldest_faw_t) < time'(tFAW_NS)) begin
                                    pen = pen + int'(time'(tFAW_NS) - ($time - oldest_faw_t))
                                              * 1000 / TCK_PS + 1;
                                    stats.faw_stall_count <= stats.faw_stall_count + 1;
                                end
                            end

                            // Refresh: if tREFI window elapsed, inject tRFC recovery
                            if (ENABLE_TIMING_MODEL && $time >= next_refresh_time) begin
                                pen = pen + tRFC_CYC;
                                next_refresh_time <= next_refresh_time + time'(tREFI_NS);
                                stats.refresh_stall_count <= stats.refresh_stall_count + 1;
                            end

                            // Update per-bank open-row state, tFAW, and timing trackers
                            bank_open_row[b_idx]     <= r_idx;
                            bank_act_time[b_idx]     <= $time;
                            bank_last_rd_time[b_idx] <= $time;
                            faw_act_times[faw_head]  <= $time;
                            faw_head                 <= (faw_head + 1) & 3;
                            if (faw_entry_count < 4) faw_entry_count <= faw_entry_count + 1;
                            last_cas_time            <= $time;
                            last_cas_bank_grp        <= b_idx >> BANK_GRP_BITS;

                            ddr4_req_cycles <= 10'(pen) + 10'(RANDOM_DELAY_EN ? $urandom_range(0, MAX_RANDOM_DELAY) : 0);
                            rd_ddr4_req     <= 1'b1;

                            if (VERBOSE_MODE)
                                $display("[%0t] DDR4_MODEL: Read started - ID=%0d, ADDR=0x%h, LEN=%0d, BURST=%0d, cyc=%0d bank=%0d",
                                        $time, ar_fifo[ar_rd_ptr].id, ar_fifo[ar_rd_ptr].addr,
                                        ar_fifo[ar_rd_ptr].len, ar_fifo[ar_rd_ptr].burst, pen, b_idx);
                        end

                        // Update transaction statistics
                        stats.total_read_transactions <= stats.total_read_transactions + 1;
                        begin
                            automatic logic [1:0] cur_burst = ar_fifo[ar_rd_ptr].burst;
                            automatic logic [7:0] cur_len   = ar_fifo[ar_rd_ptr].len;
                            case (cur_burst)
                                BURST_FIXED: stats.burst_fixed_read_count <= stats.burst_fixed_read_count + 1;
                                BURST_INCR: begin
                                    if (cur_len == 0)
                                        stats.single_read_count <= stats.single_read_count + 1;
                                    else
                                        stats.burst_incr_read_count <= stats.burst_incr_read_count + 1;
                                end
                                BURST_WRAP: stats.burst_wrap_read_count <= stats.burst_wrap_read_count + 1;
                                default: ;
                            endcase
                        end
                    end
                end

                RD_ADDR_WAIT: begin
                    // Waiting for mclk-domain ack (tRCD + CL complete).
                    // Pre-load beat-0 data and de-assert req on ack.
                    if (ddr4_ack_aclk) begin
                        rd_ddr4_req <= 1'b0;  // phase-2: req ↓
                        if (is_valid_address(rd_addr_next)) begin
                            s_axi_rdata <= memory[addr_to_mem_index(rd_addr_next)];
                            s_axi_rresp <= RESP_OKAY;
                        end else begin
                            s_axi_rdata <= '0;
                            s_axi_rresp <= RESP_SLVERR;
                            stats.address_errors <= stats.address_errors + 1;
                        end
                    end
                end

                RD_ACK_CLR: begin
                    // Phase-3: req is low; wait for ack to deassert (comb check).
                    // rdata was already loaded in RD_ADDR_WAIT — nothing to do.
                end

                RD_DATA: begin
                    s_axi_rvalid <= 1'b1;
                    s_axi_rid    <= rd_id_reg;

                    if (s_axi_rready && s_axi_rvalid) begin
                        stats.total_read_bytes <= stats.total_read_bytes + (1 << rd_size_reg);

                        if (VERBOSE_MODE)
                            $display("[%0t] DDR4_MODEL: Read beat %0d - ADDR=0x%h, DATA=0x%h",
                                    $time, rd_beat_cnt, rd_addr_next, s_axi_rdata);

                        if (rd_beat_cnt == rd_len_reg) begin
                            s_axi_rvalid <= 1'b0;

                            stats.read_latency_total <= stats.read_latency_total + ($time - rd_start_time);
                            if (($time - rd_start_time) < stats.min_read_latency)
                                stats.min_read_latency <= $time - rd_start_time;
                            if (($time - rd_start_time) > stats.max_read_latency)
                                stats.max_read_latency <= $time - rd_start_time;

                            if (VERBOSE_MODE)
                                $display("[%0t] DDR4_MODEL: Read completed - ID=%0d, Latency=%0t",
                                        $time, rd_id_reg, $time - rd_start_time);
                        end else begin
                            begin
                                automatic logic [AXI_ADDR_WIDTH-1:0] next_rd_addr;
                                next_rd_addr = calc_next_addr(
                                    rd_addr_next, rd_size_reg, rd_burst_reg,
                                    rd_len_reg,   rd_addr_reg);
                                if (is_valid_address(next_rd_addr)) begin
                                    s_axi_rdata <= memory[addr_to_mem_index(next_rd_addr)];
                                    s_axi_rresp <= RESP_OKAY;
                                end else begin
                                    s_axi_rdata <= '0;
                                    s_axi_rresp <= RESP_SLVERR;
                                    stats.address_errors <= stats.address_errors + 1;
                                end
                                rd_beat_cnt  <= rd_beat_cnt + 1;
                                rd_addr_next <= next_rd_addr;
                            end
                        end
                    end
                end
            endcase
        end
    end

    //=========================================================================
    // Busy Cycle Tracking + Outstanding-request high-water marks
    //=========================================================================
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            stats.busy_cycles            <= 0;
            stats.max_outstanding_reads  <= 0;
            stats.max_outstanding_writes <= 0;
        end else begin
            if (wr_state != WR_IDLE || rd_state != RD_IDLE)
                stats.busy_cycles <= stats.busy_cycles + 1;
            // Track pending-in-FIFO (queued but not yet processing) counts.
            // aw_count / ar_count are entries sitting in FIFOs waiting for the FSM;
            // add 1 when the FSM itself is actively processing one.
            // Peak = FIFO_DEPTH(queued) + 1(in-service) = MAX_OUTSTANDING + 1.
            // awready / arready go low at aw_count == FIFO_DEPTH, so the FIFO
            // never overflows; max_outstanding simply exceeds MAX_OUTSTANDING by 1.
            begin
                automatic longint wr_out = longint'(aw_count) +
                                           (wr_state != WR_IDLE ? 1 : 0);
                automatic longint rd_out = longint'(ar_count) +
                                           (rd_state != RD_IDLE ? 1 : 0);
                if (wr_out > stats.max_outstanding_writes)
                    stats.max_outstanding_writes <= wr_out;
                if (rd_out > stats.max_outstanding_reads)
                    stats.max_outstanding_reads <= rd_out;
            end
        end
    end

    //=========================================================================
    // Statistics Reporting Task
    //=========================================================================
    task print_statistics();
        real avg_read_latency;
        real avg_write_latency;
        real utilization;
        real read_bandwidth;
        real write_bandwidth;
        time sim_duration;

        stats.sim_end_time = $time;
        sim_duration = stats.sim_end_time - stats.sim_start_time;

        if (stats.total_read_transactions > 0)
            avg_read_latency = real'(stats.read_latency_total) / real'(stats.total_read_transactions);
        else
            avg_read_latency = 0;

        if (stats.total_write_transactions > 0)
            avg_write_latency = real'(stats.write_latency_total) / real'(stats.total_write_transactions);
        else
            avg_write_latency = 0;

        if (stats.total_clock_cycles > 0)
            utilization = (real'(stats.busy_cycles) / real'(stats.total_clock_cycles)) * 100.0;
        else
            utilization = 0;

        // Calculate bandwidth (bytes per nanosecond = GB/s)
        if (sim_duration > 0) begin
            read_bandwidth = real'(stats.total_read_bytes) / real'(sim_duration);
            write_bandwidth = real'(stats.total_write_bytes) / real'(sim_duration);
        end else begin
            read_bandwidth = 0;
            write_bandwidth = 0;
        end

        $display("\n");
        $display("╔══════════════════════════════════════════════════════════════════════════════╗");
        $display("║                    DDR4 AXI4 SLAVE SIMULATION STATISTICS                     ║");
        $display("╠══════════════════════════════════════════════════════════════════════════════╣");
        $display("║  CONFIGURATION                                                               ║");
        $display("║    Memory Density:        %4d GB                                            ║", DDR4_DENSITY_GB);
        $display("║    AXI Data Width:        %4d bits                                          ║", AXI_DATA_WIDTH);
        $display("║    AXI Address Width:     %4d bits                                          ║", AXI_ADDR_WIDTH);
        $display("╠══════════════════════════════════════════════════════════════════════════════╣");
        $display("║  SIMULATION DURATION                                                         ║");
        $display("║    Start Time:            %0t                                                ", stats.sim_start_time);
        $display("║    End Time:              %0t                                                ", stats.sim_end_time);
        $display("║    Total Duration:        %0t                                                ", sim_duration);
        $display("║    Total Clock Cycles:    %0d                                                ", stats.total_clock_cycles);
        $display("╠══════════════════════════════════════════════════════════════════════════════╣");
        $display("║  TRANSACTION SUMMARY                                                         ║");
        $display("║    Total Read Transactions:     %10d                                   ║", stats.total_read_transactions);
        $display("║    Total Write Transactions:    %10d                                   ║", stats.total_write_transactions);
        $display("║    Total Read Bytes:            %10d                                   ║", stats.total_read_bytes);
        $display("║    Total Write Bytes:           %10d                                   ║", stats.total_write_bytes);
        $display("╠══════════════════════════════════════════════════════════════════════════════╣");
        $display("║  TRANSACTION TYPE BREAKDOWN                                                  ║");
        $display("║    Single Reads:                %10d                                   ║", stats.single_read_count);
        $display("║    Single Writes:               %10d                                   ║", stats.single_write_count);
        $display("║    Burst INCR Reads:            %10d                                   ║", stats.burst_incr_read_count);
        $display("║    Burst INCR Writes:           %10d                                   ║", stats.burst_incr_write_count);
        $display("║    Burst WRAP Reads:            %10d                                   ║", stats.burst_wrap_read_count);
        $display("║    Burst WRAP Writes:           %10d                                   ║", stats.burst_wrap_write_count);
        $display("║    Burst FIXED Reads:           %10d                                   ║", stats.burst_fixed_read_count);
        $display("║    Burst FIXED Writes:          %10d                                   ║", stats.burst_fixed_write_count);
        $display("╠══════════════════════════════════════════════════════════════════════════════╣");
        $display("║  LATENCY STATISTICS                                                          ║");
        $display("║    Average Read Latency:        %10.2f ns                                ║", avg_read_latency);
        $display("║    Min Read Latency:            %10d ns                                ║", (stats.total_read_transactions > 0) ? stats.min_read_latency : 0);
        $display("║    Max Read Latency:            %10d ns                                ║", stats.max_read_latency);
        $display("║    Average Write Latency:       %10.2f ns                                ║", avg_write_latency);
        $display("║    Min Write Latency:           %10d ns                                ║", (stats.total_write_transactions > 0) ? stats.min_write_latency : 0);
        $display("║    Max Write Latency:           %10d ns                                ║", stats.max_write_latency);
        $display("╠══════════════════════════════════════════════════════════════════════════════╣");
        $display("║  PERFORMANCE METRICS                                                         ║");
        $display("║    Bus Utilization:             %10.2f %%                                 ║", utilization);
        $display("║    Read Bandwidth:              %10.4f GB/s                              ║", read_bandwidth);
        $display("║    Write Bandwidth:             %10.4f GB/s                              ║", write_bandwidth);
        $display("║    Total Bandwidth:             %10.4f GB/s                              ║", read_bandwidth + write_bandwidth);
        $display("╠══════════════════════════════════════════════════════════════════════════════╣");
        $display("║  DDR4 TIMING EVENTS                                                          ║");
        $display("║    Refresh Stalls (tRFC):       %10d                                   ║", stats.refresh_stall_count);
        $display("║    Page Hits:                   %10d                                   ║", stats.page_hit_count);
        $display("║    Page Misses:                 %10d                                   ║", stats.page_miss_count);
        $display("║    Write-to-Read Stalls (tWTR): %10d                                   ║", stats.wtr_stall_count);
        $display("║    FAW Stalls (tFAW):           %10d                                   ║", stats.faw_stall_count);
        $display("║    tRAS Stalls:                 %10d                                   ║", stats.tRAS_stall_count);
        $display("║    tRTP Stalls:                 %10d                                   ║", stats.tRTP_stall_count);
        $display("║    tCCD Stalls:                 %10d                                   ║", stats.tCCD_stall_count);
        $display("╠══════════════════════════════════════════════════════════════════════════════╣");
        $display("║  OUTSTANDING REQUESTS                                                        ║");
        $display("║    Max Outstanding Reads:       %10d  (queue depth=%0d, +1 in-service)  ║", stats.max_outstanding_reads,  MAX_OUTSTANDING);
        $display("║    Max Outstanding Writes:      %10d  (queue depth=%0d, +1 in-service)  ║", stats.max_outstanding_writes, MAX_OUTSTANDING);
        $display("╠══════════════════════════════════════════════════════════════════════════════╣");
        $display("║  ERROR STATISTICS                                                            ║");
        $display("║    Address Errors:              %10d                                   ║", stats.address_errors);
        $display("║    Protocol Errors:             %10d                                   ║", stats.protocol_errors);
        $display("╚══════════════════════════════════════════════════════════════════════════════╝");
        $display("\n");
    endtask

    //=========================================================================
    // Memory Access Tasks for Debug
    //=========================================================================
    task write_memory(
        input [AXI_ADDR_WIDTH-1:0] addr,
        input [AXI_DATA_WIDTH-1:0] data
    );
        if (is_valid_address(addr)) begin
            memory[addr_to_mem_index(addr)] = data;
            if (VERBOSE_MODE)
                $display("[%0t] DDR4_MODEL: Direct memory write - ADDR=0x%h, DATA=0x%h", $time, addr, data);
        end else begin
            $display("[%0t] DDR4_MODEL: ERROR - Direct write address out of range: 0x%h", $time, addr);
        end
    endtask

    task read_memory(
        input  [AXI_ADDR_WIDTH-1:0] addr,
        output [AXI_DATA_WIDTH-1:0] data
    );
        if (is_valid_address(addr)) begin
            data = memory[addr_to_mem_index(addr)];
            if (VERBOSE_MODE)
                $display("[%0t] DDR4_MODEL: Direct memory read - ADDR=0x%h, DATA=0x%h", $time, addr, data);
        end else begin
            data = '0;
            $display("[%0t] DDR4_MODEL: ERROR - Direct read address out of range: 0x%h", $time, addr);
        end
    endtask

    task dump_memory_region(
        input [AXI_ADDR_WIDTH-1:0] start_addr,
        input integer              num_words
    );
        $display("[%0t] DDR4_MODEL: Memory dump from 0x%h, %0d words:", $time, start_addr, num_words);
        for (int i = 0; i < num_words; i++) begin
            if (is_valid_address(start_addr + i * BYTES_PER_BEAT))
                $display("  [0x%h]: 0x%h", start_addr + i * BYTES_PER_BEAT,
                        memory[addr_to_mem_index(start_addr + i * BYTES_PER_BEAT)]);
        end
    endtask

    //=========================================================================
    // Final Statistics Report
    //=========================================================================
    final begin
        print_statistics();
    end

    //=========================================================================
    // DPI-C Memory Access Interface (compatible with elfloader / tb_kv32_soc.cpp)
    //
    // elfloader.cpp subtracts g_mem_base (0x80000000) before calling these
    // functions, so addr=0 corresponds to BASE_ADDR in AXI space.
    //=========================================================================
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
        automatic int word_idx = addr / BYTES_PER_BEAT;
        automatic int byte_lane = addr % BYTES_PER_BEAT;
        if (word_idx >= 0 && word_idx < MEM_DEPTH) begin
            memory[word_idx][byte_lane*8 +: 8] = data;
        end
    endfunction

    function byte mem_read_byte(input int addr);
        automatic int word_idx = addr / BYTES_PER_BEAT;
        automatic int byte_lane = addr % BYTES_PER_BEAT;
        if (word_idx >= 0 && word_idx < MEM_DEPTH)
            return memory[word_idx][byte_lane*8 +: 8];
        else
            return 8'hFF;
    endfunction

    // Stat stubs — return transaction counts so tb_kv32_soc.cpp can compile
    // and link with either MEM_TYPE=sram or MEM_TYPE=ddr4.
    function int mem_get_stat_ar_requests();  return int'(stats.total_read_transactions);  endfunction
    function int mem_get_stat_r_responses();  return int'(stats.total_read_transactions);  endfunction
    function int mem_get_stat_aw_requests();  return int'(stats.total_write_transactions); endfunction
    function int mem_get_stat_w_data();       return int'(stats.total_write_transactions); endfunction
    function int mem_get_stat_w_expected();   return int'(stats.total_write_transactions); endfunction
    function int mem_get_stat_b_responses();  return int'(stats.total_write_transactions); endfunction
    function int mem_get_stat_max_outstanding_reads();  return int'(stats.max_outstanding_reads);  endfunction
    function int mem_get_stat_max_outstanding_writes(); return int'(stats.max_outstanding_writes); endfunction

endmodule
/* verilator lint_on WIDTHTRUNC */
/* verilator lint_on WIDTHEXPAND */
/* verilator lint_on CASEINCOMPLETE */
/* verilator lint_on UNUSEDSIGNAL */

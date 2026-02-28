// ============================================================================
// File: axi_dma.sv
// Project: KV32 RISC-V Processor
// Description: AXI4 DMA Controller
//
// Features:
//   - Up to NUM_CHANNELS independent channels (parametric, 1..8)
//   - 1D / 2D / 3D / Scatter-Gather transfer modes
//   - Configurable data bus width: 32 / 64 / 128 bits (DATA_WIDTH)
//   - Configurable internal FIFO depth (FIFO_DEPTH, power-of-two)
//   - INCR AXI4 burst transfers; bursts never cross 4KB pages
//   - Per-channel interrupt on complete or error; aggregated to single IRQ
//   - AXI4-Lite slave port for CPU register access (base 0x2003_0000, 4 KB)
//   - AXI4 master port for DMA data movement (DATA_WIDTH-bit bus)
//
// Register Map (relative to base, 4 KB aperture):
//   Channel N registers at BASE + N*0x40  (N = 0 .. NUM_CHANNELS-1)
//     +0x00  CTRL     [7:0]
//              [0]  EN        – enable channel; must be set before START
//              [1]  START     – write 1 to arm; auto-clears next cycle
//              [2]  STOP      – write 1 to abort; auto-clears next cycle
//              [4:3] MODE     – 00=1D, 01=2D, 10=3D, 11=Scatter-Gather
//              [5]  SRC_INC   – increment source address after each beat
//              [6]  DST_INC   – increment destination address after each beat
//              [7]  IE        – interrupt enable for this channel
//     +0x04  STAT     [2:0]  (write-1-to-clear bits [2:1])
//              [0]  BUSY      – transfer in progress (read-only)
//              [1]  DONE      – transfer complete; W1C
//              [2]  ERR       – AXI error; W1C
//     +0x08  SRC_ADDR  – source base address (must be DATA_WIDTH/8-byte aligned)
//     +0x0C  DST_ADDR  – destination base address
//     +0x10  XFER_CNT  – byte count (1D: total; 2D/3D: bytes per row)
//     +0x14  SRC_STRIDE – source stride in bytes between row starts (2D/3D)
//     +0x18  DST_STRIDE – destination stride in bytes between row starts (2D/3D)
//     +0x1C  ROW_CNT   – number of rows (2D/3D; unused in 1D)
//     +0x20  SRC_PLANE_STRIDE – source stride in bytes between planes (3D)
//     +0x24  DST_PLANE_STRIDE – destination stride in bytes between planes (3D)
//     +0x28  PLANE_CNT – number of planes (3D only)
//     +0x2C  SG_ADDR   – scatter-gather descriptor list base address
//     +0x30  SG_CNT    – number of SG descriptors (0 = no transfer)
//
//   Global registers:
//     +0xF00  IRQ_STAT  – channel IRQ status (W1C); bit N = channel N done/err
//     +0xF04  IRQ_EN    – per-channel IRQ global enable (not per START)
//     +0xF08  DMA_ID    – 0xD4A0_0100 (read-only version/ID)
//     +0xF10  PERF_CTRL     – [0]=enable counters; write [1]=1 to reset all
//     +0xF14  PERF_CYCLES   – cycles elapsed while PERF_CTRL[0]=1
//     +0xF18  PERF_RD_BYTES – DMA read data bytes (S_RD_DATA beats × BPB)
//     +0xF1C  PERF_WR_BYTES – DMA write data bytes (W-channel beats × BPB)
//
// Scatter-Gather Descriptor (16 bytes in memory, little-endian):
//   [0x00]  src_addr  (32-bit)
//   [0x04]  dst_addr  (32-bit)
//   [0x08]  xfer_cnt  (32-bit byte count for this segment)
//   [0x0C]  mode_ctrl – [1:0]=mode, [2]=src_inc, [3]=dst_inc; rest reserved
// ============================================================================

`ifdef SYNTHESIS
import kv32_pkg::*;
`endif

module axi_dma #(
    parameter int NUM_CHANNELS  = 4,    // 1..8
    parameter int DATA_WIDTH    = 32,   // 32, 64, or 128
    parameter int FIFO_DEPTH    = 16,   // beat-buffer depth (power of 2, ≥2)
    parameter int MAX_BURST_LEN = 16    // max beats per AXI burst (1..256)
)(
    input  logic clk,
    input  logic rst_n,

    // ── AXI4-Lite Config Slave (CPU → DMA registers) ─────────────────────
    input  logic [31:0] cfg_awaddr,
    input  logic        cfg_awvalid,
    output logic        cfg_awready,

    input  logic [31:0] cfg_wdata,
    input  logic [3:0]  cfg_wstrb,
    input  logic        cfg_wvalid,
    output logic        cfg_wready,

    output logic [1:0]  cfg_bresp,
    output logic        cfg_bvalid,
    input  logic        cfg_bready,

    input  logic [31:0] cfg_araddr,
    input  logic        cfg_arvalid,
    output logic        cfg_arready,

    output logic [31:0] cfg_rdata,
    output logic [1:0]  cfg_rresp,
    output logic        cfg_rvalid,
    input  logic        cfg_rready,

    // ── AXI4 Data Master (DMA ↔ memory, DATA_WIDTH-bit bus) ──────────────
    output logic [31:0]              dma_awaddr,
    output logic [7:0]               dma_awlen,
    output logic [2:0]               dma_awsize,
    output logic [1:0]               dma_awburst,
    output logic                     dma_awvalid,
    input  logic                     dma_awready,

    output logic [DATA_WIDTH-1:0]    dma_wdata,   // combinatorial
    output logic [DATA_WIDTH/8-1:0]  dma_wstrb,
    output logic                     dma_wlast,   // combinatorial
    output logic                     dma_wvalid,
    input  logic                     dma_wready,

    input  logic [1:0]               dma_bresp,
    input  logic                     dma_bvalid,
    output logic                     dma_bready,

    output logic [31:0]              dma_araddr,
    output logic [7:0]               dma_arlen,
    output logic [2:0]               dma_arsize,
    output logic [1:0]               dma_arburst,
    output logic                     dma_arvalid,
    input  logic                     dma_arready,

    input  logic [DATA_WIDTH-1:0]    dma_rdata,
    input  logic [1:0]               dma_rresp,
    input  logic                     dma_rlast,
    input  logic                     dma_rvalid,
    output logic                     dma_rready,

    // ── Interrupt output (level, active-high) ─────────────────────────────
    output logic irq
);
`ifndef SYNTHESIS
    import kv32_pkg::*;
`endif

    // ========================================================================
    // Parameters & derived constants
    // ========================================================================
    localparam int BPB       = DATA_WIDTH / 8;                // bytes per beat
    localparam int AXI_SIZE  = (DATA_WIDTH == 128) ? 3'd4 :
                               (DATA_WIDTH == 64)  ? 3'd3 : 3'd2;
    localparam int FIFO_BITS = $clog2(FIFO_DEPTH);
    localparam int CH_STRIDE = 12'h040;                       // reg bytes / channel
    localparam int GLBL_OFF  = 12'hF00;                       // global regs offset

    // Capability register
    localparam logic [15:0] DMA_VERSION     = 16'h0001;
    localparam logic [31:0] CAPABILITY_REG  = {DMA_VERSION, 8'(NUM_CHANNELS), 8'(MAX_BURST_LEN)};

    // ========================================================================
    // Per-channel register arrays
    // ========================================================================
    logic [7:0]  ch_ctrl        [0:NUM_CHANNELS-1];
    logic [31:0] ch_src_addr    [0:NUM_CHANNELS-1];
    logic [31:0] ch_dst_addr    [0:NUM_CHANNELS-1];
    logic [31:0] ch_xfer_cnt    [0:NUM_CHANNELS-1];   // bytes/row
    logic [31:0] ch_src_stride  [0:NUM_CHANNELS-1];
    logic [31:0] ch_dst_stride  [0:NUM_CHANNELS-1];
    logic [31:0] ch_row_cnt     [0:NUM_CHANNELS-1];
    logic [31:0] ch_src_pstride [0:NUM_CHANNELS-1];
    logic [31:0] ch_dst_pstride [0:NUM_CHANNELS-1];
    logic [31:0] ch_plane_cnt   [0:NUM_CHANNELS-1];
    logic [31:0] ch_sg_addr     [0:NUM_CHANNELS-1];
    logic [31:0] ch_sg_cnt      [0:NUM_CHANNELS-1];

    // Status (driven by engine, W1C on DONE/ERR)
    logic [NUM_CHANNELS-1:0] ch_busy;
    logic [NUM_CHANNELS-1:0] ch_done;
    logic [NUM_CHANNELS-1:0] ch_err;
    // Sticky arm latch: set when START bit is written, cleared when engine picks the channel.
    // Separating from ch_ctrl[1] avoids the auto-clear race when the engine is busy.
    logic [NUM_CHANNELS-1:0] ch_armed;

    // Global IRQ control
    logic [NUM_CHANNELS-1:0] glb_irq_en;    // bit N = channel N globally enabled

    // Performance counters
    logic        perf_enable;              // counter gate
    logic [31:0] perf_cycles;             // elapsed cycles while perf_enable=1
    logic [31:0] perf_rd_bytes;           // DMA read bytes (S_RD_DATA beats × BPB)
    logic [31:0] perf_wr_bytes;           // DMA write bytes (W-channel beats × BPB)

    // Aggregate IRQ status for readback
    wire  [NUM_CHANNELS-1:0] irq_stat_wire = ch_done | ch_err;

    // ========================================================================
    // AXI4-Lite Config Slave – always ready (1-cycle latency)
    // ========================================================================
    assign cfg_awready = 1'b1;
    assign cfg_wready  = 1'b1;
    assign cfg_arready = 1'b1;

    // wlast is purely combinatorial: high on the last beat of a write burst
    assign dma_wlast = dma_wvalid && (beat_cnt == e_beats - 8'h1);
    // wdata/wstrb combinatorial from FIFO head; fifo_pop is a wire so rd_ptr
    // advances on the same clock edge the beat is accepted.
    assign dma_wdata = fifo_rdata;
    assign dma_wstrb = {(DATA_WIDTH/8){dma_wvalid}};

    // Write path
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_CHANNELS; i++) begin
                ch_ctrl[i]        <= 8'h00;
                ch_src_addr[i]    <= '0;
                ch_dst_addr[i]    <= '0;
                ch_xfer_cnt[i]    <= '0;
                ch_src_stride[i]  <= '0;
                ch_dst_stride[i]  <= '0;
                ch_row_cnt[i]     <= '0;
                ch_src_pstride[i] <= '0;
                ch_dst_pstride[i] <= '0;
                ch_plane_cnt[i]   <= '0;
                ch_sg_addr[i]     <= '0;
                ch_sg_cnt[i]      <= '0;
            end
            glb_irq_en <= '0;
            cfg_bvalid <= 1'b0;
            cfg_bresp  <= 2'b00;
        end else begin
            // Auto-clear one-shot bits
            for (int i = 0; i < NUM_CHANNELS; i++) begin
                ch_ctrl[i][1] <= 1'b0;   // START
                ch_ctrl[i][2] <= 1'b0;   // STOP
            end

            if (cfg_bvalid && cfg_bready) cfg_bvalid <= 1'b0;

            if (cfg_awvalid && cfg_wvalid) begin
                automatic logic [11:0] addr12 = cfg_awaddr[11:0];
                automatic int          ch_idx = int'(addr12[11:6]);  // /0x40
                automatic logic [3:0]  reg_idx = addr12[5:2];        // word index

                cfg_bvalid <= 1'b1;
                cfg_bresp  <= 2'b00;   // OKAY

                if (addr12 < GLBL_OFF) begin
                    // Per-channel register write
                    if (ch_idx < NUM_CHANNELS) begin
                        case (reg_idx)
                            4'h0: ch_ctrl[ch_idx] <= cfg_wdata[7:0];
                            // 0x04 = STATUS: W1C handled below
                            4'h2: ch_src_addr[ch_idx]    <= cfg_wdata;
                            4'h3: ch_dst_addr[ch_idx]    <= cfg_wdata;
                            4'h4: ch_xfer_cnt[ch_idx]    <= cfg_wdata;
                            4'h5: ch_src_stride[ch_idx]  <= cfg_wdata;
                            4'h6: ch_dst_stride[ch_idx]  <= cfg_wdata;
                            4'h7: ch_row_cnt[ch_idx]     <= cfg_wdata;
                            4'h8: ch_src_pstride[ch_idx] <= cfg_wdata;
                            4'h9: ch_dst_pstride[ch_idx] <= cfg_wdata;
                            4'hA: ch_plane_cnt[ch_idx]   <= cfg_wdata;
                            4'hB: ch_sg_addr[ch_idx]     <= cfg_wdata;
                            4'hC: ch_sg_cnt[ch_idx]      <= cfg_wdata;
                            default: ;
                        endcase
                    end
                end else if (addr12 == GLBL_OFF + 12'h004) begin   // IRQ_EN
                    glb_irq_en <= cfg_wdata[NUM_CHANNELS-1:0];
                end
                // GLBL_OFF+0x008 (DMA_ID) is read-only
            end
        end
    end

    // W1C for DONE / ERR via config slave STATUS write
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ch_done <= '0;
            ch_err  <= '0;
        end else begin
            // Engine sets done/err (see engine block); CPU clears via W1C
            if (cfg_awvalid && cfg_wvalid &&
                (cfg_awaddr[11:0] < GLBL_OFF) &&
                (cfg_awaddr[5:2] == 4'h1)) begin          // STAT register
                automatic int ci = int'(cfg_awaddr[11:6]);
                if (ci < NUM_CHANNELS) begin
                    if (cfg_wdata[1]) ch_done[ci] <= 1'b0;  // clear DONE
                    if (cfg_wdata[2]) ch_err[ci]  <= 1'b0;  // clear ERR
                end
            end
            // Also clear via IRQ_STAT W1C at 0xF00
            if (cfg_awvalid && cfg_wvalid &&
                cfg_awaddr[11:0] == GLBL_OFF) begin
                for (int i = 0; i < NUM_CHANNELS; i++) begin
                    if (cfg_wdata[i]) begin
                        ch_done[i] <= 1'b0;
                        ch_err[i]  <= 1'b0;
                    end
                end
            end
        end
    end

    // ── ch_armed: sticky arm latch (single driver to avoid multiple-driver lint) ──
    // Set:   when CPU writes CTRL with START bit=1 and EN bit=1
    // Clear: when EN is explicitly deasserted (CTRL write with EN=0)
    //        OR when the engine picks the channel in S_IDLE
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ch_armed <= '0;
        end else begin
            // CPU write to CTRL register
            if (cfg_awvalid && cfg_wvalid &&
                (cfg_awaddr[11:0] < GLBL_OFF) &&
                (cfg_awaddr[5:2] == 4'h0)) begin
                automatic int ci = int'(cfg_awaddr[11:6]);
                if (ci < NUM_CHANNELS) begin
                    if (!cfg_wdata[0]) begin
                        ch_armed[ci] <= 1'b0;  // EN cleared → disarm
                    end else if (cfg_wdata[1]) begin
                        ch_armed[ci] <= 1'b1;  // EN=1 and START=1 → arm
                    end
                end
            end
            // Engine picks a channel in S_IDLE → consume the arm latch
            if (eng_state == S_IDLE && !no_pending) begin
                ch_armed[sched_ch] <= 1'b0;
            end
        end
    end

    // ── Performance counters ────────────────────────────────────────────────
    // PERF_CTRL write: bit[1]=RESET clears all counters; bit[0]=ENABLE gates counting.
    // PERF_CYCLES counts every clock tick while perf_enable=1.
    // PERF_RD_BYTES counts DMA read data beats (S_RD_DATA only, excludes SG fetches).
    // PERF_WR_BYTES counts DMA write data beats (dma_wvalid && dma_wready).
    always_ff @(posedge clk or negedge rst_n) begin : perf_counters
        if (!rst_n) begin
            perf_enable   <= 1'b0;
            perf_cycles   <= '0;
            perf_rd_bytes <= '0;
            perf_wr_bytes <= '0;
        end else begin
            if (cfg_awvalid && cfg_wvalid &&
                cfg_awaddr[11:0] == GLBL_OFF + 12'h010) begin   // PERF_CTRL write
                if (cfg_wdata[1]) begin   // bit[1] = RESET
                    perf_enable   <= 1'b0;
                    perf_cycles   <= '0;
                    perf_rd_bytes <= '0;
                    perf_wr_bytes <= '0;
                end else begin
                    perf_enable <= cfg_wdata[0];   // bit[0] = ENABLE
                end
            end else if (perf_enable) begin
                perf_cycles <= perf_cycles + 32'h1;
                if (dma_rvalid && dma_rready && eng_state == S_RD_DATA)
                    perf_rd_bytes <= perf_rd_bytes + 32'(BPB);
                if (dma_wvalid && dma_wready)
                    perf_wr_bytes <= perf_wr_bytes + 32'(BPB);
            end
        end
    end

    // Read path
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_rvalid <= 1'b0;
            cfg_rdata  <= '0;
            cfg_rresp  <= 2'b00;
        end else begin
            if (cfg_arvalid && !cfg_rvalid) begin
                automatic logic [11:0] addr12 = cfg_araddr[11:0];
                automatic int          ch_idx = int'(addr12[11:6]);
                automatic logic [3:0]  reg_idx = addr12[5:2];

                cfg_rvalid <= 1'b1;
                cfg_rresp  <= 2'b00;
                cfg_rdata  <= '0;

                if (addr12 < GLBL_OFF) begin
                    if (ch_idx < NUM_CHANNELS) begin
                        case (reg_idx)
                            4'h0: cfg_rdata <= {24'h0, ch_ctrl[ch_idx]};
                            4'h1: cfg_rdata <= {29'h0,
                                                ch_err[ch_idx],
                                                ch_done[ch_idx],
                                                ch_busy[ch_idx]};
                            4'h2: cfg_rdata <= ch_src_addr[ch_idx];
                            4'h3: cfg_rdata <= ch_dst_addr[ch_idx];
                            4'h4: cfg_rdata <= ch_xfer_cnt[ch_idx];
                            4'h5: cfg_rdata <= ch_src_stride[ch_idx];
                            4'h6: cfg_rdata <= ch_dst_stride[ch_idx];
                            4'h7: cfg_rdata <= ch_row_cnt[ch_idx];
                            4'h8: cfg_rdata <= ch_src_pstride[ch_idx];
                            4'h9: cfg_rdata <= ch_dst_pstride[ch_idx];
                            4'hA: cfg_rdata <= ch_plane_cnt[ch_idx];
                            4'hB: cfg_rdata <= ch_sg_addr[ch_idx];
                            4'hC: cfg_rdata <= ch_sg_cnt[ch_idx];
                            default: cfg_rdata <= '0;
                        endcase
                    end
                end else begin
                    case (addr12 - GLBL_OFF)
                        12'h000: cfg_rdata <= {{(32-NUM_CHANNELS){1'b0}}, irq_stat_wire};
                        12'h004: cfg_rdata <= {{(32-NUM_CHANNELS){1'b0}}, glb_irq_en};
                        12'h008: cfg_rdata <= 32'hD4A0_0100;  // DMA_ID
                        12'h00C: cfg_rdata <= CAPABILITY_REG;   // CAPABILITY (RO)
                        12'h010: cfg_rdata <= {31'h0, perf_enable};   // PERF_CTRL
                        12'h014: cfg_rdata <= perf_cycles;             // PERF_CYCLES
                        12'h018: cfg_rdata <= perf_rd_bytes;           // PERF_RD_BYTES
                        12'h01C: cfg_rdata <= perf_wr_bytes;           // PERF_WR_BYTES
                        default: cfg_rdata <= '0;
                    endcase
                end
            end else if (cfg_rvalid && cfg_rready) begin
                cfg_rvalid <= 1'b0;
            end
        end
    end

    // ========================================================================
    // Internal FIFO (beat buffer between read and write phases)
    // Width = DATA_WIDTH, Depth = FIFO_DEPTH
    // ========================================================================
    logic [DATA_WIDTH-1:0] fifo_mem [0:FIFO_DEPTH-1];
    logic [FIFO_BITS:0]    fifo_wr_ptr;
    logic [FIFO_BITS:0]    fifo_rd_ptr;
    wire                   fifo_empty  = (fifo_wr_ptr == fifo_rd_ptr);
    wire                   fifo_full   = (fifo_wr_ptr[FIFO_BITS] != fifo_rd_ptr[FIFO_BITS]) &&
                                         (fifo_wr_ptr[FIFO_BITS-1:0] == fifo_rd_ptr[FIFO_BITS-1:0]);
    wire [FIFO_BITS:0]     fifo_count  = fifo_wr_ptr - fifo_rd_ptr;

    logic fifo_push;
    wire  fifo_pop = dma_wvalid && dma_wready && !fifo_empty;  // combinatorial pop
    logic [DATA_WIDTH-1:0] fifo_wdata, fifo_rdata;

    assign fifo_rdata = fifo_mem[fifo_rd_ptr[FIFO_BITS-1:0]];
    // wdata/wstrb/wlast are driven combinatorially from fifo_rdata.

    // ========================================================================
    // DMA Engine State Machine
    // ========================================================================
    typedef enum logic [3:0] {
        S_IDLE       = 4'd0,
        S_FETCH_SG   = 4'd1,   // Issue AR for SG descriptor (4-beat burst)
        S_FETCH_RDAT = 4'd2,   // Receive 4 SG descriptor words
        S_BURST_CALC = 4'd3,   // Calculate next AXI burst parameters
        S_RD_ADDR    = 4'd4,   // Issue AR
        S_RD_DATA    = 4'd5,   // Receive R beats → FIFO
        S_WR_ADDR    = 4'd6,   // Issue AW
        S_WR_DATA    = 4'd7,   // Send W beats ← FIFO
        S_WR_RESP    = 4'd8,   // Wait for B
        S_ADVANCE    = 4'd9,   // Update address / counters
        S_DONE       = 4'd10,
        S_ERROR      = 4'd11
    } eng_state_t;

    eng_state_t eng_state;

    // Active channel index (scheduled)
    logic [$clog2(NUM_CHANNELS > 1 ? NUM_CHANNELS : 2)-1:0] active_ch;
    logic [$clog2(NUM_CHANNELS > 1 ? NUM_CHANNELS : 2)-1:0] rr_ptr;    // round-robin hint

    // Snapshot of active channel's configuration (loaded at IDLE→schedule)
    logic [7:0]  e_ctrl;
    logic [1:0]  e_mode;
    logic        e_src_inc, e_dst_inc;

    // Running counters (updated in ADVANCE)
    logic [31:0] e_cur_src;       // current source address
    logic [31:0] e_cur_dst;       // current destination address
    logic [31:0] e_rem_bytes;     // bytes remaining in current row / 1D total
    logic [31:0] e_row_rem;       // rows remaining (2D/3D)
    logic [31:0] e_plane_rem;     // planes remaining (3D)
    logic [31:0] e_sg_rem;        // SG descriptors remaining
    logic [31:0] e_sg_ptr;        // address of next SG descriptor

    // Burst parameters (set in BURST_CALC)
    logic [7:0]  e_beats;         // beats in current burst (arlen = beats-1)
    logic [31:0] e_burst_bytes;   // bytes in current burst = beats * BPB

    // Beat counter for RD_DATA / WR_DATA
    logic [7:0]  beat_cnt;

    // SG descriptor receive buffer (4 words)
    logic [31:0] sg_desc [0:3];
    logic [1:0]  sg_word_cnt;

    // ── channel scheduler ──────────────────────────────────────────────────
    // Returns an active channel index or sets no_pending if none is ready.
    // A channel is "ready" when:  EN=1, START=1, BUSY=0, DONE=0 (not already done/running)
    logic                                          no_pending;
    logic [$clog2(NUM_CHANNELS > 1 ? NUM_CHANNELS : 2)-1:0] sched_ch;

    always_comb begin : scheduler
        sched_ch   = '0;
        no_pending = 1'b1;
        // Round-robin: scan NUM_CHANNELS slots starting from rr_ptr
        for (int k = 0; k < NUM_CHANNELS; k++) begin
            automatic int idx = (int'(rr_ptr) + k) % NUM_CHANNELS;
            if (ch_ctrl[idx][0] &&    // EN
                ch_armed[idx]   &&    // START was written and not yet consumed
                !ch_busy[idx]) begin
                sched_ch   = idx[$clog2(NUM_CHANNELS > 1 ? NUM_CHANNELS : 2)-1:0];
                no_pending = 1'b0;
                break;
            end
        end
    end

    // ── engine main always_ff ─────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin : eng
        if (!rst_n) begin
            eng_state   <= S_IDLE;
            active_ch   <= '0;
            rr_ptr      <= '0;
            ch_busy     <= '0;
            // ch_done / ch_err managed in separate always_ff above
            e_ctrl      <= '0;
            e_mode      <= '0;
            e_src_inc   <= 1'b0;
            e_dst_inc   <= 1'b0;
            e_cur_src   <= '0;
            e_cur_dst   <= '0;
            e_rem_bytes <= '0;
            e_row_rem   <= '0;
            e_plane_rem <= '0;
            e_sg_rem    <= '0;
            e_sg_ptr    <= '0;
            e_beats     <= '0;
            e_burst_bytes <= '0;
            beat_cnt    <= '0;
            sg_word_cnt <= '0;
            sg_desc[0]  <= '0; sg_desc[1] <= '0;
            sg_desc[2]  <= '0; sg_desc[3] <= '0;
            // AXI master outputs
            dma_awaddr  <= '0; dma_awlen  <= '0;
            dma_awsize  <= '0; dma_awburst<= '0;
            dma_awvalid <= 1'b0;
            dma_wvalid  <= 1'b0;
            dma_bready  <= 1'b0;
            dma_araddr  <= '0; dma_arlen  <= '0;
            dma_arsize  <= '0; dma_arburst<= '0;
            dma_arvalid <= 1'b0;
            dma_rready  <= 1'b0;
            fifo_push   <= 1'b0;
            fifo_wdata  <= '0;
        end else begin
            // Default: de-assert one-shot signals
            dma_arvalid <= 1'b0;
            dma_awvalid <= 1'b0;
            dma_wvalid  <= 1'b0;
            dma_rready  <= 1'b0;
            dma_bready  <= 1'b0;
            fifo_push   <= 1'b0;
            // fifo_pop is a wire, no register to clear

            case (eng_state)

                // ── IDLE: scan for a pending channel ──────────────────────
                S_IDLE: begin
                    if (!no_pending) begin
                        active_ch   <= sched_ch;
                        rr_ptr      <= sched_ch + 1'b1;
                        ch_busy[sched_ch] <= 1'b1;
                        // ch_armed[sched_ch] is cleared in its own always_ff

                        // Load channel snapshot
                        e_ctrl     <= ch_ctrl[sched_ch];
                        e_mode     <= ch_ctrl[sched_ch][4:3];
                        e_src_inc  <= ch_ctrl[sched_ch][5];
                        e_dst_inc  <= ch_ctrl[sched_ch][6];
                        e_cur_src  <= ch_src_addr[sched_ch];
                        e_cur_dst  <= ch_dst_addr[sched_ch];
                        e_rem_bytes<= ch_xfer_cnt[sched_ch];
                        e_row_rem  <= ch_row_cnt[sched_ch];
                        e_plane_rem<= ch_plane_cnt[sched_ch];
                        e_sg_rem   <= ch_sg_cnt[sched_ch];
                        e_sg_ptr   <= ch_sg_addr[sched_ch];

                        // Flush FIFO
                        // (FIFO pointers are reset when we start a new transfer;
                        //  safe because IDLE means engine is idle)

                        if (ch_ctrl[sched_ch][4:3] == 2'b11) begin
                            // SG mode: fetch first descriptor
                            eng_state <= S_FETCH_SG;
                        end else begin
                            eng_state <= S_BURST_CALC;
                        end
                    end
                end

                // ── FETCH_SG: issue AR for 4-word SG descriptor ───────────
                S_FETCH_SG: begin
                    if (e_sg_rem == 32'h0) begin
                        // No more descriptors → done
                        eng_state <= S_DONE;
                    end else begin
                        dma_araddr  <= e_sg_ptr;
                        dma_arlen   <= 8'd3;       // 4 beats
                        dma_arsize  <= 3'b010;     // 4 bytes (descriptor words are 32-bit)
                        dma_arburst <= 2'b01;      // INCR
                        dma_arvalid <= 1'b1;
                        sg_word_cnt <= 2'd0;
                        if (dma_arvalid && dma_arready) begin
                            dma_arvalid <= 1'b0;
                            dma_rready  <= 1'b1;
                            eng_state   <= S_FETCH_RDAT;
                        end
                    end
                end

                // ── FETCH_RDAT: receive 4 descriptor words ────────────────
                S_FETCH_RDAT: begin
                    dma_rready <= 1'b1;
                    if (dma_rvalid && dma_rready) begin
                        sg_desc[sg_word_cnt] <= dma_rdata[31:0];
                        if (dma_rresp != 2'b00) begin
                            dma_rready  <= 1'b0;
                            eng_state   <= S_ERROR;
                        end else if (dma_rlast) begin
                            dma_rready  <= 1'b0;
                            // Parse descriptor into running regs
                            e_cur_src   <= dma_rdata[31:0]; // overwritten below after fully captured
                            sg_word_cnt <= sg_word_cnt + 1'b1;
                            eng_state   <= S_BURST_CALC;
                        end else begin
                            sg_word_cnt <= sg_word_cnt + 1'b1;
                        end
                    end
                end

                // ── BURST_CALC: compute next burst length (4K boundary) ───
                S_BURST_CALC: begin
                    // For SG mode pick up the freshly captured descriptor words
                    // directly so that burst calc sees the right addresses/lengths.
                    begin : bc
                        automatic logic [31:0] bc_src = (e_mode == 2'b11) ? sg_desc[0] : e_cur_src;
                        automatic logic [31:0] bc_dst = (e_mode == 2'b11) ? sg_desc[1] : e_cur_dst;
                        automatic logic [31:0] bc_rem = (e_mode == 2'b11) ? sg_desc[2] : e_rem_bytes;
                        automatic logic [31:0] rem_in_src_page = 32'h1000 - {20'h0, bc_src[11:0]};
                        automatic logic [31:0] rem_in_dst_page = 32'h1000 - {20'h0, bc_dst[11:0]};
                        automatic logic [31:0] max_burst_bytes = {24'h0, MAX_BURST_LEN[7:0]} * BPB;
                        automatic logic [31:0] limit = (bc_rem < max_burst_bytes) ? bc_rem : max_burst_bytes;
                        automatic logic [31:0] limit_aligned   = (limit / BPB) * BPB;
                        automatic logic [31:0] src_page_limit  = (limit_aligned < rem_in_src_page) ? limit_aligned : rem_in_src_page;
                        automatic logic [31:0] dst_page_limit  = (src_page_limit < rem_in_dst_page) ? src_page_limit : rem_in_dst_page;
                        automatic logic [31:0] burst_bytes     = (dst_page_limit / BPB) * BPB;
                        if (burst_bytes < BPB) burst_bytes = BPB;
                        e_burst_bytes <= burst_bytes;
                        e_beats       <= burst_bytes[8:0] / BPB[8:0];
                    end

                    if (e_mode == 2'b11) begin
                        e_cur_src   <= sg_desc[0];
                        e_cur_dst   <= sg_desc[1];
                        e_rem_bytes <= sg_desc[2];
                        e_src_inc   <= sg_desc[3][2];
                        e_dst_inc   <= sg_desc[3][3];
                    end

                    eng_state <= S_RD_ADDR;
                end

                // ── RD_ADDR: issue AXI read ───────────────────────────────
                S_RD_ADDR: begin
                    dma_araddr  <= e_cur_src;
                    dma_arlen   <= e_beats - 8'h1;
                    dma_arsize  <= AXI_SIZE[2:0];
                    dma_arburst <= e_src_inc ? 2'b01 : 2'b00; // INCR or FIXED
                    dma_arvalid <= 1'b1;
                    beat_cnt    <= 8'h0;
                    if (dma_arvalid && dma_arready) begin
                        dma_arvalid <= 1'b0;
                        dma_rready  <= 1'b1;
                        eng_state   <= S_RD_DATA;
                    end
                end

                // ── RD_DATA: receive beats into FIFO ─────────────────────
                S_RD_DATA: begin
                    dma_rready <= !fifo_full;
                    if (dma_rvalid && !fifo_full) begin
                        fifo_push  <= 1'b1;
                        fifo_wdata <= dma_rdata;
                        beat_cnt   <= beat_cnt + 1'b1;
                        if (dma_rresp != 2'b00) begin
                            // AXI read error
                            dma_rready <= 1'b0;
                            eng_state  <= S_ERROR;
                        end else if (dma_rlast || beat_cnt == e_beats - 8'h1) begin
                            dma_rready <= 1'b0;
                            eng_state  <= S_WR_ADDR;
                        end
                    end
                end

                // ── WR_ADDR: issue AXI write address ─────────────────────
                S_WR_ADDR: begin
                    dma_awaddr  <= e_cur_dst;
                    dma_awlen   <= e_beats - 8'h1;
                    dma_awsize  <= AXI_SIZE[2:0];
                    dma_awburst <= e_dst_inc ? 2'b01 : 2'b00;
                    dma_awvalid <= 1'b1;
                    beat_cnt    <= 8'h0;
                    if (dma_awready) begin
                        dma_awvalid <= 1'b0;
                        eng_state   <= S_WR_DATA;
                    end
                end

                // ── WR_DATA: drain FIFO to W channel ─────────────────────
                S_WR_DATA: begin
                    if (!fifo_empty) begin
                        dma_wvalid <= 1'b1;
                        if (dma_wvalid && dma_wready) begin  // real AXI handshake
                            beat_cnt <= beat_cnt + 1'b1;
                            if (beat_cnt == e_beats - 8'h1) begin
                                dma_wvalid <= 1'b0;
                                dma_bready <= 1'b1;
                                eng_state  <= S_WR_RESP;
                            end
                        end
                    end
                end

                // ── WR_RESP: wait for B response ─────────────────────────
                S_WR_RESP: begin
                    dma_bready <= 1'b1;
                    if (dma_bvalid) begin
                        dma_bready <= 1'b0;
                        if (dma_bresp != 2'b00) begin
                            eng_state <= S_ERROR;
                        end else begin
                            eng_state <= S_ADVANCE;
                        end
                    end
                end

                // ── ADVANCE: update addresses/counts, decide next step ────
                S_ADVANCE: begin
                    // Advance addresses
                    if (e_src_inc) e_cur_src <= e_cur_src + e_burst_bytes;
                    if (e_dst_inc) e_cur_dst <= e_cur_dst + e_burst_bytes;
                    e_rem_bytes <= e_rem_bytes - e_burst_bytes;

                    if (e_rem_bytes == e_burst_bytes) begin
                        // Current row/1D segment finished
                        if (e_mode == 2'b00) begin
                            // 1D: done
                            eng_state <= S_DONE;
                        end else if (e_mode == 2'b11) begin
                            // SG: advance to next descriptor
                            e_sg_rem  <= e_sg_rem - 32'h1;
                            e_sg_ptr  <= e_sg_ptr + 32'h10; // 16 bytes per descriptor
                            if (e_sg_rem == 32'h1) begin
                                eng_state <= S_DONE;
                            end else begin
                                eng_state <= S_FETCH_SG;
                            end
                        end else begin
                            // 2D or 3D: advance row
                            e_row_rem <= e_row_rem - 32'h1;
                            // Reload row parameters from saved regs
                            e_cur_src <= e_cur_src - (e_rem_bytes - e_burst_bytes) +
                                         ch_src_stride[active_ch];
                            e_cur_dst <= e_cur_dst - (e_rem_bytes - e_burst_bytes) +
                                         ch_dst_stride[active_ch];
                            e_rem_bytes <= ch_xfer_cnt[active_ch]; // reset bytes per row

                            if (e_row_rem == 32'h1) begin
                                // All rows in this plane done
                                if (e_mode == 2'b01) begin
                                    // 2D: done
                                    eng_state <= S_DONE;
                                end else begin
                                    // 3D: advance plane
                                    e_plane_rem <= e_plane_rem - 32'h1;
                                    // Jump to next plane start
                                    e_cur_src <= ch_src_addr[active_ch] +
                                                 (ch_plane_cnt[active_ch] - e_plane_rem + 32'h1) *
                                                 ch_src_pstride[active_ch];
                                    e_cur_dst <= ch_dst_addr[active_ch] +
                                                 (ch_plane_cnt[active_ch] - e_plane_rem + 32'h1) *
                                                 ch_dst_pstride[active_ch];
                                    e_row_rem   <= ch_row_cnt[active_ch];
                                    e_rem_bytes <= ch_xfer_cnt[active_ch];
                                    if (e_plane_rem == 32'h1) begin
                                        eng_state <= S_DONE;
                                    end else begin
                                        eng_state <= S_BURST_CALC;
                                    end
                                end
                            end else begin
                                eng_state <= S_BURST_CALC;
                            end
                        end
                    end else begin
                        // Row not yet complete: next burst
                        eng_state <= S_BURST_CALC;
                    end
                end

                // ── DONE ─────────────────────────────────────────────────
                S_DONE: begin
                    ch_busy[active_ch] <= 1'b0;
                    ch_done[active_ch] <= 1'b1;
                    eng_state          <= S_IDLE;
                end

                // ── ERROR ─────────────────────────────────────────────────
                S_ERROR: begin
                    ch_busy[active_ch] <= 1'b0;
                    ch_err[active_ch]  <= 1'b1;
                    // Drain any pending R channel
                    dma_rready         <= 1'b0;
                    eng_state          <= S_IDLE;
                end

                default: eng_state <= S_IDLE;
            endcase

            // STOP abort: if CPU sets STOP while channel is active
            if (ch_ctrl[active_ch][2] && ch_busy[active_ch]) begin
                ch_busy[active_ch] <= 1'b0;
                ch_err[active_ch]  <= 1'b1;
                dma_arvalid <= 1'b0;
                dma_awvalid <= 1'b0;
                dma_wvalid  <= 1'b0;
                dma_rready  <= 1'b0;
                dma_bready  <= 1'b0;
                eng_state   <= S_IDLE;
            end
        end
    end

    // FIFO memory, pointer management, and IDLE-flush in one always_ff
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr_ptr <= '0;
            fifo_rd_ptr <= '0;
        end else if (eng_state == S_IDLE && !no_pending) begin
            // Flush FIFO at start of each new transfer
            fifo_wr_ptr <= '0;
            fifo_rd_ptr <= '0;
        end else begin
            if (fifo_push && !fifo_full) begin
                fifo_mem[fifo_wr_ptr[FIFO_BITS-1:0]] <= fifo_wdata;
                fifo_wr_ptr <= fifo_wr_ptr + 1;
            end
            if (fifo_pop && !fifo_empty) fifo_rd_ptr <= fifo_rd_ptr + 1;
        end
    end

    // ========================================================================
    // IRQ output
    // ========================================================================
    // IRQ is asserted when any channel with IE=1 has DONE or ERR, AND
    // the global enable for that channel is set.
    always_comb begin : irq_gen
        irq = 1'b0;
        for (int i = 0; i < NUM_CHANNELS; i++) begin
            if ((ch_done[i] | ch_err[i]) && ch_ctrl[i][7] && glb_irq_en[i])
                irq = 1'b1;
        end
    end

    // ========================================================================
    // AXI4 Protocol Assertions - Master Interface
    // ========================================================================
    // Define ASSERTION by default (can be disabled with +define+NO_ASSERTION)
`ifndef NO_ASSERTION
`ifndef ASSERTION
`define ASSERTION
`endif
`endif // NO_ASSERTION

`ifdef ASSERTION
    // DATA_WIDTH must be 32, 64, or 128
    initial begin
        assert (DATA_WIDTH == 32 || DATA_WIDTH == 64 || DATA_WIDTH == 128)
            else $fatal(1, "[AXI_DMA] DATA_WIDTH must be 32, 64, or 128");
        assert (NUM_CHANNELS >= 1 && NUM_CHANNELS <= 8)
            else $fatal(1, "[AXI_DMA] NUM_CHANNELS must be 1..8");
        assert (FIFO_DEPTH >= 2 && (FIFO_DEPTH & (FIFO_DEPTH-1)) == 0)
            else $fatal(1, "[AXI_DMA] FIFO_DEPTH must be a power-of-two >= 2");
        assert (MAX_BURST_LEN >= 1 && MAX_BURST_LEN <= 256)
            else $fatal(1, "[AXI_DMA] MAX_BURST_LEN must be 1..256");
    end

    property p_dma_arvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (dma_arvalid && !dma_arready) |=> $stable(dma_arvalid) && $stable(dma_araddr);
    endproperty
    assert property (p_dma_arvalid_stable)
        else $error("[AXI_DMA] ARVALID/ARADDR must be stable until ARREADY");

    property p_dma_awvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (dma_awvalid && !dma_awready) |=> $stable(dma_awvalid) && $stable(dma_awaddr);
    endproperty
    assert property (p_dma_awvalid_stable)
        else $error("[AXI_DMA] AWVALID/AWADDR must be stable until AWREADY");

    property p_dma_wvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (dma_wvalid && !dma_wready) |=> $stable(dma_wvalid) && $stable(dma_wdata);
    endproperty
    assert property (p_dma_wvalid_stable)
        else $error("[AXI_DMA] WVALID/WDATA must be stable until WREADY");
`endif // ASSERTION

endmodule

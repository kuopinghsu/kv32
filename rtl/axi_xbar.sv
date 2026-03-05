// ============================================================================
// File: axi_xbar.sv
// Project: KV32 RISC-V Processor
// Description: AXI4 1-to-10 Crossbar (Interconnect)
//
// Routes AXI4 transactions from a single master to ten slave devices:
//   - Slave 0: Main RAM       (0x8000_0000 - 0x801F_FFFF)
//   - Slave 1: Magic Device   (0x4000_0000 - 0x4000_FFFF)
//   - Slave 2: CLINT Timer    (0x0200_0000 - 0x020B_FFFF)
//   - Slave 3: PLIC           (0x0C00_0000 - 0x0CFF_FFFF)
//   - Slave 4: DMA            (0x2000_0000 - 0x2000_FFFF)
//   - Slave 5: UART           (0x2001_0000 - 0x2001_FFFF)
//   - Slave 6: I2C            (0x2002_0000 - 0x2002_FFFF)
//   - Slave 7: SPI            (0x2003_0000 - 0x2003_FFFF)
//   - Slave 8: Timer/PWM      (0x2004_0000 - 0x2004_FFFF)
//   - Slave 9: GPIO           (0x2005_0000 - 0x2005_FFFF)
//
// Handles address decoding, channel routing with ID support, and error
// responses for unmapped addresses. Supports multiple outstanding transactions
// via AXI ID mechanism.
// ============================================================================

module axi_xbar (
    input  logic        clk,
    input  logic        rst_n,

    // Master interface (from memory bus) with ID support
    input  logic [31:0]              m_axi_awaddr,
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] m_axi_awid,
    input  logic [7:0]               m_axi_awlen,
    input  logic [2:0]               m_axi_awsize,
    input  logic [1:0]               m_axi_awburst,
    input  logic                     m_axi_awvalid,
    output logic                     m_axi_awready,

    input  logic [31:0]              m_axi_wdata,
    input  logic [3:0]               m_axi_wstrb,
    input  logic                     m_axi_wlast,
    input  logic                     m_axi_wvalid,
    output logic                     m_axi_wready,

    output logic [1:0]               m_axi_bresp,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] m_axi_bid,
    output logic                     m_axi_bvalid,
    input  logic                     m_axi_bready,

    input  logic [31:0]              m_axi_araddr,
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] m_axi_arid,
    input  logic [7:0]               m_axi_arlen,
    input  logic [2:0]               m_axi_arsize,
    input  logic [1:0]               m_axi_arburst,
    input  logic                     m_axi_arvalid,
    output logic                     m_axi_arready,

    output logic [31:0]              m_axi_rdata,
    output logic [1:0]               m_axi_rresp,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] m_axi_rid,
    output logic                     m_axi_rlast,
    output logic                     m_axi_rvalid,
    input  logic                     m_axi_rready,

    // Slave 0: RAM (0x8000_0000 - 0x801F_FFFF)
    output logic [31:0] s0_axi_awaddr,
    output logic [7:0]  s0_axi_awlen,
    output logic [2:0]  s0_axi_awsize,
    output logic [1:0]  s0_axi_awburst,
    output logic        s0_axi_awvalid,
    input  logic        s0_axi_awready,

    output logic [31:0] s0_axi_wdata,
    output logic [3:0]  s0_axi_wstrb,
    output logic        s0_axi_wlast,
    output logic        s0_axi_wvalid,
    input  logic        s0_axi_wready,

    input  logic [1:0]  s0_axi_bresp,
    input  logic        s0_axi_bvalid,
    output logic        s0_axi_bready,

    output logic [31:0] s0_axi_araddr,
    output logic [7:0]  s0_axi_arlen,
    output logic [2:0]  s0_axi_arsize,
    output logic [1:0]  s0_axi_arburst,
    output logic        s0_axi_arvalid,
    input  logic        s0_axi_arready,

    input  logic [31:0] s0_axi_rdata,
    input  logic [1:0]  s0_axi_rresp,
    input  logic        s0_axi_rlast,
    input  logic        s0_axi_rvalid,
    output logic        s0_axi_rready,

    // Slave 1: Magic (0x4000_0000 - 0x4000_FFFF)
    output logic [31:0] s1_axi_awaddr,
    output logic        s1_axi_awvalid,
    input  logic        s1_axi_awready,

    output logic [31:0] s1_axi_wdata,
    output logic [3:0]  s1_axi_wstrb,
    output logic        s1_axi_wvalid,
    input  logic        s1_axi_wready,

    input  logic [1:0]  s1_axi_bresp,
    input  logic        s1_axi_bvalid,
    output logic        s1_axi_bready,

    output logic [31:0] s1_axi_araddr,
    output logic        s1_axi_arvalid,
    input  logic        s1_axi_arready,

    input  logic [31:0] s1_axi_rdata,
    input  logic [1:0]  s1_axi_rresp,
    input  logic        s1_axi_rvalid,
    output logic        s1_axi_rready,

    // Slave 2: CLINT (0x0200_0000 - 0x020B_FFFF)
    output logic [31:0] s2_axi_awaddr,
    output logic        s2_axi_awvalid,
    input  logic        s2_axi_awready,

    output logic [31:0] s2_axi_wdata,
    output logic [3:0]  s2_axi_wstrb,
    output logic        s2_axi_wvalid,
    input  logic        s2_axi_wready,

    input  logic [1:0]  s2_axi_bresp,
    input  logic        s2_axi_bvalid,
    output logic        s2_axi_bready,

    output logic [31:0] s2_axi_araddr,
    output logic        s2_axi_arvalid,
    input  logic        s2_axi_arready,

    input  logic [31:0] s2_axi_rdata,
    input  logic [1:0]  s2_axi_rresp,
    input  logic        s2_axi_rvalid,
    output logic        s2_axi_rready,

    // Slave 3: PLIC (0x0C00_0000 - 0x0CFF_FFFF)
    output logic [31:0] s3_axi_awaddr,
    output logic        s3_axi_awvalid,
    input  logic        s3_axi_awready,

    output logic [31:0] s3_axi_wdata,
    output logic [3:0]  s3_axi_wstrb,
    output logic        s3_axi_wvalid,
    input  logic        s3_axi_wready,

    input  logic [1:0]  s3_axi_bresp,
    input  logic        s3_axi_bvalid,
    output logic        s3_axi_bready,

    output logic [31:0] s3_axi_araddr,
    output logic        s3_axi_arvalid,
    input  logic        s3_axi_arready,

    input  logic [31:0] s3_axi_rdata,
    input  logic [1:0]  s3_axi_rresp,
    input  logic        s3_axi_rvalid,
    output logic        s3_axi_rready,

    // Slave 4: DMA (0x2000_0000 - 0x2000_FFFF)
    output logic [31:0] s4_axi_awaddr,
    output logic        s4_axi_awvalid,
    input  logic        s4_axi_awready,

    output logic [31:0] s4_axi_wdata,
    output logic [3:0]  s4_axi_wstrb,
    output logic        s4_axi_wvalid,
    input  logic        s4_axi_wready,

    input  logic [1:0]  s4_axi_bresp,
    input  logic        s4_axi_bvalid,
    output logic        s4_axi_bready,

    output logic [31:0] s4_axi_araddr,
    output logic        s4_axi_arvalid,
    input  logic        s4_axi_arready,

    input  logic [31:0] s4_axi_rdata,
    input  logic [1:0]  s4_axi_rresp,
    input  logic        s4_axi_rvalid,
    output logic        s4_axi_rready,

    // Slave 5: UART (0x2001_0000 - 0x2001_FFFF)
    output logic [31:0] s5_axi_awaddr,
    output logic        s5_axi_awvalid,
    input  logic        s5_axi_awready,

    output logic [31:0] s5_axi_wdata,
    output logic [3:0]  s5_axi_wstrb,
    output logic        s5_axi_wvalid,
    input  logic        s5_axi_wready,

    input  logic [1:0]  s5_axi_bresp,
    input  logic        s5_axi_bvalid,
    output logic        s5_axi_bready,

    output logic [31:0] s5_axi_araddr,
    output logic        s5_axi_arvalid,
    input  logic        s5_axi_arready,

    input  logic [31:0] s5_axi_rdata,
    input  logic [1:0]  s5_axi_rresp,
    input  logic        s5_axi_rvalid,
    output logic        s5_axi_rready,

    // Slave 6: I2C (0x2002_0000 - 0x2002_FFFF)
    output logic [31:0] s6_axi_awaddr,
    output logic        s6_axi_awvalid,
    input  logic        s6_axi_awready,

    output logic [31:0] s6_axi_wdata,
    output logic [3:0]  s6_axi_wstrb,
    output logic        s6_axi_wvalid,
    input  logic        s6_axi_wready,

    input  logic [1:0]  s6_axi_bresp,
    input  logic        s6_axi_bvalid,
    output logic        s6_axi_bready,

    output logic [31:0] s6_axi_araddr,
    output logic        s6_axi_arvalid,
    input  logic        s6_axi_arready,

    input  logic [31:0] s6_axi_rdata,
    input  logic [1:0]  s6_axi_rresp,
    input  logic        s6_axi_rvalid,
    output logic        s6_axi_rready,

    // Slave 7: SPI (0x2003_0000 - 0x2003_FFFF)
    output logic [31:0] s7_axi_awaddr,
    output logic        s7_axi_awvalid,
    input  logic        s7_axi_awready,

    output logic [31:0] s7_axi_wdata,
    output logic [3:0]  s7_axi_wstrb,
    output logic        s7_axi_wvalid,
    input  logic        s7_axi_wready,

    input  logic [1:0]  s7_axi_bresp,
    input  logic        s7_axi_bvalid,
    output logic        s7_axi_bready,

    output logic [31:0] s7_axi_araddr,
    output logic        s7_axi_arvalid,
    input  logic        s7_axi_arready,

    input  logic [31:0] s7_axi_rdata,
    input  logic [1:0]  s7_axi_rresp,
    input  logic        s7_axi_rvalid,
    output logic        s7_axi_rready,

    // Slave 8: Timer/PWM (0x2004_0000 - 0x2004_FFFF)
    output logic [31:0] s8_axi_awaddr,
    output logic        s8_axi_awvalid,
    input  logic        s8_axi_awready,

    output logic [31:0] s8_axi_wdata,
    output logic [3:0]  s8_axi_wstrb,
    output logic        s8_axi_wvalid,
    input  logic        s8_axi_wready,

    input  logic [1:0]  s8_axi_bresp,
    input  logic        s8_axi_bvalid,
    output logic        s8_axi_bready,

    output logic [31:0] s8_axi_araddr,
    output logic        s8_axi_arvalid,
    input  logic        s8_axi_arready,

    input  logic [31:0] s8_axi_rdata,
    input  logic [1:0]  s8_axi_rresp,
    input  logic        s8_axi_rvalid,
    output logic        s8_axi_rready,

    // Slave 9: GPIO (0x2005_0000 - 0x2005_FFFF)
    output logic [31:0] s9_axi_awaddr,
    output logic        s9_axi_awvalid,
    input  logic        s9_axi_awready,

    output logic [31:0] s9_axi_wdata,
    output logic [3:0]  s9_axi_wstrb,
    output logic        s9_axi_wvalid,
    input  logic        s9_axi_wready,

    input  logic [1:0]  s9_axi_bresp,
    input  logic        s9_axi_bvalid,
    output logic        s9_axi_bready,

    output logic [31:0] s9_axi_araddr,
    output logic        s9_axi_arvalid,
    input  logic        s9_axi_arready,

    input  logic [31:0] s9_axi_rdata,
    input  logic [1:0]  s9_axi_rresp,
    input  logic        s9_axi_rvalid,
    output logic        s9_axi_rready
);

    // Address decode
    logic sel_s0_aw, sel_s1_aw, sel_s2_aw, sel_s3_aw, sel_s4_aw, sel_s5_aw, sel_s6_aw, sel_s7_aw, sel_s8_aw, sel_s9_aw;
    logic sel_s0_ar, sel_s1_ar, sel_s2_ar, sel_s3_ar, sel_s4_ar, sel_s5_ar, sel_s6_ar, sel_s7_ar, sel_s8_ar, sel_s9_ar;

    // ID FIFOs per slave to correctly handle multiple outstanding reads.
    // A single register was insufficient: if IMEM and DMEM both issue ARs to the
    // same slave (e.g. RAM), the second AR would overwrite the first's ID, causing
    // the first response to be routed back to the wrong master, hanging the bus.
    //
    // Depth must cover the maximum outstanding reads the downstream slave accepts.
    // Set to MAX_OUTSTANDING_READS (16) so the FIFO can never overflow.
    localparam int AR_ID_FIFO_DEPTH = 16;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] s0_ar_id_fifo [0:AR_ID_FIFO_DEPTH-1];
    logic [$clog2(AR_ID_FIFO_DEPTH):0] s0_ar_id_wr_ptr, s0_ar_id_rd_ptr;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] s1_ar_id_fifo [0:AR_ID_FIFO_DEPTH-1];
    logic [$clog2(AR_ID_FIFO_DEPTH):0] s1_ar_id_wr_ptr, s1_ar_id_rd_ptr;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] s2_ar_id_fifo [0:AR_ID_FIFO_DEPTH-1];
    logic [$clog2(AR_ID_FIFO_DEPTH):0] s2_ar_id_wr_ptr, s2_ar_id_rd_ptr;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] s3_ar_id_fifo [0:AR_ID_FIFO_DEPTH-1];
    logic [$clog2(AR_ID_FIFO_DEPTH):0] s3_ar_id_wr_ptr, s3_ar_id_rd_ptr;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] s4_ar_id_fifo [0:AR_ID_FIFO_DEPTH-1];
    logic [$clog2(AR_ID_FIFO_DEPTH):0] s4_ar_id_wr_ptr, s4_ar_id_rd_ptr;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] s5_ar_id_fifo [0:AR_ID_FIFO_DEPTH-1];
    logic [$clog2(AR_ID_FIFO_DEPTH):0] s5_ar_id_wr_ptr, s5_ar_id_rd_ptr;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] s6_ar_id_fifo [0:AR_ID_FIFO_DEPTH-1];
    logic [$clog2(AR_ID_FIFO_DEPTH):0] s6_ar_id_wr_ptr, s6_ar_id_rd_ptr;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] s7_ar_id_fifo [0:AR_ID_FIFO_DEPTH-1];
    logic [$clog2(AR_ID_FIFO_DEPTH):0] s7_ar_id_wr_ptr, s7_ar_id_rd_ptr;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] s8_ar_id_fifo [0:AR_ID_FIFO_DEPTH-1];
    logic [$clog2(AR_ID_FIFO_DEPTH):0] s8_ar_id_wr_ptr, s8_ar_id_rd_ptr;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] s9_ar_id_fifo [0:AR_ID_FIFO_DEPTH-1];
    logic [$clog2(AR_ID_FIFO_DEPTH):0] s9_ar_id_wr_ptr, s9_ar_id_rd_ptr;

    // Decode error handling for unmapped read addresses
    localparam int DECODE_ERR_FIFO_DEPTH = 8;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] decode_err_id_fifo  [0:DECODE_ERR_FIFO_DEPTH-1];
    logic [7:0]                        decode_err_len_fifo [0:DECODE_ERR_FIFO_DEPTH-1];
    logic [$clog2(DECODE_ERR_FIFO_DEPTH):0] decode_err_wr_ptr;
    logic [$clog2(DECODE_ERR_FIFO_DEPTH):0] decode_err_rd_ptr;
    logic decode_err_pending;
    logic decode_err_push, decode_err_pop, decode_err_beat_accepted;
    logic [7:0] decode_err_beat_cnt;  // beats sent so far for current burst

    // Push AR IDs into per-slave FIFOs on AR handshake; pop on R handshake.
    // This correctly handles multiple outstanding reads to the same slave
    // (e.g. simultaneous IMEM + DMEM reads to RAM / slave 0).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_ar_id_wr_ptr <= '0; s0_ar_id_rd_ptr <= '0;
            s1_ar_id_wr_ptr <= '0; s1_ar_id_rd_ptr <= '0;
            s2_ar_id_wr_ptr <= '0; s2_ar_id_rd_ptr <= '0;
            s3_ar_id_wr_ptr <= '0; s3_ar_id_rd_ptr <= '0;
            s4_ar_id_wr_ptr <= '0; s4_ar_id_rd_ptr <= '0;
            s5_ar_id_wr_ptr <= '0; s5_ar_id_rd_ptr <= '0;
            s6_ar_id_wr_ptr <= '0; s6_ar_id_rd_ptr <= '0;
            s7_ar_id_wr_ptr <= '0; s7_ar_id_rd_ptr <= '0;
            s8_ar_id_wr_ptr <= '0; s8_ar_id_rd_ptr <= '0;
            s9_ar_id_wr_ptr <= '0; s9_ar_id_rd_ptr <= '0;
        end else begin
            // Push: AR accepted to each slave
            if (m_axi_arvalid && s0_axi_arready && sel_s0_ar) begin
                s0_ar_id_fifo[s0_ar_id_wr_ptr[$clog2(AR_ID_FIFO_DEPTH)-1:0]] <= m_axi_arid;
                s0_ar_id_wr_ptr <= s0_ar_id_wr_ptr + 1;
            end
            if (m_axi_arvalid && s1_axi_arready && sel_s1_ar) begin
                s1_ar_id_fifo[s1_ar_id_wr_ptr[$clog2(AR_ID_FIFO_DEPTH)-1:0]] <= m_axi_arid;
                s1_ar_id_wr_ptr <= s1_ar_id_wr_ptr + 1;
            end
            if (m_axi_arvalid && s2_axi_arready && sel_s2_ar) begin
                s2_ar_id_fifo[s2_ar_id_wr_ptr[$clog2(AR_ID_FIFO_DEPTH)-1:0]] <= m_axi_arid;
                s2_ar_id_wr_ptr <= s2_ar_id_wr_ptr + 1;
            end
            if (m_axi_arvalid && s3_axi_arready && sel_s3_ar) begin
                s3_ar_id_fifo[s3_ar_id_wr_ptr[$clog2(AR_ID_FIFO_DEPTH)-1:0]] <= m_axi_arid;
                s3_ar_id_wr_ptr <= s3_ar_id_wr_ptr + 1;
            end
            if (m_axi_arvalid && s4_axi_arready && sel_s4_ar) begin
                s4_ar_id_fifo[s4_ar_id_wr_ptr[$clog2(AR_ID_FIFO_DEPTH)-1:0]] <= m_axi_arid;
                s4_ar_id_wr_ptr <= s4_ar_id_wr_ptr + 1;
            end
            if (m_axi_arvalid && s5_axi_arready && sel_s5_ar) begin
                s5_ar_id_fifo[s5_ar_id_wr_ptr[$clog2(AR_ID_FIFO_DEPTH)-1:0]] <= m_axi_arid;
                s5_ar_id_wr_ptr <= s5_ar_id_wr_ptr + 1;
            end
            if (m_axi_arvalid && s6_axi_arready && sel_s6_ar) begin
                s6_ar_id_fifo[s6_ar_id_wr_ptr[$clog2(AR_ID_FIFO_DEPTH)-1:0]] <= m_axi_arid;
                s6_ar_id_wr_ptr <= s6_ar_id_wr_ptr + 1;
            end
            if (m_axi_arvalid && s7_axi_arready && sel_s7_ar) begin
                s7_ar_id_fifo[s7_ar_id_wr_ptr[$clog2(AR_ID_FIFO_DEPTH)-1:0]] <= m_axi_arid;
                s7_ar_id_wr_ptr <= s7_ar_id_wr_ptr + 1;
            end
            if (m_axi_arvalid && s8_axi_arready && sel_s8_ar) begin
                s8_ar_id_fifo[s8_ar_id_wr_ptr[$clog2(AR_ID_FIFO_DEPTH)-1:0]] <= m_axi_arid;
                s8_ar_id_wr_ptr <= s8_ar_id_wr_ptr + 1;
            end
            if (m_axi_arvalid && s9_axi_arready && sel_s9_ar) begin
                s9_ar_id_fifo[s9_ar_id_wr_ptr[$clog2(AR_ID_FIFO_DEPTH)-1:0]] <= m_axi_arid;
                s9_ar_id_wr_ptr <= s9_ar_id_wr_ptr + 1;
            end
            // Pop: R handshake completes for each slave
            // Slave 0 may return multi-beat bursts – only pop FIFO on the last beat.
            if (s0_axi_rvalid && s0_axi_rready && s0_axi_rlast) s0_ar_id_rd_ptr <= s0_ar_id_rd_ptr + 1;
            if (s1_axi_rvalid && s1_axi_rready) s1_ar_id_rd_ptr <= s1_ar_id_rd_ptr + 1;
            if (s2_axi_rvalid && s2_axi_rready) s2_ar_id_rd_ptr <= s2_ar_id_rd_ptr + 1;
            if (s3_axi_rvalid && s3_axi_rready) s3_ar_id_rd_ptr <= s3_ar_id_rd_ptr + 1;
            if (s4_axi_rvalid && s4_axi_rready) s4_ar_id_rd_ptr <= s4_ar_id_rd_ptr + 1;
            if (s5_axi_rvalid && s5_axi_rready) s5_ar_id_rd_ptr <= s5_ar_id_rd_ptr + 1;
            if (s6_axi_rvalid && s6_axi_rready) s6_ar_id_rd_ptr <= s6_ar_id_rd_ptr + 1;
            if (s7_axi_rvalid && s7_axi_rready) s7_ar_id_rd_ptr <= s7_ar_id_rd_ptr + 1;
            if (s8_axi_rvalid && s8_axi_rready) s8_ar_id_rd_ptr <= s8_ar_id_rd_ptr + 1;
            if (s9_axi_rvalid && s9_axi_rready) s9_ar_id_rd_ptr <= s9_ar_id_rd_ptr + 1;
        end
    end

    // Decode error FIFO for unmapped read addresses
    assign decode_err_push = m_axi_arvalid && m_axi_arready &&
                            !(sel_s0_ar | sel_s1_ar | sel_s2_ar | sel_s3_ar | sel_s4_ar | sel_s5_ar | sel_s6_ar | sel_s7_ar | sel_s8_ar | sel_s9_ar);
    assign decode_err_pending = (decode_err_wr_ptr != decode_err_rd_ptr);
    // 1-cycle delay: only drive rvalid/pop after pending has been registered,
    // preventing the push and pop from firing in the same simulation delta cycle.
    // decode_err_valid is set when the FIFO becomes non-empty (registered) and
    // cleared immediately when the response handshake completes (pop fires).
    logic decode_err_valid;
    // A beat is accepted whenever decode_err is driving and rready is asserted
    assign decode_err_beat_accepted = decode_err_valid && m_axi_rready &&
                            !(s0_axi_rvalid | s1_axi_rvalid | s2_axi_rvalid | s3_axi_rvalid |
                              s4_axi_rvalid | s5_axi_rvalid | s6_axi_rvalid | s7_axi_rvalid |
                              s8_axi_rvalid | s9_axi_rvalid);
    // Pop the FIFO entry only after all arlen+1 beats have been delivered
    assign decode_err_pop = decode_err_beat_accepted &&
                            (decode_err_beat_cnt == decode_err_len_fifo[decode_err_rd_ptr[$clog2(DECODE_ERR_FIFO_DEPTH)-1:0]]);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            decode_err_valid <= 1'b0;
        else if (decode_err_pop)
            // After consuming this entry: remain valid if a second entry exists
            // (wr_ptr != rd_ptr+1) or if a new push arrived this same cycle.
            decode_err_valid <= (decode_err_wr_ptr != (decode_err_rd_ptr + 1'b1)) || decode_err_push;
        else
            // Set valid when FIFO becomes non-empty (1-cycle delay from push)
            decode_err_valid <= decode_err_pending;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            decode_err_wr_ptr  <= '0;
            decode_err_rd_ptr  <= '0;
            decode_err_beat_cnt <= '0;
        end else begin
            if (decode_err_push) begin
                decode_err_id_fifo [decode_err_wr_ptr[$clog2(DECODE_ERR_FIFO_DEPTH)-1:0]] <= m_axi_arid;
                decode_err_len_fifo[decode_err_wr_ptr[$clog2(DECODE_ERR_FIFO_DEPTH)-1:0]] <= m_axi_arlen;
                decode_err_wr_ptr <= decode_err_wr_ptr + 1;
            end
            if (decode_err_pop) begin
                decode_err_rd_ptr   <= decode_err_rd_ptr + 1;
                decode_err_beat_cnt <= '0;  // reset counter for next transaction
            end else if (decode_err_beat_accepted) begin
                decode_err_beat_cnt <= decode_err_beat_cnt + 8'h1;
            end
        end
    end

    // Write ID tracking - single register for in-order writes
    logic [axi_pkg::AXI_ID_WIDTH-1:0] w_id_reg;

    // Capture write ID during AW handshake
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_id_reg <= '0;
        end else begin
            // Capture ID when AW handshake occurs
            if (m_axi_awvalid && m_axi_awready) begin
                w_id_reg <= m_axi_awid;
                `DEBUG2(`DBG_GRP_AXI, ("[XBAR] AW captured id=%0d", m_axi_awid));
            end
        end
    end

`ifdef DEBUG
    // Read ID tracking for debug - tracks outstanding read transactions
    localparam int ID_FIFO_DEPTH = 16;
    logic [3:0] r_sel_next;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [axi_pkg::AXI_ID_WIDTH-1:0] r_id_fifo [0:ID_FIFO_DEPTH-1];
    logic [3:0] r_sel_fifo [0:ID_FIFO_DEPTH-1];
    logic [$clog2(ID_FIFO_DEPTH):0] r_id_wr_ptr;
    logic [$clog2(ID_FIFO_DEPTH):0] r_id_rd_ptr;
    logic [$clog2(ID_FIFO_DEPTH):0] r_fifo_count;
    /* verilator lint_on UNUSEDSIGNAL */

    // FIFO management for read IDs (debug only)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_id_wr_ptr <= '0;
            r_id_rd_ptr <= '0;
        end else begin
            // Push ID when AR handshake occurs
            if (m_axi_arvalid && m_axi_arready) begin
                r_id_fifo[r_id_wr_ptr[$clog2(ID_FIFO_DEPTH)-1:0]] <= m_axi_arid;
                r_sel_fifo[r_id_wr_ptr[$clog2(ID_FIFO_DEPTH)-1:0]] <= r_sel_next;
                r_id_wr_ptr <= r_id_wr_ptr + 1;
                `DEBUG2(`DBG_GRP_AXI, ("[XBAR] AR FIFO push id=%0d sel=%0d fifo_count=%0d->%0d", m_axi_arid, r_sel_next, r_id_wr_ptr - r_id_rd_ptr, r_id_wr_ptr + 1 - r_id_rd_ptr));
            end
            // Pop ID when R handshake occurs
            if (m_axi_rvalid && m_axi_rready) begin
                r_id_rd_ptr <= r_id_rd_ptr + 1;
                `DEBUG2(`DBG_GRP_AXI, ("[XBAR] R FIFO pop id=%0d fifo_count=%0d->%0d", m_axi_rid, r_id_wr_ptr - r_id_rd_ptr, r_id_wr_ptr - (r_id_rd_ptr + 1)));
            end
        end
    end

    assign r_fifo_count = r_id_wr_ptr - r_id_rd_ptr;
`endif // DEBUG

    // Write address decode
    always_comb begin
        sel_s0_aw = (m_axi_awaddr[31:21] == 11'h400);                                        // RAM
        sel_s1_aw = (m_axi_awaddr[31:16] == 16'h4000);                                       // Magic
        sel_s2_aw = (m_axi_awaddr[31:20] == 12'h020) && (m_axi_awaddr[19:18] != 2'b11);     // CLINT
        sel_s3_aw = (m_axi_awaddr[31:24] == 8'h0C);   // 0x0C00_0000 - 0x0CFF_FFFF (PLIC, 16 MB)
        sel_s4_aw = (m_axi_awaddr[31:16] == 16'h2000);    // 0x2000_0000 - 0x2000_FFFF (DMA, 64 KB)
        sel_s5_aw = (m_axi_awaddr[31:16] == 16'h2001);   // UART
        sel_s6_aw = (m_axi_awaddr[31:16] == 16'h2002);   // I2C
        sel_s7_aw = (m_axi_awaddr[31:16] == 16'h2003);   // SPI
        sel_s8_aw = (m_axi_awaddr[31:16] == 16'h2004);   // Timer/PWM
        sel_s9_aw = (m_axi_awaddr[31:16] == 16'h2005);   // GPIO
    end

    // Read address decode
    always_comb begin
        sel_s0_ar = (m_axi_araddr[31:21] == 11'h400);                                       // RAM
        sel_s1_ar = (m_axi_araddr[31:16] == 16'h4000);                                      // Magic
        sel_s2_ar = (m_axi_araddr[31:20] == 12'h020) && (m_axi_araddr[19:18] != 2'b11);     // CLINT
        sel_s3_ar = (m_axi_araddr[31:24] == 8'h0C);     // 0x0C00_0000 - 0x0CFF_FFFF (PLIC, 16 MB)
        sel_s4_ar = (m_axi_araddr[31:16] == 16'h2000);  // DMA (64 KB)
        sel_s5_ar = (m_axi_araddr[31:16] == 16'h2001);  // UART (64 KB)
        sel_s6_ar = (m_axi_araddr[31:16] == 16'h2002);  // I2C (64 KB)
        sel_s7_ar = (m_axi_araddr[31:16] == 16'h2003);  // SPI (64 KB)
        sel_s8_ar = (m_axi_araddr[31:16] == 16'h2004);  // Timer/PWM (64 KB)
        sel_s9_ar = (m_axi_araddr[31:16] == 16'h2005);  // GPIO (64 KB)
    end

    // Forward declarations needed by debug always block and W-channel routing below
    logic [3:0] w_sel;
    logic w_transaction_active;
    logic [3:0] active_w_dest;

    always_ff @(posedge clk) begin
        if (m_axi_arvalid) begin
            `DEBUG2(`DBG_GRP_AXI, ("[XBAR] AR: addr=0x%h sel=%b%b%b%b%b%b%b%b%b%b",
                m_axi_araddr, sel_s9_ar, sel_s8_ar, sel_s7_ar, sel_s6_ar, sel_s5_ar, sel_s4_ar, sel_s3_ar, sel_s2_ar, sel_s1_ar, sel_s0_ar));
        end
        if (m_axi_awvalid) begin
            `DEBUG2(`DBG_GRP_AXI, ("[XBAR] AW: addr=0x%h sel=%b%b%b%b%b%b%b%b%b%b awready=%b w_transaction_active=%b",
                m_axi_awaddr, sel_s9_aw, sel_s8_aw, sel_s7_aw, sel_s6_aw, sel_s5_aw, sel_s4_aw, sel_s3_aw, sel_s2_aw, sel_s1_aw, sel_s0_aw,
                m_axi_awready, w_transaction_active));
        end
    end

    // Write address channel routing
    logic [3:0] new_w_dest;              // Computed destination for incoming AW
    logic block_aw_different_dest;       // Block AW if W pending to different dest

    always_comb begin
        s0_axi_awaddr  = m_axi_awaddr;
        s0_axi_awlen   = m_axi_awlen;
        s0_axi_awsize  = m_axi_awsize;
        s0_axi_awburst = m_axi_awburst;
        s0_axi_awvalid = m_axi_awvalid && sel_s0_aw;

        s1_axi_awaddr  = m_axi_awaddr;
        s1_axi_awvalid = m_axi_awvalid && sel_s1_aw;

        s2_axi_awaddr  = m_axi_awaddr;
        s2_axi_awvalid = m_axi_awvalid && sel_s2_aw;

        s3_axi_awaddr  = m_axi_awaddr;
        s3_axi_awvalid = m_axi_awvalid && sel_s3_aw;

        s4_axi_awaddr  = m_axi_awaddr;
        s4_axi_awvalid = m_axi_awvalid && sel_s4_aw;

        s5_axi_awaddr  = m_axi_awaddr;
        s5_axi_awvalid = m_axi_awvalid && sel_s5_aw;

        s6_axi_awaddr  = m_axi_awaddr;
        s6_axi_awvalid = m_axi_awvalid && sel_s6_aw;

        s7_axi_awaddr  = m_axi_awaddr;
        s7_axi_awvalid = m_axi_awvalid && sel_s7_aw;

        s8_axi_awaddr  = m_axi_awaddr;
        s8_axi_awvalid = m_axi_awvalid && sel_s8_aw;

        s9_axi_awaddr  = m_axi_awaddr;
        s9_axi_awvalid = m_axi_awvalid && sel_s9_aw;

        // Compute new destination for this AW
        if (sel_s0_aw) new_w_dest = 4'd0;
        else if (sel_s1_aw) new_w_dest = 4'd1;
        else if (sel_s2_aw) new_w_dest = 4'd2;
        else if (sel_s3_aw) new_w_dest = 4'd3;
        else if (sel_s4_aw) new_w_dest = 4'd4;
        else if (sel_s5_aw) new_w_dest = 4'd5;
        else if (sel_s6_aw) new_w_dest = 4'd6;
        else if (sel_s7_aw) new_w_dest = 4'd7;
        else if (sel_s8_aw) new_w_dest = 4'd8;
        else if (sel_s9_aw) new_w_dest = 4'd9;
        else new_w_dest = 4'd10;

        // Block new AW if W is pending to a DIFFERENT destination AND transaction is active
        block_aw_different_dest = w_transaction_active && (m_axi_wvalid && !m_axi_wready) && (new_w_dest != w_sel);

        if (block_aw_different_dest) begin
            m_axi_awready = 1'b0;
        end else if (sel_s0_aw)
            m_axi_awready = s0_axi_awready;
        else if (sel_s1_aw)
            m_axi_awready = s1_axi_awready;
        else if (sel_s2_aw)
            m_axi_awready = s2_axi_awready;
        else if (sel_s3_aw)
            m_axi_awready = s3_axi_awready;
        else if (sel_s4_aw)
            m_axi_awready = s4_axi_awready;
        else if (sel_s5_aw)
            m_axi_awready = s5_axi_awready;
        else if (sel_s6_aw)
            m_axi_awready = s6_axi_awready;
        else if (sel_s7_aw)
            m_axi_awready = s7_axi_awready;
        else if (sel_s8_aw)
            m_axi_awready = s8_axi_awready;
        else if (sel_s9_aw)
            m_axi_awready = s9_axi_awready;
        else
            m_axi_awready = m_axi_wready;  // Decode error
    end

    // Write data channel routing
    // w_sel: declared earlier as forward declaration
    logic [3:0] w_sel_next;  // Next destination for incoming AW
    // w_transaction_active: declared earlier as forward declaration
    logic write_decode_err_w_done;   // Track if W data received for decode error

    // Compute next destination from current AW address
    always_comb begin
        if (sel_s0_aw)      w_sel_next = 4'd0;
        else if (sel_s1_aw) w_sel_next = 4'd1;
        else if (sel_s2_aw) w_sel_next = 4'd2;
        else if (sel_s3_aw) w_sel_next = 4'd3;
        else if (sel_s4_aw) w_sel_next = 4'd4;
        else if (sel_s5_aw) w_sel_next = 4'd5;
        else if (sel_s6_aw) w_sel_next = 4'd6;
        else if (sel_s7_aw) w_sel_next = 4'd7;
        else if (sel_s8_aw) w_sel_next = 4'd8;
        else if (sel_s9_aw) w_sel_next = 4'd9;
        else                w_sel_next = 4'd10;  // decode error
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_sel <= 4'd0;
            w_transaction_active <= 1'b0;
            write_decode_err_w_done <= 1'b0;
        end else begin
            // Handle simultaneous B-complete and new AW in one priority block
            // to avoid w_transaction_active being incorrectly cleared.
            if (m_axi_bvalid && m_axi_bready) begin
                // B response completing this cycle
                if (w_sel == 4'd10) begin
                    write_decode_err_w_done <= 1'b0;
                end
                if (m_axi_awvalid) begin
                    // Simultaneous: B completes AND new AW arrives —
                    // transition directly to new transaction (stay active).
                    w_sel <= w_sel_next;
                    w_transaction_active <= 1'b1;
                    `DEBUG2(`DBG_GRP_AXI, ("[XBAR] B+AW simultaneous: w_sel=%0d addr=0x%h", w_sel_next, m_axi_awaddr));
                    if (w_sel_next == 4'd10) begin
                        write_decode_err_w_done <= 1'b0;
                    end
                end else begin
                    w_transaction_active <= 1'b0;
                    `DEBUG2(`DBG_GRP_AXI, ("[XBAR] B complete, w_transaction_active cleared"));
                end
            end else if (m_axi_awvalid && !w_transaction_active) begin
                // New AW with no competing B this cycle
                w_sel <= w_sel_next;
                w_transaction_active <= 1'b1;
                `DEBUG2(`DBG_GRP_AXI, ("[XBAR] Captured w_sel=%0d from AW addr=0x%h", w_sel_next, m_axi_awaddr));
                if (w_sel_next == 4'd10) begin
                    write_decode_err_w_done <= 1'b0;
                end
            end

            // Track W data received for decode error
            if (m_axi_wvalid && m_axi_wready && active_w_dest == 4'd10) begin
                write_decode_err_w_done <= 1'b1;
            end
        end
    end

    // Use w_sel for W channel routing, but override with incoming AW destination
    // active_w_dest: declared earlier as forward declaration
    always_comb begin
        if (m_axi_awvalid && !w_transaction_active) begin
            active_w_dest = w_sel_next;
        end else begin
            active_w_dest = w_sel;
        end
    end

    always_ff @(posedge clk) begin
        if (m_axi_wvalid && m_axi_wready) begin
            `DEBUG2(`DBG_GRP_AXI, ("[XBAR] W handshake: w_sel=%0d active_w_dest=%0d",
                     w_sel, active_w_dest));
        end
    end

    // Write data channel routing
    always_comb begin
        s0_axi_wdata  = m_axi_wdata;
        s0_axi_wstrb  = m_axi_wstrb;
        s0_axi_wlast  = m_axi_wlast;
        s0_axi_wvalid = m_axi_wvalid && (active_w_dest == 4'd0);

        s1_axi_wdata  = m_axi_wdata;
        s1_axi_wstrb  = m_axi_wstrb;
        s1_axi_wvalid = m_axi_wvalid && (active_w_dest == 4'd1);

        s2_axi_wdata  = m_axi_wdata;
        s2_axi_wstrb  = m_axi_wstrb;
        s2_axi_wvalid = m_axi_wvalid && (active_w_dest == 4'd2);

        s3_axi_wdata  = m_axi_wdata;
        s3_axi_wstrb  = m_axi_wstrb;
        s3_axi_wvalid = m_axi_wvalid && (active_w_dest == 4'd3);

        s4_axi_wdata  = m_axi_wdata;
        s4_axi_wstrb  = m_axi_wstrb;
        s4_axi_wvalid = m_axi_wvalid && (active_w_dest == 4'd4);

        s5_axi_wdata  = m_axi_wdata;
        s5_axi_wstrb  = m_axi_wstrb;
        s5_axi_wvalid = m_axi_wvalid && (active_w_dest == 4'd5);

        s6_axi_wdata  = m_axi_wdata;
        s6_axi_wstrb  = m_axi_wstrb;
        s6_axi_wvalid = m_axi_wvalid && (active_w_dest == 4'd6);

        s7_axi_wdata  = m_axi_wdata;
        s7_axi_wstrb  = m_axi_wstrb;
        s7_axi_wvalid = m_axi_wvalid && (active_w_dest == 4'd7);

        s8_axi_wdata  = m_axi_wdata;
        s8_axi_wstrb  = m_axi_wstrb;
        s8_axi_wvalid = m_axi_wvalid && (active_w_dest == 4'd8);

        s9_axi_wdata  = m_axi_wdata;
        s9_axi_wstrb  = m_axi_wstrb;
        s9_axi_wvalid = m_axi_wvalid && (active_w_dest == 4'd9);

        case (active_w_dest)
            4'd0:    m_axi_wready = s0_axi_wready;
            4'd1:    m_axi_wready = s1_axi_wready;
            4'd2:    m_axi_wready = s2_axi_wready;
            4'd3:    m_axi_wready = s3_axi_wready;
            4'd4:    m_axi_wready = s4_axi_wready;
            4'd5:    m_axi_wready = s5_axi_wready;
            4'd6:    m_axi_wready = s6_axi_wready;
            4'd7:    m_axi_wready = s7_axi_wready;
            4'd8:    m_axi_wready = s8_axi_wready;
            4'd9:    m_axi_wready = s9_axi_wready;
            default: m_axi_wready = 1'b1;
        endcase
    end

    // Write response channel routing - Pass through master's ID (only M1 writes)
    always_comb begin
        s0_axi_bready = m_axi_bready && (w_sel == 4'd0);
        s1_axi_bready = m_axi_bready && (w_sel == 4'd1);
        s2_axi_bready = m_axi_bready && (w_sel == 4'd2);
        s3_axi_bready = m_axi_bready && (w_sel == 4'd3);
        s4_axi_bready = m_axi_bready && (w_sel == 4'd4);
        s5_axi_bready = m_axi_bready && (w_sel == 4'd5);
        s6_axi_bready = m_axi_bready && (w_sel == 4'd6);
        s7_axi_bready = m_axi_bready && (w_sel == 4'd7);
        s8_axi_bready = m_axi_bready && (w_sel == 4'd8);
        s9_axi_bready = m_axi_bready && (w_sel == 4'd9);

        m_axi_bid = w_id_reg;

        case (w_sel)
            4'd0: begin
                m_axi_bresp  = s0_axi_bresp;
                m_axi_bvalid = s0_axi_bvalid;
            end
            4'd1: begin
                m_axi_bresp  = s1_axi_bresp;
                m_axi_bvalid = s1_axi_bvalid;
            end
            4'd2: begin
                m_axi_bresp  = s2_axi_bresp;
                m_axi_bvalid = s2_axi_bvalid;
            end
            4'd3: begin
                m_axi_bresp  = s3_axi_bresp;
                m_axi_bvalid = s3_axi_bvalid;
            end
            4'd4: begin
                m_axi_bresp  = s4_axi_bresp;
                m_axi_bvalid = s4_axi_bvalid;
            end
            4'd5: begin
                m_axi_bresp  = s5_axi_bresp;
                m_axi_bvalid = s5_axi_bvalid;
            end
            4'd6: begin
                m_axi_bresp  = s6_axi_bresp;
                m_axi_bvalid = s6_axi_bvalid;
            end
            4'd7: begin
                m_axi_bresp  = s7_axi_bresp;
                m_axi_bvalid = s7_axi_bvalid;
            end
            4'd8: begin
                m_axi_bresp  = s8_axi_bresp;
                m_axi_bvalid = s8_axi_bvalid;
            end
            4'd9: begin
                m_axi_bresp  = s9_axi_bresp;
                m_axi_bvalid = s9_axi_bvalid;
            end
            default: begin
                m_axi_bresp  = 2'b11;  // DECERR
                m_axi_bvalid = write_decode_err_w_done;
            end
        endcase
    end

`ifndef SYNTHESIS
    // ── Lightweight write-transaction trace ──────────────────────────────────
    // Prints the last few AW/W/B transactions to diagnose missing B responses.
    // Active unconditionally (no DEBUG flag needed), shows transactions >= 1000.
    int unsigned xbar_aw_seq;
    int unsigned xbar_w_seq;
    int unsigned xbar_b_seq;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xbar_aw_seq <= 0;
            xbar_w_seq  <= 0;
            xbar_b_seq  <= 0;
        end else begin
            if (m_axi_awvalid && m_axi_awready) begin
                xbar_aw_seq <= xbar_aw_seq + 1;
                if (xbar_aw_seq >= 99999999)
                    $display("[XBAR_AW] #%0d addr=0x%h awlen=%0d id=0x%h w_sel_next=%0d",
                             xbar_aw_seq+1, m_axi_awaddr, m_axi_awlen, m_axi_awid, w_sel_next);
            end
            if (m_axi_wvalid && m_axi_wready) begin
                xbar_w_seq <= xbar_w_seq + 1;
                if (xbar_w_seq >= 99999999)
                    $display("[XBAR_W]  #%0d wlast=%b",
                             xbar_w_seq+1, m_axi_wlast);
            end
            if (m_axi_bvalid && m_axi_bready) begin
                xbar_b_seq <= xbar_b_seq + 1;
                if (xbar_b_seq >= 99999999)
                    $display("[XBAR_B]  #%0d", xbar_b_seq+1);
            end
        end
    end
`endif

    // Read address channel routing
    always_comb begin
        s0_axi_araddr  = m_axi_araddr;
        s0_axi_arlen   = m_axi_arlen;
        s0_axi_arsize  = m_axi_arsize;
        s0_axi_arburst = m_axi_arburst;
        s0_axi_arvalid = m_axi_arvalid && sel_s0_ar;

        s1_axi_araddr  = m_axi_araddr;
        s1_axi_arvalid = m_axi_arvalid && sel_s1_ar;

        s2_axi_araddr  = m_axi_araddr;
        s2_axi_arvalid = m_axi_arvalid && sel_s2_ar;

        s3_axi_araddr  = m_axi_araddr;
        s3_axi_arvalid = m_axi_arvalid && sel_s3_ar;

        s4_axi_araddr  = m_axi_araddr;
        s4_axi_arvalid = m_axi_arvalid && sel_s4_ar;

        s5_axi_araddr  = m_axi_araddr;
        s5_axi_arvalid = m_axi_arvalid && sel_s5_ar;

        s6_axi_araddr  = m_axi_araddr;
        s6_axi_arvalid = m_axi_arvalid && sel_s6_ar;

        s7_axi_araddr  = m_axi_araddr;
        s7_axi_arvalid = m_axi_arvalid && sel_s7_ar;

        s8_axi_araddr  = m_axi_araddr;
        s8_axi_arvalid = m_axi_arvalid && sel_s8_ar;

        s9_axi_araddr  = m_axi_araddr;
        s9_axi_arvalid = m_axi_arvalid && sel_s9_ar;

        if (sel_s0_ar)
            m_axi_arready = s0_axi_arready;
        else if (sel_s1_ar)
            m_axi_arready = s1_axi_arready;
        else if (sel_s2_ar)
            m_axi_arready = s2_axi_arready;
        else if (sel_s3_ar)
            m_axi_arready = s3_axi_arready;
        else if (sel_s4_ar)
            m_axi_arready = s4_axi_arready;
        else if (sel_s5_ar)
            m_axi_arready = s5_axi_arready;
        else if (sel_s6_ar)
            m_axi_arready = s6_axi_arready;
        else if (sel_s7_ar)
            m_axi_arready = s7_axi_arready;
        else if (sel_s8_ar)
            m_axi_arready = s8_axi_arready;
        else if (sel_s9_ar)
            m_axi_arready = s9_axi_arready;
        else
            m_axi_arready = 1'b1;  // Decode error
    end

`ifdef DEBUG
    // Determine which slave should respond for debug tracking
    always_comb begin
        if (sel_s0_ar)
            r_sel_next = 4'd0;
        else if (sel_s1_ar)
            r_sel_next = 4'd1;
        else if (sel_s2_ar)
            r_sel_next = 4'd2;
        else if (sel_s3_ar)
            r_sel_next = 4'd3;
        else if (sel_s4_ar)
            r_sel_next = 4'd4;
        else if (sel_s5_ar)
            r_sel_next = 4'd5;
        else if (sel_s6_ar)
            r_sel_next = 4'd6;
        else if (sel_s7_ar)
            r_sel_next = 4'd7;
        else if (sel_s8_ar)
            r_sel_next = 4'd8;
        else if (sel_s9_ar)
            r_sel_next = 4'd9;
        else
            r_sel_next = 4'd10;
    end
`endif // DEBUG

    // Read data channel routing
    // Route based on which slave has rvalid - priority encoder
    // Slaves manage their own outstanding transactions
    always_comb begin
        // Default: no slave selected
        s0_axi_rready = 1'b0;
        s1_axi_rready = 1'b0;
        s2_axi_rready = 1'b0;
        s3_axi_rready = 1'b0;
        s4_axi_rready = 1'b0;
        s5_axi_rready = 1'b0;
        s6_axi_rready = 1'b0;
        s7_axi_rready = 1'b0;
        s8_axi_rready = 1'b0;
        s9_axi_rready = 1'b0;

        m_axi_rdata  = 32'h0;
        m_axi_rresp  = 2'b00;
        m_axi_rid    = '0;
        m_axi_rlast  = 1'b0;
        m_axi_rvalid = 1'b0;

        //Priority encoder: route first slave with rvalid and return head of its ID FIFO
        if (s0_axi_rvalid) begin
            s0_axi_rready = m_axi_rready;
            m_axi_rdata   = s0_axi_rdata;
            m_axi_rresp   = s0_axi_rresp;
            m_axi_rlast   = s0_axi_rlast;
            m_axi_rvalid  = 1'b1;
            m_axi_rid     = s0_ar_id_fifo[s0_ar_id_rd_ptr[$clog2(AR_ID_FIFO_DEPTH)-1:0]];
        end else if (s1_axi_rvalid) begin
            s1_axi_rready = m_axi_rready;
            m_axi_rdata   = s1_axi_rdata;
            m_axi_rresp   = s1_axi_rresp;
            m_axi_rlast   = 1'b1;  // single-beat slaves always assert rlast
            m_axi_rvalid  = 1'b1;
            m_axi_rid     = s1_ar_id_fifo[s1_ar_id_rd_ptr[$clog2(AR_ID_FIFO_DEPTH)-1:0]];
        end else if (s2_axi_rvalid) begin
            s2_axi_rready = m_axi_rready;
            m_axi_rdata   = s2_axi_rdata;
            m_axi_rresp   = s2_axi_rresp;
            m_axi_rlast   = 1'b1;
            m_axi_rvalid  = 1'b1;
            m_axi_rid     = s2_ar_id_fifo[s2_ar_id_rd_ptr[$clog2(AR_ID_FIFO_DEPTH)-1:0]];
        end else if (s3_axi_rvalid) begin
            s3_axi_rready = m_axi_rready;
            m_axi_rdata   = s3_axi_rdata;
            m_axi_rresp = s3_axi_rresp;
            m_axi_rlast   = 1'b1;
            m_axi_rvalid  = 1'b1;
            m_axi_rid     = s3_ar_id_fifo[s3_ar_id_rd_ptr[$clog2(AR_ID_FIFO_DEPTH)-1:0]];
        end else if (s4_axi_rvalid) begin
            s4_axi_rready = m_axi_rready;
            m_axi_rdata   = s4_axi_rdata;
            m_axi_rresp   = s4_axi_rresp;
            m_axi_rlast   = 1'b1;
            m_axi_rvalid  = 1'b1;
            m_axi_rid     = s4_ar_id_fifo[s4_ar_id_rd_ptr[$clog2(AR_ID_FIFO_DEPTH)-1:0]];
        end else if (s5_axi_rvalid) begin
            s5_axi_rready = m_axi_rready;
            m_axi_rdata   = s5_axi_rdata;
            m_axi_rresp   = s5_axi_rresp;
            m_axi_rlast   = 1'b1;
            m_axi_rvalid  = 1'b1;
            m_axi_rid     = s5_ar_id_fifo[s5_ar_id_rd_ptr[$clog2(AR_ID_FIFO_DEPTH)-1:0]];
        end else if (s6_axi_rvalid) begin
            s6_axi_rready = m_axi_rready;
            m_axi_rdata   = s6_axi_rdata;
            m_axi_rresp   = s6_axi_rresp;
            m_axi_rlast   = 1'b1;
            m_axi_rvalid  = 1'b1;
            m_axi_rid     = s6_ar_id_fifo[s6_ar_id_rd_ptr[$clog2(AR_ID_FIFO_DEPTH)-1:0]];
        end else if (s7_axi_rvalid) begin
            s7_axi_rready = m_axi_rready;
            m_axi_rdata   = s7_axi_rdata;
            m_axi_rresp   = s7_axi_rresp;
            m_axi_rlast   = 1'b1;
            m_axi_rvalid  = 1'b1;
            m_axi_rid     = s7_ar_id_fifo[s7_ar_id_rd_ptr[$clog2(AR_ID_FIFO_DEPTH)-1:0]];
        end else if (s8_axi_rvalid) begin
            s8_axi_rready = m_axi_rready;
            m_axi_rdata   = s8_axi_rdata;
            m_axi_rresp   = s8_axi_rresp;
            m_axi_rlast   = 1'b1;
            m_axi_rvalid  = 1'b1;
            m_axi_rid     = s8_ar_id_fifo[s8_ar_id_rd_ptr[$clog2(AR_ID_FIFO_DEPTH)-1:0]];
        end else if (s9_axi_rvalid) begin
            s9_axi_rready = m_axi_rready;
            m_axi_rdata   = s9_axi_rdata;
            m_axi_rresp   = s9_axi_rresp;
            m_axi_rlast   = 1'b1;
            m_axi_rvalid  = 1'b1;
            m_axi_rid     = s9_ar_id_fifo[s9_ar_id_rd_ptr[$clog2(AR_ID_FIFO_DEPTH)-1:0]];
        end else if (decode_err_valid) begin
            // Generate decode error response for unmapped address.
            // Must send arlen+1 beats and assert RLAST only on the final beat
            // to comply with AXI4 burst protocol.
            m_axi_rdata   = 32'hDEADBEEF;  // Debug pattern for decode errors
            m_axi_rresp   = 2'b10;  // SLVERR
            m_axi_rlast   = (decode_err_beat_cnt == decode_err_len_fifo[decode_err_rd_ptr[$clog2(DECODE_ERR_FIFO_DEPTH)-1:0]]);
            m_axi_rvalid  = 1'b1;
            m_axi_rid     = decode_err_id_fifo[decode_err_rd_ptr[$clog2(DECODE_ERR_FIFO_DEPTH)-1:0]];
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

    // Master Write Address Channel
    property p_m_awvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (m_axi_awvalid && !m_axi_awready) |=> $stable(m_axi_awvalid);
    endproperty
    assert property (p_m_awvalid_stable)
        else $error("[AXI_XBAR] Master AWVALID must remain stable until AWREADY");

    property p_m_awaddr_stable;
        @(posedge clk) disable iff (!rst_n)
        (m_axi_awvalid && !m_axi_awready) |=> $stable(m_axi_awaddr);
    endproperty
    assert property (p_m_awaddr_stable)
        else $error("[AXI_XBAR] Master AWADDR must remain stable while AWVALID is high");

    property p_m_awid_stable;
        @(posedge clk) disable iff (!rst_n)
        (m_axi_awvalid && !m_axi_awready) |=> $stable(m_axi_awid);
    endproperty
    assert property (p_m_awid_stable)
        else $error("[AXI_XBAR] Master AWID must remain stable while AWVALID is high");

    // Master Write Data Channel
    property p_m_wvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (m_axi_wvalid && !m_axi_wready) |=> $stable(m_axi_wvalid);
    endproperty
    assert property (p_m_wvalid_stable)
        else $error("[AXI_XBAR] Master WVALID must remain stable until WREADY");

    property p_m_wdata_stable;
        @(posedge clk) disable iff (!rst_n)
        (m_axi_wvalid && !m_axi_wready) |=> $stable(m_axi_wdata);
    endproperty
    assert property (p_m_wdata_stable)
        else $error("[AXI_XBAR] Master WDATA must remain stable while WVALID is high");

    property p_m_wstrb_stable;
        @(posedge clk) disable iff (!rst_n)
        (m_axi_wvalid && !m_axi_wready) |=> $stable(m_axi_wstrb);
    endproperty
    assert property (p_m_wstrb_stable)
        else $error("[AXI_XBAR] Master WSTRB must remain stable while WVALID is high");

    // Master Read Address Channel
    property p_m_arvalid_stable;
        @(posedge clk) disable iff (!rst_n)
        (m_axi_arvalid && !m_axi_arready) |=> $stable(m_axi_arvalid);
    endproperty
    assert property (p_m_arvalid_stable)
        else $error("[AXI_XBAR] Master ARVALID must remain stable until ARREADY");

    property p_m_araddr_stable;
        @(posedge clk) disable iff (!rst_n)
        (m_axi_arvalid && !m_axi_arready) |=> $stable(m_axi_araddr);
    endproperty
    assert property (p_m_araddr_stable)
        else $error("[AXI_XBAR] Master ARADDR must remain stable while ARVALID is high");

    property p_m_arid_stable;
        @(posedge clk) disable iff (!rst_n)
        (m_axi_arvalid && !m_axi_arready) |=> $stable(m_axi_arid);
    endproperty
    assert property (p_m_arid_stable)
        else $error("[AXI_XBAR] Master ARID must remain stable while ARVALID is high");

    // X/Z Detection on Master Input Signals
    property p_m_no_x_awvalid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(m_axi_awvalid);
    endproperty
    assert property (p_m_no_x_awvalid)
        else $error("[AXI_XBAR] X/Z detected on master m_axi_awvalid");

    property p_m_no_x_wvalid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(m_axi_wvalid);
    endproperty
    assert property (p_m_no_x_wvalid)
        else $error("[AXI_XBAR] X/Z detected on master m_axi_wvalid");

    property p_m_no_x_arvalid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(m_axi_arvalid);
    endproperty
    assert property (p_m_no_x_arvalid)
        else $error("[AXI_XBAR] X/Z detected on master m_axi_arvalid");

    property p_m_no_x_bready;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(m_axi_bready);
    endproperty
    assert property (p_m_no_x_bready)
        else $error("[AXI_XBAR] X/Z detected on master m_axi_bready");

    property p_m_no_x_rready;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(m_axi_rready);
    endproperty
    assert property (p_m_no_x_rready)
        else $error("[AXI_XBAR] X/Z detected on master m_axi_rready");

    // Address Decode Correctness
    property p_address_decode_onehot;
        @(posedge clk) disable iff (!rst_n)
        (m_axi_awvalid) |-> $onehot0({sel_s0_aw, sel_s1_aw, sel_s2_aw, sel_s3_aw, sel_s4_aw, sel_s5_aw, sel_s6_aw, sel_s7_aw, sel_s8_aw, sel_s9_aw});
    endproperty
    assert property (p_address_decode_onehot)
        else $error("[AXI_XBAR] Write address decode must be one-hot or zero (decode error)");

    property p_read_decode_onehot;
        @(posedge clk) disable iff (!rst_n)
        (m_axi_arvalid) |-> $onehot0({sel_s0_ar, sel_s1_ar, sel_s2_ar, sel_s3_ar, sel_s4_ar, sel_s5_ar, sel_s6_ar, sel_s7_ar, sel_s8_ar, sel_s9_ar});
    endproperty
    assert property (p_read_decode_onehot)
        else $error("[AXI_XBAR] Read address decode must be one-hot or zero (decode error)");

`endif // ASSERTION

endmodule


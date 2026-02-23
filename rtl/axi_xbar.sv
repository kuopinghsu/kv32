// ============================================================================
// File: axi_xbar.sv
// Project: RV32 RISC-V Processor
// Description: AXI4 1-to-6 Crossbar (Interconnect)
//
// Routes AXI4 transactions from a single master to six slave devices:
//   - Slave 0: Main RAM       (0x8000_0000 - 0x9FFF_FFFF)
//   - Slave 1: CLINT Timer    (0x0200_0000 - 0x0200_FFFF)
//   - Slave 2: UART           (0x0201_0000 - 0x0201_FFFF)
//   - Slave 3: SPI            (0x0202_0000 - 0x0202_FFFF)
//   - Slave 4: I2C            (0x0203_0000 - 0x0203_FFFF)
//   - Slave 5: Magic Device   (0xFFFF_0000 - 0xFFFF_FFFF)
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
    input  logic                     m_axi_awvalid,
    output logic                     m_axi_awready,

    input  logic [31:0]              m_axi_wdata,
    input  logic [3:0]               m_axi_wstrb,
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

    // Slave 0: RAM (0x8000_0000 - 0x9FFF_FFFF)
    output logic [31:0] s0_axi_awaddr,
    output logic        s0_axi_awvalid,
    input  logic        s0_axi_awready,

    output logic [31:0] s0_axi_wdata,
    output logic [3:0]  s0_axi_wstrb,
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

    // Slave 1: CLINT (0x0200_0000 - 0x0200_FFFF)
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

    // Slave 2: UART (0x0201_0000 - 0x0201_FFFF)
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

    // Slave 3: SPI (0x0202_0000 - 0x0202_FFFF)
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

    // Slave 4: I2C (0x0203_0000 - 0x0203_FFFF)
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

    // Slave 5: Magic (0xFFFF_0000 - 0xFFFF_FFFF)
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
    output logic        s5_axi_rready
);

    // Address decode
    logic sel_s0, sel_s1, sel_s2, sel_s3, sel_s4, sel_s5;
    logic sel_s0_aw, sel_s1_aw, sel_s2_aw, sel_s3_aw, sel_s4_aw, sel_s5_aw;
    logic sel_s0_ar, sel_s1_ar, sel_s2_ar, sel_s3_ar, sel_s4_ar, sel_s5_ar;

    logic [2:0] r_sel_next;

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

    // Decode error handling for unmapped read addresses
    localparam int DECODE_ERR_FIFO_DEPTH = 8;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] decode_err_id_fifo [0:DECODE_ERR_FIFO_DEPTH-1];
    logic [$clog2(DECODE_ERR_FIFO_DEPTH):0] decode_err_wr_ptr;
    logic [$clog2(DECODE_ERR_FIFO_DEPTH):0] decode_err_rd_ptr;
    logic decode_err_pending;
    logic decode_err_push, decode_err_pop;

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
            // Pop: R handshake completes for each slave
            // Slave 0 may return multi-beat bursts – only pop FIFO on the last beat.
            if (s0_axi_rvalid && s0_axi_rready && s0_axi_rlast) s0_ar_id_rd_ptr <= s0_ar_id_rd_ptr + 1;
            if (s1_axi_rvalid && s1_axi_rready) s1_ar_id_rd_ptr <= s1_ar_id_rd_ptr + 1;
            if (s2_axi_rvalid && s2_axi_rready) s2_ar_id_rd_ptr <= s2_ar_id_rd_ptr + 1;
            if (s3_axi_rvalid && s3_axi_rready) s3_ar_id_rd_ptr <= s3_ar_id_rd_ptr + 1;
            if (s4_axi_rvalid && s4_axi_rready) s4_ar_id_rd_ptr <= s4_ar_id_rd_ptr + 1;
            if (s5_axi_rvalid && s5_axi_rready) s5_ar_id_rd_ptr <= s5_ar_id_rd_ptr + 1;
        end
    end

    // Decode error FIFO for unmapped read addresses
    assign decode_err_push = m_axi_arvalid && m_axi_arready &&
                            !(sel_s0_ar | sel_s1_ar | sel_s2_ar | sel_s3_ar | sel_s4_ar | sel_s5_ar);
    assign decode_err_pending = (decode_err_wr_ptr != decode_err_rd_ptr);
    assign decode_err_pop = decode_err_pending && m_axi_rready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            decode_err_wr_ptr <= '0;
            decode_err_rd_ptr <= '0;
        end else begin
            if (decode_err_push) begin
                decode_err_id_fifo[decode_err_wr_ptr[$clog2(DECODE_ERR_FIFO_DEPTH)-1:0]] <= m_axi_arid;
                decode_err_wr_ptr <= decode_err_wr_ptr + 1;
            end
            if (decode_err_pop) begin
                decode_err_rd_ptr <= decode_err_rd_ptr + 1;
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
                `DBG2(("XBAR: AW captured id=%0d", m_axi_awid));
            end
        end
    end

`ifdef DEBUG
    // Read ID tracking for debug - tracks outstanding read transactions
    localparam int ID_FIFO_DEPTH = 16;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] r_id_fifo [0:ID_FIFO_DEPTH-1];
    logic [2:0] r_sel_fifo [0:ID_FIFO_DEPTH-1];
    logic [$clog2(ID_FIFO_DEPTH):0] r_id_wr_ptr;
    logic [$clog2(ID_FIFO_DEPTH):0] r_id_rd_ptr;
    logic [$clog2(ID_FIFO_DEPTH):0] r_fifo_count;

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
                `DBG2(("XBAR: AR FIFO push id=%0d sel=%0d fifo_count=%0d->%0d", m_axi_arid, r_sel_next, r_id_wr_ptr - r_id_rd_ptr, r_id_wr_ptr + 1 - r_id_rd_ptr));
            end
            // Pop ID when R handshake occurs
            if (m_axi_rvalid && m_axi_rready) begin
                r_id_rd_ptr <= r_id_rd_ptr + 1;
                `DBG2(("XBAR: R FIFO pop id=%0d fifo_count=%0d->%0d", m_axi_rid, r_id_wr_ptr - r_id_rd_ptr, r_id_wr_ptr - (r_id_rd_ptr + 1)));
            end
        end
    end

    assign r_fifo_count = r_id_wr_ptr - r_id_rd_ptr;
`endif // DEBUG

    // Write address decode
    always_comb begin
        sel_s0_aw = (m_axi_awaddr[31:28] == 4'h8 || m_axi_awaddr[31:28] == 4'h9);
        sel_s1_aw = (m_axi_awaddr[31:16] == 16'h0200);
        sel_s2_aw = (m_axi_awaddr[31:16] == 16'h0201);
        sel_s3_aw = (m_axi_awaddr[31:16] == 16'h0202);
        sel_s4_aw = (m_axi_awaddr[31:16] == 16'h0203);
        sel_s5_aw = (m_axi_awaddr[31:16] == 16'hFFFF);
    end

    // Read address decode
    always_comb begin
        sel_s0_ar = (m_axi_araddr[31:28] == 4'h8 || m_axi_araddr[31:28] == 4'h9);
        sel_s1_ar = (m_axi_araddr[31:16] == 16'h0200);
        sel_s2_ar = (m_axi_araddr[31:16] == 16'h0201);
        sel_s3_ar = (m_axi_araddr[31:16] == 16'h0202);
        sel_s4_ar = (m_axi_araddr[31:16] == 16'h0203);
        sel_s5_ar = (m_axi_araddr[31:16] == 16'hFFFF);
    end

    always @(posedge clk) begin
        if (m_axi_arvalid) begin
            `DBG2(("[DEBUG] AXI_XBAR AR: addr=0x%h sel=%b%b%b%b%b%b",
                m_axi_araddr, sel_s5_ar, sel_s4_ar, sel_s3_ar, sel_s2_ar, sel_s1_ar, sel_s0_ar));
        end
        if (m_axi_awvalid) begin
            `DBG2(("[DEBUG] AXI_XBAR AW: addr=0x%h sel=%b%b%b%b%b%b awready=%b w_transaction_active=%b",
                m_axi_awaddr, sel_s5_aw, sel_s4_aw, sel_s3_aw, sel_s2_aw, sel_s1_aw, sel_s0_aw,
                m_axi_awready, w_transaction_active));
        end
    end

    // Write address channel routing
    logic [2:0] new_w_dest;              // Computed destination for incoming AW
    logic block_aw_different_dest;       // Block AW if W pending to different dest

    always_comb begin
        s0_axi_awaddr  = m_axi_awaddr;
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

        // Compute new destination for this AW
        if (sel_s0_aw) new_w_dest = 3'd0;
        else if (sel_s1_aw) new_w_dest = 3'd1;
        else if (sel_s2_aw) new_w_dest = 3'd2;
        else if (sel_s3_aw) new_w_dest = 3'd3;
        else if (sel_s4_aw) new_w_dest = 3'd4;
        else if (sel_s5_aw) new_w_dest = 3'd5;
        else new_w_dest = 3'd6;

        // Block new AW if W is pending to a DIFFERENT destination AND transaction is active
        // This prevents w_sel from changing while W is still active
        // But allow AW when starting a new transaction (!w_transaction_active)
        block_aw_different_dest = w_transaction_active && (m_axi_wvalid && !m_axi_wready) && (new_w_dest != w_sel);

        if (block_aw_different_dest) begin
            m_axi_awready = 1'b0;  // Block AW to different destination while W pending
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
        else
            // Decode error: wait for W to be ready too (keep AW/W synchronized)
            m_axi_awready = m_axi_wready;  // Only accept AW when W can also be accepted
    end

    // Write data channel routing
    logic [2:0] w_sel;
    logic [2:0] w_sel_next;  // Next destination for incoming AW
    logic w_transaction_active;  // Track if write transaction is in progress
    logic write_decode_err_pending;  // Track pending decode error write
    logic write_decode_err_w_done;   // Track if W data received for decode error

    // Compute next destination from current AW address
    always_comb begin
        if (sel_s0_aw)      w_sel_next = 3'd0;
        else if (sel_s1_aw) w_sel_next = 3'd1;
        else if (sel_s2_aw) w_sel_next = 3'd2;
        else if (sel_s3_aw) w_sel_next = 3'd3;
        else if (sel_s4_aw) w_sel_next = 3'd4;
        else if (sel_s5_aw) w_sel_next = 3'd5;
        else                w_sel_next = 3'd6;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_sel <= 3'd0;
            w_transaction_active <= 1'b0;
            write_decode_err_pending <= 1'b0;
            write_decode_err_w_done <= 1'b0;
        end else begin
            // Capture destination when new AW arrives and no transaction is active
            if (m_axi_awvalid && !w_transaction_active) begin
                w_sel <= w_sel_next;
                w_transaction_active <= 1'b1;
                `DBG2(("XBAR: Captured w_sel=%0d from AW addr=0x%h", w_sel_next, m_axi_awaddr));
                if (w_sel_next == 3'd6) begin
                    write_decode_err_pending <= 1'b1;
                    write_decode_err_w_done <= 1'b0;
                end
            end

            // Clear transaction flag when B response completes
            if (m_axi_bvalid && m_axi_bready) begin
                w_transaction_active <= 1'b0;
                `DBG2(("XBAR: B complete, w_transaction_active cleared"));
                if (w_sel == 3'd6) begin
                    write_decode_err_pending <= 1'b0;
                    write_decode_err_w_done <= 1'b0;
                end
            end

            // Track W data received for decode error
            // Use active_w_dest (which includes same-cycle AW->w_sel) so that
            // when AW and W arrive simultaneously the W is not missed.
            if (m_axi_wvalid && m_axi_wready && active_w_dest == 3'd6) begin
                write_decode_err_w_done <= 1'b1;
            end
        end
    end

    // Use w_sel for W channel routing, but override with incoming AW destination
    // This handles the case when AW and W arrive in the same cycle
    logic [2:0] active_w_dest;
    always_comb begin
        if (m_axi_awvalid && !w_transaction_active) begin
            // New transaction starting: use destination from incoming AW
            active_w_dest = w_sel_next;
        end else begin
            // Transaction in progress: use captured w_sel
            active_w_dest = w_sel;
        end
    end

    always @(posedge clk) begin
        if (m_axi_wvalid && m_axi_wready) begin
            `DBG2(("[DEBUG] XBAR W handshake: w_sel=%0d active_w_dest=%0d addr=0x%h",
                     w_sel, active_w_dest, (active_w_dest == 3'd5) ? 32'hFFFFFFFF : 32'h0));
        end
    end

    // Write data channel routing
    always_comb begin
        s0_axi_wdata  = m_axi_wdata;
        s0_axi_wstrb  = m_axi_wstrb;
        s0_axi_wvalid = m_axi_wvalid && (active_w_dest == 3'd0);

        s1_axi_wdata  = m_axi_wdata;
        s1_axi_wstrb  = m_axi_wstrb;
        s1_axi_wvalid = m_axi_wvalid && (active_w_dest == 3'd1);

        s2_axi_wdata  = m_axi_wdata;
        s2_axi_wstrb  = m_axi_wstrb;
        s2_axi_wvalid = m_axi_wvalid && (active_w_dest == 3'd2);

        s3_axi_wdata  = m_axi_wdata;
        s3_axi_wstrb  = m_axi_wstrb;
        s3_axi_wvalid = m_axi_wvalid && (active_w_dest == 3'd3);

        s4_axi_wdata  = m_axi_wdata;
        s4_axi_wstrb  = m_axi_wstrb;
        s4_axi_wvalid = m_axi_wvalid && (active_w_dest == 3'd4);

        s5_axi_wdata  = m_axi_wdata;
        s5_axi_wstrb  = m_axi_wstrb;
        s5_axi_wvalid = m_axi_wvalid && (active_w_dest == 3'd5);

        case (active_w_dest)
            3'd0:    m_axi_wready = s0_axi_wready;
            3'd1:    m_axi_wready = s1_axi_wready;
            3'd2:    m_axi_wready = s2_axi_wready;
            3'd3:    m_axi_wready = s3_axi_wready;
            3'd4:    m_axi_wready = s4_axi_wready;
            3'd5:    m_axi_wready = s5_axi_wready;
            default: m_axi_wready = 1'b1;
        endcase
    end

    // Write response channel routing - Pass through master's ID (only M1 writes)
    always_comb begin
        s0_axi_bready = m_axi_bready && (w_sel == 3'd0);
        s1_axi_bready = m_axi_bready && (w_sel == 3'd1);
        s2_axi_bready = m_axi_bready && (w_sel == 3'd2);
        s3_axi_bready = m_axi_bready && (w_sel == 3'd3);
        s4_axi_bready = m_axi_bready && (w_sel == 3'd4);
        s5_axi_bready = m_axi_bready && (w_sel == 3'd5);

        // Return write ID from captured register (captured during AW handshake)
        m_axi_bid = w_id_reg;

        case (w_sel)
            3'd0: begin
                m_axi_bresp  = s0_axi_bresp;
                m_axi_bvalid = s0_axi_bvalid;
            end
            3'd1: begin
                m_axi_bresp  = s1_axi_bresp;
                m_axi_bvalid = s1_axi_bvalid;
            end
            3'd2: begin
                m_axi_bresp  = s2_axi_bresp;
                m_axi_bvalid = s2_axi_bvalid;
            end
            3'd3: begin
                m_axi_bresp  = s3_axi_bresp;
                m_axi_bvalid = s3_axi_bvalid;
            end
            3'd4: begin
                m_axi_bresp  = s4_axi_bresp;
                m_axi_bvalid = s4_axi_bvalid;
            end
            3'd5: begin
                m_axi_bresp  = s5_axi_bresp;
                m_axi_bvalid = s5_axi_bvalid;
            end
            default: begin
                m_axi_bresp  = 2'b11;  // DECERR
                m_axi_bvalid = write_decode_err_w_done;  // Only respond after W data received
            end
        endcase
    end

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
        else
            m_axi_arready = 1'b1;  // Decode error
    end

    // Determine which slave should respond for debug tracking
    always_comb begin
        if (sel_s0_ar)
            r_sel_next = 3'd0;
        else if (sel_s1_ar)
            r_sel_next = 3'd1;
        else if (sel_s2_ar)
            r_sel_next = 3'd2;
        else if (sel_s3_ar)
            r_sel_next = 3'd3;
        else if (sel_s4_ar)
            r_sel_next = 3'd4;
        else if (sel_s5_ar)
            r_sel_next = 3'd5;
        else
            r_sel_next = 3'd6;
    end

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
            m_axi_rresp   = s3_axi_rresp;
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
        end else if (decode_err_pending) begin
            // Generate decode error response for unmapped address
            m_axi_rdata   = 32'hDEADBEEF;  // Debug pattern for decode errors
            m_axi_rresp   = 2'b10;  // SLVERR
            m_axi_rlast   = 1'b1;
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
        (m_axi_awvalid) |-> $onehot0({sel_s0_aw, sel_s1_aw, sel_s2_aw, sel_s3_aw, sel_s4_aw, sel_s5_aw});
    endproperty
    assert property (p_address_decode_onehot)
        else $error("[AXI_XBAR] Write address decode must be one-hot or zero (decode error)");

    property p_read_decode_onehot;
        @(posedge clk) disable iff (!rst_n)
        (m_axi_arvalid) |-> $onehot0({sel_s0_ar, sel_s1_ar, sel_s2_ar, sel_s3_ar, sel_s4_ar, sel_s5_ar});
    endproperty
    assert property (p_read_decode_onehot)
        else $error("[AXI_XBAR] Read address decode must be one-hot or zero (decode error)");

`endif // ASSERTION

endmodule

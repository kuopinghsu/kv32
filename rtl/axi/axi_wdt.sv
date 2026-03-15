// ============================================================================
// File: axi_wdt.sv
// Project: KV32 RISC-V Processor
// Description: AXI4-Lite Hardware Watchdog Timer (WDT)
//
// Counts down from the LOAD value each clock cycle while EN=1.
// When the counter reaches zero one of two actions fires based on INTR_EN:
//   INTR_EN=1 → Set STATUS[0] and assert IRQ (PLIC source KV_PLIC_SRC_WDT).
//              EN is kept set; COUNT latches at 0 until a KICK reload.
//              Firmware clears STATUS (W1C) and KICK-reloads COUNT to re-arm.
//   INTR_EN=0 → Assert wdt_reset_o (hardware reset request). EN is cleared.
//              System integrator connects wdt_reset_o to the system reset tree.
//
// Register Map (base 0x2006_0000):
//   0x00: CTRL    [0]=EN (1=running), [1]=INTR_EN (1=IRQ, 0=reset)
//   0x04: LOAD    Reload value (written before each start/kick)
//   0x08: COUNT   Current count (read-only)
//   0x0C: KICK    Write-only: reload count from LOAD (value written is ignored)
//   0x10: STATUS  [0]=WDT_INT (W1C – write 1 to clear)
//   0x14: CAP     Read-only: 0x0001_0020 (version 0.1, 32-bit counter)
//
// SLVERR is returned for offsets 0x18 and above (addr[4:3] == 2'b11).
//
// ============================================================================

/**
 * @brief AXI4-Lite Hardware Watchdog Timer.
 *
 * Provides a single-channel countdown watchdog with configurable expiry
 * action (interrupt or hardware reset).  PLIC-compatible IRQ output.
 *
 * @see kv_wdt.h, kv32_soc
 * @ingroup rtl
 */

module axi_wdt (
    input  logic        clk,
    input  logic        rst_n,

    // AXI4-Lite interface
    input  logic [31:0] axi_awaddr,
    input  logic        axi_awvalid,
    output logic        axi_awready,

    input  logic [31:0] axi_wdata,
    input  logic [3:0]  axi_wstrb,
    input  logic        axi_wvalid,
    output logic        axi_wready,

    output logic [1:0]  axi_bresp,
    output logic        axi_bvalid,
    input  logic        axi_bready,

    input  logic [31:0] axi_araddr,
    input  logic        axi_arvalid,
    output logic        axi_arready,

    output logic [31:0] axi_rdata,
    output logic [1:0]  axi_rresp,
    output logic        axi_rvalid,
    input  logic        axi_rready,

    // Interrupt output (PLIC source KV_PLIC_SRC_WDT)
    output logic        irq,

    // Hardware reset request output (asserted when WDT expires with INTR_EN=0).
    // Stays high until rst_n is asserted. System integrator feeds into reset tree.
    output logic        wdt_reset_o
);

    // Capability register: version 0.1, 32-bit counter
    localparam logic [31:0] WDT_CAP = 32'h0001_0020;

    // Address validity: SLVERR for offsets 0x18+ (addr[4:3] == 2'b11)
    wire wr_addr_valid = (axi_awaddr[4:3] != 2'b11);
    wire rd_addr_valid = (axi_araddr[4:3] != 2'b11);

    // ========================================================================
    // Registers
    // ========================================================================
    logic [1:0]  ctrl_r;      // [0]=EN, [1]=INTR_EN
    logic [31:0] load_r;      // Reload value
    logic [31:0] count_r;     // Current count (RO from AXI)
    logic        status_r;    // [0]=WDT_INT (W1C)
    logic        wdt_reset_r; // Latched reset request; cleared only by rst_n

    // ========================================================================
    // AXI handshake helpers
    // ========================================================================
    logic aw_hs, w_hs, ar_hs;
    assign aw_hs = axi_awvalid && axi_awready;
    assign w_hs  = axi_wvalid  && axi_wready;
    assign ar_hs = axi_arvalid && axi_arready;

    // ========================================================================
    // Register Write + Watchdog Countdown Logic
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_r      <= 2'h0;
            load_r      <= 32'h0;
            count_r     <= 32'h0;
            status_r    <= 1'b0;
            wdt_reset_r <= 1'b0;
        end else begin
            // ── Watchdog countdown (lower priority than AXI writes) ─────────
            if (ctrl_r[0]) begin  // EN=1
                if (count_r > 32'h1) begin
                    count_r <= count_r - 1;
                end else if (count_r == 32'h1) begin
                    // Expiry fires once on the 1->0 transition.
                    count_r <= 32'h0;
                    if (ctrl_r[1]) begin
                        // INTR_EN=1: assert interrupt; keep EN so KICK re-arms
                        status_r <= 1'b1;
                    end else begin
                        // INTR_EN=0: hardware reset mode — clear EN and latch reset
                        ctrl_r[0]   <= 1'b0;
                        wdt_reset_r <= 1'b1;
                    end
                end
            end

            // ── AXI writes (win over countdown changes on the same cycle) ───
            if (aw_hs && w_hs) begin
                case (axi_awaddr[4:2])
                    3'b000: ctrl_r   <= axi_wdata[1:0];        // CTRL
                    3'b001: load_r   <= axi_wdata;              // LOAD
                    // 3'b010 COUNT is read-only; writes silently ignored
                    3'b011: count_r  <= load_r;                 // KICK: reload
                    3'b100: status_r <= status_r & ~axi_wdata[0]; // STATUS W1C
                    // 3'b101 CAP is read-only; writes silently ignored
                    default: ;
                endcase
            end
        end
    end

    // ========================================================================
    // IRQ Output
    // ========================================================================
    assign irq = status_r & ctrl_r[1];

    // ========================================================================
    // AXI4-Lite Interface
    // ========================================================================
    // Write address and data arrive together
    assign axi_awready = axi_awvalid && axi_wvalid && !axi_bvalid;
    assign axi_wready  = axi_awvalid && axi_wvalid && !axi_bvalid;

    // Write response
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_bvalid <= 1'b0;
            axi_bresp  <= 2'b00;
        end else begin
            if (aw_hs && w_hs && !axi_bvalid) begin
                axi_bvalid <= 1'b1;
                axi_bresp  <= wr_addr_valid ? 2'b00 : 2'b10;  // OKAY or SLVERR
            end else if (axi_bready) begin
                axi_bvalid <= 1'b0;
            end
        end
    end

    // Read address
    assign axi_arready = axi_arvalid && !axi_rvalid;

    // Read data
    logic [31:0] rdata_next;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_rvalid <= 1'b0;
            axi_rdata  <= 32'h0;
            axi_rresp  <= 2'b00;
        end else begin
            if (ar_hs && !axi_rvalid) begin
                axi_rvalid <= 1'b1;
                axi_rdata  <= rdata_next;
                axi_rresp  <= rd_addr_valid ? 2'b00 : 2'b10;  // OKAY or SLVERR
            end else if (axi_rready) begin
                axi_rvalid <= 1'b0;
            end
        end
    end

    // ========================================================================
    // Register Read Logic
    // ========================================================================
    always_comb begin
        case (axi_araddr[4:2])
            3'b000:  rdata_next = {30'h0, ctrl_r};   // CTRL
            3'b001:  rdata_next = load_r;              // LOAD
            3'b010:  rdata_next = count_r;             // COUNT (RO)
            3'b011:  rdata_next = 32'h0;               // KICK (WO, reads 0)
            3'b100:  rdata_next = {31'h0, status_r};  // STATUS
            3'b101:  rdata_next = WDT_CAP;             // CAP (RO)
            default: rdata_next = 32'h0;
        endcase
    end

    // Hardware reset output: latches high when WDT expires in reset mode (INTR_EN=0).
    // Cleared only by rst_n; in hardware this feeds the system reset controller.
    assign wdt_reset_o = wdt_reset_r;

    // Tie off unused upper address bits and wstrb — WDT only decodes addr[4:2].
    logic _unused = &{1'b0, axi_awaddr[31:5], axi_awaddr[1:0],
                             axi_wstrb,
                             axi_araddr[31:5], axi_araddr[1:0]};

endmodule

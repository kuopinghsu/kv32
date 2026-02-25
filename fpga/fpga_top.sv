// ============================================================================
// File: fpga_top.sv
// Project: RV32 RISC-V Processor - FPGA Top Level
// Description: FPGA top-level for Kintex UltraScale+ (xcku5p-ffvb676-1-e)
//
// Architecture:
//   - 100MHz differential input clock → DDR4 MIG (internal MMCM)
//   - DDR4 MIG outputs ui_clk (300MHz) → MMCME4_ADV PLL → cpu_clk (50MHz)
//   - AXI clock converter (50MHz ↔ 300MHz) + data width converter (32b → 64b)
//   - rv32_soc running at 50MHz with AXI connected to DDR4
//
// Clock Domains:
//   - ui_clk    (300MHz): DDR4 AXI interface, AXI infrastructure
//   - cpu_clk   ( 50MHz): rv32_soc processor core
//
// Reset Sequence:
//   1. 100MHz differential clock starts
//   2. DDR4 MIG calibration (~1ms)
//   3. MMCM (PLL) locks, cpu_clk (50MHz) stable
//   4. CPU reset released
// ============================================================================

module fpga_top (
    // ========================================================================
    // System Clock & Reset
    // ========================================================================
    input  wire        sys_clk_p,          // 100MHz differential clock (positive)
    input  wire        sys_clk_n,          // 100MHz differential clock (negative)
    input  wire        sys_rst_n,          // Active-low board reset

    // ========================================================================
    // DDR4 SDRAM Interface (MT40A512M16HA-075E, 16-bit)
    // ========================================================================
    output wire        c0_ddr4_act_n,
    output wire [16:0] c0_ddr4_adr,
    output wire [1:0]  c0_ddr4_ba,
    output wire [0:0]  c0_ddr4_bg,
    output wire [0:0]  c0_ddr4_cke,
    output wire [0:0]  c0_ddr4_ck_t,
    output wire [0:0]  c0_ddr4_ck_c,
    output wire [0:0]  c0_ddr4_cs_n,
    inout  wire [15:0] c0_ddr4_dq,
    inout  wire [1:0]  c0_ddr4_dqs_t,
    inout  wire [1:0]  c0_ddr4_dqs_c,
    inout  wire [1:0]  c0_ddr4_dm_dbi_n,
    output wire [0:0]  c0_ddr4_odt,
    output wire        c0_ddr4_reset_n,

    // ========================================================================
    // UART
    // ========================================================================
    input  wire        uart_rx,
    output wire        uart_tx,

    // ========================================================================
    // SPI
    // ========================================================================
    output wire        spi_sclk,
    output wire        spi_mosi,
    input  wire        spi_miso,
    output wire [3:0]  spi_cs_n,

    // ========================================================================
    // I2C (directly expose separate signals; IOBUF for tri-state)
    // ========================================================================
    inout  wire        i2c_scl,
    inout  wire        i2c_sda,

    // ========================================================================
    // Status LEDs
    // ========================================================================
    output wire        led0                // DDR4 init calibration complete
);

    // ========================================================================
    // Parameters
    // ========================================================================
    localparam CPU_CLK_FREQ = 50_000_000;   // 50 MHz CPU clock
    localparam BAUD_RATE    = 115200;        // UART baud rate

    // ========================================================================
    // Internal Signals
    // ========================================================================

    // DDR4 MIG outputs
    wire        c0_ddr4_ui_clk;             // 300 MHz UI clock
    wire        c0_ddr4_ui_clk_sync_rst;    // Active-high reset, sync to ui_clk
    wire        c0_init_calib_complete;      // DDR4 calibration done

    // PLL (MMCM) signals
    wire        cpu_clk;                    // 50 MHz CPU clock
    wire        cpu_clk_mmcm;               // MMCM output (pre-BUFG)
    wire        mmcm_clkfb;                 // MMCM feedback
    wire        mmcm_clkfb_out;             // MMCM feedback output
    wire        mmcm_locked;                // MMCM lock indicator

    // Reset signals
    wire        cpu_rst_n;                  // Active-low CPU reset (sync to cpu_clk)
    wire        ui_rst_n;                   // Active-low AXI reset (sync to ui_clk)

    // I2C internal signals
    wire        i2c_scl_o, i2c_scl_i, i2c_scl_oe;
    wire        i2c_sda_o, i2c_sda_i, i2c_sda_oe;

    // rv32_soc AXI master signals (cpu_clk domain, 32-bit data)
    wire [31:0] soc_axi_awaddr;
    wire        soc_axi_awvalid;
    wire        soc_axi_awready;
    wire [31:0] soc_axi_wdata;
    wire [3:0]  soc_axi_wstrb;
    wire        soc_axi_wvalid;
    wire        soc_axi_wready;
    wire [1:0]  soc_axi_bresp;
    wire        soc_axi_bvalid;
    wire        soc_axi_bready;
    wire [31:0] soc_axi_araddr;
    wire        soc_axi_arvalid;
    wire        soc_axi_arready;
    wire [7:0]  soc_axi_arlen;
    wire [2:0]  soc_axi_arsize;
    wire [1:0]  soc_axi_arburst;
    wire [31:0] soc_axi_rdata;
    wire [1:0]  soc_axi_rresp;
    wire        soc_axi_rvalid;
    wire        soc_axi_rready;
    wire        soc_axi_rlast;

    // AXI clock converter output → AXI dwidth converter input (ui_clk domain, 32-bit)
    wire [3:0]  cdc_axi_awid;
    wire [31:0] cdc_axi_awaddr;
    wire [7:0]  cdc_axi_awlen;
    wire [2:0]  cdc_axi_awsize;
    wire [1:0]  cdc_axi_awburst;
    wire [0:0]  cdc_axi_awlock;
    wire [3:0]  cdc_axi_awcache;
    wire [2:0]  cdc_axi_awprot;
    wire [3:0]  cdc_axi_awqos;
    wire        cdc_axi_awvalid;
    wire        cdc_axi_awready;
    wire [31:0] cdc_axi_wdata;
    wire [3:0]  cdc_axi_wstrb;
    wire        cdc_axi_wlast;
    wire        cdc_axi_wvalid;
    wire        cdc_axi_wready;
    wire [3:0]  cdc_axi_bid;
    wire [1:0]  cdc_axi_bresp;
    wire        cdc_axi_bvalid;
    wire        cdc_axi_bready;
    wire [3:0]  cdc_axi_arid;
    wire [31:0] cdc_axi_araddr;
    wire [7:0]  cdc_axi_arlen;
    wire [2:0]  cdc_axi_arsize;
    wire [1:0]  cdc_axi_arburst;
    wire [0:0]  cdc_axi_arlock;
    wire [3:0]  cdc_axi_arcache;
    wire [2:0]  cdc_axi_arprot;
    wire [3:0]  cdc_axi_arqos;
    wire        cdc_axi_arvalid;
    wire        cdc_axi_arready;
    wire [3:0]  cdc_axi_rid;
    wire [31:0] cdc_axi_rdata;
    wire [1:0]  cdc_axi_rresp;
    wire        cdc_axi_rlast;
    wire        cdc_axi_rvalid;
    wire        cdc_axi_rready;

    // AXI dwidth converter output → DDR4 AXI slave (ui_clk domain, 64-bit)
    wire [3:0]  ddr4_s_axi_awid;
    wire [31:0] ddr4_s_axi_awaddr;
    wire [7:0]  ddr4_s_axi_awlen;
    wire [2:0]  ddr4_s_axi_awsize;
    wire [1:0]  ddr4_s_axi_awburst;
    wire [0:0]  ddr4_s_axi_awlock;
    wire [3:0]  ddr4_s_axi_awcache;
    wire [2:0]  ddr4_s_axi_awprot;
    wire [3:0]  ddr4_s_axi_awqos;
    wire        ddr4_s_axi_awvalid;
    wire        ddr4_s_axi_awready;
    wire [63:0] ddr4_s_axi_wdata;
    wire [7:0]  ddr4_s_axi_wstrb;
    wire        ddr4_s_axi_wlast;
    wire        ddr4_s_axi_wvalid;
    wire        ddr4_s_axi_wready;
    wire [3:0]  ddr4_s_axi_bid;
    wire [1:0]  ddr4_s_axi_bresp;
    wire        ddr4_s_axi_bvalid;
    wire        ddr4_s_axi_bready;
    wire [3:0]  ddr4_s_axi_arid;
    wire [31:0] ddr4_s_axi_araddr;
    wire [7:0]  ddr4_s_axi_arlen;
    wire [2:0]  ddr4_s_axi_arsize;
    wire [1:0]  ddr4_s_axi_arburst;
    wire [0:0]  ddr4_s_axi_arlock;
    wire [3:0]  ddr4_s_axi_arcache;
    wire [2:0]  ddr4_s_axi_arprot;
    wire [3:0]  ddr4_s_axi_arqos;
    wire        ddr4_s_axi_arvalid;
    wire        ddr4_s_axi_arready;
    wire [3:0]  ddr4_s_axi_rid;
    wire [63:0] ddr4_s_axi_rdata;
    wire [1:0]  ddr4_s_axi_rresp;
    wire        ddr4_s_axi_rlast;
    wire        ddr4_s_axi_rvalid;
    wire        ddr4_s_axi_rready;

    // Performance counters (unused in FPGA, leave unconnected)
    wire [63:0] cycle_count;
    wire [63:0] instret_count;
    wire [63:0] stall_count;
    wire [63:0] first_retire_cycle;
    wire [63:0] last_retire_cycle;

    // ========================================================================
    // LED Status
    // ========================================================================
    assign led0 = c0_init_calib_complete;

    // ========================================================================
    // I2C Tri-State Buffers (Open-Drain)
    // ========================================================================
    IOBUF u_i2c_scl_iobuf (
        .IO (i2c_scl),
        .I  (i2c_scl_o),
        .O  (i2c_scl_i),
        .T  (~i2c_scl_oe)
    );

    IOBUF u_i2c_sda_iobuf (
        .IO (i2c_sda),
        .I  (i2c_sda_o),
        .O  (i2c_sda_i),
        .T  (~i2c_sda_oe)
    );

    // ========================================================================
    // DDR4 MIG IP (ddr4_0)
    // ========================================================================
    // Takes 100MHz differential input, provides ui_clk (300MHz) and AXI slave.
    // AXI interface: 64-bit data, 32-bit address, 4-bit ID, running at ui_clk.
    ddr4_0 u_ddr4 (
        // System clock & reset
        .c0_sys_clk_p               (sys_clk_p),
        .c0_sys_clk_n               (sys_clk_n),
        .sys_rst                    (~sys_rst_n),           // Active-high

        // DDR4 PHY interface
        .c0_ddr4_act_n              (c0_ddr4_act_n),
        .c0_ddr4_adr                (c0_ddr4_adr),
        .c0_ddr4_ba                 (c0_ddr4_ba),
        .c0_ddr4_bg                 (c0_ddr4_bg),
        .c0_ddr4_cke                (c0_ddr4_cke),
        .c0_ddr4_ck_t               (c0_ddr4_ck_t),
        .c0_ddr4_ck_c               (c0_ddr4_ck_c),
        .c0_ddr4_cs_n               (c0_ddr4_cs_n),
        .c0_ddr4_dq                 (c0_ddr4_dq),
        .c0_ddr4_dqs_t              (c0_ddr4_dqs_t),
        .c0_ddr4_dqs_c              (c0_ddr4_dqs_c),
        .c0_ddr4_dm_dbi_n           (c0_ddr4_dm_dbi_n),
        .c0_ddr4_odt                (c0_ddr4_odt),
        .c0_ddr4_reset_n            (c0_ddr4_reset_n),

        // UI clock & reset
        .c0_ddr4_ui_clk             (c0_ddr4_ui_clk),
        .c0_ddr4_ui_clk_sync_rst    (c0_ddr4_ui_clk_sync_rst),
        .c0_init_calib_complete     (c0_init_calib_complete),

        // AXI reset (active-low)
        .c0_ddr4_aresetn            (ui_rst_n),

        // AXI4 Slave Interface (64-bit, ui_clk domain)
        .c0_ddr4_s_axi_awid         (ddr4_s_axi_awid),
        .c0_ddr4_s_axi_awaddr       (ddr4_s_axi_awaddr),
        .c0_ddr4_s_axi_awlen        (ddr4_s_axi_awlen),
        .c0_ddr4_s_axi_awsize       (ddr4_s_axi_awsize),
        .c0_ddr4_s_axi_awburst      (ddr4_s_axi_awburst),
        .c0_ddr4_s_axi_awlock       (ddr4_s_axi_awlock),
        .c0_ddr4_s_axi_awcache      (ddr4_s_axi_awcache),
        .c0_ddr4_s_axi_awprot       (ddr4_s_axi_awprot),
        .c0_ddr4_s_axi_awqos        (ddr4_s_axi_awqos),
        .c0_ddr4_s_axi_awvalid      (ddr4_s_axi_awvalid),
        .c0_ddr4_s_axi_awready      (ddr4_s_axi_awready),
        .c0_ddr4_s_axi_wdata        (ddr4_s_axi_wdata),
        .c0_ddr4_s_axi_wstrb        (ddr4_s_axi_wstrb),
        .c0_ddr4_s_axi_wlast        (ddr4_s_axi_wlast),
        .c0_ddr4_s_axi_wvalid       (ddr4_s_axi_wvalid),
        .c0_ddr4_s_axi_wready       (ddr4_s_axi_wready),
        .c0_ddr4_s_axi_bid          (ddr4_s_axi_bid),
        .c0_ddr4_s_axi_bresp        (ddr4_s_axi_bresp),
        .c0_ddr4_s_axi_bvalid       (ddr4_s_axi_bvalid),
        .c0_ddr4_s_axi_bready       (ddr4_s_axi_bready),
        .c0_ddr4_s_axi_arid         (ddr4_s_axi_arid),
        .c0_ddr4_s_axi_araddr       (ddr4_s_axi_araddr),
        .c0_ddr4_s_axi_arlen        (ddr4_s_axi_arlen),
        .c0_ddr4_s_axi_arsize       (ddr4_s_axi_arsize),
        .c0_ddr4_s_axi_arburst      (ddr4_s_axi_arburst),
        .c0_ddr4_s_axi_arlock       (ddr4_s_axi_arlock),
        .c0_ddr4_s_axi_arcache      (ddr4_s_axi_arcache),
        .c0_ddr4_s_axi_arprot       (ddr4_s_axi_arprot),
        .c0_ddr4_s_axi_arqos        (ddr4_s_axi_arqos),
        .c0_ddr4_s_axi_arvalid      (ddr4_s_axi_arvalid),
        .c0_ddr4_s_axi_arready      (ddr4_s_axi_arready),
        .c0_ddr4_s_axi_rid          (ddr4_s_axi_rid),
        .c0_ddr4_s_axi_rdata        (ddr4_s_axi_rdata),
        .c0_ddr4_s_axi_rresp        (ddr4_s_axi_rresp),
        .c0_ddr4_s_axi_rlast        (ddr4_s_axi_rlast),
        .c0_ddr4_s_axi_rvalid       (ddr4_s_axi_rvalid),
        .c0_ddr4_s_axi_rready       (ddr4_s_axi_rready)
    );

    // ========================================================================
    // PLL (MMCME4_ADV) - 300MHz (ui_clk) → 50MHz (cpu_clk)
    // ========================================================================
    // VCO = 300 MHz × 4 = 1200 MHz (range: 800–1600 MHz for KU5P)
    // CLKOUT0 = 1200 / 24 = 50 MHz
    MMCME4_ADV #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLKFBOUT_MULT_F    (4.0),          // VCO = 300 × 4 = 1200 MHz
        .CLKFBOUT_PHASE     (0.0),
        .CLKIN1_PERIOD       (3.333),        // 300 MHz input
        .CLKOUT0_DIVIDE_F   (24.0),         // 1200 / 24 = 50 MHz
        .CLKOUT0_DUTY_CYCLE (0.5),
        .CLKOUT0_PHASE      (0.0),
        .DIVCLK_DIVIDE      (1),
        .STARTUP_WAIT       ("FALSE")
    ) u_mmcm (
        // Clock inputs
        .CLKIN1     (c0_ddr4_ui_clk),
        .CLKIN2     (1'b0),
        .CLKINSEL   (1'b1),                 // Select CLKIN1

        // Feedback
        .CLKFBIN    (mmcm_clkfb),
        .CLKFBOUT   (mmcm_clkfb_out),
        .CLKFBOUTB  (),

        // Clock outputs
        .CLKOUT0    (cpu_clk_mmcm),
        .CLKOUT0B   (),
        .CLKOUT1    (), .CLKOUT1B   (),
        .CLKOUT2    (), .CLKOUT2B   (),
        .CLKOUT3    (), .CLKOUT3B   (),
        .CLKOUT4    (),
        .CLKOUT5    (),
        .CLKOUT6    (),

        // Status
        .LOCKED     (mmcm_locked),
        .CLKFBSTOPPED (),
        .CLKINSTOPPED (),

        // Control
        .PWRDWN     (1'b0),
        .RST        (c0_ddr4_ui_clk_sync_rst),

        // DRP (unused)
        .DADDR      (7'h0),
        .DCLK       (1'b0),
        .DEN        (1'b0),
        .DI         (16'h0),
        .DO         (),
        .DRDY       (),
        .DWE        (1'b0),

        // Phase shift (unused)
        .PSCLK      (1'b0),
        .PSEN       (1'b0),
        .PSINCDEC   (1'b0),
        .PSDONE     (),

        // CDC request (unused)
        .CDDCREQ    (1'b0),
        .CDDCDONE   ()
    );

    // BUFG for CPU clock
    BUFGCE u_bufg_cpu_clk (
        .I  (cpu_clk_mmcm),
        .CE (1'b1),
        .O  (cpu_clk)
    );

    // BUFG for MMCM feedback
    BUFG u_bufg_fb (
        .I  (mmcm_clkfb_out),
        .O  (mmcm_clkfb)
    );

    // ========================================================================
    // Reset Logic
    // ========================================================================

    // UI clock domain reset (active-low)
    // Released when DDR4 calibration complete and no sync reset
    assign ui_rst_n = ~c0_ddr4_ui_clk_sync_rst & c0_init_calib_complete;

    // CPU clock domain reset synchronizer (active-low)
    // Released when: MMCM locked AND DDR4 calibrated AND board reset deasserted
    wire cpu_rst_n_pre = mmcm_locked & c0_init_calib_complete & sys_rst_n;

    reg [3:0] cpu_rst_sync;
    always_ff @(posedge cpu_clk or negedge cpu_rst_n_pre) begin
        if (!cpu_rst_n_pre)
            cpu_rst_sync <= 4'b0000;
        else
            cpu_rst_sync <= {cpu_rst_sync[2:0], 1'b1};
    end
    assign cpu_rst_n = cpu_rst_sync[3];

    // ========================================================================
    // RV32 SoC
    // ========================================================================
    rv32_soc #(
        .CLK_FREQ   (CPU_CLK_FREQ),
        .BAUD_RATE  (BAUD_RATE),
        .IB_DEPTH   (4),
        .SB_DEPTH   (2),
        .FAST_MUL   (1),
        .FAST_DIV   (0),               // Use serial divider for better timing at 50MHz
        .ICACHE_EN  (1),
        .ICACHE_SIZE(4096),
        .ICACHE_LINE_SIZE(32),
        .ICACHE_WAYS(2)
    ) u_rv32_soc (
        .clk                (cpu_clk),
        .rst_n              (cpu_rst_n),

        // UART
        .uart_rx            (uart_rx),
        .uart_tx            (uart_tx),

        // SPI
        .spi_sclk           (spi_sclk),
        .spi_mosi           (spi_mosi),
        .spi_miso           (spi_miso),
        .spi_cs_n           (spi_cs_n),

        // I2C
        .i2c_scl_o          (i2c_scl_o),
        .i2c_scl_i          (i2c_scl_i),
        .i2c_scl_oe         (i2c_scl_oe),
        .i2c_sda_o          (i2c_sda_o),
        .i2c_sda_i          (i2c_sda_i),
        .i2c_sda_oe         (i2c_sda_oe),

        // External AXI master (to DDR4 via CDC + dwidth converter)
        .m_axi_awaddr       (soc_axi_awaddr),
        .m_axi_awvalid      (soc_axi_awvalid),
        .m_axi_awready      (soc_axi_awready),
        .m_axi_wdata        (soc_axi_wdata),
        .m_axi_wstrb        (soc_axi_wstrb),
        .m_axi_wvalid       (soc_axi_wvalid),
        .m_axi_wready       (soc_axi_wready),
        .m_axi_bresp        (soc_axi_bresp),
        .m_axi_bvalid       (soc_axi_bvalid),
        .m_axi_bready       (soc_axi_bready),
        .m_axi_araddr       (soc_axi_araddr),
        .m_axi_arvalid      (soc_axi_arvalid),
        .m_axi_arready      (soc_axi_arready),
        .m_axi_arlen        (soc_axi_arlen),
        .m_axi_arsize       (soc_axi_arsize),
        .m_axi_arburst      (soc_axi_arburst),
        .m_axi_rdata        (soc_axi_rdata),
        .m_axi_rresp        (soc_axi_rresp),
        .m_axi_rvalid       (soc_axi_rvalid),
        .m_axi_rready       (soc_axi_rready),
        .m_axi_rlast        (soc_axi_rlast),

        // Performance counters (unused in FPGA)
        .cycle_count        (cycle_count),
        .instret_count      (instret_count),
        .stall_count        (stall_count),
        .first_retire_cycle (first_retire_cycle),
        .last_retire_cycle  (last_retire_cycle)
    );

    // ========================================================================
    // AXI Clock Converter (axi_clock_converter_0)
    // ========================================================================
    // Bridges cpu_clk (50MHz) ↔ ui_clk (300MHz), 32-bit data, 4-bit ID.
    // rv32_soc doesn't have AXI ID/burst signals on writes; tie them off.
    axi_clock_converter_0 u_axi_cdc (
        // Slave interface (cpu_clk domain, from rv32_soc)
        .s_axi_aclk     (cpu_clk),
        .s_axi_aresetn  (cpu_rst_n),

        .s_axi_awid     (4'b0),
        .s_axi_awaddr   (soc_axi_awaddr),
        .s_axi_awlen    (8'h0),                 // Single-beat writes
        .s_axi_awsize   (3'b010),               // 4 bytes
        .s_axi_awburst  (2'b01),                // INCR
        .s_axi_awlock   (1'b0),
        .s_axi_awcache  (4'b0011),              // Normal non-cacheable bufferable
        .s_axi_awprot   (3'b000),
        .s_axi_awregion (4'b0),
        .s_axi_awqos    (4'b0),
        .s_axi_awvalid  (soc_axi_awvalid),
        .s_axi_awready  (soc_axi_awready),

        .s_axi_wdata    (soc_axi_wdata),
        .s_axi_wstrb    (soc_axi_wstrb),
        .s_axi_wlast    (1'b1),                 // Always last (single beat)
        .s_axi_wvalid   (soc_axi_wvalid),
        .s_axi_wready   (soc_axi_wready),

        .s_axi_bid      (),                     // Unused (single master)
        .s_axi_bresp    (soc_axi_bresp),
        .s_axi_bvalid   (soc_axi_bvalid),
        .s_axi_bready   (soc_axi_bready),

        .s_axi_arid     (4'b0),
        .s_axi_araddr   (soc_axi_araddr),
        .s_axi_arlen    (soc_axi_arlen),         // Burst reads (icache)
        .s_axi_arsize   (soc_axi_arsize),
        .s_axi_arburst  (soc_axi_arburst),
        .s_axi_arlock   (1'b0),
        .s_axi_arcache  (4'b0011),
        .s_axi_arprot   (3'b000),
        .s_axi_arregion (4'b0),
        .s_axi_arqos    (4'b0),
        .s_axi_arvalid  (soc_axi_arvalid),
        .s_axi_arready  (soc_axi_arready),

        .s_axi_rid      (),                     // Unused
        .s_axi_rdata    (soc_axi_rdata),
        .s_axi_rresp    (soc_axi_rresp),
        .s_axi_rlast    (soc_axi_rlast),
        .s_axi_rvalid   (soc_axi_rvalid),
        .s_axi_rready   (soc_axi_rready),

        // Master interface (ui_clk domain, to dwidth converter)
        .m_axi_aclk     (c0_ddr4_ui_clk),
        .m_axi_aresetn  (ui_rst_n),

        .m_axi_awid     (cdc_axi_awid),
        .m_axi_awaddr   (cdc_axi_awaddr),
        .m_axi_awlen    (cdc_axi_awlen),
        .m_axi_awsize   (cdc_axi_awsize),
        .m_axi_awburst  (cdc_axi_awburst),
        .m_axi_awlock   (cdc_axi_awlock),
        .m_axi_awcache  (cdc_axi_awcache),
        .m_axi_awprot   (cdc_axi_awprot),
        .m_axi_awregion (),
        .m_axi_awqos    (cdc_axi_awqos),
        .m_axi_awvalid  (cdc_axi_awvalid),
        .m_axi_awready  (cdc_axi_awready),

        .m_axi_wdata    (cdc_axi_wdata),
        .m_axi_wstrb    (cdc_axi_wstrb),
        .m_axi_wlast    (cdc_axi_wlast),
        .m_axi_wvalid   (cdc_axi_wvalid),
        .m_axi_wready   (cdc_axi_wready),

        .m_axi_bid      (cdc_axi_bid),
        .m_axi_bresp    (cdc_axi_bresp),
        .m_axi_bvalid   (cdc_axi_bvalid),
        .m_axi_bready   (cdc_axi_bready),

        .m_axi_arid     (cdc_axi_arid),
        .m_axi_araddr   (cdc_axi_araddr),
        .m_axi_arlen    (cdc_axi_arlen),
        .m_axi_arsize   (cdc_axi_arsize),
        .m_axi_arburst  (cdc_axi_arburst),
        .m_axi_arlock   (cdc_axi_arlock),
        .m_axi_arcache  (cdc_axi_arcache),
        .m_axi_arprot   (cdc_axi_arprot),
        .m_axi_arregion (),
        .m_axi_arqos    (cdc_axi_arqos),
        .m_axi_arvalid  (cdc_axi_arvalid),
        .m_axi_arready  (cdc_axi_arready),

        .m_axi_rid      (cdc_axi_rid),
        .m_axi_rdata    (cdc_axi_rdata),
        .m_axi_rresp    (cdc_axi_rresp),
        .m_axi_rlast    (cdc_axi_rlast),
        .m_axi_rvalid   (cdc_axi_rvalid),
        .m_axi_rready   (cdc_axi_rready)
    );

    // ========================================================================
    // AXI Data Width Converter (axi_dwidth_converter_0)
    // ========================================================================
    // Converts 32-bit AXI data to 64-bit for DDR4 MIG.
    // Runs entirely in ui_clk (300MHz) domain.
    axi_dwidth_converter_0 u_axi_dw (
        .s_axi_aclk     (c0_ddr4_ui_clk),
        .s_axi_aresetn  (ui_rst_n),

        // Slave interface (32-bit, from clock converter)
        .s_axi_awid     (cdc_axi_awid),
        .s_axi_awaddr   (cdc_axi_awaddr),
        .s_axi_awlen    (cdc_axi_awlen),
        .s_axi_awsize   (cdc_axi_awsize),
        .s_axi_awburst  (cdc_axi_awburst),
        .s_axi_awlock   (cdc_axi_awlock),
        .s_axi_awcache  (cdc_axi_awcache),
        .s_axi_awprot   (cdc_axi_awprot),
        .s_axi_awqos    (cdc_axi_awqos),
        .s_axi_awvalid  (cdc_axi_awvalid),
        .s_axi_awready  (cdc_axi_awready),

        .s_axi_wdata    (cdc_axi_wdata),
        .s_axi_wstrb    (cdc_axi_wstrb),
        .s_axi_wlast    (cdc_axi_wlast),
        .s_axi_wvalid   (cdc_axi_wvalid),
        .s_axi_wready   (cdc_axi_wready),

        .s_axi_bid      (cdc_axi_bid),
        .s_axi_bresp    (cdc_axi_bresp),
        .s_axi_bvalid   (cdc_axi_bvalid),
        .s_axi_bready   (cdc_axi_bready),

        .s_axi_arid     (cdc_axi_arid),
        .s_axi_araddr   (cdc_axi_araddr),
        .s_axi_arlen    (cdc_axi_arlen),
        .s_axi_arsize   (cdc_axi_arsize),
        .s_axi_arburst  (cdc_axi_arburst),
        .s_axi_arlock   (cdc_axi_arlock),
        .s_axi_arcache  (cdc_axi_arcache),
        .s_axi_arprot   (cdc_axi_arprot),
        .s_axi_arqos    (cdc_axi_arqos),
        .s_axi_arvalid  (cdc_axi_arvalid),
        .s_axi_arready  (cdc_axi_arready),

        .s_axi_rid      (cdc_axi_rid),
        .s_axi_rdata    (cdc_axi_rdata),
        .s_axi_rresp    (cdc_axi_rresp),
        .s_axi_rlast    (cdc_axi_rlast),
        .s_axi_rvalid   (cdc_axi_rvalid),
        .s_axi_rready   (cdc_axi_rready),

        // Master interface (64-bit, to DDR4 MIG)
        .m_axi_awid     (ddr4_s_axi_awid),
        .m_axi_awaddr   (ddr4_s_axi_awaddr),
        .m_axi_awlen    (ddr4_s_axi_awlen),
        .m_axi_awsize   (ddr4_s_axi_awsize),
        .m_axi_awburst  (ddr4_s_axi_awburst),
        .m_axi_awlock   (ddr4_s_axi_awlock),
        .m_axi_awcache  (ddr4_s_axi_awcache),
        .m_axi_awprot   (ddr4_s_axi_awprot),
        .m_axi_awqos    (ddr4_s_axi_awqos),
        .m_axi_awvalid  (ddr4_s_axi_awvalid),
        .m_axi_awready  (ddr4_s_axi_awready),

        .m_axi_wdata    (ddr4_s_axi_wdata),
        .m_axi_wstrb    (ddr4_s_axi_wstrb),
        .m_axi_wlast    (ddr4_s_axi_wlast),
        .m_axi_wvalid   (ddr4_s_axi_wvalid),
        .m_axi_wready   (ddr4_s_axi_wready),

        .m_axi_bid      (ddr4_s_axi_bid),
        .m_axi_bresp    (ddr4_s_axi_bresp),
        .m_axi_bvalid   (ddr4_s_axi_bvalid),
        .m_axi_bready   (ddr4_s_axi_bready),

        .m_axi_arid     (ddr4_s_axi_arid),
        .m_axi_araddr   (ddr4_s_axi_araddr),
        .m_axi_arlen    (ddr4_s_axi_arlen),
        .m_axi_arsize   (ddr4_s_axi_arsize),
        .m_axi_arburst  (ddr4_s_axi_arburst),
        .m_axi_arlock   (ddr4_s_axi_arlock),
        .m_axi_arcache  (ddr4_s_axi_arcache),
        .m_axi_arprot   (ddr4_s_axi_arprot),
        .m_axi_arqos    (ddr4_s_axi_arqos),
        .m_axi_arvalid  (ddr4_s_axi_arvalid),
        .m_axi_arready  (ddr4_s_axi_arready),

        .m_axi_rid      (ddr4_s_axi_rid),
        .m_axi_rdata    (ddr4_s_axi_rdata),
        .m_axi_rresp    (ddr4_s_axi_rresp),
        .m_axi_rlast    (ddr4_s_axi_rlast),
        .m_axi_rvalid   (ddr4_s_axi_rvalid),
        .m_axi_rready   (ddr4_s_axi_rready)
    );

endmodule

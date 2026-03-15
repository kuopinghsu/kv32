module axi_top #(
    parameter int unsigned CLK_FREQ      = 100_000_000,
    parameter int unsigned BAUD_RATE     = 25_000_000,
    parameter int unsigned GPIO_NUM_PINS = 4
) (
    input  logic clk,
    input  logic soc_rst_n,

    input  logic [31:0] imem_axi_araddr,
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] imem_axi_arid,
    input  logic        imem_axi_arvalid,
    output logic        imem_axi_arready,
    input  logic [7:0]  imem_axi_arlen,
    input  logic [2:0]  imem_axi_arsize,
    input  logic [1:0]  imem_axi_arburst,
    output logic [31:0] imem_axi_rdata,
    output logic [1:0]  imem_axi_rresp,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] imem_axi_rid,
    output logic        imem_axi_rvalid,
    input  logic        imem_axi_rready,
    output logic        imem_axi_rlast,

    input  logic [31:0] dmem_axi_awaddr,
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] dmem_axi_awid,
    input  logic [7:0]  dmem_axi_awlen,
    input  logic [2:0]  dmem_axi_awsize,
    input  logic [1:0]  dmem_axi_awburst,
    input  logic        dmem_axi_awvalid,
    output logic        dmem_axi_awready,
    input  logic [31:0] dmem_axi_wdata,
    input  logic [3:0]  dmem_axi_wstrb,
    input  logic        dmem_axi_wlast,
    input  logic        dmem_axi_wvalid,
    output logic        dmem_axi_wready,
    output logic [1:0]  dmem_axi_bresp,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] dmem_axi_bid,
    output logic        dmem_axi_bvalid,
    input  logic        dmem_axi_bready,
    input  logic [31:0] dmem_axi_araddr,
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] dmem_axi_arid,
    input  logic [7:0]  dmem_axi_arlen,
    input  logic [2:0]  dmem_axi_arsize,
    input  logic [1:0]  dmem_axi_arburst,
    input  logic        dmem_axi_arvalid,
    output logic        dmem_axi_arready,
    output logic [31:0] dmem_axi_rdata,
    output logic [1:0]  dmem_axi_rresp,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] dmem_axi_rid,
    output logic        dmem_axi_rlast,
    output logic        dmem_axi_rvalid,
    input  logic        dmem_axi_rready,

    output logic [31:0] m_axi_awaddr,
    output logic [7:0]  m_axi_awlen,
    output logic [2:0]  m_axi_awsize,
    output logic [1:0]  m_axi_awburst,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,
    output logic [31:0] m_axi_wdata,
    output logic [3:0]  m_axi_wstrb,
    output logic        m_axi_wlast,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,
    input  logic [1:0]  m_axi_bresp,
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready,
    output logic [31:0] m_axi_araddr,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,
    output logic [7:0]  m_axi_arlen,
    output logic [2:0]  m_axi_arsize,
    output logic [1:0]  m_axi_arburst,
    input  logic [31:0] m_axi_rdata,
    input  logic [1:0]  m_axi_rresp,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready,
    input  logic        m_axi_rlast,

    input  logic uart_rx,
    output logic uart_tx,
    output logic        spi_sclk,
    output logic        spi_mosi,
    input  logic        spi_miso,
    output logic [3:0]  spi_cs_n,
    output logic        i2c_scl_o,
    input  logic        i2c_scl_i,
    output logic        i2c_scl_oe,
    output logic        i2c_sda_o,
    input  logic        i2c_sda_i,
    output logic        i2c_sda_oe,
    output logic [GPIO_NUM_PINS-1:0] gpio_o,
    input  logic [GPIO_NUM_PINS-1:0] gpio_i,
    output logic [GPIO_NUM_PINS-1:0] gpio_oe,
    output logic [3:0]  pwm_o,

    output logic timer_irq_o,
    output logic software_irq_o,
    output logic external_irq_o,
    output logic wdt_reset_o,

    input  logic core_sleep_i,
`ifndef SYNTHESIS
    input  logic trace_mode,
    input  logic core_retire_instr,
    input  logic core_wb_store,
    input  logic [31:0] core_wb_store_addr,
    input  logic [31:0] core_wb_store_data,
    input  logic [3:0]  core_wb_store_strb,
`endif
    output logic [31:0] dummy_o
);

    logic [31:0]              arb_axi_awaddr;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] arb_axi_awid;
    logic [7:0]               arb_axi_awlen;
    logic [2:0]               arb_axi_awsize;
    logic [1:0]               arb_axi_awburst;
    logic                     arb_axi_awvalid;
    logic                     arb_axi_awready;
    logic [31:0]              arb_axi_wdata;
    logic [3:0]               arb_axi_wstrb;
    logic                     arb_axi_wlast;
    logic                     arb_axi_wvalid;
    logic                     arb_axi_wready;
    logic [1:0]               arb_axi_bresp;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] arb_axi_bid;
    logic                     arb_axi_bvalid;
    logic                     arb_axi_bready;
    logic [31:0]              arb_axi_araddr;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] arb_axi_arid;
    logic [7:0]               arb_axi_arlen;
    logic [2:0]               arb_axi_arsize;
    logic [1:0]               arb_axi_arburst;
    logic                     arb_axi_arvalid;
    logic                     arb_axi_arready;
    logic [31:0]              arb_axi_rdata;
    logic [1:0]               arb_axi_rresp;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] arb_axi_rid;
    logic                     arb_axi_rlast;
    logic                     arb_axi_rvalid;
    logic                     arb_axi_rready;

    logic [31:0] clint_axi_awaddr; logic clint_axi_awvalid; logic clint_axi_awready;
    logic [31:0] clint_axi_wdata;  logic [3:0] clint_axi_wstrb; logic clint_axi_wvalid; logic clint_axi_wready;
    logic [1:0]  clint_axi_bresp;  logic clint_axi_bvalid; logic clint_axi_bready;
    logic [31:0] clint_axi_araddr; logic clint_axi_arvalid; logic clint_axi_arready;
    logic [31:0] clint_axi_rdata;  logic [1:0] clint_axi_rresp; logic clint_axi_rvalid; logic clint_axi_rready;

    logic [31:0] plic_axi_awaddr; logic plic_axi_awvalid; logic plic_axi_awready;
    logic [31:0] plic_axi_wdata;  logic [3:0] plic_axi_wstrb; logic plic_axi_wvalid; logic plic_axi_wready;
    logic [1:0]  plic_axi_bresp;  logic plic_axi_bvalid; logic plic_axi_bready;
    logic [31:0] plic_axi_araddr; logic plic_axi_arvalid; logic plic_axi_arready;
    logic [31:0] plic_axi_rdata;  logic [1:0] plic_axi_rresp; logic plic_axi_rvalid; logic plic_axi_rready;

    logic [31:0] uart_axi_awaddr; logic uart_axi_awvalid; logic uart_axi_awready;
    logic [31:0] uart_axi_wdata;  logic [3:0] uart_axi_wstrb; logic uart_axi_wvalid; logic uart_axi_wready;
    logic [1:0]  uart_axi_bresp;  logic uart_axi_bvalid; logic uart_axi_bready;
    logic [31:0] uart_axi_araddr; logic uart_axi_arvalid; logic uart_axi_arready;
    logic [31:0] uart_axi_rdata;  logic [1:0] uart_axi_rresp; logic uart_axi_rvalid; logic uart_axi_rready;

    logic [31:0] spi_axi_awaddr; logic spi_axi_awvalid; logic spi_axi_awready;
    logic [31:0] spi_axi_wdata;  logic [3:0] spi_axi_wstrb; logic spi_axi_wvalid; logic spi_axi_wready;
    logic [1:0]  spi_axi_bresp;  logic spi_axi_bvalid; logic spi_axi_bready;
    logic [31:0] spi_axi_araddr; logic spi_axi_arvalid; logic spi_axi_arready;
    logic [31:0] spi_axi_rdata;  logic [1:0] spi_axi_rresp; logic spi_axi_rvalid; logic spi_axi_rready;

    logic [31:0] i2c_axi_awaddr; logic i2c_axi_awvalid; logic i2c_axi_awready;
    logic [31:0] i2c_axi_wdata;  logic [3:0] i2c_axi_wstrb; logic i2c_axi_wvalid; logic i2c_axi_wready;
    logic [1:0]  i2c_axi_bresp;  logic i2c_axi_bvalid; logic i2c_axi_bready;
    logic [31:0] i2c_axi_araddr; logic i2c_axi_arvalid; logic i2c_axi_arready;
    logic [31:0] i2c_axi_rdata;  logic [1:0] i2c_axi_rresp; logic i2c_axi_rvalid; logic i2c_axi_rready;

    logic [31:0] gpio_axi_awaddr; logic gpio_axi_awvalid; logic gpio_axi_awready;
    logic [31:0] gpio_axi_wdata;  logic [3:0] gpio_axi_wstrb; logic gpio_axi_wvalid; logic gpio_axi_wready;
    logic [1:0]  gpio_axi_bresp;  logic gpio_axi_bvalid; logic gpio_axi_bready;
    logic [31:0] gpio_axi_araddr; logic gpio_axi_arvalid; logic gpio_axi_arready;
    logic [31:0] gpio_axi_rdata;  logic [1:0] gpio_axi_rresp; logic gpio_axi_rvalid; logic gpio_axi_rready;

    logic [31:0] timer_axi_awaddr; logic timer_axi_awvalid; logic timer_axi_awready;
    logic [31:0] timer_axi_wdata;  logic [3:0] timer_axi_wstrb; logic timer_axi_wvalid; logic timer_axi_wready;
    logic [1:0]  timer_axi_bresp;  logic timer_axi_bvalid; logic timer_axi_bready;
    logic [31:0] timer_axi_araddr; logic timer_axi_arvalid; logic timer_axi_arready;
    logic [31:0] timer_axi_rdata;  logic [1:0] timer_axi_rresp; logic timer_axi_rvalid; logic timer_axi_rready;

    logic [31:0] wdt_axi_awaddr; logic wdt_axi_awvalid; logic wdt_axi_awready;
    logic [31:0] wdt_axi_wdata;  logic [3:0] wdt_axi_wstrb; logic wdt_axi_wvalid; logic wdt_axi_wready;
    logic [1:0]  wdt_axi_bresp;  logic wdt_axi_bvalid; logic wdt_axi_bready;
    logic [31:0] wdt_axi_araddr; logic wdt_axi_arvalid; logic wdt_axi_arready;
    logic [31:0] wdt_axi_rdata;  logic [1:0] wdt_axi_rresp; logic wdt_axi_rvalid; logic wdt_axi_rready;

    logic [31:0] dma_cfg_axi_awaddr; logic dma_cfg_axi_awvalid; logic dma_cfg_axi_awready;
    logic [31:0] dma_cfg_axi_wdata; logic [3:0] dma_cfg_axi_wstrb; logic dma_cfg_axi_wvalid; logic dma_cfg_axi_wready;
    logic [1:0] dma_cfg_axi_bresp; logic dma_cfg_axi_bvalid; logic dma_cfg_axi_bready;
    logic [31:0] dma_cfg_axi_araddr; logic dma_cfg_axi_arvalid; logic dma_cfg_axi_arready;
    logic [31:0] dma_cfg_axi_rdata; logic [1:0] dma_cfg_axi_rresp; logic dma_cfg_axi_rvalid; logic dma_cfg_axi_rready;

    logic [31:0] dma_m_axi_awaddr; logic [7:0] dma_m_axi_awlen; logic [2:0] dma_m_axi_awsize; logic [1:0] dma_m_axi_awburst;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] dma_m_axi_awid;
    logic dma_m_axi_awvalid; logic dma_m_axi_awready;
    logic [31:0] dma_m_axi_wdata; logic [3:0] dma_m_axi_wstrb; logic dma_m_axi_wlast; logic dma_m_axi_wvalid; logic dma_m_axi_wready;
    logic [1:0] dma_m_axi_bresp; logic [axi_pkg::AXI_ID_WIDTH-1:0] dma_m_axi_bid; logic dma_m_axi_bvalid; logic dma_m_axi_bready;
    logic [31:0] dma_m_axi_araddr; logic [7:0] dma_m_axi_arlen; logic [2:0] dma_m_axi_arsize; logic [1:0] dma_m_axi_arburst;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] dma_m_axi_arid;
    logic dma_m_axi_arvalid; logic dma_m_axi_arready;
    logic [31:0] dma_m_axi_rdata; logic [1:0] dma_m_axi_rresp; logic [axi_pkg::AXI_ID_WIDTH-1:0] dma_m_axi_rid;
    logic dma_m_axi_rlast; logic dma_m_axi_rvalid; logic dma_m_axi_rready;

    logic [31:0] magic_axi_awaddr; logic magic_axi_awvalid; logic magic_axi_awready;
    logic [31:0] magic_axi_wdata; logic [3:0] magic_axi_wstrb; logic magic_axi_wvalid; logic magic_axi_wready;
    logic [1:0] magic_axi_bresp; logic magic_axi_bvalid; logic magic_axi_bready;
    logic [31:0] magic_axi_araddr; logic magic_axi_arvalid; logic magic_axi_arready;
    logic [31:0] magic_axi_rdata; logic [1:0] magic_axi_rresp; logic magic_axi_rvalid; logic magic_axi_rready;
    logic        dma_ids_unused;

    logic uart_irq;
    logic spi_irq;
    logic i2c_irq;
    logic dma_irq;
    logic gpio_irq;
    logic [3:0] timer_ch_irq;
    logic wdt_irq;

    localparam int unsigned PLIC_NUM_IRQ = 11;
    logic [PLIC_NUM_IRQ:0] plic_irq_src;

    assign plic_irq_src[0]   = 1'b0;
    assign plic_irq_src[1]   = uart_irq;
    assign plic_irq_src[2]   = spi_irq;
    assign plic_irq_src[3]   = i2c_irq;
    assign plic_irq_src[4]   = dma_irq;
    assign plic_irq_src[5]   = gpio_irq;
    assign plic_irq_src[6]   = timer_ch_irq[0];
    assign plic_irq_src[7]   = timer_ch_irq[1];
    assign plic_irq_src[8]   = timer_ch_irq[2];
    assign plic_irq_src[9]   = timer_ch_irq[3];
    assign plic_irq_src[10]  = wdt_irq;
    assign plic_irq_src[11]  = 1'b0;

    assign dma_m_axi_awid = '0;
    assign dma_m_axi_arid = '0;
    assign dummy_o = 32'h0;
    assign dma_ids_unused = ^{dma_m_axi_bid, dma_m_axi_rid};

    axi_arbiter #(
        .OUTSTANDING_DEPTH(8)
    ) arbiter (
        .clk(clk),
        .rst_n(soc_rst_n),
        .m0_axi_araddr  (imem_axi_araddr),
        .m0_axi_arid    (imem_axi_arid),
        .m0_axi_arvalid (imem_axi_arvalid),
        .m0_axi_arready (imem_axi_arready),
        .m0_axi_arlen   (imem_axi_arlen),
        .m0_axi_arsize  (imem_axi_arsize),
        .m0_axi_arburst (imem_axi_arburst),
        .m0_axi_rdata   (imem_axi_rdata),
        .m0_axi_rresp   (imem_axi_rresp),
        .m0_axi_rid     (imem_axi_rid),
        .m0_axi_rvalid  (imem_axi_rvalid),
        .m0_axi_rready  (imem_axi_rready),
        .m0_axi_rlast   (imem_axi_rlast),
        .m1_axi_awaddr (dmem_axi_awaddr),
        .m1_axi_awid   (dmem_axi_awid),
        .m1_axi_awlen  (dmem_axi_awlen),
        .m1_axi_awsize (dmem_axi_awsize),
        .m1_axi_awburst(dmem_axi_awburst),
        .m1_axi_awvalid(dmem_axi_awvalid),
        .m1_axi_awready(dmem_axi_awready),
        .m1_axi_wdata  (dmem_axi_wdata),
        .m1_axi_wstrb  (dmem_axi_wstrb),
        .m1_axi_wlast  (dmem_axi_wlast),
        .m1_axi_wvalid (dmem_axi_wvalid),
        .m1_axi_wready (dmem_axi_wready),
        .m1_axi_bresp  (dmem_axi_bresp),
        .m1_axi_bid    (dmem_axi_bid),
        .m1_axi_bvalid (dmem_axi_bvalid),
        .m1_axi_bready (dmem_axi_bready),
        .m1_axi_araddr (dmem_axi_araddr),
        .m1_axi_arid   (dmem_axi_arid),
        .m1_axi_arlen  (dmem_axi_arlen),
        .m1_axi_arsize (dmem_axi_arsize),
        .m1_axi_arburst(dmem_axi_arburst),
        .m1_axi_arvalid(dmem_axi_arvalid),
        .m1_axi_arready(dmem_axi_arready),
        .m1_axi_rdata  (dmem_axi_rdata),
        .m1_axi_rresp  (dmem_axi_rresp),
        .m1_axi_rid    (dmem_axi_rid),
        .m1_axi_rlast  (dmem_axi_rlast),
        .m1_axi_rvalid (dmem_axi_rvalid),
        .m1_axi_rready (dmem_axi_rready),
        .m2_axi_awaddr  (dma_m_axi_awaddr),
        .m2_axi_awid    (dma_m_axi_awid),
        .m2_axi_awlen   (dma_m_axi_awlen),
        .m2_axi_awsize  (dma_m_axi_awsize),
        .m2_axi_awburst (dma_m_axi_awburst),
        .m2_axi_awvalid (dma_m_axi_awvalid),
        .m2_axi_awready (dma_m_axi_awready),
        .m2_axi_wdata   (dma_m_axi_wdata),
        .m2_axi_wstrb   (dma_m_axi_wstrb),
        .m2_axi_wlast   (dma_m_axi_wlast),
        .m2_axi_wvalid  (dma_m_axi_wvalid),
        .m2_axi_wready  (dma_m_axi_wready),
        .m2_axi_bresp   (dma_m_axi_bresp),
        .m2_axi_bid     (dma_m_axi_bid),
        .m2_axi_bvalid  (dma_m_axi_bvalid),
        .m2_axi_bready  (dma_m_axi_bready),
        .m2_axi_araddr  (dma_m_axi_araddr),
        .m2_axi_arid    (dma_m_axi_arid),
        .m2_axi_arlen   (dma_m_axi_arlen),
        .m2_axi_arsize  (dma_m_axi_arsize),
        .m2_axi_arburst (dma_m_axi_arburst),
        .m2_axi_arvalid (dma_m_axi_arvalid),
        .m2_axi_arready (dma_m_axi_arready),
        .m2_axi_rdata   (dma_m_axi_rdata),
        .m2_axi_rresp   (dma_m_axi_rresp),
        .m2_axi_rid     (dma_m_axi_rid),
        .m2_axi_rlast   (dma_m_axi_rlast),
        .m2_axi_rvalid  (dma_m_axi_rvalid),
        .m2_axi_rready  (dma_m_axi_rready),
        .s_axi_awaddr  (arb_axi_awaddr),
        .s_axi_awid    (arb_axi_awid),
        .s_axi_awlen   (arb_axi_awlen),
        .s_axi_awsize  (arb_axi_awsize),
        .s_axi_awburst (arb_axi_awburst),
        .s_axi_awvalid (arb_axi_awvalid),
        .s_axi_awready (arb_axi_awready),
        .s_axi_wdata   (arb_axi_wdata),
        .s_axi_wstrb   (arb_axi_wstrb),
        .s_axi_wlast   (arb_axi_wlast),
        .s_axi_wvalid  (arb_axi_wvalid),
        .s_axi_wready  (arb_axi_wready),
        .s_axi_bresp   (arb_axi_bresp),
        .s_axi_bid     (arb_axi_bid),
        .s_axi_bvalid  (arb_axi_bvalid),
        .s_axi_bready  (arb_axi_bready),
        .s_axi_araddr  (arb_axi_araddr),
        .s_axi_arid    (arb_axi_arid),
        .s_axi_arvalid (arb_axi_arvalid),
        .s_axi_arready (arb_axi_arready),
        .s_axi_arlen   (arb_axi_arlen),
        .s_axi_arsize  (arb_axi_arsize),
        .s_axi_arburst (arb_axi_arburst),
        .s_axi_rdata   (arb_axi_rdata),
        .s_axi_rresp   (arb_axi_rresp),
        .s_axi_rid     (arb_axi_rid),
        .s_axi_rvalid  (arb_axi_rvalid),
        .s_axi_rready  (arb_axi_rready),
        .s_axi_rlast   (arb_axi_rlast)
    );

    axi_xbar axi_intercon (
        .clk(clk),
        .rst_n(soc_rst_n),
        .m_axi_awaddr  (arb_axi_awaddr),
        .m_axi_awid    (arb_axi_awid),
        .m_axi_awlen   (arb_axi_awlen),
        .m_axi_awsize  (arb_axi_awsize),
        .m_axi_awburst (arb_axi_awburst),
        .m_axi_awvalid (arb_axi_awvalid),
        .m_axi_awready (arb_axi_awready),
        .m_axi_wdata   (arb_axi_wdata),
        .m_axi_wstrb   (arb_axi_wstrb),
        .m_axi_wlast   (arb_axi_wlast),
        .m_axi_wvalid  (arb_axi_wvalid),
        .m_axi_wready  (arb_axi_wready),
        .m_axi_bresp   (arb_axi_bresp),
        .m_axi_bid     (arb_axi_bid),
        .m_axi_bvalid  (arb_axi_bvalid),
        .m_axi_bready  (arb_axi_bready),
        .m_axi_araddr  (arb_axi_araddr),
        .m_axi_arid    (arb_axi_arid),
        .m_axi_arvalid (arb_axi_arvalid),
        .m_axi_arready (arb_axi_arready),
        .m_axi_arlen   (arb_axi_arlen),
        .m_axi_arsize  (arb_axi_arsize),
        .m_axi_arburst (arb_axi_arburst),
        .m_axi_rdata   (arb_axi_rdata),
        .m_axi_rresp   (arb_axi_rresp),
        .m_axi_rid     (arb_axi_rid),
        .m_axi_rvalid  (arb_axi_rvalid),
        .m_axi_rready  (arb_axi_rready),
        .m_axi_rlast   (arb_axi_rlast),
        .s0_axi_awaddr (m_axi_awaddr),
        .s0_axi_awlen  (m_axi_awlen),
        .s0_axi_awsize (m_axi_awsize),
        .s0_axi_awburst(m_axi_awburst),
        .s0_axi_awvalid(m_axi_awvalid),
        .s0_axi_awready(m_axi_awready),
        .s0_axi_wdata  (m_axi_wdata),
        .s0_axi_wstrb  (m_axi_wstrb),
        .s0_axi_wlast  (m_axi_wlast),
        .s0_axi_wvalid (m_axi_wvalid),
        .s0_axi_wready (m_axi_wready),
        .s0_axi_bresp  (m_axi_bresp),
        .s0_axi_bvalid (m_axi_bvalid),
        .s0_axi_bready (m_axi_bready),
        .s0_axi_araddr (m_axi_araddr),
        .s0_axi_arvalid(m_axi_arvalid),
        .s0_axi_arready(m_axi_arready),
        .s0_axi_arlen  (m_axi_arlen),
        .s0_axi_arsize (m_axi_arsize),
        .s0_axi_arburst(m_axi_arburst),
        .s0_axi_rdata  (m_axi_rdata),
        .s0_axi_rresp  (m_axi_rresp),
        .s0_axi_rvalid (m_axi_rvalid),
        .s0_axi_rready (m_axi_rready),
        .s0_axi_rlast  (m_axi_rlast),
        .s1_axi_awaddr  (magic_axi_awaddr),
        .s1_axi_awvalid (magic_axi_awvalid),
        .s1_axi_awready (magic_axi_awready),
        .s1_axi_wdata   (magic_axi_wdata),
        .s1_axi_wstrb   (magic_axi_wstrb),
        .s1_axi_wvalid  (magic_axi_wvalid),
        .s1_axi_wready  (magic_axi_wready),
        .s1_axi_bresp   (magic_axi_bresp),
        .s1_axi_bvalid  (magic_axi_bvalid),
        .s1_axi_bready  (magic_axi_bready),
        .s1_axi_araddr  (magic_axi_araddr),
        .s1_axi_arvalid (magic_axi_arvalid),
        .s1_axi_arready (magic_axi_arready),
        .s1_axi_rdata   (magic_axi_rdata),
        .s1_axi_rresp   (magic_axi_rresp),
        .s1_axi_rvalid  (magic_axi_rvalid),
        .s1_axi_rready  (magic_axi_rready),
        .s2_axi_awaddr(clint_axi_awaddr),
        .s2_axi_awvalid(clint_axi_awvalid),
        .s2_axi_awready(clint_axi_awready),
        .s2_axi_wdata(clint_axi_wdata),
        .s2_axi_wstrb(clint_axi_wstrb),
        .s2_axi_wvalid(clint_axi_wvalid),
        .s2_axi_wready(clint_axi_wready),
        .s2_axi_bresp(clint_axi_bresp),
        .s2_axi_bvalid(clint_axi_bvalid),
        .s2_axi_bready(clint_axi_bready),
        .s2_axi_araddr(clint_axi_araddr),
        .s2_axi_arvalid(clint_axi_arvalid),
        .s2_axi_arready(clint_axi_arready),
        .s2_axi_rdata(clint_axi_rdata),
        .s2_axi_rresp(clint_axi_rresp),
        .s2_axi_rvalid(clint_axi_rvalid),
        .s2_axi_rready(clint_axi_rready),
        .s3_axi_awaddr(plic_axi_awaddr),
        .s3_axi_awvalid(plic_axi_awvalid),
        .s3_axi_awready(plic_axi_awready),
        .s3_axi_wdata(plic_axi_wdata),
        .s3_axi_wstrb(plic_axi_wstrb),
        .s3_axi_wvalid(plic_axi_wvalid),
        .s3_axi_wready(plic_axi_wready),
        .s3_axi_bresp(plic_axi_bresp),
        .s3_axi_bvalid(plic_axi_bvalid),
        .s3_axi_bready(plic_axi_bready),
        .s3_axi_araddr(plic_axi_araddr),
        .s3_axi_arvalid(plic_axi_arvalid),
        .s3_axi_arready(plic_axi_arready),
        .s3_axi_rdata(plic_axi_rdata),
        .s3_axi_rresp(plic_axi_rresp),
        .s3_axi_rvalid(plic_axi_rvalid),
        .s3_axi_rready(plic_axi_rready),
        .s4_axi_awaddr  (dma_cfg_axi_awaddr),
        .s4_axi_awvalid (dma_cfg_axi_awvalid),
        .s4_axi_awready (dma_cfg_axi_awready),
        .s4_axi_wdata   (dma_cfg_axi_wdata),
        .s4_axi_wstrb   (dma_cfg_axi_wstrb),
        .s4_axi_wvalid  (dma_cfg_axi_wvalid),
        .s4_axi_wready  (dma_cfg_axi_wready),
        .s4_axi_bresp   (dma_cfg_axi_bresp),
        .s4_axi_bvalid  (dma_cfg_axi_bvalid),
        .s4_axi_bready  (dma_cfg_axi_bready),
        .s4_axi_araddr  (dma_cfg_axi_araddr),
        .s4_axi_arvalid (dma_cfg_axi_arvalid),
        .s4_axi_arready (dma_cfg_axi_arready),
        .s4_axi_rdata   (dma_cfg_axi_rdata),
        .s4_axi_rresp   (dma_cfg_axi_rresp),
        .s4_axi_rvalid  (dma_cfg_axi_rvalid),
        .s4_axi_rready  (dma_cfg_axi_rready),
        .s5_axi_awaddr(uart_axi_awaddr),
        .s5_axi_awvalid(uart_axi_awvalid),
        .s5_axi_awready(uart_axi_awready),
        .s5_axi_wdata(uart_axi_wdata),
        .s5_axi_wstrb(uart_axi_wstrb),
        .s5_axi_wvalid(uart_axi_wvalid),
        .s5_axi_wready(uart_axi_wready),
        .s5_axi_bresp(uart_axi_bresp),
        .s5_axi_bvalid(uart_axi_bvalid),
        .s5_axi_bready(uart_axi_bready),
        .s5_axi_araddr(uart_axi_araddr),
        .s5_axi_arvalid(uart_axi_arvalid),
        .s5_axi_arready(uart_axi_arready),
        .s5_axi_rdata(uart_axi_rdata),
        .s5_axi_rresp(uart_axi_rresp),
        .s5_axi_rvalid(uart_axi_rvalid),
        .s5_axi_rready(uart_axi_rready),
        .s6_axi_awaddr  (i2c_axi_awaddr),
        .s6_axi_awvalid (i2c_axi_awvalid),
        .s6_axi_awready (i2c_axi_awready),
        .s6_axi_wdata   (i2c_axi_wdata),
        .s6_axi_wstrb   (i2c_axi_wstrb),
        .s6_axi_wvalid  (i2c_axi_wvalid),
        .s6_axi_wready  (i2c_axi_wready),
        .s6_axi_bresp   (i2c_axi_bresp),
        .s6_axi_bvalid  (i2c_axi_bvalid),
        .s6_axi_bready  (i2c_axi_bready),
        .s6_axi_araddr  (i2c_axi_araddr),
        .s6_axi_arvalid (i2c_axi_arvalid),
        .s6_axi_arready (i2c_axi_arready),
        .s6_axi_rdata   (i2c_axi_rdata),
        .s6_axi_rresp   (i2c_axi_rresp),
        .s6_axi_rvalid  (i2c_axi_rvalid),
        .s6_axi_rready  (i2c_axi_rready),
        .s7_axi_awaddr  (spi_axi_awaddr),
        .s7_axi_awvalid (spi_axi_awvalid),
        .s7_axi_awready (spi_axi_awready),
        .s7_axi_wdata   (spi_axi_wdata),
        .s7_axi_wstrb   (spi_axi_wstrb),
        .s7_axi_wvalid  (spi_axi_wvalid),
        .s7_axi_wready  (spi_axi_wready),
        .s7_axi_bresp   (spi_axi_bresp),
        .s7_axi_bvalid  (spi_axi_bvalid),
        .s7_axi_bready  (spi_axi_bready),
        .s7_axi_araddr  (spi_axi_araddr),
        .s7_axi_arvalid (spi_axi_arvalid),
        .s7_axi_arready (spi_axi_arready),
        .s7_axi_rdata   (spi_axi_rdata),
        .s7_axi_rresp   (spi_axi_rresp),
        .s7_axi_rvalid  (spi_axi_rvalid),
        .s7_axi_rready  (spi_axi_rready),
        .s8_axi_awaddr  (timer_axi_awaddr),
        .s8_axi_awvalid (timer_axi_awvalid),
        .s8_axi_awready (timer_axi_awready),
        .s8_axi_wdata   (timer_axi_wdata),
        .s8_axi_wstrb   (timer_axi_wstrb),
        .s8_axi_wvalid  (timer_axi_wvalid),
        .s8_axi_wready  (timer_axi_wready),
        .s8_axi_bresp   (timer_axi_bresp),
        .s8_axi_bvalid  (timer_axi_bvalid),
        .s8_axi_bready  (timer_axi_bready),
        .s8_axi_araddr  (timer_axi_araddr),
        .s8_axi_arvalid (timer_axi_arvalid),
        .s8_axi_arready (timer_axi_arready),
        .s8_axi_rdata   (timer_axi_rdata),
        .s8_axi_rresp   (timer_axi_rresp),
        .s8_axi_rvalid  (timer_axi_rvalid),
        .s8_axi_rready  (timer_axi_rready),
        .s9_axi_awaddr  (gpio_axi_awaddr),
        .s9_axi_awvalid (gpio_axi_awvalid),
        .s9_axi_awready (gpio_axi_awready),
        .s9_axi_wdata   (gpio_axi_wdata),
        .s9_axi_wstrb   (gpio_axi_wstrb),
        .s9_axi_wvalid  (gpio_axi_wvalid),
        .s9_axi_wready  (gpio_axi_wready),
        .s9_axi_bresp   (gpio_axi_bresp),
        .s9_axi_bvalid  (gpio_axi_bvalid),
        .s9_axi_bready  (gpio_axi_bready),
        .s9_axi_araddr  (gpio_axi_araddr),
        .s9_axi_arvalid (gpio_axi_arvalid),
        .s9_axi_arready (gpio_axi_arready),
        .s9_axi_rdata   (gpio_axi_rdata),
        .s9_axi_rresp   (gpio_axi_rresp),
        .s9_axi_rvalid  (gpio_axi_rvalid),
        .s9_axi_rready  (gpio_axi_rready),
        .s10_axi_awaddr  (wdt_axi_awaddr),
        .s10_axi_awvalid (wdt_axi_awvalid),
        .s10_axi_awready (wdt_axi_awready),
        .s10_axi_wdata   (wdt_axi_wdata),
        .s10_axi_wstrb   (wdt_axi_wstrb),
        .s10_axi_wvalid  (wdt_axi_wvalid),
        .s10_axi_wready  (wdt_axi_wready),
        .s10_axi_bresp   (wdt_axi_bresp),
        .s10_axi_bvalid  (wdt_axi_bvalid),
        .s10_axi_bready  (wdt_axi_bready),
        .s10_axi_araddr  (wdt_axi_araddr),
        .s10_axi_arvalid (wdt_axi_arvalid),
        .s10_axi_arready (wdt_axi_arready),
        .s10_axi_rdata   (wdt_axi_rdata),
        .s10_axi_rresp   (wdt_axi_rresp),
        .s10_axi_rvalid  (wdt_axi_rvalid),
        .s10_axi_rready  (wdt_axi_rready)
    );

    axi_clint clint (
        .clk(clk),
        .rst_n(soc_rst_n),
        .axi_awaddr(clint_axi_awaddr), .axi_awvalid(clint_axi_awvalid), .axi_awready(clint_axi_awready),
        .axi_wdata(clint_axi_wdata), .axi_wstrb(clint_axi_wstrb), .axi_wvalid(clint_axi_wvalid), .axi_wready(clint_axi_wready),
        .axi_bresp(clint_axi_bresp), .axi_bvalid(clint_axi_bvalid), .axi_bready(clint_axi_bready),
        .axi_araddr(clint_axi_araddr), .axi_arvalid(clint_axi_arvalid), .axi_arready(clint_axi_arready),
        .axi_rdata(clint_axi_rdata), .axi_rresp(clint_axi_rresp), .axi_rvalid(clint_axi_rvalid), .axi_rready(clint_axi_rready),
        .timer_irq(timer_irq_o),
        .software_irq(software_irq_o)
`ifndef SYNTHESIS
       ,.trace_mode(trace_mode)
        ,.retire_instr(core_retire_instr)
        ,.core_sleep_i(core_sleep_i)
        ,.trace_store_valid(core_wb_store &&
                            (core_wb_store_addr[31:20] == 12'h020) &&
                            (core_wb_store_addr[19:18] != 2'b11))
        ,.trace_store_addr(core_wb_store_addr)
        ,.trace_store_data(core_wb_store_data)
        ,.trace_store_strb(core_wb_store_strb)
`endif
    );

    axi_plic #(.NUM_IRQ(PLIC_NUM_IRQ)) u_plic (
        .clk(clk), .rst_n(soc_rst_n),
        .axi_awaddr(plic_axi_awaddr), .axi_awvalid(plic_axi_awvalid), .axi_awready(plic_axi_awready),
        .axi_wdata(plic_axi_wdata), .axi_wstrb(plic_axi_wstrb), .axi_wvalid(plic_axi_wvalid), .axi_wready(plic_axi_wready),
        .axi_bresp(plic_axi_bresp), .axi_bvalid(plic_axi_bvalid), .axi_bready(plic_axi_bready),
        .axi_araddr(plic_axi_araddr), .axi_arvalid(plic_axi_arvalid), .axi_arready(plic_axi_arready),
        .axi_rdata(plic_axi_rdata), .axi_rresp(plic_axi_rresp), .axi_rvalid(plic_axi_rvalid), .axi_rready(plic_axi_rready),
        .irq_src(plic_irq_src), .irq(external_irq_o)
    );

    axi_uart #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) uart (
        .clk(clk), .rst_n(soc_rst_n),
        .axi_awaddr(uart_axi_awaddr), .axi_awvalid(uart_axi_awvalid), .axi_awready(uart_axi_awready),
        .axi_wdata(uart_axi_wdata), .axi_wstrb(uart_axi_wstrb), .axi_wvalid(uart_axi_wvalid), .axi_wready(uart_axi_wready),
        .axi_bresp(uart_axi_bresp), .axi_bvalid(uart_axi_bvalid), .axi_bready(uart_axi_bready),
        .axi_araddr(uart_axi_araddr), .axi_arvalid(uart_axi_arvalid), .axi_arready(uart_axi_arready),
        .axi_rdata(uart_axi_rdata), .axi_rresp(uart_axi_rresp), .axi_rvalid(uart_axi_rvalid), .axi_rready(uart_axi_rready),
        .irq(uart_irq), .uart_rx(uart_rx), .uart_tx(uart_tx)
    );

    axi_spi #(.CLK_FREQ(CLK_FREQ)) spi (
        .clk(clk), .rst_n(soc_rst_n),
        .axi_awaddr(spi_axi_awaddr), .axi_awvalid(spi_axi_awvalid), .axi_awready(spi_axi_awready),
        .axi_wdata(spi_axi_wdata), .axi_wstrb(spi_axi_wstrb), .axi_wvalid(spi_axi_wvalid), .axi_wready(spi_axi_wready),
        .axi_bresp(spi_axi_bresp), .axi_bvalid(spi_axi_bvalid), .axi_bready(spi_axi_bready),
        .axi_araddr(spi_axi_araddr), .axi_arvalid(spi_axi_arvalid), .axi_arready(spi_axi_arready),
        .axi_rdata(spi_axi_rdata), .axi_rresp(spi_axi_rresp), .axi_rvalid(spi_axi_rvalid), .axi_rready(spi_axi_rready),
        .irq(spi_irq), .spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_miso(spi_miso), .spi_cs_n(spi_cs_n)
    );

    axi_i2c #(.CLK_FREQ(CLK_FREQ)) i2c (
        .clk(clk), .rst_n(soc_rst_n),
        .axi_awaddr(i2c_axi_awaddr), .axi_awvalid(i2c_axi_awvalid), .axi_awready(i2c_axi_awready),
        .axi_wdata(i2c_axi_wdata), .axi_wstrb(i2c_axi_wstrb), .axi_wvalid(i2c_axi_wvalid), .axi_wready(i2c_axi_wready),
        .axi_bresp(i2c_axi_bresp), .axi_bvalid(i2c_axi_bvalid), .axi_bready(i2c_axi_bready),
        .axi_araddr(i2c_axi_araddr), .axi_arvalid(i2c_axi_arvalid), .axi_arready(i2c_axi_arready),
        .axi_rdata(i2c_axi_rdata), .axi_rresp(i2c_axi_rresp), .axi_rvalid(i2c_axi_rvalid), .axi_rready(i2c_axi_rready),
        .irq(i2c_irq), .i2c_scl_o(i2c_scl_o), .i2c_scl_i(i2c_scl_i), .i2c_scl_oe(i2c_scl_oe),
        .i2c_sda_o(i2c_sda_o), .i2c_sda_i(i2c_sda_i), .i2c_sda_oe(i2c_sda_oe)
    );

    axi_dma #(.NUM_CHANNELS(4), .DATA_WIDTH(32), .FIFO_DEPTH(16), .MAX_BURST_LEN(16)) u_dma (
        .clk(clk), .rst_n(soc_rst_n),
        .cfg_awaddr(dma_cfg_axi_awaddr), .cfg_awvalid(dma_cfg_axi_awvalid), .cfg_awready(dma_cfg_axi_awready),
        .cfg_wdata(dma_cfg_axi_wdata), .cfg_wstrb(dma_cfg_axi_wstrb), .cfg_wvalid(dma_cfg_axi_wvalid), .cfg_wready(dma_cfg_axi_wready),
        .cfg_bresp(dma_cfg_axi_bresp), .cfg_bvalid(dma_cfg_axi_bvalid), .cfg_bready(dma_cfg_axi_bready),
        .cfg_araddr(dma_cfg_axi_araddr), .cfg_arvalid(dma_cfg_axi_arvalid), .cfg_arready(dma_cfg_axi_arready),
        .cfg_rdata(dma_cfg_axi_rdata), .cfg_rresp(dma_cfg_axi_rresp), .cfg_rvalid(dma_cfg_axi_rvalid), .cfg_rready(dma_cfg_axi_rready),
        .dma_awaddr(dma_m_axi_awaddr), .dma_awlen(dma_m_axi_awlen), .dma_awsize(dma_m_axi_awsize), .dma_awburst(dma_m_axi_awburst),
        .dma_awvalid(dma_m_axi_awvalid), .dma_awready(dma_m_axi_awready), .dma_wdata(dma_m_axi_wdata), .dma_wstrb(dma_m_axi_wstrb),
        .dma_wlast(dma_m_axi_wlast), .dma_wvalid(dma_m_axi_wvalid), .dma_wready(dma_m_axi_wready), .dma_bresp(dma_m_axi_bresp),
        .dma_bvalid(dma_m_axi_bvalid), .dma_bready(dma_m_axi_bready), .dma_araddr(dma_m_axi_araddr), .dma_arlen(dma_m_axi_arlen),
        .dma_arsize(dma_m_axi_arsize), .dma_arburst(dma_m_axi_arburst), .dma_arvalid(dma_m_axi_arvalid), .dma_arready(dma_m_axi_arready),
        .dma_rdata(dma_m_axi_rdata), .dma_rresp(dma_m_axi_rresp), .dma_rlast(dma_m_axi_rlast), .dma_rvalid(dma_m_axi_rvalid),
        .dma_rready(dma_m_axi_rready), .irq(dma_irq)
    );

    axi_gpio #(.NUM_PINS(GPIO_NUM_PINS)) gpio (
        .clk(clk), .rst_n(soc_rst_n),
        .axi_awaddr(gpio_axi_awaddr), .axi_awvalid(gpio_axi_awvalid), .axi_awready(gpio_axi_awready),
        .axi_wdata(gpio_axi_wdata), .axi_wstrb(gpio_axi_wstrb), .axi_wvalid(gpio_axi_wvalid), .axi_wready(gpio_axi_wready),
        .axi_bresp(gpio_axi_bresp), .axi_bvalid(gpio_axi_bvalid), .axi_bready(gpio_axi_bready),
        .axi_araddr(gpio_axi_araddr), .axi_arvalid(gpio_axi_arvalid), .axi_arready(gpio_axi_arready),
        .axi_rdata(gpio_axi_rdata), .axi_rresp(gpio_axi_rresp), .axi_rvalid(gpio_axi_rvalid), .axi_rready(gpio_axi_rready),
        .irq(gpio_irq), .gpio_o(gpio_o), .gpio_i(gpio_i), .gpio_oe(gpio_oe)
    );

    axi_timer timer (
        .clk(clk), .rst_n(soc_rst_n),
        .axi_awaddr(timer_axi_awaddr), .axi_awvalid(timer_axi_awvalid), .axi_awready(timer_axi_awready),
        .axi_wdata(timer_axi_wdata), .axi_wstrb(timer_axi_wstrb), .axi_wvalid(timer_axi_wvalid), .axi_wready(timer_axi_wready),
        .axi_bresp(timer_axi_bresp), .axi_bvalid(timer_axi_bvalid), .axi_bready(timer_axi_bready),
        .axi_araddr(timer_axi_araddr), .axi_arvalid(timer_axi_arvalid), .axi_arready(timer_axi_arready),
        .axi_rdata(timer_axi_rdata), .axi_rresp(timer_axi_rresp), .axi_rvalid(timer_axi_rvalid), .axi_rready(timer_axi_rready),
        .irq(timer_ch_irq), .pwm_o(pwm_o)
    );

    axi_wdt u_wdt (
        .clk(clk), .rst_n(soc_rst_n),
        .axi_awaddr(wdt_axi_awaddr), .axi_awvalid(wdt_axi_awvalid), .axi_awready(wdt_axi_awready),
        .axi_wdata(wdt_axi_wdata), .axi_wstrb(wdt_axi_wstrb), .axi_wvalid(wdt_axi_wvalid), .axi_wready(wdt_axi_wready),
        .axi_bresp(wdt_axi_bresp), .axi_bvalid(wdt_axi_bvalid), .axi_bready(wdt_axi_bready),
        .axi_araddr(wdt_axi_araddr), .axi_arvalid(wdt_axi_arvalid), .axi_arready(wdt_axi_arready),
        .axi_rdata(wdt_axi_rdata), .axi_rresp(wdt_axi_rresp), .axi_rvalid(wdt_axi_rvalid), .axi_rready(wdt_axi_rready),
        .irq(wdt_irq), .wdt_reset_o(wdt_reset_o)
    );

    axi_magic magic (
        .clk(clk), .rst_n(soc_rst_n),
        .axi_awaddr(magic_axi_awaddr), .axi_awvalid(magic_axi_awvalid), .axi_awready(magic_axi_awready),
        .axi_wdata(magic_axi_wdata), .axi_wstrb(magic_axi_wstrb), .axi_wvalid(magic_axi_wvalid), .axi_wready(magic_axi_wready),
        .axi_bresp(magic_axi_bresp), .axi_bvalid(magic_axi_bvalid), .axi_bready(magic_axi_bready),
        .axi_araddr(magic_axi_araddr), .axi_arvalid(magic_axi_arvalid), .axi_arready(magic_axi_arready),
        .axi_rdata(magic_axi_rdata), .axi_rresp(magic_axi_rresp), .axi_rvalid(magic_axi_rvalid), .axi_rready(magic_axi_rready)
    );

endmodule

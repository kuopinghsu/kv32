module kv32_soc #(
    parameter int unsigned CLK_FREQ          = 100_000_000,
    parameter int unsigned BAUD_RATE         = 25_000_000,
    parameter int unsigned IB_DEPTH          = 4,
    parameter int unsigned SB_DEPTH          = 2,
    parameter int unsigned FAST_MUL          = 1,
    parameter int unsigned FAST_DIV          = 1,
    parameter bit          BP_EN             = 1'b1,
    parameter int unsigned BTB_SIZE          = 32,
    parameter int unsigned BHT_SIZE          = 64,
    parameter bit          RAS_EN            = 1'b1,
    parameter int unsigned RAS_DEPTH         = 8,
    parameter bit          ICACHE_EN         = 1'b1,
    parameter int unsigned ICACHE_SIZE       = 4096,
    parameter int unsigned ICACHE_LINE_SIZE  = 32,
    parameter int unsigned ICACHE_WAYS       = 2,
    parameter bit          DCACHE_EN         = 1'b1,
    parameter int unsigned DCACHE_SIZE       = 4096,
    parameter int unsigned DCACHE_LINE_SIZE  = 32,
    parameter int unsigned DCACHE_WAYS       = 2,
    parameter bit          DCACHE_WRITE_BACK = 1'b1,
    parameter bit          DCACHE_WRITE_ALLOC= 1'b1,
    parameter bit          USE_CJTAG         = 1'b1,
    parameter bit [31:0]   JTAG_IDCODE       = 32'h1DEAD3FF,
    parameter int unsigned GPIO_NUM_PINS     = 4
) (
    input  logic clk,
    input  logic rst_n,

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

    input  logic        jtag_tck_i,
    input  logic        jtag_tms_i,
    output logic        jtag_tms_o,
    output logic        jtag_tms_oe,
    input  logic        jtag_tdi_i,
    output logic        jtag_tdo_o,
    output logic        jtag_tdo_oe,
    output logic        cjtag_online_o,

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

    output logic [63:0] cycle_count,
    output logic [63:0] instret_count,
    output logic [63:0] stall_count,
    output logic [63:0] first_retire_cycle,
    output logic [63:0] last_retire_cycle,
    output logic        wdt_reset_o
`ifndef SYNTHESIS
    ,output logic       timeout_error,
    input  logic        trace_mode,
    output logic [31:0] icache_perf_req_cnt,
    output logic [31:0] icache_perf_hit_cnt,
    output logic [31:0] icache_perf_miss_cnt,
    output logic [31:0] icache_perf_bypass_cnt,
    output logic [31:0] icache_perf_fill_cnt,
    output logic [31:0] icache_perf_cmo_cnt,
    output logic [31:0] dcache_perf_req_cnt,
    output logic [31:0] dcache_perf_hit_cnt,
    output logic [31:0] dcache_perf_miss_cnt,
    output logic [31:0] dcache_perf_bypass_cnt,
    output logic [31:0] dcache_perf_fill_cnt,
    output logic [31:0] dcache_perf_evict_cnt,
    output logic [31:0] dcache_perf_cmo_cnt,
    output logic [31:0] bp_perf_branch_cnt,
    output logic [31:0] bp_perf_jump_cnt,
    output logic [31:0] bp_perf_pred_cnt,
    output logic [31:0] bp_perf_mispred_cnt,
    output logic [31:0] bp_perf_ras_push_cnt,
    output logic [31:0] bp_perf_ras_pop_cnt
`endif
);

    logic        timer_irq;
    logic        software_irq;
    logic        external_irq;
    logic        soc_rst_n;

    logic [31:0] imem_axi_araddr;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] imem_axi_arid;
    logic        imem_axi_arvalid;
    logic        imem_axi_arready;
    logic [7:0]  imem_axi_arlen;
    logic [2:0]  imem_axi_arsize;
    logic [1:0]  imem_axi_arburst;
    logic [31:0] imem_axi_rdata;
    logic [1:0]  imem_axi_rresp;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] imem_axi_rid;
    logic        imem_axi_rvalid;
    logic        imem_axi_rready;
    logic        imem_axi_rlast;

    logic [31:0] dmem_axi_awaddr;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] dmem_axi_awid;
    logic [7:0]  dmem_axi_awlen;
    logic [2:0]  dmem_axi_awsize;
    logic [1:0]  dmem_axi_awburst;
    logic        dmem_axi_awvalid;
    logic        dmem_axi_awready;
    logic [31:0] dmem_axi_wdata;
    logic [3:0]  dmem_axi_wstrb;
    logic        dmem_axi_wlast;
    logic        dmem_axi_wvalid;
    logic        dmem_axi_wready;
    logic [1:0]  dmem_axi_bresp;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] dmem_axi_bid;
    logic        dmem_axi_bvalid;
    logic        dmem_axi_bready;
    logic [31:0] dmem_axi_araddr;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] dmem_axi_arid;
    logic [7:0]  dmem_axi_arlen;
    logic [2:0]  dmem_axi_arsize;
    logic [1:0]  dmem_axi_arburst;
    logic        dmem_axi_arvalid;
    logic        dmem_axi_arready;
    logic [31:0] dmem_axi_rdata;
    logic [1:0]  dmem_axi_rresp;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] dmem_axi_rid;
    logic        dmem_axi_rlast;
    logic        dmem_axi_rvalid;
    logic        dmem_axi_rready;

`ifndef SYNTHESIS
    logic core_retire_instr;
    logic core_wb_store;
    logic [31:0] core_wb_store_addr;
    logic [31:0] core_wb_store_data;
    logic [3:0]  core_wb_store_strb;
`endif

    logic core_sleep;
    logic [31:0] dummy_axi;
    logic [31:0] core_wb_store_addr_o_dummy;
    logic [31:0] core_wb_store_data_o_dummy;
    logic [3:0]  core_wb_store_strb_o_dummy;
    logic        dummy_axi_unused;
    logic        core_dummy_unused;

    assign dummy_axi_unused = |dummy_axi;
    assign core_dummy_unused = ^{core_wb_store_addr_o_dummy, core_wb_store_data_o_dummy, core_wb_store_strb_o_dummy};

    kv32_top #(
        .IB_DEPTH(IB_DEPTH),
        .SB_DEPTH(SB_DEPTH),
        .FAST_MUL(FAST_MUL),
        .FAST_DIV(FAST_DIV),
        .BP_EN(BP_EN),
        .BTB_SIZE(BTB_SIZE),
        .BHT_SIZE(BHT_SIZE),
        .RAS_EN(RAS_EN),
        .RAS_DEPTH(RAS_DEPTH),
        .ICACHE_EN(ICACHE_EN),
        .ICACHE_SIZE(ICACHE_SIZE),
        .ICACHE_LINE_SIZE(ICACHE_LINE_SIZE),
        .ICACHE_WAYS(ICACHE_WAYS),
        .DCACHE_EN(DCACHE_EN),
        .DCACHE_SIZE(DCACHE_SIZE),
        .DCACHE_LINE_SIZE(DCACHE_LINE_SIZE),
        .DCACHE_WAYS(DCACHE_WAYS),
        .DCACHE_WRITE_BACK(DCACHE_WRITE_BACK),
        .DCACHE_WRITE_ALLOC(DCACHE_WRITE_ALLOC),
        .USE_CJTAG(USE_CJTAG),
        .JTAG_IDCODE(JTAG_IDCODE)
    ) u_kv32_top (
        .clk(clk),
        .rst_n(rst_n),
        .timer_irq_i(timer_irq),
        .software_irq_i(software_irq),
        .external_irq_i(external_irq),
        .soc_rst_n_o(soc_rst_n),
        .imem_axi_araddr(imem_axi_araddr),
        .imem_axi_arid(imem_axi_arid),
        .imem_axi_arvalid(imem_axi_arvalid),
        .imem_axi_arready(imem_axi_arready),
        .imem_axi_arlen(imem_axi_arlen),
        .imem_axi_arsize(imem_axi_arsize),
        .imem_axi_arburst(imem_axi_arburst),
        .imem_axi_rdata(imem_axi_rdata),
        .imem_axi_rresp(imem_axi_rresp),
        .imem_axi_rid(imem_axi_rid),
        .imem_axi_rvalid(imem_axi_rvalid),
        .imem_axi_rready(imem_axi_rready),
        .imem_axi_rlast(imem_axi_rlast),
        .dmem_axi_awaddr(dmem_axi_awaddr),
        .dmem_axi_awid(dmem_axi_awid),
        .dmem_axi_awlen(dmem_axi_awlen),
        .dmem_axi_awsize(dmem_axi_awsize),
        .dmem_axi_awburst(dmem_axi_awburst),
        .dmem_axi_awvalid(dmem_axi_awvalid),
        .dmem_axi_awready(dmem_axi_awready),
        .dmem_axi_wdata(dmem_axi_wdata),
        .dmem_axi_wstrb(dmem_axi_wstrb),
        .dmem_axi_wlast(dmem_axi_wlast),
        .dmem_axi_wvalid(dmem_axi_wvalid),
        .dmem_axi_wready(dmem_axi_wready),
        .dmem_axi_bresp(dmem_axi_bresp),
        .dmem_axi_bid(dmem_axi_bid),
        .dmem_axi_bvalid(dmem_axi_bvalid),
        .dmem_axi_bready(dmem_axi_bready),
        .dmem_axi_araddr(dmem_axi_araddr),
        .dmem_axi_arid(dmem_axi_arid),
        .dmem_axi_arlen(dmem_axi_arlen),
        .dmem_axi_arsize(dmem_axi_arsize),
        .dmem_axi_arburst(dmem_axi_arburst),
        .dmem_axi_arvalid(dmem_axi_arvalid),
        .dmem_axi_arready(dmem_axi_arready),
        .dmem_axi_rdata(dmem_axi_rdata),
        .dmem_axi_rresp(dmem_axi_rresp),
        .dmem_axi_rid(dmem_axi_rid),
        .dmem_axi_rlast(dmem_axi_rlast),
        .dmem_axi_rvalid(dmem_axi_rvalid),
        .dmem_axi_rready(dmem_axi_rready),
        .jtag_tck_i(jtag_tck_i),
        .jtag_tms_i(jtag_tms_i),
        .jtag_tms_o(jtag_tms_o),
        .jtag_tms_oe(jtag_tms_oe),
        .jtag_tdi_i(jtag_tdi_i),
        .jtag_tdo_o(jtag_tdo_o),
        .jtag_tdo_oe(jtag_tdo_oe),
        .cjtag_online_o(cjtag_online_o),
        .cycle_count(cycle_count),
        .instret_count(instret_count),
        .stall_count(stall_count),
        .first_retire_cycle(first_retire_cycle),
        .last_retire_cycle(last_retire_cycle),
        .core_sleep_o(core_sleep),
`ifndef SYNTHESIS
        .trace_mode(trace_mode),
        .timeout_error(timeout_error),
        .icache_perf_req_cnt(icache_perf_req_cnt),
        .icache_perf_hit_cnt(icache_perf_hit_cnt),
        .icache_perf_miss_cnt(icache_perf_miss_cnt),
        .icache_perf_bypass_cnt(icache_perf_bypass_cnt),
        .icache_perf_fill_cnt(icache_perf_fill_cnt),
        .icache_perf_cmo_cnt(icache_perf_cmo_cnt),
        .dcache_perf_req_cnt(dcache_perf_req_cnt),
        .dcache_perf_hit_cnt(dcache_perf_hit_cnt),
        .dcache_perf_miss_cnt(dcache_perf_miss_cnt),
        .dcache_perf_bypass_cnt(dcache_perf_bypass_cnt),
        .dcache_perf_fill_cnt(dcache_perf_fill_cnt),
        .dcache_perf_evict_cnt(dcache_perf_evict_cnt),
        .dcache_perf_cmo_cnt(dcache_perf_cmo_cnt),
        .bp_perf_branch_cnt(bp_perf_branch_cnt),
        .bp_perf_jump_cnt(bp_perf_jump_cnt),
        .bp_perf_pred_cnt(bp_perf_pred_cnt),
        .bp_perf_mispred_cnt(bp_perf_mispred_cnt),
        .bp_perf_ras_push_cnt(bp_perf_ras_push_cnt),
        .bp_perf_ras_pop_cnt(bp_perf_ras_pop_cnt),
        .core_retire_instr_o(core_retire_instr),
        .core_wb_store_o(core_wb_store),
        .core_wb_store_addr_o(core_wb_store_addr),
        .core_wb_store_data_o(core_wb_store_data),
        .core_wb_store_strb_o(core_wb_store_strb),
`endif
        .core_wb_store_addr_o_dummy(core_wb_store_addr_o_dummy),
        .core_wb_store_data_o_dummy(core_wb_store_data_o_dummy),
        .core_wb_store_strb_o_dummy(core_wb_store_strb_o_dummy)
    );

    axi_top #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE),
        .GPIO_NUM_PINS(GPIO_NUM_PINS)
    ) u_axi_top (
        .clk(clk),
        .soc_rst_n(soc_rst_n),
        .imem_axi_araddr(imem_axi_araddr),
        .imem_axi_arid(imem_axi_arid),
        .imem_axi_arvalid(imem_axi_arvalid),
        .imem_axi_arready(imem_axi_arready),
        .imem_axi_arlen(imem_axi_arlen),
        .imem_axi_arsize(imem_axi_arsize),
        .imem_axi_arburst(imem_axi_arburst),
        .imem_axi_rdata(imem_axi_rdata),
        .imem_axi_rresp(imem_axi_rresp),
        .imem_axi_rid(imem_axi_rid),
        .imem_axi_rvalid(imem_axi_rvalid),
        .imem_axi_rready(imem_axi_rready),
        .imem_axi_rlast(imem_axi_rlast),
        .dmem_axi_awaddr(dmem_axi_awaddr),
        .dmem_axi_awid(dmem_axi_awid),
        .dmem_axi_awlen(dmem_axi_awlen),
        .dmem_axi_awsize(dmem_axi_awsize),
        .dmem_axi_awburst(dmem_axi_awburst),
        .dmem_axi_awvalid(dmem_axi_awvalid),
        .dmem_axi_awready(dmem_axi_awready),
        .dmem_axi_wdata(dmem_axi_wdata),
        .dmem_axi_wstrb(dmem_axi_wstrb),
        .dmem_axi_wlast(dmem_axi_wlast),
        .dmem_axi_wvalid(dmem_axi_wvalid),
        .dmem_axi_wready(dmem_axi_wready),
        .dmem_axi_bresp(dmem_axi_bresp),
        .dmem_axi_bid(dmem_axi_bid),
        .dmem_axi_bvalid(dmem_axi_bvalid),
        .dmem_axi_bready(dmem_axi_bready),
        .dmem_axi_araddr(dmem_axi_araddr),
        .dmem_axi_arid(dmem_axi_arid),
        .dmem_axi_arlen(dmem_axi_arlen),
        .dmem_axi_arsize(dmem_axi_arsize),
        .dmem_axi_arburst(dmem_axi_arburst),
        .dmem_axi_arvalid(dmem_axi_arvalid),
        .dmem_axi_arready(dmem_axi_arready),
        .dmem_axi_rdata(dmem_axi_rdata),
        .dmem_axi_rresp(dmem_axi_rresp),
        .dmem_axi_rid(dmem_axi_rid),
        .dmem_axi_rlast(dmem_axi_rlast),
        .dmem_axi_rvalid(dmem_axi_rvalid),
        .dmem_axi_rready(dmem_axi_rready),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .m_axi_rlast(m_axi_rlast),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .spi_sclk(spi_sclk),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso),
        .spi_cs_n(spi_cs_n),
        .i2c_scl_o(i2c_scl_o),
        .i2c_scl_i(i2c_scl_i),
        .i2c_scl_oe(i2c_scl_oe),
        .i2c_sda_o(i2c_sda_o),
        .i2c_sda_i(i2c_sda_i),
        .i2c_sda_oe(i2c_sda_oe),
        .gpio_o(gpio_o),
        .gpio_i(gpio_i),
        .gpio_oe(gpio_oe),
        .pwm_o(pwm_o),
        .timer_irq_o(timer_irq),
        .software_irq_o(software_irq),
        .external_irq_o(external_irq),
        .wdt_reset_o(wdt_reset_o),
        .core_sleep_i(core_sleep),
`ifndef SYNTHESIS
        .trace_mode(trace_mode),
        .core_retire_instr(core_retire_instr),
        .core_wb_store(core_wb_store),
        .core_wb_store_addr(core_wb_store_addr),
        .core_wb_store_data(core_wb_store_data),
        .core_wb_store_strb(core_wb_store_strb),
`endif
        .dummy_o(dummy_axi)
    );

endmodule


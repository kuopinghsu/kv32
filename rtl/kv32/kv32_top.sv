module kv32_top #(
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
    parameter bit [31:0]   JTAG_IDCODE       = 32'h1DEAD3FF
) (
    input  logic clk,
    input  logic rst_n,

    input  logic        timer_irq_i,
    input  logic        software_irq_i,
    input  logic        external_irq_i,

    output logic        soc_rst_n_o,

    output logic [31:0] imem_axi_araddr,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] imem_axi_arid,
    output logic        imem_axi_arvalid,
    input  logic        imem_axi_arready,
    output logic [7:0]  imem_axi_arlen,
    output logic [2:0]  imem_axi_arsize,
    output logic [1:0]  imem_axi_arburst,
    input  logic [31:0] imem_axi_rdata,
    input  logic [1:0]  imem_axi_rresp,
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] imem_axi_rid,
    input  logic        imem_axi_rvalid,
    output logic        imem_axi_rready,
    input  logic        imem_axi_rlast,

    output logic [31:0] dmem_axi_awaddr,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] dmem_axi_awid,
    output logic [7:0]  dmem_axi_awlen,
    output logic [2:0]  dmem_axi_awsize,
    output logic [1:0]  dmem_axi_awburst,
    output logic        dmem_axi_awvalid,
    input  logic        dmem_axi_awready,
    output logic [31:0] dmem_axi_wdata,
    output logic [3:0]  dmem_axi_wstrb,
    output logic        dmem_axi_wlast,
    output logic        dmem_axi_wvalid,
    input  logic        dmem_axi_wready,
    input  logic [1:0]  dmem_axi_bresp,
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] dmem_axi_bid,
    input  logic        dmem_axi_bvalid,
    output logic        dmem_axi_bready,
    output logic [31:0] dmem_axi_araddr,
    output logic [axi_pkg::AXI_ID_WIDTH-1:0] dmem_axi_arid,
    output logic [7:0]  dmem_axi_arlen,
    output logic [2:0]  dmem_axi_arsize,
    output logic [1:0]  dmem_axi_arburst,
    output logic        dmem_axi_arvalid,
    input  logic        dmem_axi_arready,
    input  logic [31:0] dmem_axi_rdata,
    input  logic [1:0]  dmem_axi_rresp,
    input  logic [axi_pkg::AXI_ID_WIDTH-1:0] dmem_axi_rid,
    input  logic        dmem_axi_rlast,
    input  logic        dmem_axi_rvalid,
    output logic        dmem_axi_rready,

    input  logic        jtag_tck_i,
    input  logic        jtag_tms_i,
    output logic        jtag_tms_o,
    output logic        jtag_tms_oe,
    input  logic        jtag_tdi_i,
    output logic        jtag_tdo_o,
    output logic        jtag_tdo_oe,
    output logic        cjtag_online_o,

    output logic [63:0] cycle_count,
    output logic [63:0] instret_count,
    output logic [63:0] stall_count,
    output logic [63:0] first_retire_cycle,
    output logic [63:0] last_retire_cycle,

    output logic        core_sleep_o,

`ifndef SYNTHESIS
    input  logic        trace_mode,
    output logic        timeout_error,
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
    output logic [31:0] bp_perf_ras_pop_cnt,
    output logic        core_retire_instr_o,
    output logic        core_wb_store_o,
    output logic [31:0] core_wb_store_addr_o,
    output logic [31:0] core_wb_store_data_o,
    output logic [3:0]  core_wb_store_strb_o,
`endif

    output logic [31:0] core_wb_store_addr_o_dummy,
    output logic [31:0] core_wb_store_data_o_dummy,
    output logic [3:0]  core_wb_store_strb_o_dummy
);

    logic cpu_rst_n;
    logic soc_rst_n;

    logic        dbg_halt_req;
    logic        dbg_halted;
    logic        dbg_resume_req;
    logic        dbg_resumeack;
    logic [4:0]  dbg_reg_addr;
    logic [31:0] dbg_reg_wdata;
    logic        dbg_reg_we;
    logic [31:0] dbg_reg_rdata;
    logic [31:0] dbg_pc;
    logic [31:0] dbg_pc_wdata;
    logic        dbg_pc_we;
    logic        dbg_mem_req;
    logic [31:0] dbg_mem_addr;
    logic [3:0]  dbg_mem_we;
    logic [31:0] dbg_mem_wdata;
    logic        dbg_mem_ready;
    logic [31:0] dbg_mem_rdata;
    logic        dbg_ndmreset;
    logic        dbg_hartreset;

    logic        external_irq_meta;
    logic        external_irq_sync;

    logic        core_sleep;
    logic        core_clk;
    logic        core_wakeup;
    logic        icache_idle;
    logic        dcache_idle;

    logic [1:0][31:0] pma_cfg;
    logic [7:0][31:0] pma_addr;

    logic [31:0] core_icap;
    logic [31:0] core_dcap;
    logic        core_cdiag_req;
    logic        core_cdiag_sel;
    logic [1:0]  core_cdiag_way;
    logic [5:0]  core_cdiag_set;
    logic [3:0]  core_cdiag_word;
    logic        cdiag_sel_d;
    logic [31:0] icache_diag_tag;
    logic [31:0] icache_diag_data;
    logic        icache_diag_valid;
    logic [31:0] dcache_diag_tag;
    logic [31:0] dcache_diag_data;
    logic        dcache_diag_valid;
    logic        dcache_diag_dirty;
    logic [31:0] core_cdiag_tag;
    logic [31:0] core_cdiag_data;
    logic        core_cdiag_valid;
    logic        core_cdiag_dirty;

    logic        core_cmo_valid;
    logic [1:0]  core_cmo_op;
    logic [31:0] core_cmo_addr;
    logic        core_cmo_ready;

    logic        core_dcache_cmo_valid;
    logic [1:0]  core_dcache_cmo_op;
    logic [31:0] core_dcache_cmo_addr;
    logic        core_dcache_cmo_ready;

    logic        imem_req_valid;
    logic [31:0] imem_req_addr;
    logic        imem_req_ready;
    logic [31:0] imem_req_addr_fill;
    logic        imem_resp_valid;
    logic [31:0] imem_resp_data;
    logic        imem_resp_error;
    logic        imem_resp_ready;

    logic        dmem_req_valid;
    logic [31:0] dmem_req_addr;
    logic [3:0]  dmem_req_we;
    logic [31:0] dmem_req_wdata;
    logic        dmem_req_ready;
    logic        dmem_resp_valid;
    logic [31:0] dmem_resp_data;
    logic        dmem_resp_error;
    logic        dmem_resp_is_write;
    logic        dmem_resp_ready;

    logic        cjtag_nsp_unused;
    logic        dbg_mem_unused;
    logic [10:0] core_cdiag_tag_hi_unused;
    logic        axi_id_unused;

`ifndef SYNTHESIS
    logic        core_retire_instr;
    logic        core_wb_store;
    logic [31:0] core_wb_store_addr;
    logic [31:0] core_wb_store_data;
    logic [3:0]  core_wb_store_strb;
`endif

    assign dbg_mem_ready = 1'b0;
    assign dbg_mem_rdata = 32'h0;

    assign cpu_rst_n = rst_n && !dbg_ndmreset && !dbg_hartreset;
    assign soc_rst_n = rst_n && !dbg_ndmreset;
    assign soc_rst_n_o = soc_rst_n;
    assign core_sleep_o = core_sleep;

`ifndef SYNTHESIS
    assign core_retire_instr_o = core_retire_instr;
    assign core_wb_store_o = core_wb_store;
    assign core_wb_store_addr_o = core_wb_store_addr;
    assign core_wb_store_data_o = core_wb_store_data;
    assign core_wb_store_strb_o = core_wb_store_strb;
`endif

    assign core_wb_store_addr_o_dummy = 32'h0;
    assign core_wb_store_data_o_dummy = 32'h0;
    assign core_wb_store_strb_o_dummy = 4'h0;
    assign axi_id_unused = ^{imem_axi_rid, dmem_axi_bid, dmem_axi_rid};
    assign dbg_mem_unused = dbg_mem_req | (|dbg_mem_addr) | (|dbg_mem_we) | (|dbg_mem_wdata);
    assign core_cdiag_tag_hi_unused = core_cdiag_tag[31:21];

    always_ff @(posedge clk or negedge soc_rst_n) begin
        if (!soc_rst_n) begin
            external_irq_meta <= 1'b0;
            external_irq_sync <= 1'b0;
        end else begin
            external_irq_meta <= external_irq_i;
            external_irq_sync <= external_irq_meta;
        end
    end

    always_ff @(posedge core_clk or negedge cpu_rst_n) begin
        if (!cpu_rst_n)
            cdiag_sel_d <= 1'b0;
        else if (core_cdiag_req)
            cdiag_sel_d <= core_cdiag_sel;
    end

    assign core_cdiag_tag   = cdiag_sel_d ? dcache_diag_tag   : icache_diag_tag;
    assign core_cdiag_data  = cdiag_sel_d ? dcache_diag_data  : icache_diag_data;
    assign core_cdiag_valid = cdiag_sel_d ? dcache_diag_valid : icache_diag_valid;
    assign core_cdiag_dirty = cdiag_sel_d ? dcache_diag_dirty : 1'b0;

    kv32_pm u_kv32_pm (
        .clk_i         (clk),
        .rst_n         (rst_n),
        .sleep_req_i   (core_sleep),
        .timer_irq_i   (timer_irq_i),
        .external_irq_i(external_irq_sync),
        .software_irq_i(software_irq_i),
        .gated_clk_o   (core_clk),
        .wakeup_o      (core_wakeup)
    );

    kv32_core #(
        .IB_DEPTH(IB_DEPTH),
        .SB_DEPTH(SB_DEPTH),
        .FAST_MUL(FAST_MUL),
        .FAST_DIV(FAST_DIV),
        .BP_EN(BP_EN),
        .BTB_SIZE(BTB_SIZE),
        .BHT_SIZE(BHT_SIZE),
        .RAS_EN(RAS_EN),
        .RAS_DEPTH(RAS_DEPTH)
    ) core (
        .clk(core_clk),
        .rst_n(cpu_rst_n),
        .imem_req_valid(imem_req_valid),
        .imem_req_addr(imem_req_addr),
        .imem_req_ready(imem_req_ready),
        .imem_req_addr_fill(imem_req_addr_fill),
        .imem_resp_valid(imem_resp_valid),
        .imem_resp_data(imem_resp_data),
        .imem_resp_error(imem_resp_error),
        .imem_resp_ready(imem_resp_ready),
        .dmem_req_valid(dmem_req_valid),
        .dmem_req_addr(dmem_req_addr),
        .dmem_req_we(dmem_req_we),
        .dmem_req_wdata(dmem_req_wdata),
        .dmem_req_ready(dmem_req_ready),
        .dmem_resp_valid(dmem_resp_valid),
        .dmem_resp_data(dmem_resp_data),
        .dmem_resp_error(dmem_resp_error),
        .dmem_resp_is_write(dmem_resp_is_write),
        .dmem_resp_ready(dmem_resp_ready),
        .timer_irq(timer_irq_i),
        .external_irq(external_irq_sync),
        .software_irq(software_irq_i),
        .cycle_count(cycle_count),
        .instret_count(instret_count),
        .stall_count(stall_count),
        .first_retire_cycle(first_retire_cycle),
        .last_retire_cycle(last_retire_cycle),
        .icache_cmo_valid(core_cmo_valid),
        .icache_cmo_op(core_cmo_op),
        .icache_cmo_addr(core_cmo_addr),
        .icache_cmo_ready(core_cmo_ready),
        .icache_idle_i   (icache_idle),
        .dcache_cmo_valid(core_dcache_cmo_valid),
        .dcache_cmo_op   (core_dcache_cmo_op),
        .dcache_cmo_addr (core_dcache_cmo_addr),
        .dcache_cmo_ready(core_dcache_cmo_ready),
        .dcache_idle_i   (dcache_idle),
        .core_sleep_o(core_sleep),
        .wakeup_i    (core_wakeup),
        .pma_cfg_o (pma_cfg),
        .pma_addr_o(pma_addr),
        .icap_i       (core_icap),
        .dcap_i       (core_dcap),
        .cdiag_tag_i  (core_cdiag_tag[20:0]),
        .cdiag_dirty_i(core_cdiag_dirty),
        .cdiag_valid_i(core_cdiag_valid),
        .cdiag_data_i (core_cdiag_data),
        .cdiag_req_o  (core_cdiag_req),
        .cdiag_sel_o  (core_cdiag_sel),
        .cdiag_way_o  (core_cdiag_way),
        .cdiag_set_o  (core_cdiag_set),
        .cdiag_word_o (core_cdiag_word),
        .dbg_halt_req_i(dbg_halt_req),
        .dbg_halted_o(dbg_halted),
        .dbg_resume_req_i(dbg_resume_req),
        .dbg_resumeack_o(dbg_resumeack),
        .dbg_reg_addr_i(dbg_reg_addr),
        .dbg_reg_wdata_i(dbg_reg_wdata),
        .dbg_reg_we_i(dbg_reg_we),
        .dbg_reg_rdata_o(dbg_reg_rdata),
        .dbg_pc_o(dbg_pc),
        .dbg_pc_i(dbg_pc_wdata),
        .dbg_pc_we_i(dbg_pc_we)
`ifndef SYNTHESIS
        ,.timeout_error(timeout_error)
        ,.retire_instr_out(core_retire_instr)
        ,.wb_store_out(core_wb_store)
        ,.wb_store_addr_out(core_wb_store_addr)
        ,.wb_store_data_out(core_wb_store_data)
        ,.wb_store_strb_out(core_wb_store_strb)
        ,.trace_mode(trace_mode)
        ,.bp_perf_branch_cnt(bp_perf_branch_cnt)
        ,.bp_perf_jump_cnt(bp_perf_jump_cnt)
        ,.bp_perf_pred_cnt(bp_perf_pred_cnt)
        ,.bp_perf_mispred_cnt(bp_perf_mispred_cnt)
        ,.bp_perf_ras_push_cnt(bp_perf_ras_push_cnt)
        ,.bp_perf_ras_pop_cnt(bp_perf_ras_pop_cnt)
`endif
    );

    if (ICACHE_EN) begin : g_icache
        logic icache_cmo_ready_w;
        logic icache_idle_w;

        assign core_cmo_ready = icache_cmo_ready_w;
        assign icache_idle    = icache_idle_w;

        kv32_icache #(
            .CACHE_SIZE     (ICACHE_SIZE),
            .CACHE_LINE_SIZE(ICACHE_LINE_SIZE),
            .CACHE_WAYS     (ICACHE_WAYS)
        ) icache (
            .clk    (core_clk),
            .rst_n  (cpu_rst_n),
            .imem_req_valid (imem_req_valid),
            .imem_req_addr  (imem_req_addr),
            .imem_req_ready (imem_req_ready),
            .imem_req_addr_fill (imem_req_addr_fill),
            .imem_resp_valid(imem_resp_valid),
            .imem_resp_data (imem_resp_data),
            .imem_resp_error(imem_resp_error),
            .imem_resp_ready(imem_resp_ready),
            .axi_araddr  (imem_axi_araddr),
            .axi_arvalid (imem_axi_arvalid),
            .axi_arready (imem_axi_arready),
            .axi_arlen   (imem_axi_arlen),
            .axi_arsize  (imem_axi_arsize),
            .axi_arburst (imem_axi_arburst),
            .axi_rdata   (imem_axi_rdata),
            .axi_rresp   (imem_axi_rresp),
            .axi_rvalid  (imem_axi_rvalid),
            .axi_rlast   (imem_axi_rlast),
            .axi_rready  (imem_axi_rready),
            .cmo_valid  (core_cmo_valid),
            .cmo_addr   (core_cmo_addr),
            .cmo_op     (core_cmo_op),
            .cmo_ready  (icache_cmo_ready_w),
            .pma_cfg_i (pma_cfg),
            .pma_addr_i(pma_addr),
            .cap_o      (core_icap),
            .diag_req_i (core_cdiag_req && !core_cdiag_sel),
            .diag_way_i (core_cdiag_way),
            .diag_set_i (core_cdiag_set),
            .diag_word_i(core_cdiag_word),
            .diag_valid_o(icache_diag_valid),
            .diag_tag_o  (icache_diag_tag),
            .diag_data_o (icache_diag_data),
            .icache_idle(icache_idle_w)
`ifndef SYNTHESIS
            ,.perf_req_cnt    (icache_perf_req_cnt)
            ,.perf_hit_cnt    (icache_perf_hit_cnt)
            ,.perf_miss_cnt   (icache_perf_miss_cnt)
            ,.perf_bypass_cnt (icache_perf_bypass_cnt)
            ,.perf_fill_cnt   (icache_perf_fill_cnt)
            ,.perf_cmo_cnt    (icache_perf_cmo_cnt)
`endif
        );

        assign imem_axi_arid = '0;

    end else begin : g_no_icache
        mem_axi_ro #(
`ifndef SYNTHESIS
            .BRIDGE_NAME("IMEM_BRIDGE"),
`endif
            .OUTSTANDING_DEPTH(IB_DEPTH)
        ) imem_bridge (
            .clk(clk),
            .rst_n(cpu_rst_n),
            .mem_req_valid(imem_req_valid),
            .mem_req_addr (imem_req_addr),
            .mem_req_ready(imem_req_ready),
            .mem_resp_valid(imem_resp_valid),
            .mem_resp_data (imem_resp_data),
            .mem_resp_error(imem_resp_error),
            .mem_resp_ready(imem_resp_ready),
            .axi_araddr (imem_axi_araddr),
            .axi_arid   (imem_axi_arid),
            .axi_arvalid(imem_axi_arvalid),
            .axi_arready(imem_axi_arready),
            .axi_rdata  (imem_axi_rdata),
            .axi_rresp  (imem_axi_rresp),
            .axi_rid    (imem_axi_rid),
            .axi_rvalid (imem_axi_rvalid),
            .axi_rready (imem_axi_rready)
        );

        assign imem_axi_arlen   = 8'h00;
        assign imem_axi_arsize  = 3'b010;
        assign imem_axi_arburst = 2'b01;
        assign core_cmo_ready   = 1'b1;
        assign icache_idle      = 1'b1;
        assign core_icap        = 32'd0;
        assign icache_diag_valid = 1'b0;
        assign icache_diag_tag   = 32'd0;
        assign icache_diag_data  = 32'd0;
`ifndef SYNTHESIS
        assign icache_perf_req_cnt    = '0;
        assign icache_perf_hit_cnt    = '0;
        assign icache_perf_miss_cnt   = '0;
        assign icache_perf_bypass_cnt = '0;
        assign icache_perf_fill_cnt   = '0;
        assign icache_perf_cmo_cnt    = '0;
`endif
    end

    if (DCACHE_EN) begin : g_dcache
        kv32_dcache #(
            .DCACHE_SIZE       (DCACHE_SIZE),
            .DCACHE_LINE_SIZE  (DCACHE_LINE_SIZE),
            .DCACHE_WAYS       (DCACHE_WAYS),
            .DCACHE_WRITE_BACK (DCACHE_WRITE_BACK),
            .DCACHE_WRITE_ALLOC(DCACHE_WRITE_ALLOC)
        ) dcache (
            .clk    (core_clk),
            .rst_n  (cpu_rst_n),
            .core_req_valid    (dmem_req_valid),
            .core_req_addr     (dmem_req_addr),
            .core_req_we       (dmem_req_we),
            .core_req_wdata    (dmem_req_wdata),
            .core_req_ready    (dmem_req_ready),
            .core_resp_valid   (dmem_resp_valid),
            .core_resp_data    (dmem_resp_data),
            .core_resp_error   (dmem_resp_error),
            .core_resp_is_write(dmem_resp_is_write),
            .core_resp_ready   (dmem_resp_ready),
            .cmo_valid_i(core_dcache_cmo_valid),
            .cmo_op_i   (core_dcache_cmo_op),
            .cmo_addr_i (core_dcache_cmo_addr),
            .cmo_ready_o(core_dcache_cmo_ready),
            .axi_awvalid(dmem_axi_awvalid),
            .axi_awaddr (dmem_axi_awaddr),
            .axi_awlen  (dmem_axi_awlen),
            .axi_awsize (dmem_axi_awsize),
            .axi_awburst(dmem_axi_awburst),
            .axi_awready(dmem_axi_awready),
            .axi_wvalid (dmem_axi_wvalid),
            .axi_wdata  (dmem_axi_wdata),
            .axi_wstrb  (dmem_axi_wstrb),
            .axi_wlast  (dmem_axi_wlast),
            .axi_wready (dmem_axi_wready),
            .axi_bresp  (dmem_axi_bresp),
            .axi_bvalid (dmem_axi_bvalid),
            .axi_bready (dmem_axi_bready),
            .axi_arvalid(dmem_axi_arvalid),
            .axi_araddr (dmem_axi_araddr),
            .axi_arlen  (dmem_axi_arlen),
            .axi_arsize (dmem_axi_arsize),
            .axi_arburst(dmem_axi_arburst),
            .axi_arready(dmem_axi_arready),
            .axi_rdata  (dmem_axi_rdata),
            .axi_rresp  (dmem_axi_rresp),
            .axi_rlast  (dmem_axi_rlast),
            .axi_rvalid (dmem_axi_rvalid),
            .axi_rready (dmem_axi_rready),
            .dcache_enable_i(1'b1),
            .dcache_idle_o  (dcache_idle),
            .pma_cfg_i (pma_cfg),
            .pma_addr_i(pma_addr),
            .cap_o      (core_dcap),
            .diag_req_i (core_cdiag_req && core_cdiag_sel),
            .diag_way_i (core_cdiag_way),
            .diag_set_i (core_cdiag_set),
            .diag_word_i(core_cdiag_word),
            .diag_valid_o(dcache_diag_valid),
            .diag_dirty_o(dcache_diag_dirty),
            .diag_tag_o  (dcache_diag_tag),
            .diag_data_o (dcache_diag_data)
`ifndef SYNTHESIS
            ,.perf_req_cnt    (dcache_perf_req_cnt)
            ,.perf_hit_cnt    (dcache_perf_hit_cnt)
            ,.perf_miss_cnt   (dcache_perf_miss_cnt)
            ,.perf_bypass_cnt (dcache_perf_bypass_cnt)
            ,.perf_fill_cnt   (dcache_perf_fill_cnt)
            ,.perf_evict_cnt  (dcache_perf_evict_cnt)
            ,.perf_cmo_cnt    (dcache_perf_cmo_cnt)
`endif
        );

        assign dmem_axi_awid  = '0;
        assign dmem_axi_arid  = '0;
    end else begin : g_no_dcache
        mem_axi #(
`ifndef SYNTHESIS
            .BRIDGE_NAME("DMEM_BRIDGE"),
`endif
            .OUTSTANDING_DEPTH(4)
        ) dmem_bridge (
            .clk(clk),
            .rst_n(soc_rst_n),
            .mem_req_valid(dmem_req_valid),
            .mem_req_addr(dmem_req_addr),
            .mem_req_we(dmem_req_we),
            .mem_req_wdata(dmem_req_wdata),
            .mem_req_ready(dmem_req_ready),
            .mem_resp_valid(dmem_resp_valid),
            .mem_resp_data(dmem_resp_data),
            .mem_resp_error(dmem_resp_error),
            .mem_resp_is_write(dmem_resp_is_write),
            .mem_resp_ready(dmem_resp_ready),
            .axi_awaddr(dmem_axi_awaddr),
            .axi_awid(dmem_axi_awid),
            .axi_awvalid(dmem_axi_awvalid),
            .axi_awready(dmem_axi_awready),
            .axi_wdata(dmem_axi_wdata),
            .axi_wstrb(dmem_axi_wstrb),
            .axi_wvalid(dmem_axi_wvalid),
            .axi_wready(dmem_axi_wready),
            .axi_bresp(dmem_axi_bresp),
            .axi_bid(dmem_axi_bid),
            .axi_bvalid(dmem_axi_bvalid),
            .axi_bready(dmem_axi_bready),
            .axi_araddr(dmem_axi_araddr),
            .axi_arid(dmem_axi_arid),
            .axi_arvalid(dmem_axi_arvalid),
            .axi_arready(dmem_axi_arready),
            .axi_rdata(dmem_axi_rdata),
            .axi_rresp(dmem_axi_rresp),
            .axi_rid(dmem_axi_rid),
            .axi_rlast(dmem_axi_rlast),
            .axi_rvalid(dmem_axi_rvalid),
            .axi_rready(dmem_axi_rready)
        );

        assign dmem_axi_awlen   = 8'h00;
        assign dmem_axi_awsize  = 3'b010;
        assign dmem_axi_awburst = 2'b01;
        assign dmem_axi_wlast   = 1'b1;
        assign dmem_axi_arlen   = 8'h00;
        assign dmem_axi_arsize  = 3'b010;
        assign dmem_axi_arburst = 2'b01;
        assign core_dcache_cmo_ready = 1'b1;
        assign dcache_idle           = 1'b1;
        assign core_dcap             = 32'd0;
        assign dcache_diag_valid     = 1'b0;
        assign dcache_diag_dirty     = 1'b0;
        assign dcache_diag_tag       = 32'd0;
        assign dcache_diag_data      = 32'd0;
`ifndef SYNTHESIS
        assign dcache_perf_req_cnt    = '0;
        assign dcache_perf_hit_cnt    = '0;
        assign dcache_perf_miss_cnt   = '0;
        assign dcache_perf_bypass_cnt = '0;
        assign dcache_perf_fill_cnt   = '0;
        assign dcache_perf_evict_cnt  = '0;
        assign dcache_perf_cmo_cnt    = '0;
`endif
    end

    jtag_top #(
        .USE_CJTAG  (USE_CJTAG),
        .IDCODE     (JTAG_IDCODE),
        .IR_LEN     (5)
    ) u_jtag_debug (
        .clk_i          (clk),
        .rst_n_i        (rst_n),
        .ntrst_i        (rst_n),
        .pin0_tck_i     (jtag_tck_i),
        .pin1_tms_i     (jtag_tms_i),
        .pin1_tms_o     (jtag_tms_o),
        .pin1_tms_oe    (jtag_tms_oe),
        .pin2_tdi_i     (jtag_tdi_i),
        .pin3_tdo_o     (jtag_tdo_o),
        .pin3_tdo_oe    (jtag_tdo_oe),
        .cjtag_online_o (cjtag_online_o),
        .cjtag_nsp_o    (cjtag_nsp_unused),
        .halt_req_o      (dbg_halt_req),
        .halted_i        (dbg_halted),
        .resume_req_o    (dbg_resume_req),
        .resumeack_i     (dbg_resumeack),
        .dbg_reg_addr_o  (dbg_reg_addr),
        .dbg_reg_wdata_o (dbg_reg_wdata),
        .dbg_reg_we_o    (dbg_reg_we),
        .dbg_reg_rdata_i (dbg_reg_rdata),
        .dbg_pc_wdata_o  (dbg_pc_wdata),
        .dbg_pc_we_o     (dbg_pc_we),
        .dbg_pc_i        (dbg_pc),
        .dbg_mem_req_o   (dbg_mem_req),
        .dbg_mem_addr_o  (dbg_mem_addr),
        .dbg_mem_we_o    (dbg_mem_we),
        .dbg_mem_wdata_o (dbg_mem_wdata),
        .dbg_mem_ready_i (dbg_mem_ready),
        .dbg_mem_rdata_i (dbg_mem_rdata),
        .dbg_ndmreset_o  (dbg_ndmreset),
        .dbg_hartreset_o (dbg_hartreset)
    );

endmodule

// ============================================================================
// File: tb_rv32_soc.sv
// Project: RV32 RISC-V Processor
// Description: Testbench Wrapper for RV32 SoC
//
// Wraps the RV32 SoC with external AXI memory and peripheral test targets.
// Includes UART loopback, SPI slave memory, and I2C EEPROM for realistic
// peripheral testing in simulation.
// ============================================================================

/* verilator lint_off SYNCASYNCNET */
module tb_rv32_soc #(
    parameter int FAST_MUL         = 1,     // Multiply mode: 1=combinatorial, 0=serial
    parameter int FAST_DIV         = 1,     // Division mode: 1=combinatorial, 0=serial
    parameter int ICACHE_EN        = 1,     // I-cache: 1=enabled, 0=bypass
    parameter int ICACHE_SIZE      = 4096,  // I-cache total bytes
    parameter int ICACHE_LINE_SIZE = 32,    // Cache line size in bytes
    parameter int ICACHE_WAYS      = 2      // Cache associativity
) (
    input wire clk,
    input wire rst_n,
    output wire uart_rx,
    output wire uart_tx,
    output wire spi_miso,
    output wire spi_sclk,
    output wire spi_mosi,
    output wire [3:0] spi_cs_n,
    output wire i2c_scl_i,
    output wire i2c_scl_o,
    output wire i2c_scl_oe,
    output wire i2c_sda_i,
    output wire i2c_sda_o,
    output wire i2c_sda_oe,
    output logic [63:0] cycle_count,
    output logic [63:0] instret_count,
    output logic [63:0] stall_count,
    output logic [63:0] first_retire_cycle,
    output logic [63:0] last_retire_cycle
`ifndef SYNTHESIS
    ,output logic timeout_error
    // Trace-compare mode: when asserted (+TRACE active), cycle/time CSR reads in
    // the core return minstret instead of mcycle, making them pipeline-stall-
    // independent and matching what the software simulator returns.
    ,input  logic trace_mode
    // I-cache performance counters (always present but zero when ICACHE_EN=0)
    ,output logic [31:0] icache_perf_req_cnt
    ,output logic [31:0] icache_perf_hit_cnt
    ,output logic [31:0] icache_perf_miss_cnt
    ,output logic [31:0] icache_perf_bypass_cnt
    ,output logic [31:0] icache_perf_fill_cnt
    ,output logic [31:0] icache_perf_cmo_cnt
`endif
);

    // AXI Interface signals
    logic [31:0] axi_awaddr;
    logic [7:0]  axi_awlen;    // AW burst length
    logic [1:0]  axi_awburst;  // AW burst type
    logic        axi_awvalid;
    logic        axi_awready;
    logic [31:0] axi_wdata;
    logic [3:0]  axi_wstrb;
    logic        axi_wlast;    // W channel last beat
    logic        axi_wvalid;
    logic        axi_wready;
    logic [1:0]  axi_bresp;
    logic        axi_bvalid;
    logic        axi_bready;
    logic [31:0] axi_araddr;
    logic        axi_arvalid;
    logic        axi_arready;
    logic [7:0]  axi_arlen;    // Burst length
    logic [2:0]  axi_arsize;   // Burst size
    logic [1:0]  axi_arburst;  // Burst type
    logic [31:0] axi_rdata;
    logic [1:0]  axi_rresp;
    logic        axi_rvalid;
    logic        axi_rready;
    logic        axi_rlast;    // Last beat of burst

    // Internal signals for testbench peripherals
    logic uart_tx_internal;     // SoC UART TX output
    logic spi_sclk_internal;    // SoC SPI clock output
    logic spi_mosi_internal;    // SoC SPI MOSI output
    logic [3:0] spi_cs_n_internal; // SoC SPI CS outputs
    logic spi_miso_internal;    // SPI slave MISO output
    logic i2c_scl_o_internal, i2c_scl_oe_internal; // SoC I2C SCL outputs
    logic i2c_sda_o_internal, i2c_sda_oe_internal; // SoC I2C SDA outputs
    logic i2c_scl_wire, i2c_sda_wire;
    logic i2c_slave_sda_out, i2c_slave_sda_oe;

    // Instantiate RISC-V SoC
    rv32_soc #(
        .FAST_MUL       (FAST_MUL),
        .FAST_DIV       (FAST_DIV),
        .ICACHE_EN      (ICACHE_EN),
        .ICACHE_SIZE    (ICACHE_SIZE),
        .ICACHE_LINE_SIZE(ICACHE_LINE_SIZE),
        .ICACHE_WAYS    (ICACHE_WAYS)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx_internal),
        // SPI pins
        .spi_sclk(spi_sclk_internal),
        .spi_mosi(spi_mosi_internal),
        .spi_miso(spi_miso_internal),
        .spi_cs_n(spi_cs_n_internal),
        // I2C pins
        .i2c_scl_o(i2c_scl_o_internal),
        .i2c_scl_i(i2c_scl_wire),
        .i2c_scl_oe(i2c_scl_oe_internal),
        .i2c_sda_o(i2c_sda_o_internal),
        .i2c_sda_i(i2c_sda_wire),
        .i2c_sda_oe(i2c_sda_oe_internal),
        // External AXI master port
        .m_axi_awaddr(axi_awaddr),
        .m_axi_awlen (axi_awlen),
        .m_axi_awburst(axi_awburst),
        .m_axi_awvalid(axi_awvalid),
        .m_axi_awready(axi_awready),
        .m_axi_wdata(axi_wdata),
        .m_axi_wstrb(axi_wstrb),
        .m_axi_wlast (axi_wlast),
        .m_axi_wvalid(axi_wvalid),
        .m_axi_wready(axi_wready),
        .m_axi_bresp(axi_bresp),
        .m_axi_bvalid(axi_bvalid),
        .m_axi_bready(axi_bready),
        .m_axi_araddr  (axi_araddr),
        .m_axi_arvalid (axi_arvalid),
        .m_axi_arready (axi_arready),
        .m_axi_arlen   (axi_arlen),
        .m_axi_arsize  (axi_arsize),
        .m_axi_arburst (axi_arburst),
        .m_axi_rdata   (axi_rdata),
        .m_axi_rresp   (axi_rresp),
        .m_axi_rvalid  (axi_rvalid),
        .m_axi_rready  (axi_rready),
        .m_axi_rlast   (axi_rlast),
        .cycle_count(cycle_count),
        .instret_count(instret_count),
        .stall_count(stall_count),
        .first_retire_cycle(first_retire_cycle),
        .last_retire_cycle(last_retire_cycle)
`ifndef SYNTHESIS
        ,.timeout_error(timeout_error)
        ,.trace_mode(trace_mode)
        ,.icache_perf_req_cnt   (icache_perf_req_cnt)
        ,.icache_perf_hit_cnt   (icache_perf_hit_cnt)
        ,.icache_perf_miss_cnt  (icache_perf_miss_cnt)
        ,.icache_perf_bypass_cnt(icache_perf_bypass_cnt)
        ,.icache_perf_fill_cnt  (icache_perf_fill_cnt)
        ,.icache_perf_cmo_cnt   (icache_perf_cmo_cnt)
`endif
    );

    // AXI write-channel monitor — detects tohost writes and exits simulation
    axi_monitor tohost_monitor (
        .clk         (clk),
        .rst_n       (rst_n),
        .axi_awaddr  (axi_awaddr),
        .axi_awvalid (axi_awvalid),
        .axi_awready (axi_awready),
        .axi_wdata   (axi_wdata),
        .axi_wstrb   (axi_wstrb),
        .axi_wvalid  (axi_wvalid),
        .axi_wready  (axi_wready)
    );

    // Instantiate external memory (2MB)
    axi_memory #(
        .ADDR_WIDTH(32),
        .DATA_WIDTH(32),
        .MEM_SIZE(2 * 1024 * 1024),
        .BASE_ADDR(32'h80000000),
        .MEM_READ_LATENCY(1),
        .MEM_WRITE_LATENCY(1),
        .MAX_OUTSTANDING_READS(16),
        .MAX_OUTSTANDING_WRITES(16),
    `ifdef DEBUG_LEVEL_2
        .ENABLE_MEM_TRACE(1),
    `else
        .ENABLE_MEM_TRACE(0),
    `endif
        .MEM_DUAL_PORT(1)
    ) ext_mem (
        .clk(clk),
        .rst_n(rst_n),
        .axi_awaddr(axi_awaddr),
        .axi_awlen (axi_awlen),
        .axi_awburst(axi_awburst),
        .axi_awvalid(axi_awvalid),
        .axi_awready(axi_awready),
        .axi_wdata(axi_wdata),
        .axi_wstrb(axi_wstrb),
        .axi_wlast (axi_wlast),
        .axi_wvalid(axi_wvalid),
        .axi_wready(axi_wready),
        .axi_bresp(axi_bresp),
        .axi_bvalid(axi_bvalid),
        .axi_bready(axi_bready),
        .axi_araddr (axi_araddr),
        .axi_arvalid(axi_arvalid),
        .axi_arready(axi_arready),
        .axi_arlen  (axi_arlen),
        .axi_arsize (axi_arsize),
        .axi_arburst(axi_arburst),
        .axi_rdata  (axi_rdata),
        .axi_rresp  (axi_rresp),
        .axi_rvalid (axi_rvalid),
        .axi_rready (axi_rready),
        .axi_rlast  (axi_rlast)
    );

    // ========================================================================
    // Testbench Peripheral Targets
    // ========================================================================

    // UART Loopback - Echoes back received characters
    uart_loopback #(
        .CLKS_PER_BIT(4)  // Match UART baud rate
    ) uart_target (
        .clk(clk),
        .rst_n(rst_n),
        .rx(uart_tx_internal),  // Connect to SoC TX output
        .tx(uart_rx)            // Connect directly to SoC RX input
    );

    // Drive testbench output port from SoC internal signal
    assign uart_tx = uart_tx_internal;

    // SPI Slave Memories - 256-byte memories for SPI testing (one per CS line)
    logic [3:0] spi_miso_slaves;    // MISO from each slave

    spi_slave_memory spi_target0 (
        .rst_n(rst_n),
        .sclk(spi_sclk_internal),
        .cs_n(spi_cs_n_internal[0]),
        .mosi(spi_mosi_internal),
        .miso(spi_miso_slaves[0])
    );

    spi_slave_memory spi_target1 (
        .rst_n(rst_n),
        .sclk(spi_sclk_internal),
        .cs_n(spi_cs_n_internal[1]),
        .mosi(spi_mosi_internal),
        .miso(spi_miso_slaves[1])
    );

    spi_slave_memory spi_target2 (
        .rst_n(rst_n),
        .sclk(spi_sclk_internal),
        .cs_n(spi_cs_n_internal[2]),
        .mosi(spi_mosi_internal),
        .miso(spi_miso_slaves[2])
    );

    spi_slave_memory spi_target3 (
        .rst_n(rst_n),
        .sclk(spi_sclk_internal),
        .cs_n(spi_cs_n_internal[3]),
        .mosi(spi_mosi_internal),
        .miso(spi_miso_slaves[3])
    );

    // Wire-OR MISO from all slaves (only one active at a time)
    assign spi_miso_internal = spi_miso_slaves[0] | spi_miso_slaves[1] |
                               spi_miso_slaves[2] | spi_miso_slaves[3];

    // Drive testbench output ports from internal signals
    assign spi_sclk = spi_sclk_internal;
    assign spi_mosi = spi_mosi_internal;
    assign spi_cs_n = spi_cs_n_internal;
    assign spi_miso = spi_miso_internal;

    // I2C Slave EEPROM - 256-byte EEPROM at address 0x50
    // I2C bidirectional bus handling (wired-AND)
    assign i2c_scl_wire = (i2c_scl_oe_internal ? 1'b1 : i2c_scl_o_internal);
    assign i2c_sda_wire = (i2c_sda_oe_internal ? 1'b1 : i2c_sda_o_internal) &
                          (i2c_slave_sda_oe ? i2c_slave_sda_out : 1'b1);

    i2c_slave_eeprom #(
        .DEVICE_ADDR(7'h50)
    ) i2c_target (
        .clk(clk),
        .rst_n(rst_n),
        .scl(i2c_scl_wire),
        .sda_in(i2c_sda_wire),
        .sda_out(i2c_slave_sda_out),
        .sda_oe(i2c_slave_sda_oe)
    );

    // Drive testbench output ports from internal signals
    assign i2c_scl_i = i2c_scl_wire;
    assign i2c_scl_o = i2c_scl_o_internal;
    assign i2c_scl_oe = i2c_scl_oe_internal;
    assign i2c_sda_i = i2c_sda_wire;
    assign i2c_sda_o = i2c_sda_o_internal;
    assign i2c_sda_oe = i2c_sda_oe_internal;

    // ========================================================================
    // DPI functions for trace generation
    // ========================================================================
    export "DPI-C" function get_ex_valid;
    export "DPI-C" function get_ex_signals;
    export "DPI-C" function get_mem_signals;
    export "DPI-C" function get_csr_signals;
    export "DPI-C" function get_wb_signals;
    export "DPI-C" function get_reg_value;

    function bit get_ex_valid();
        return dut.core.ex_valid;
    endfunction

    function void get_ex_signals(
        output bit [31:0] pc_ex,
        output bit [31:0] instr_ex,
        output bit [4:0]  rd_addr_ex,
        output bit        reg_we_ex,
        output bit        mem_read_ex,
        output bit        mem_write_ex,
        output bit [31:0] alu_result,
        output bit [31:0] rs2_data_ex
    );
        pc_ex = dut.core.pc_ex;
        instr_ex = dut.core.instr_ex;
        rd_addr_ex = dut.core.rd_addr_ex;
        reg_we_ex = dut.core.reg_we_ex;
        mem_read_ex = dut.core.mem_read_ex;
        mem_write_ex = dut.core.mem_write_ex;
        alu_result = dut.core.alu_result_final;
        rs2_data_ex = dut.core.rs2_forwarded;
    endfunction

    function void get_wb_signals(
        output bit        wb_valid,
        output bit        retire_instr,
        output bit [31:0] pc_wb,
        output bit [31:0] instr_wb,
        output bit [4:0]  rd_addr_wb,
        output bit        reg_we_wb,
        output bit        mem_read_wb,
        output bit        mem_write_wb,
        output bit [31:0] alu_result_wb,
        output bit [31:0] mem_data_wb,
        output bit [31:0] store_data_wb,
        output bit [31:0] csr_wdata_wb,
        output bit [4:0]  csr_zimm_wb,
        output bit [2:0]  csr_op_wb,
        output bit [11:0] csr_addr_wb,
        output bit [31:0] csr_rdata_wb,
        output bit [31:0] mstatus_wb
    );
        wb_valid = dut.core.wb_valid;
        retire_instr = dut.core.retire_instr;
        pc_wb = dut.core.pc_wb;
        instr_wb = dut.core.instr_wb;
        rd_addr_wb = dut.core.rd_addr_wb;
        reg_we_wb = dut.core.reg_we_wb;
        mem_read_wb = dut.core.mem_read_wb;
        mem_write_wb = dut.core.mem_write_wb;
        alu_result_wb = dut.core.alu_result_wb;
        mem_data_wb = dut.core.mem_data_wb;
        store_data_wb = dut.core.store_data_wb;
        csr_wdata_wb = dut.core.csr_wdata_wb;
        csr_zimm_wb = dut.core.csr_zimm_wb;
        csr_op_wb = dut.core.csr_op_wb;
        csr_addr_wb = dut.core.csr_addr_wb;
        csr_rdata_wb = dut.core.csr_rdata_wb;
        mstatus_wb = dut.core.csr.mstatus;
    endfunction

    function int unsigned get_reg_value(input int unsigned reg_idx);
        if (reg_idx == 0) begin
            return 32'd0;
        end
        if (reg_idx >= 1 && reg_idx <= 31) begin
            return dut.core.regfile.regs[reg_idx];
        end
        return 32'd0;
    endfunction

    function void get_mem_signals(
        output bit        mem_write_mem,
        output bit        mem_valid,
        output bit [31:0] alu_result_mem,
        output bit [31:0] dmem_req_wdata,
        output bit [3:0]  dmem_req_we
    );
        mem_write_mem = dut.core.mem_write_mem;
        mem_valid = dut.core.mem_valid;
        alu_result_mem = dut.core.alu_result_mem;
        dmem_req_wdata = dut.core.dmem_req_wdata;
        dmem_req_we = dut.core.dmem_req_we;
    endfunction

    function void get_csr_signals(
        output bit [2:0]  csr_op_ex,
        output bit [11:0] csr_addr_ex,
        output bit [31:0] csr_wdata,
        output bit [31:0] csr_rdata
    );
        csr_op_ex = dut.core.csr_op_ex;
        csr_addr_ex = dut.core.csr_addr_ex;
        csr_wdata = dut.core.rs1_forwarded;  // CSR write data comes from rs1
        csr_rdata = dut.core.csr_rdata;
    endfunction

endmodule

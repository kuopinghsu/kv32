// ============================================================================
// File: rv32_soc.sv
// Project: RV32 RISC-V Processor
// Description: RV32IMA System-on-Chip Top-Level Module
//
// Integrates all major components of the RISC-V SoC:
//   - RV32IMA processor core (5-stage pipeline)
//   - External 2MB RAM via AXI4-Lite
//   - Memory-mapped peripherals (CLINT, UART, SPI, I2C, Magic)
//   - AXI4-Lite interconnect infrastructure
//
// This is the top-level module that should be instantiated in testbenches
// or FPGA designs.
//
// Features:
//   - 5-stage pipelined RV32IMA core with CSRs
//   - Separate instruction and data memory interfaces
//   - AXI arbiter for read channel arbitration
//   - Standard RISC-V CLINT timer with mtime/mtimecmp
//   - High-speed UART for serial I/O (up to 25 Mbaud)
//   - SPI master controller for peripheral interfacing
//   - I2C master controller for sensor interfacing
//   - Magic addresses for simulation control
//   - AXI4-Lite system bus with 1-to-6 interconnect
//
// Memory Map:
//   0x8000_0000 - 0x801F_FFFF: RAM (2MB)
//   0x0200_0000 - 0x0200_FFFF: CLINT
//   0x0201_0000 - 0x0201_00FF: UART
//   0x0202_0000 - 0x0202_00FF: SPI
//   0x0203_0000 - 0x0203_00FF: I2C
//   0xFFFF_0000 - 0xFFFF_FFFF: Magic addresses
//
// Default Configuration:
//   - System Clock: 100 MHz
//   - UART Baud Rate: 25 Mbaud (maximum for CLKS_PER_BIT=4)
//   - Instruction Buffer Depth: 2 (up to 2 outstanding fetches)
//   - Store Buffer Depth: 2 (up to 2 buffered stores)
//   - Multiply Mode: FAST_MUL=1 (combinatorial, single cycle)
//   - Division Mode: FAST_DIV=1 (combinatorial, single cycle)
// ============================================================================

module rv32_soc #(
    parameter CLK_FREQ = 100_000_000,    // System clock frequency in Hz
    parameter BAUD_RATE = 25_000_000,    // UART baud rate (max = CLK_FREQ/4)
    parameter IB_DEPTH = 4,              // Instruction buffer depth (outstanding fetches); must be power-of-2 >= effective_latency+1
    parameter SB_DEPTH = 2,              // Store buffer depth (buffered stores)
    parameter FAST_MUL = 1,              // Multiply mode: 1=combinatorial, 0=serial
    parameter FAST_DIV = 1               // Division mode: 1=combinatorial, 0=serial
)(
    input  logic clk,
    input  logic rst_n,

    // UART pins
    input  logic uart_rx,
    output logic uart_tx,

    // SPI pins
    output logic        spi_sclk,
    output logic        spi_mosi,
    input  logic        spi_miso,
    output logic [3:0]  spi_cs_n,

    // I2C pins
    output logic        i2c_scl_o,
    input  logic        i2c_scl_i,
    output logic        i2c_scl_t,
    output logic        i2c_sda_o,
    input  logic        i2c_sda_i,
    output logic        i2c_sda_t,

    // External AXI4-Lite RAM interface (2MB)
    output logic [31:0] m_axi_awaddr,
    output logic        m_axi_awvalid,
    input  logic        m_axi_awready,

    output logic [31:0] m_axi_wdata,
    output logic [3:0]  m_axi_wstrb,
    output logic        m_axi_wvalid,
    input  logic        m_axi_wready,

    input  logic [1:0]  m_axi_bresp,
    input  logic        m_axi_bvalid,
    output logic        m_axi_bready,

    output logic [31:0] m_axi_araddr,
    output logic        m_axi_arvalid,
    input  logic        m_axi_arready,

    input  logic [31:0] m_axi_rdata,
    input  logic [1:0]  m_axi_rresp,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready,

    // Performance counters
    output logic [63:0] cycle_count,
    output logic [63:0] instret_count,
    output logic [63:0] stall_count,
    output logic [63:0] first_retire_cycle,
    output logic [63:0] last_retire_cycle

`ifndef SYNTHESIS
    ,output logic       timeout_error,
    // Trace-compare mode: when asserted by the testbench (+TRACE), cycle/time
    // CSR reads in the core return minstret instead of mcycle so that the
    // cycle counter is pipeline-stall-independent and matches the software sim.
    input  logic        trace_mode
`endif
);

    // ========================================================================
    // Core <-> Memory Bus Interface Signals
    // ========================================================================
    // Instruction Memory Interface (Read-Only)
    // Simple request/response protocol used by the processor core
    logic        imem_req_valid;      // Core has instruction fetch request
    logic [31:0] imem_req_addr;       // Instruction address to fetch
    logic        imem_req_ready;      // Memory system ready for new request
    logic        imem_resp_valid;     // Instruction data available
    logic [31:0] imem_resp_data;      // Fetched instruction word
    logic        imem_resp_error;     // Access error (e.g., unmapped address)
    logic        imem_resp_ready;     // Core ready to consume response

    // Data Memory Interface (Read/Write)
    // Supports both load and store operations with byte enables
    logic        dmem_req_valid;      // Core has data access request
    logic [31:0] dmem_req_addr;       // Data address to access
    logic [3:0]  dmem_req_we;         // Write enable per byte (0000=read)
    logic [31:0] dmem_req_wdata;      // Data to write (for stores)
    logic        dmem_req_ready;      // Memory system ready for new request
    logic        dmem_resp_valid;     // Response data available
    logic [31:0] dmem_resp_data;      // Read data (for loads)
    logic        dmem_resp_error;     // Access error
    logic        dmem_resp_is_write;  // 1=B response (store done), 0=R response (load data)
    logic        dmem_resp_ready;     // Core ready to consume response

    // ========================================================================
    // Instruction Memory AXI Bridge Signals (Read-Only)
    // ========================================================================
    // Converts core's simple request/response to AXI4 AR/R channels with ID support
    logic [31:0]              imem_axi_araddr;     // Read address
    logic [axi_pkg::AXI_ID_WIDTH-1:0] imem_axi_arid;      // Read address ID
    logic                     imem_axi_arvalid;    // Read address valid
    logic                     imem_axi_arready;    // Read address ready (from arbiter)
    logic [31:0]              imem_axi_rdata;      // Read data
    logic [1:0]               imem_axi_rresp;      // Read response (OKAY/SLVERR/DECERR)
    logic [axi_pkg::AXI_ID_WIDTH-1:0] imem_axi_rid;       // Read data ID
    logic                     imem_axi_rvalid;     // Read data valid
    logic                     imem_axi_rready;     // Read data ready

    // ========================================================================
    // Data Memory AXI Bridge Signals (Read/Write)
    // ========================================================================
    // Converts core's simple request/response to full AXI4 with ID support
    logic [31:0]              dmem_axi_awaddr;     // Write address
    logic [axi_pkg::AXI_ID_WIDTH-1:0] dmem_axi_awid;      // Write address ID
    logic                     dmem_axi_awvalid;
    logic                     dmem_axi_awready;
    logic [31:0]              dmem_axi_wdata;
    logic [3:0]               dmem_axi_wstrb;
    logic                     dmem_axi_wvalid;
    logic                     dmem_axi_wready;
    logic [1:0]               dmem_axi_bresp;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] dmem_axi_bid;       // Write response ID
    logic                     dmem_axi_bvalid;
    logic                     dmem_axi_bready;
    logic [31:0]              dmem_axi_araddr;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] dmem_axi_arid;      // Read address ID
    logic                     dmem_axi_arvalid;
    logic                     dmem_axi_arready;
    logic [31:0]              dmem_axi_rdata;
    logic [1:0]               dmem_axi_rresp;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] dmem_axi_rid;       // Read data ID
    logic                     dmem_axi_rvalid;
    logic                     dmem_axi_rready;

    // ========================================================================
    // AXI Arbiter Output Signals (to Interconnect)
    // ========================================================================
    // Arbitrated signals combining imem (read-only) and dmem (read/write) with ID support
    logic [31:0]              arb_axi_awaddr;      // Write address (from dmem only)
    logic [axi_pkg::AXI_ID_WIDTH-1:0] arb_axi_awid;       // Write address ID
    logic                     arb_axi_awvalid;
    logic                     arb_axi_awready;
    logic [31:0]              arb_axi_wdata;
    logic [3:0]               arb_axi_wstrb;
    logic                     arb_axi_wvalid;
    logic                     arb_axi_wready;
    logic [1:0]               arb_axi_bresp;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] arb_axi_bid;        // Write response ID
    logic                     arb_axi_bvalid;
    logic                     arb_axi_bready;
    logic [31:0]              arb_axi_araddr;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] arb_axi_arid;       // Read address ID
    logic                     arb_axi_arvalid;
    logic                     arb_axi_arready;
    logic [31:0]              arb_axi_rdata;
    logic [1:0]               arb_axi_rresp;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] arb_axi_rid;        // Read data ID
    logic                     arb_axi_rvalid;
    logic                     arb_axi_rready;

    // ========================================================================
    // AXI Interconnect <-> CLINT Signals
    // ========================================================================
    // Memory-mapped access to timer (mtime) and comparator (mtimecmp)
    // Base address: 0x0200_0000
    logic [31:0] clint_axi_awaddr;
    logic        clint_axi_awvalid;
    logic        clint_axi_awready;
    logic [31:0] clint_axi_wdata;
    logic [3:0]  clint_axi_wstrb;
    logic        clint_axi_wvalid;
    logic        clint_axi_wready;
    logic [1:0]  clint_axi_bresp;
    logic        clint_axi_bvalid;
    logic        clint_axi_bready;
    logic [31:0] clint_axi_araddr;
    logic        clint_axi_arvalid;
    logic        clint_axi_arready;
    logic [31:0] clint_axi_rdata;
    logic [1:0]  clint_axi_rresp;
    logic        clint_axi_rvalid;
    logic        clint_axi_rready;

    // ========================================================================
    // AXI Interconnect <-> UART Signals
    // ========================================================================
    // Memory-mapped access to UART TX/RX data and status registers
    // Base address: 0x0201_0000
    logic [31:0] uart_axi_awaddr;
    logic        uart_axi_awvalid;
    logic        uart_axi_awready;
    logic [31:0] uart_axi_wdata;
    logic [3:0]  uart_axi_wstrb;
    logic        uart_axi_wvalid;
    logic        uart_axi_wready;
    logic [1:0]  uart_axi_bresp;
    logic        uart_axi_bvalid;
    logic        uart_axi_bready;
    logic [31:0] uart_axi_araddr;
    logic        uart_axi_arvalid;
    logic        uart_axi_arready;
    logic [31:0] uart_axi_rdata;
    logic [1:0]  uart_axi_rresp;
    logic        uart_axi_rvalid;
    logic        uart_axi_rready;

    // ========================================================================
    // AXI Interconnect <-> SPI Signals
    // ========================================================================
    // Memory-mapped access to SPI control, data, and status registers
    // Base address: 0x0202_0000
    logic [31:0] spi_axi_awaddr;
    logic        spi_axi_awvalid;
    logic        spi_axi_awready;
    logic [31:0] spi_axi_wdata;
    logic [3:0]  spi_axi_wstrb;
    logic        spi_axi_wvalid;
    logic        spi_axi_wready;
    logic [1:0]  spi_axi_bresp;
    logic        spi_axi_bvalid;
    logic        spi_axi_bready;
    logic [31:0] spi_axi_araddr;
    logic        spi_axi_arvalid;
    logic        spi_axi_arready;
    logic [31:0] spi_axi_rdata;
    logic [1:0]  spi_axi_rresp;
    logic        spi_axi_rvalid;
    logic        spi_axi_rready;

    // ========================================================================
    // AXI Interconnect <-> I2C Peripheral Signals
    // ========================================================================
    // Memory-mapped I2C master controller for sensor interfacing
    // Base address: 0x0203_0000
    logic [31:0] i2c_axi_awaddr;
    logic        i2c_axi_awvalid;
    logic        i2c_axi_awready;
    logic [31:0] i2c_axi_wdata;
    logic [3:0]  i2c_axi_wstrb;
    logic        i2c_axi_wvalid;
    logic        i2c_axi_wready;
    logic [1:0]  i2c_axi_bresp;
    logic        i2c_axi_bvalid;
    logic        i2c_axi_bready;
    logic [31:0] i2c_axi_araddr;
    logic        i2c_axi_arvalid;
    logic        i2c_axi_arready;
    logic [31:0] i2c_axi_rdata;
    logic [1:0]  i2c_axi_rresp;
    logic        i2c_axi_rvalid;
    logic        i2c_axi_rready;

    // ========================================================================
    // AXI Interconnect <-> Magic Address Signals
    // ========================================================================
    // Special addresses for simulation control (exit, pass/fail, etc.)
    // Base address: 0xFFFF_0000
    logic [31:0] magic_axi_awaddr;
    logic        magic_axi_awvalid;
    logic        magic_axi_awready;
    logic [31:0] magic_axi_wdata;
    logic [3:0]  magic_axi_wstrb;
    logic        magic_axi_wvalid;
    logic        magic_axi_wready;
    logic [1:0]  magic_axi_bresp;
    logic        magic_axi_bvalid;
    logic        magic_axi_bready;
    logic [31:0] magic_axi_araddr;
    logic        magic_axi_arvalid;
    logic        magic_axi_arready;
    logic [31:0] magic_axi_rdata;
    logic [1:0]  magic_axi_rresp;
    logic        magic_axi_rvalid;
    logic        magic_axi_rready;

    // ========================================================================
    // Interrupt Signals
    // ========================================================================
    logic        timer_irq;           // Timer interrupt from CLINT
    logic        software_irq;        // Software interrupt from CLINT
    logic        external_irq;        // External interrupt (unused)

`ifndef SYNTHESIS
    logic        core_retire_instr;   // Instruction retirement pulse for trace-mode mtime
    logic        core_wb_store;       // Retiring store pulse for trace-mode CLINT bypass
    logic [31:0] core_wb_store_addr;  // Store effective address
    logic [31:0] core_wb_store_data;  // Store data word
    logic [3:0]  core_wb_store_strb;  // Store byte enables
`endif

    // External interrupts not implemented in this SoC configuration
    assign external_irq = 1'b0;

    // ========================================================================
    // RV32IMA Processor Core Instance
    // ========================================================================
    // 5-stage pipelined RISC-V core implementing RV32IMA ISA
    // Features: CSRs, interrupts, precise exceptions, performance counters
    // Configurable instruction buffer (IB_DEPTH) and store buffer (SB_DEPTH)
    rv32_core #(
        .IB_DEPTH(IB_DEPTH),
        .SB_DEPTH(SB_DEPTH),
        .FAST_MUL(FAST_MUL),
        .FAST_DIV(FAST_DIV)
    ) core (
        .clk(clk),
        .rst_n(rst_n),

        .imem_req_valid(imem_req_valid),
        .imem_req_addr(imem_req_addr),
        .imem_req_ready(imem_req_ready),
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

        .timer_irq(timer_irq),
        .external_irq(external_irq),
        .software_irq(software_irq),

        .cycle_count(cycle_count),
        .instret_count(instret_count),
        .stall_count(stall_count),
        .first_retire_cycle(first_retire_cycle),
        .last_retire_cycle(last_retire_cycle)

`ifndef SYNTHESIS
        ,.timeout_error(timeout_error)
        ,.retire_instr_out(core_retire_instr)
        ,.wb_store_out(core_wb_store)
        ,.wb_store_addr_out(core_wb_store_addr)
        ,.wb_store_data_out(core_wb_store_data)
        ,.wb_store_strb_out(core_wb_store_strb)
        ,.trace_mode(trace_mode)
`endif
    );

    // ========================================================================
    // Instruction Memory to AXI Bridge (Read-Only)
    // ========================================================================
    // Converts core's simple read request/response to AXI4 AR/R channels with ID support
    // Only implements read path since instruction fetches are read-only
    mem_axi_ro #(
        .BRIDGE_NAME("IMEM_BRIDGE"),
        .OUTSTANDING_DEPTH(IB_DEPTH)  // Match instruction buffer depth (conservative limit)
    ) imem_bridge (
        .clk(clk),
        .rst_n(rst_n),

        .mem_req_valid(imem_req_valid),
        .mem_req_addr(imem_req_addr),
        .mem_req_ready(imem_req_ready),

        .mem_resp_valid(imem_resp_valid),
        .mem_resp_data(imem_resp_data),
        .mem_resp_error(imem_resp_error),
        .mem_resp_ready(imem_resp_ready),

        .axi_araddr(imem_axi_araddr),
        .axi_arid(imem_axi_arid),
        .axi_arvalid(imem_axi_arvalid),
        .axi_arready(imem_axi_arready),

        .axi_rdata(imem_axi_rdata),
        .axi_rresp(imem_axi_rresp),
        .axi_rid(imem_axi_rid),
        .axi_rvalid(imem_axi_rvalid),
        .axi_rready(imem_axi_rready)
    );

    // ========================================================================
    // Data Memory to AXI Bridge (Read/Write)
    // ========================================================================
    // Converts core's simple request/response to full AXI4 (AW/W/B/AR/R) with ID support
    // Supports both loads and stores with byte-level write enables
    mem_axi #(
        .BRIDGE_NAME("DMEM_BRIDGE"),
        .OUTSTANDING_DEPTH(4)  // Conservative limit matching original system capability
    ) dmem_bridge (
        .clk(clk),
        .rst_n(rst_n),

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
        .axi_rvalid(dmem_axi_rvalid),
        .axi_rready(dmem_axi_rready)
    );

    // ========================================================================
    // AXI Arbiter (Split Read/Write)
    // ========================================================================
    // Arbitrates read channels (AR/R) between instruction and data masters with ID tracking
    // Priority: data > instruction (to avoid pipeline stalls)
    // Forwards write channels (AW/W/B) directly from data master (no arbitration)
    // This allows simultaneous instruction fetch and data store operations
    axi_arbiter #(
        .OUTSTANDING_DEPTH(8)  // Arbiter tracking capacity
    ) arbiter (
        .clk(clk),
        .rst_n(rst_n),

        // Master 0: Instruction memory (Read-Only) with ID
        .m0_axi_araddr(imem_axi_araddr),
        .m0_axi_arid(imem_axi_arid),
        .m0_axi_arvalid(imem_axi_arvalid),
        .m0_axi_arready(imem_axi_arready),
        .m0_axi_rdata(imem_axi_rdata),
        .m0_axi_rresp(imem_axi_rresp),
        .m0_axi_rid(imem_axi_rid),
        .m0_axi_rvalid(imem_axi_rvalid),
        .m0_axi_rready(imem_axi_rready),

        // Master 1: Data memory (Read/Write) with ID
        .m1_axi_awaddr(dmem_axi_awaddr),
        .m1_axi_awid(dmem_axi_awid),
        .m1_axi_awvalid(dmem_axi_awvalid),
        .m1_axi_awready(dmem_axi_awready),
        .m1_axi_wdata(dmem_axi_wdata),
        .m1_axi_wstrb(dmem_axi_wstrb),
        .m1_axi_wvalid(dmem_axi_wvalid),
        .m1_axi_wready(dmem_axi_wready),
        .m1_axi_bresp(dmem_axi_bresp),
        .m1_axi_bid(dmem_axi_bid),
        .m1_axi_bvalid(dmem_axi_bvalid),
        .m1_axi_bready(dmem_axi_bready),
        .m1_axi_araddr(dmem_axi_araddr),
        .m1_axi_arid(dmem_axi_arid),
        .m1_axi_arvalid(dmem_axi_arvalid),
        .m1_axi_arready(dmem_axi_arready),
        .m1_axi_rdata(dmem_axi_rdata),
        .m1_axi_rresp(dmem_axi_rresp),
        .m1_axi_rid(dmem_axi_rid),
        .m1_axi_rvalid(dmem_axi_rvalid),
        .m1_axi_rready(dmem_axi_rready),

        // Slave: to interconnect with ID
        .s_axi_awaddr(arb_axi_awaddr),
        .s_axi_awid(arb_axi_awid),
        .s_axi_awvalid(arb_axi_awvalid),
        .s_axi_awready(arb_axi_awready),
        .s_axi_wdata(arb_axi_wdata),
        .s_axi_wstrb(arb_axi_wstrb),
        .s_axi_wvalid(arb_axi_wvalid),
        .s_axi_wready(arb_axi_wready),
        .s_axi_bresp(arb_axi_bresp),
        .s_axi_bid(arb_axi_bid),
        .s_axi_bvalid(arb_axi_bvalid),
        .s_axi_bready(arb_axi_bready),
        .s_axi_araddr(arb_axi_araddr),
        .s_axi_arid(arb_axi_arid),
        .s_axi_arvalid(arb_axi_arvalid),
        .s_axi_arready(arb_axi_arready),
        .s_axi_rdata(arb_axi_rdata),
        .s_axi_rresp(arb_axi_rresp),
        .s_axi_rid(arb_axi_rid),
        .s_axi_rvalid(arb_axi_rvalid),
        .s_axi_rready(arb_axi_rready)
    );

    // ========================================================================
    // AXI4 Interconnect (1-to-6 Crossbar)
    // ========================================================================
    // Routes transactions from arbiter to 6 slave devices based on address with ID tracking:
    //   Slave 0 (0x8000_0000): External 2MB RAM
    //   Slave 1 (0x0200_0000): CLINT timer peripheral
    //   Slave 2 (0x0201_0000): UART peripheral
    //   Slave 3 (0x0202_0000): SPI peripheral
    //   Slave 4 (0x0203_0000): I2C peripheral
    //   Slave 5 (0xFFFF_0000): Magic addresses for simulation
    // Returns DECERR response for unmapped addresses
    axi_xbar axi_intercon (
        .clk(clk),
        .rst_n(rst_n),

        // Master (from arbiter) with ID support
        .m_axi_awaddr(arb_axi_awaddr),
        .m_axi_awid(arb_axi_awid),
        .m_axi_awvalid(arb_axi_awvalid),
        .m_axi_awready(arb_axi_awready),

        .m_axi_wdata(arb_axi_wdata),
        .m_axi_wstrb(arb_axi_wstrb),
        .m_axi_wvalid(arb_axi_wvalid),
        .m_axi_wready(arb_axi_wready),

        .m_axi_bresp(arb_axi_bresp),
        .m_axi_bid(arb_axi_bid),
        .m_axi_bvalid(arb_axi_bvalid),
        .m_axi_bready(arb_axi_bready),

        .m_axi_araddr(arb_axi_araddr),
        .m_axi_arid(arb_axi_arid),
        .m_axi_arvalid(arb_axi_arvalid),
        .m_axi_arready(arb_axi_arready),

        .m_axi_rdata(arb_axi_rdata),
        .m_axi_rresp(arb_axi_rresp),
        .m_axi_rid(arb_axi_rid),
        .m_axi_rvalid(arb_axi_rvalid),
        .m_axi_rready(arb_axi_rready),

        // Slave 0: External RAM
        .s0_axi_awaddr(m_axi_awaddr),
        .s0_axi_awvalid(m_axi_awvalid),
        .s0_axi_awready(m_axi_awready),

        .s0_axi_wdata(m_axi_wdata),
        .s0_axi_wstrb(m_axi_wstrb),
        .s0_axi_wvalid(m_axi_wvalid),
        .s0_axi_wready(m_axi_wready),

        .s0_axi_bresp(m_axi_bresp),
        .s0_axi_bvalid(m_axi_bvalid),
        .s0_axi_bready(m_axi_bready),

        .s0_axi_araddr(m_axi_araddr),
        .s0_axi_arvalid(m_axi_arvalid),
        .s0_axi_arready(m_axi_arready),

        .s0_axi_rdata(m_axi_rdata),
        .s0_axi_rresp(m_axi_rresp),
        .s0_axi_rvalid(m_axi_rvalid),
        .s0_axi_rready(m_axi_rready),

        // Slave 1: CLINT
        .s1_axi_awaddr(clint_axi_awaddr),
        .s1_axi_awvalid(clint_axi_awvalid),
        .s1_axi_awready(clint_axi_awready),

        .s1_axi_wdata(clint_axi_wdata),
        .s1_axi_wstrb(clint_axi_wstrb),
        .s1_axi_wvalid(clint_axi_wvalid),
        .s1_axi_wready(clint_axi_wready),

        .s1_axi_bresp(clint_axi_bresp),
        .s1_axi_bvalid(clint_axi_bvalid),
        .s1_axi_bready(clint_axi_bready),

        .s1_axi_araddr(clint_axi_araddr),
        .s1_axi_arvalid(clint_axi_arvalid),
        .s1_axi_arready(clint_axi_arready),

        .s1_axi_rdata(clint_axi_rdata),
        .s1_axi_rresp(clint_axi_rresp),
        .s1_axi_rvalid(clint_axi_rvalid),
        .s1_axi_rready(clint_axi_rready),

        // Slave 2: UART
        .s2_axi_awaddr(uart_axi_awaddr),
        .s2_axi_awvalid(uart_axi_awvalid),
        .s2_axi_awready(uart_axi_awready),

        .s2_axi_wdata(uart_axi_wdata),
        .s2_axi_wstrb(uart_axi_wstrb),
        .s2_axi_wvalid(uart_axi_wvalid),
        .s2_axi_wready(uart_axi_wready),

        .s2_axi_bresp(uart_axi_bresp),
        .s2_axi_bvalid(uart_axi_bvalid),
        .s2_axi_bready(uart_axi_bready),

        .s2_axi_araddr(uart_axi_araddr),
        .s2_axi_arvalid(uart_axi_arvalid),
        .s2_axi_arready(uart_axi_arready),

        .s2_axi_rdata(uart_axi_rdata),
        .s2_axi_rresp(uart_axi_rresp),
        .s2_axi_rvalid(uart_axi_rvalid),
        .s2_axi_rready(uart_axi_rready),

        // Slave 3: SPI
        .s3_axi_awaddr(spi_axi_awaddr),
        .s3_axi_awvalid(spi_axi_awvalid),
        .s3_axi_awready(spi_axi_awready),

        .s3_axi_wdata(spi_axi_wdata),
        .s3_axi_wstrb(spi_axi_wstrb),
        .s3_axi_wvalid(spi_axi_wvalid),
        .s3_axi_wready(spi_axi_wready),

        .s3_axi_bresp(spi_axi_bresp),
        .s3_axi_bvalid(spi_axi_bvalid),
        .s3_axi_bready(spi_axi_bready),

        .s3_axi_araddr(spi_axi_araddr),
        .s3_axi_arvalid(spi_axi_arvalid),
        .s3_axi_arready(spi_axi_arready),

        .s3_axi_rdata(spi_axi_rdata),
        .s3_axi_rresp(spi_axi_rresp),
        .s3_axi_rvalid(spi_axi_rvalid),
        .s3_axi_rready(spi_axi_rready),

        // Slave 4: I2C
        .s4_axi_awaddr(i2c_axi_awaddr),
        .s4_axi_awvalid(i2c_axi_awvalid),
        .s4_axi_awready(i2c_axi_awready),

        .s4_axi_wdata(i2c_axi_wdata),
        .s4_axi_wstrb(i2c_axi_wstrb),
        .s4_axi_wvalid(i2c_axi_wvalid),
        .s4_axi_wready(i2c_axi_wready),

        .s4_axi_bresp(i2c_axi_bresp),
        .s4_axi_bvalid(i2c_axi_bvalid),
        .s4_axi_bready(i2c_axi_bready),

        .s4_axi_araddr(i2c_axi_araddr),
        .s4_axi_arvalid(i2c_axi_arvalid),
        .s4_axi_arready(i2c_axi_arready),

        .s4_axi_rdata(i2c_axi_rdata),
        .s4_axi_rresp(i2c_axi_rresp),
        .s4_axi_rvalid(i2c_axi_rvalid),
        .s4_axi_rready(i2c_axi_rready),

        // Slave 5: Magic
        .s5_axi_awaddr(magic_axi_awaddr),
        .s5_axi_awvalid(magic_axi_awvalid),
        .s5_axi_awready(magic_axi_awready),

        .s5_axi_wdata(magic_axi_wdata),
        .s5_axi_wstrb(magic_axi_wstrb),
        .s5_axi_wvalid(magic_axi_wvalid),
        .s5_axi_wready(magic_axi_wready),

        .s5_axi_bresp(magic_axi_bresp),
        .s5_axi_bvalid(magic_axi_bvalid),
        .s5_axi_bready(magic_axi_bready),

        .s5_axi_araddr(magic_axi_araddr),
        .s5_axi_arvalid(magic_axi_arvalid),
        .s5_axi_arready(magic_axi_arready),

        .s5_axi_rdata(magic_axi_rdata),
        .s5_axi_rresp(magic_axi_rresp),
        .s5_axi_rvalid(magic_axi_rvalid),
        .s5_axi_rready(magic_axi_rready)
    );

    // ========================================================================
    // CLINT - Core Local Interruptor
    // ========================================================================
    // Provides timer (mtime) and timer comparator (mtimecmp) for timer interrupts
    // Also provides software interrupt control via memory-mapped registers
    // Memory map: 0x0200_0000 (standard RISC-V CLINT base address)
    axi_clint clint (
        .clk(clk),
        .rst_n(rst_n),

        .axi_awaddr(clint_axi_awaddr),
        .axi_awvalid(clint_axi_awvalid),
        .axi_awready(clint_axi_awready),

        .axi_wdata(clint_axi_wdata),
        .axi_wstrb(clint_axi_wstrb),
        .axi_wvalid(clint_axi_wvalid),
        .axi_wready(clint_axi_wready),

        .axi_bresp(clint_axi_bresp),
        .axi_bvalid(clint_axi_bvalid),
        .axi_bready(clint_axi_bready),

        .axi_araddr(clint_axi_araddr),
        .axi_arvalid(clint_axi_arvalid),
        .axi_arready(clint_axi_arready),

        .axi_rdata(clint_axi_rdata),
        .axi_rresp(clint_axi_rresp),
        .axi_rvalid(clint_axi_rvalid),
        .axi_rready(clint_axi_rready),

        .timer_irq(timer_irq),
        .software_irq(software_irq)

`ifndef SYNTHESIS
       ,.trace_mode(trace_mode)
        ,.retire_instr(core_retire_instr)
        // Retire-store bypass: forward retiring store addresses/data directly
        // to the CLINT so that MSIP (and other CLINT regs) are updated on the
        // very cycle the store retires, matching SW-sim timing.
        // Only forward stores that target the CLINT address window.
        ,.trace_store_valid(core_wb_store &&
                            (core_wb_store_addr[31:16] == 16'h0200))
        ,.trace_store_addr(core_wb_store_addr)
        ,.trace_store_data(core_wb_store_data)
        ,.trace_store_strb(core_wb_store_strb)
`endif
    );

    // ========================================================================
    // UART - Universal Asynchronous Receiver/Transmitter
    // ========================================================================
    // High-speed serial communication peripheral with integrated TX/RX
    // Memory map: 0x0201_0000 (TX data, RX data, status registers)
    // Configuration: 8N1 format, configurable baud rate
    // Current: 100 MHz clock, 25 Mbaud (CLKS_PER_BIT=4, maximum rate)
    axi_uart #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) uart (
        .clk(clk),
        .rst_n(rst_n),

        .axi_awaddr(uart_axi_awaddr),
        .axi_awvalid(uart_axi_awvalid),
        .axi_awready(uart_axi_awready),

        .axi_wdata(uart_axi_wdata),
        .axi_wstrb(uart_axi_wstrb),
        .axi_wvalid(uart_axi_wvalid),
        .axi_wready(uart_axi_wready),

        .axi_bresp(uart_axi_bresp),
        .axi_bvalid(uart_axi_bvalid),
        .axi_bready(uart_axi_bready),

        .axi_araddr(uart_axi_araddr),
        .axi_arvalid(uart_axi_arvalid),
        .axi_arready(uart_axi_arready),

        .axi_rdata(uart_axi_rdata),
        .axi_rresp(uart_axi_rresp),
        .axi_rvalid(uart_axi_rvalid),
        .axi_rready(uart_axi_rready),

        .uart_rx(uart_rx),
        .uart_tx(uart_tx)
    );

    // ========================================================================
    // SPI - Serial Peripheral Interface
    // ========================================================================
    // SPI master controller for interfacing with external SPI devices
    // Memory map: 0x0202_0000 (control, clock divider, data, status)
    // Features: Configurable CPOL/CPHA, clock divider, 4 chip selects
    axi_spi #(
        .CLK_FREQ(CLK_FREQ)
    ) spi (
        .clk(clk),
        .rst_n(rst_n),

        .axi_awaddr(spi_axi_awaddr),
        .axi_awvalid(spi_axi_awvalid),
        .axi_awready(spi_axi_awready),

        .axi_wdata(spi_axi_wdata),
        .axi_wstrb(spi_axi_wstrb),
        .axi_wvalid(spi_axi_wvalid),
        .axi_wready(spi_axi_wready),

        .axi_bresp(spi_axi_bresp),
        .axi_bvalid(spi_axi_bvalid),
        .axi_bready(spi_axi_bready),

        .axi_araddr(spi_axi_araddr),
        .axi_arvalid(spi_axi_arvalid),
        .axi_arready(spi_axi_arready),

        .axi_rdata(spi_axi_rdata),
        .axi_rresp(spi_axi_rresp),
        .axi_rvalid(spi_axi_rvalid),
        .axi_rready(spi_axi_rready),

        .spi_sclk(spi_sclk),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso),
        .spi_cs_n(spi_cs_n)
    );

    // ========================================================================
    // I2C - Inter-Integrated Circuit
    // ========================================================================
    // I2C master controller for interfacing with sensors and other I2C devices
    // Memory map: 0x0203_0000 (control, clock divider, data, status)
    // Features: Standard (100kHz) and Fast (400kHz) modes, 7-bit addressing
    axi_i2c #(
        .CLK_FREQ(CLK_FREQ)
    ) i2c (
        .clk(clk),
        .rst_n(rst_n),

        .axi_awaddr(i2c_axi_awaddr),
        .axi_awvalid(i2c_axi_awvalid),
        .axi_awready(i2c_axi_awready),

        .axi_wdata(i2c_axi_wdata),
        .axi_wstrb(i2c_axi_wstrb),
        .axi_wvalid(i2c_axi_wvalid),
        .axi_wready(i2c_axi_wready),

        .axi_bresp(i2c_axi_bresp),
        .axi_bvalid(i2c_axi_bvalid),
        .axi_bready(i2c_axi_bready),

        .axi_araddr(i2c_axi_araddr),
        .axi_arvalid(i2c_axi_arvalid),
        .axi_arready(i2c_axi_arready),

        .axi_rdata(i2c_axi_rdata),
        .axi_rresp(i2c_axi_rresp),
        .axi_rvalid(i2c_axi_rvalid),
        .axi_rready(i2c_axi_rready),

        .i2c_scl_o(i2c_scl_o),
        .i2c_scl_i(i2c_scl_i),
        .i2c_scl_t(i2c_scl_t),
        .i2c_sda_o(i2c_sda_o),
        .i2c_sda_i(i2c_sda_i),
        .i2c_sda_t(i2c_sda_t)
    );

    // ========================================================================
    // Magic Addresses - Simulation Control
    // ========================================================================
    // Provides special memory-mapped addresses for testbench control:
    //   - Exit simulation
    //   - Report test pass/fail
    //   - Performance measurement triggers
    // Memory map: 0xFFFF_0000
    axi_magic magic (
        .clk(clk),
        .rst_n(rst_n),

        .axi_awaddr(magic_axi_awaddr),
        .axi_awvalid(magic_axi_awvalid),
        .axi_awready(magic_axi_awready),

        .axi_wdata(magic_axi_wdata),
        .axi_wstrb(magic_axi_wstrb),
        .axi_wvalid(magic_axi_wvalid),
        .axi_wready(magic_axi_wready),

        .axi_bresp(magic_axi_bresp),
        .axi_bvalid(magic_axi_bvalid),
        .axi_bready(magic_axi_bready),

        .axi_araddr(magic_axi_araddr),
        .axi_arvalid(magic_axi_arvalid),
        .axi_arready(magic_axi_arready),

        .axi_rdata(magic_axi_rdata),
        .axi_rresp(magic_axi_rresp),
        .axi_rvalid(magic_axi_rvalid),
        .axi_rready(magic_axi_rready)
    );

    // ========================================================================
    // SystemVerilog Assertions - SoC Integration Verification
    // ========================================================================
    // Define ASSERTION by default (can be disabled with +define+NO_ASSERTION)
`ifndef NO_ASSERTION
`ifndef ASSERTION
`define ASSERTION
`endif
`endif // NO_ASSERTION

`ifdef ASSERTION
    // Core Memory Interface Protocol Assertions
    // Check instruction memory request/response handshaking

    // IMEM: Request address must be 4-byte aligned
    property p_imem_addr_aligned;
        @(posedge clk) disable iff (!rst_n)
        !imem_req_valid || (imem_req_addr[1:0] == 2'b00);
    endproperty
    assert property (p_imem_addr_aligned)
        else $error("[SOC] IMEM request address not 4-byte aligned: 0x%h", imem_req_addr);

    // NOTE: IMEM response timing is handled by instruction buffer tracking in core

    // DMEM: Request address must be naturally aligned based on access size
    // Note: Actual alignment checking is done in core, here we just check for X/Z

    // DMEM: Write enable must be all-or-nothing for word writes
    property p_dmem_we_consistency;
        @(posedge clk) disable iff (!rst_n)
        !dmem_req_valid ||
        (dmem_req_we == 4'b0000) || // Read
        (dmem_req_we == 4'b1111) || // Word write
        (dmem_req_we == 4'b0011) || (dmem_req_we == 4'b1100) || // Half-word
        (dmem_req_we == 4'b0001) || (dmem_req_we == 4'b0010) ||
        (dmem_req_we == 4'b0100) || (dmem_req_we == 4'b1000);   // Byte
    endproperty
    assert property (p_dmem_we_consistency)
        else $error("[SOC] DMEM invalid write enable pattern: 0x%h", dmem_req_we);

    // NOTE: DMEM response timing is handled by store buffer and load tracking in core

    // AXI Protocol Assertions - Instruction Bridge (Read-Only)
    // NOTE: IMEM bridge is structurally read-only (mem_axi_ro has no write channels)

    // IMEM Bridge: AR address must be 4-byte aligned
    property p_imem_axi_araddr_aligned;
        @(posedge clk) disable iff (!rst_n)
        !imem_axi_arvalid || (imem_axi_araddr[1:0] == 2'b00);
    endproperty
    assert property (p_imem_axi_araddr_aligned)
        else $error("[SOC] IMEM AXI AR address not aligned: 0x%h", imem_axi_araddr);

    // IMEM Bridge: AR valid stability (must stay high until ready)
    property p_imem_axi_ar_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(imem_axi_arvalid && !imem_axi_arready)) |->
        (imem_axi_arvalid && imem_axi_araddr == $past(imem_axi_araddr));
    endproperty
    assert property (p_imem_axi_ar_stable)
        else $error("[SOC] IMEM AXI AR valid/addr changed before ready");

    // IMEM Bridge: R valid stability (must stay high until ready)
    property p_imem_axi_r_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(imem_axi_rvalid && !imem_axi_rready)) |-> imem_axi_rvalid;
    endproperty
    assert property (p_imem_axi_r_stable)
        else $error("[SOC] IMEM AXI R valid dropped before ready");

    // AXI Protocol Assertions - Data Bridge (Read/Write)

    // DMEM Bridge: AW valid stability (must stay high until ready)
    property p_dmem_axi_aw_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(dmem_axi_awvalid && !dmem_axi_awready)) |->
        (dmem_axi_awvalid && dmem_axi_awaddr == $past(dmem_axi_awaddr));
    endproperty
    assert property (p_dmem_axi_aw_stable)
        else $error("[SOC] DMEM AXI AW valid/addr changed before ready");

    // DMEM Bridge: W valid stability (must stay high until ready)
    property p_dmem_axi_w_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(dmem_axi_wvalid && !dmem_axi_wready)) |->
        (dmem_axi_wvalid && dmem_axi_wdata == $past(dmem_axi_wdata));
    endproperty
    assert property (p_dmem_axi_w_stable)
        else $error("[SOC] DMEM AXI W valid/data changed before ready");

    // DMEM Bridge: AR valid stability (must stay high until ready)
    property p_dmem_axi_ar_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(dmem_axi_arvalid && !dmem_axi_arready)) |->
        (dmem_axi_arvalid && dmem_axi_araddr == $past(dmem_axi_araddr));
    endproperty
    assert property (p_dmem_axi_ar_stable)
        else $error("[SOC] DMEM AXI AR valid/addr changed before ready");

    // DMEM Bridge: B valid stability (must stay high until ready)
    property p_dmem_axi_b_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(dmem_axi_bvalid && !dmem_axi_bready)) |-> dmem_axi_bvalid;
    endproperty
    assert property (p_dmem_axi_b_stable)
        else $error("[SOC] DMEM AXI B valid dropped before ready");

    // DMEM Bridge: R valid stability (must stay high until ready)
    property p_dmem_axi_r_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(dmem_axi_rvalid && !dmem_axi_rready)) |-> dmem_axi_rvalid;
    endproperty
    assert property (p_dmem_axi_r_stable)
        else $error("[SOC] DMEM AXI R valid dropped before ready");

    // DMEM Bridge: Write strobe must match write valid
    property p_dmem_axi_wstrb_valid;
        @(posedge clk) disable iff (!rst_n)
        !dmem_axi_wvalid ||
        (dmem_axi_wstrb == 4'b0001) || (dmem_axi_wstrb == 4'b0010) ||
        (dmem_axi_wstrb == 4'b0100) || (dmem_axi_wstrb == 4'b1000) ||
        (dmem_axi_wstrb == 4'b0011) || (dmem_axi_wstrb == 4'b1100) ||
        (dmem_axi_wstrb == 4'b1111);
    endproperty
    assert property (p_dmem_axi_wstrb_valid)
        else $error("[SOC] DMEM AXI invalid write strobe: 0x%h", dmem_axi_wstrb);

    // AXI Arbiter Assertions

    // Arbiter: Write channels pass through from DMEM only
    property p_arb_aw_from_dmem;
        @(posedge clk) disable iff (!rst_n)
        !arb_axi_awvalid || dmem_axi_awvalid;
    endproperty
    assert property (p_arb_aw_from_dmem)
        else $error("[SOC] Arbiter AW valid without DMEM AW valid");

    property p_arb_w_from_dmem;
        @(posedge clk) disable iff (!rst_n)
        !arb_axi_wvalid || dmem_axi_wvalid;
    endproperty
    assert property (p_arb_w_from_dmem)
        else $error("[SOC] Arbiter W valid without DMEM W valid");

    // Arbiter: Read channel must come from either IMEM or DMEM
    property p_arb_ar_source;
        @(posedge clk) disable iff (!rst_n)
        !arb_axi_arvalid || imem_axi_arvalid || dmem_axi_arvalid;
    endproperty
    assert property (p_arb_ar_source)
        else $error("[SOC] Arbiter AR valid without any master AR valid");

    // Arbiter: AXI valid stability (must stay high until ready)
    property p_arb_axi_aw_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(arb_axi_awvalid && !arb_axi_awready)) |-> arb_axi_awvalid;
    endproperty
    assert property (p_arb_axi_aw_stable)
        else $error("[SOC] Arbiter AXI AW valid dropped before ready");

    property p_arb_axi_w_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(arb_axi_wvalid && !arb_axi_wready)) |-> arb_axi_wvalid;
    endproperty
    assert property (p_arb_axi_w_stable)
        else $error("[SOC] Arbiter AXI W valid dropped before ready");

    property p_arb_axi_ar_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(arb_axi_arvalid && !arb_axi_arready)) |-> arb_axi_arvalid;
    endproperty
    assert property (p_arb_axi_ar_stable)
        else $error("[SOC] Arbiter AXI AR valid dropped before ready");

    // AXI Interconnect Assertions

    // Interconnect: External RAM (Slave 0) AXI valid stability
    property p_ram_axi_aw_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(m_axi_awvalid && !m_axi_awready)) |-> m_axi_awvalid;
    endproperty
    assert property (p_ram_axi_aw_stable)
        else $error("[SOC] RAM AXI AW valid dropped before ready");

    property p_ram_axi_w_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(m_axi_wvalid && !m_axi_wready)) |-> m_axi_wvalid;
    endproperty
    assert property (p_ram_axi_w_stable)
        else $error("[SOC] RAM AXI W valid dropped before ready");

    property p_ram_axi_ar_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(m_axi_arvalid && !m_axi_arready)) |-> m_axi_arvalid;
    endproperty
    assert property (p_ram_axi_ar_stable)
        else $error("[SOC] RAM AXI AR valid dropped before ready");

    // Interconnect: CLINT (Slave 1) AXI valid stability
    property p_clint_axi_aw_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(clint_axi_awvalid && !clint_axi_awready)) |-> clint_axi_awvalid;
    endproperty
    assert property (p_clint_axi_aw_stable)
        else $error("[SOC] CLINT AXI AW valid dropped before ready");

    property p_clint_axi_ar_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(clint_axi_arvalid && !clint_axi_arready)) |-> clint_axi_arvalid;
    endproperty
    assert property (p_clint_axi_ar_stable)
        else $error("[SOC] CLINT AXI AR valid dropped before ready");

    // Interconnect: UART (Slave 2) AXI valid stability
    property p_uart_axi_aw_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(uart_axi_awvalid && !uart_axi_awready)) |-> uart_axi_awvalid;
    endproperty
    assert property (p_uart_axi_aw_stable)
        else $error("[SOC] UART AXI AW valid dropped before ready");

    property p_uart_axi_ar_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(uart_axi_arvalid && !uart_axi_arready)) |-> uart_axi_arvalid;
    endproperty
    assert property (p_uart_axi_ar_stable)
        else $error("[SOC] UART AXI AR valid dropped before ready");

    // Interconnect: SPI (Slave 3) AXI valid stability
    property p_spi_axi_aw_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(spi_axi_awvalid && !spi_axi_awready)) |-> spi_axi_awvalid;
    endproperty
    assert property (p_spi_axi_aw_stable)
        else $error("[SOC] SPI AXI AW valid dropped before ready");

    property p_spi_axi_ar_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(spi_axi_arvalid && !spi_axi_arready)) |-> spi_axi_arvalid;
    endproperty
    assert property (p_spi_axi_ar_stable)
        else $error("[SOC] SPI AXI AR valid dropped before ready");

    // Interconnect: I2C (Slave 4) AXI valid stability
    property p_i2c_axi_aw_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(i2c_axi_awvalid && !i2c_axi_awready)) |-> i2c_axi_awvalid;
    endproperty
    assert property (p_i2c_axi_aw_stable)
        else $error("[SOC] I2C AXI AW valid dropped before ready");

    property p_i2c_axi_ar_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(i2c_axi_arvalid && !i2c_axi_arready)) |-> i2c_axi_arvalid;
    endproperty
    assert property (p_i2c_axi_ar_stable)
        else $error("[SOC] I2C AXI AR valid dropped before ready");

    // Interconnect: Magic (Slave 5) AXI valid stability
    property p_magic_axi_aw_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(magic_axi_awvalid && !magic_axi_awready)) |-> magic_axi_awvalid;
    endproperty
    assert property (p_magic_axi_aw_stable)
        else $error("[SOC] Magic AXI AW valid dropped before ready");

    property p_magic_axi_ar_stable;
        @(posedge clk) disable iff (!rst_n)
        ($past(magic_axi_arvalid && !magic_axi_arready)) |-> magic_axi_arvalid;
    endproperty
    assert property (p_magic_axi_ar_stable)
        else $error("[SOC] Magic AXI AR valid dropped before ready");

    // Peripheral Response Protocol Assertions
    // NOTE: Response timing is complex due to pipelining and doesn't require
    // immediate response in next cycle. The peripherals handle their own timing.
    // We just check for X/Z on response signals below.

    // X/Z Detection on Critical Control Signals

    // Core memory interface
    property p_no_x_imem_req_valid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(imem_req_valid);
    endproperty
    assert property (p_no_x_imem_req_valid)
        else $error("[SOC] X/Z detected on imem_req_valid");

    property p_no_x_imem_req_ready;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(imem_req_ready);
    endproperty
    assert property (p_no_x_imem_req_ready)
        else $error("[SOC] X/Z detected on imem_req_ready");

    property p_no_x_dmem_req_valid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(dmem_req_valid);
    endproperty
    assert property (p_no_x_dmem_req_valid)
        else $error("[SOC] X/Z detected on dmem_req_valid");

    property p_no_x_dmem_req_ready;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(dmem_req_ready);
    endproperty
    assert property (p_no_x_dmem_req_ready)
        else $error("[SOC] X/Z detected on dmem_req_ready");

    // Arbiter AXI interface
    property p_no_x_arb_awvalid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(arb_axi_awvalid);
    endproperty
    assert property (p_no_x_arb_awvalid)
        else $error("[SOC] X/Z detected on arb_axi_awvalid");

    property p_no_x_arb_awready;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(arb_axi_awready);
    endproperty
    assert property (p_no_x_arb_awready)
        else $error("[SOC] X/Z detected on arb_axi_awready");

    property p_no_x_arb_wvalid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(arb_axi_wvalid);
    endproperty
    assert property (p_no_x_arb_wvalid)
        else $error("[SOC] X/Z detected on arb_axi_wvalid");

    property p_no_x_arb_wready;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(arb_axi_wready);
    endproperty
    assert property (p_no_x_arb_wready)
        else $error("[SOC] X/Z detected on arb_axi_wready");

    property p_no_x_arb_arvalid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(arb_axi_arvalid);
    endproperty
    assert property (p_no_x_arb_arvalid)
        else $error("[SOC] X/Z detected on arb_axi_arvalid");

    property p_no_x_arb_arready;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(arb_axi_arready);
    endproperty
    assert property (p_no_x_arb_arready)
        else $error("[SOC] X/Z detected on arb_axi_arready");

    // External RAM interface
    property p_no_x_ram_awvalid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(m_axi_awvalid);
    endproperty
    assert property (p_no_x_ram_awvalid)
        else $error("[SOC] X/Z detected on m_axi_awvalid");

    property p_no_x_ram_arvalid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(m_axi_arvalid);
    endproperty
    assert property (p_no_x_ram_arvalid)
        else $error("[SOC] X/Z detected on m_axi_arvalid");

    // Interrupt signals
    property p_no_x_timer_irq;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(timer_irq);
    endproperty
    assert property (p_no_x_timer_irq)
        else $error("[SOC] X/Z detected on timer_irq");

    property p_no_x_software_irq;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(software_irq);
    endproperty
    assert property (p_no_x_software_irq)
        else $error("[SOC] X/Z detected on software_irq");

    // System-Level Parameter Sanity Checks
    initial begin
        assert_ib_depth_valid: assert (IB_DEPTH >= 1 && IB_DEPTH <= 8)
            else $error("[SOC] IB_DEPTH must be between 1 and 8, got %0d", IB_DEPTH);

        assert_sb_depth_valid: assert (SB_DEPTH >= 1 && SB_DEPTH <= 8)
            else $error("[SOC] SB_DEPTH must be between 1 and 8, got %0d", SB_DEPTH);

        assert_clk_freq_valid: assert (CLK_FREQ >= 1_000_000 && CLK_FREQ <= 1_000_000_000)
            else $error("[SOC] CLK_FREQ must be between 1MHz and 1GHz, got %0d", CLK_FREQ);

        assert_baud_rate_valid: assert (BAUD_RATE >= 9600 && BAUD_RATE <= CLK_FREQ/4)
            else $error("[SOC] BAUD_RATE must be between 9600 and CLK_FREQ/4, got %0d", BAUD_RATE);
    end

`endif // ASSERTION

endmodule

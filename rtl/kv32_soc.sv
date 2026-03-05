// ============================================================================
// File: kv32_soc.sv
// Project: KV32 RISC-V Processor
// Description: RV32IMAC System-on-Chip Top-Level Module
//
// Integrates all major components of the RISC-V SoC:
//   - RV32IMAC processor core (5-stage pipeline)
//   - External 2MB RAM via AXI4-Lite
//   - Memory-mapped peripherals (CLINT, PLIC, UART, SPI, I2C, GPIO, Timer, DMA, Magic)
//   - AXI4-Lite interconnect infrastructure
//
// This is the top-level module that should be instantiated in testbenches
// or FPGA designs.
//
// Features:
//   - 5-stage pipelined RV32IMAC core with CSRs
//   - Separate instruction and data memory interfaces
//   - AXI arbiter for read channel arbitration
//   - Standard RISC-V CLINT timer with mtime/mtimecmp
//   - PLIC (Platform-Level Interrupt Controller) placeholder
//   - High-speed UART for serial I/O (up to 25 Mbaud)
//   - SPI master controller for peripheral interfacing
//   - I2C master controller for sensor interfacing
//   - GPIO with up to 128 configurable pins
//   - Timer/PWM with 4 independent 32-bit timers
//   - DMA controller for memory-to-memory transfers
//   - Magic addresses for simulation control
//   - AXI4-Lite system bus with 1-to-10 interconnect
//
// Memory Map:
//   0x8000_0000 - 0x801F_FFFF: RAM (2MB)
//   0x0200_0000 - 0x020B_FFFF: CLINT
//   0x0C00_0000 - 0x0CFF_FFFF: PLIC
//   0x4000_0000 - 0x4000_FFFF: Magic addresses
//   0x0200_0000 - 0x020B_FFFF: CLINT
//   0x0C00_0000 - 0x0CFF_FFFF: PLIC
//   0x2000_0000 - 0x2000_FFFF: DMA
//   0x2001_0000 - 0x2001_FFFF: UART
//   0x2002_0000 - 0x2002_FFFF: I2C
//   0x2003_0000 - 0x2003_FFFF: SPI
//   0x2004_0000 - 0x2004_FFFF: Timer
//   0x2005_0000 - 0x2005_FFFF: GPIO
//   0x8000_0000 - 0x801F_FFFF: RAM (2MB)
//
// Default Configuration:
//   - System Clock: 100 MHz
//   - UART Baud Rate: 25 Mbaud (maximum for CLKS_PER_BIT=4)
//   - Instruction Buffer Depth: 2 (up to 2 outstanding fetches)
//   - Store Buffer Depth: 2 (up to 2 buffered stores)
//   - Multiply Mode: FAST_MUL=1 (combinatorial, single cycle)
//   - Division Mode: FAST_DIV=1 (combinatorial, single cycle)
// ============================================================================

module kv32_soc #(
    parameter int unsigned CLK_FREQ          = 100_000_000,      // System clock frequency in Hz
    parameter int unsigned BAUD_RATE         = 25_000_000,       // UART baud rate (max = CLK_FREQ/4)
    parameter int unsigned IB_DEPTH          = 4,                // Instruction buffer depth (outstanding fetches); must be power-of-2 >= effective_latency+1
    parameter int unsigned SB_DEPTH          = 2,                // Store buffer depth (buffered stores)
    parameter int unsigned FAST_MUL          = 1,                // Multiply mode: 1=combinatorial, 0=serial
    parameter int unsigned FAST_DIV          = 1,                // Division mode: 1=combinatorial, 0=serial
    parameter bit          ICACHE_EN         = 1'b1,             // Instruction cache: 1=enabled, 0=bypass (uses mem_axi_ro)
    parameter int unsigned ICACHE_SIZE       = 4096,             // I-cache total bytes
    parameter int unsigned ICACHE_LINE_SIZE  = 32,               // Cache line size in bytes (32 = 8 words/line)
    parameter int unsigned ICACHE_WAYS       = 2,                // Cache associativity (number of ways)
    parameter bit          USE_CJTAG         = 1'b1,             // JTAG mode: 0=JTAG, 1=cJTAG
    parameter bit [31:0]   JTAG_IDCODE       = 32'h1DEAD3FF,     // JTAG device identification code
    parameter int unsigned GPIO_NUM_PINS     = 4                 // Number of GPIO pins (1-128, generates only required registers)
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
    output logic        i2c_scl_oe,
    output logic        i2c_sda_o,
    input  logic        i2c_sda_i,
    output logic        i2c_sda_oe,

    // GPIO pins
    output logic [GPIO_NUM_PINS-1:0] gpio_o,
    input  logic [GPIO_NUM_PINS-1:0] gpio_i,
    output logic [GPIO_NUM_PINS-1:0] gpio_oe,

    // PWM outputs from Timer peripheral
    output logic [3:0]  pwm_o,

    // JTAG/cJTAG Debug Interface (4-pin, muxed)
    input  logic        jtag_tck_i,         // Pin 0: TCK/TCKC (clock)
    input  logic        jtag_tms_i,         // Pin 1: TMS/TMSC input
    output logic        jtag_tms_o,         // Pin 1: TMS/TMSC output
    output logic        jtag_tms_oe,        // Pin 1: Output enable
    input  logic        jtag_tdi_i,         // Pin 2: TDI (JTAG only)
    output logic        jtag_tdo_o,         // Pin 3: TDO output
    output logic        jtag_tdo_oe,        // Pin 3: Output enable
    output logic        cjtag_online_o,     // cJTAG online status (for LED indicator)

    // External AXI4-Lite RAM interface (2MB)
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
    output logic [7:0]  m_axi_arlen,     // Burst length (icache cache-line fills)
    output logic [2:0]  m_axi_arsize,    // Burst size
    output logic [1:0]  m_axi_arburst,   // Burst type (INCR/WRAP)

    input  logic [31:0] m_axi_rdata,
    input  logic [1:0]  m_axi_rresp,
    input  logic        m_axi_rvalid,
    output logic        m_axi_rready,
    input  logic        m_axi_rlast,     // Last beat of burst (from axi_memory)

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
    input  logic        trace_mode,
    // I-cache performance counters (zero when ICACHE_EN=0)
    output logic [31:0] icache_perf_req_cnt,
    output logic [31:0] icache_perf_hit_cnt,
    output logic [31:0] icache_perf_miss_cnt,
    output logic [31:0] icache_perf_bypass_cnt,
    output logic [31:0] icache_perf_fill_cnt,
    output logic [31:0] icache_perf_cmo_cnt
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
    // Loop-free version of imem_req_addr for icache fill-pending logic;
    // uses dedup_consumed (without imem_req_ready) to break the UNOPTFLAT loop.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] imem_req_addr_fill;
    /* verilator lint_on UNUSEDSIGNAL */
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
    logic [7:0]               imem_axi_arlen;      // Burst length (icache only)
    logic [2:0]               imem_axi_arsize;     // Burst size
    logic [1:0]               imem_axi_arburst;    // Burst type (INCR/WRAP)
    /* verilator lint_off UNUSEDSIGNAL */
    logic                     imem_axi_rlast;      // Last beat of burst (icache only)
    /* verilator lint_on UNUSEDSIGNAL */

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
    logic [7:0]               arb_axi_arlen;       // Burst length (from arbiter to xbar)
    logic [2:0]               arb_axi_arsize;      // Burst size
    logic [1:0]               arb_axi_arburst;     // Burst type
    logic [7:0]               arb_axi_awlen;       // Write burst length
    logic [2:0]               arb_axi_awsize;      // Write burst size
    logic [1:0]               arb_axi_awburst;     // Write burst type
    logic                     arb_axi_wlast;       // Write data last beat
    logic [31:0]              arb_axi_rdata;
    logic [1:0]               arb_axi_rresp;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] arb_axi_rid;        // Read data ID
    logic                     arb_axi_rvalid;
    logic                     arb_axi_rready;
    logic                     arb_axi_rlast;       // Last beat of burst

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
    // AXI Interconnect <-> PLIC Signals
    // ========================================================================
    // Platform-Level Interrupt Controller (placeholder)
    // Base address: 0x0C00_0000
    logic [31:0] plic_axi_awaddr;
    logic        plic_axi_awvalid;
    logic        plic_axi_awready;
    logic [31:0] plic_axi_wdata;
    logic [3:0]  plic_axi_wstrb;
    logic        plic_axi_wvalid;
    logic        plic_axi_wready;
    logic [1:0]  plic_axi_bresp;
    logic        plic_axi_bvalid;
    logic        plic_axi_bready;
    logic [31:0] plic_axi_araddr;
    logic        plic_axi_arvalid;
    logic        plic_axi_arready;
    logic [31:0] plic_axi_rdata;
    logic [1:0]  plic_axi_rresp;
    logic        plic_axi_rvalid;
    logic        plic_axi_rready;

    // ========================================================================
    // AXI Interconnect <-> UART Signals
    // ========================================================================
    // Memory-mapped access to UART TX/RX data and status registers
    // Base address: 0x2001_0000
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
    // Base address: 0x2003_0000
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
    // Base address: 0x2002_0000
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
    // AXI Interconnect <-> GPIO Peripheral Signals
    // ========================================================================
    // Memory-mapped GPIO controller with up to 128 configurable pins
    // Base address: 0x2005_0000
    logic [31:0] gpio_axi_awaddr;
    logic        gpio_axi_awvalid;
    logic        gpio_axi_awready;
    logic [31:0] gpio_axi_wdata;
    logic [3:0]  gpio_axi_wstrb;
    logic        gpio_axi_wvalid;
    logic        gpio_axi_wready;
    logic [1:0]  gpio_axi_bresp;
    logic        gpio_axi_bvalid;
    logic        gpio_axi_bready;
    logic [31:0] gpio_axi_araddr;
    logic        gpio_axi_arvalid;
    logic        gpio_axi_arready;
    logic [31:0] gpio_axi_rdata;
    logic [1:0]  gpio_axi_rresp;
    logic        gpio_axi_rvalid;
    logic        gpio_axi_rready;

    // ========================================================================
    // AXI Interconnect <-> Timer Peripheral Signals
    // ========================================================================
    // Memory-mapped Timer/PWM controller with 4 independent 32-bit timers
    // Base address: 0x2004_0000
    logic [31:0] timer_axi_awaddr;
    logic        timer_axi_awvalid;
    logic        timer_axi_awready;
    logic [31:0] timer_axi_wdata;
    logic [3:0]  timer_axi_wstrb;
    logic        timer_axi_wvalid;
    logic        timer_axi_wready;
    logic [1:0]  timer_axi_bresp;
    logic        timer_axi_bvalid;
    logic        timer_axi_bready;
    logic [31:0] timer_axi_araddr;
    logic        timer_axi_arvalid;
    logic        timer_axi_arready;
    logic [31:0] timer_axi_rdata;
    logic [1:0]  timer_axi_rresp;
    logic        timer_axi_rvalid;
    logic        timer_axi_rready;

    // ========================================================================
    // AXI Interconnect <-> DMA Controller Signals
    // ========================================================================
    // Special addresses for simulation control (exit, pass/fail, etc.)
    // Base address: 0x2000_0000
    // DMA configuration slave AXI-Lite signals (xbar s4 → axi_dma cfg port)
    logic [31:0] dma_cfg_axi_awaddr;  logic dma_cfg_axi_awvalid;  logic dma_cfg_axi_awready;
    logic [31:0] dma_cfg_axi_wdata;   logic [3:0] dma_cfg_axi_wstrb;
    logic        dma_cfg_axi_wvalid;  logic dma_cfg_axi_wready;
    logic [1:0]  dma_cfg_axi_bresp;   logic dma_cfg_axi_bvalid;   logic dma_cfg_axi_bready;
    logic [31:0] dma_cfg_axi_araddr;  logic dma_cfg_axi_arvalid;  logic dma_cfg_axi_arready;
    logic [31:0] dma_cfg_axi_rdata;   logic [1:0] dma_cfg_axi_rresp;
    logic        dma_cfg_axi_rvalid;  logic dma_cfg_axi_rready;
    // DMA master AXI signals (axi_dma dma port → arbiter M2)
    logic [31:0] dma_m_axi_awaddr;  logic [7:0] dma_m_axi_awlen;
    logic [2:0]  dma_m_axi_awsize;  logic [1:0] dma_m_axi_awburst;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] dma_m_axi_awid;
    logic        dma_m_axi_awvalid; logic dma_m_axi_awready;
    logic [31:0] dma_m_axi_wdata;   logic [3:0] dma_m_axi_wstrb;
    logic        dma_m_axi_wlast;   logic dma_m_axi_wvalid;  logic dma_m_axi_wready;
    logic [1:0]  dma_m_axi_bresp;   logic [axi_pkg::AXI_ID_WIDTH-1:0] dma_m_axi_bid;
    logic        dma_m_axi_bvalid;  logic dma_m_axi_bready;
    logic [31:0] dma_m_axi_araddr;  logic [7:0] dma_m_axi_arlen;
    logic [2:0]  dma_m_axi_arsize;  logic [1:0] dma_m_axi_arburst;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] dma_m_axi_arid;
    logic        dma_m_axi_arvalid; logic dma_m_axi_arready;
    logic [31:0] dma_m_axi_rdata;   logic [1:0] dma_m_axi_rresp;
    logic [axi_pkg::AXI_ID_WIDTH-1:0] dma_m_axi_rid;
    logic        dma_m_axi_rlast;   logic dma_m_axi_rvalid;  logic dma_m_axi_rready;
    assign dma_m_axi_awid = '0;
    assign dma_m_axi_arid = '0;

    // ========================================================================
    // AXI Interconnect <-> Magic Device Signals
    // ========================================================================
    // Special addresses for simulation control (exit, pass/fail, etc.)
    // Base address: 0x4000_0000
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

    // CMO sideband from CPU core (FENCE.I / cbo.inval instructions)
    /* verilator lint_off UNUSEDSIGNAL */
    logic        core_cmo_valid;     // Core CMO request valid
    logic [1:0]  core_cmo_op;        // Core CMO operation
    logic [31:0] core_cmo_addr;      // Core CMO target address
    /* verilator lint_on UNUSEDSIGNAL */
    logic        core_cmo_ready;     // Acknowledge back to core

    // ========================================================================
    // Interrupt Signals
    // ========================================================================
    logic        timer_irq;           // Timer interrupt from CLINT
    logic        software_irq;        // Software interrupt from CLINT
    logic        external_irq;        // External interrupt from PLIC
    logic        uart_irq;            // UART FIFO interrupt → PLIC source 1
    logic        spi_irq;             // SPI  FIFO interrupt → PLIC source 2
    logic        i2c_irq;             // I2C  FIFO interrupt → PLIC source 3
    logic        dma_irq;             // DMA interrupt → PLIC source 4
    logic        gpio_irq;            // GPIO interrupt → PLIC source 5
    logic        pwm_timer_irq;       // Timer/PWM interrupt → PLIC source 6

    // ========================================================================
    // Debug Interface Signals
    // ========================================================================
    logic        dbg_halt_req;        // Debug halt request
    logic        dbg_halted;          // CPU is halted
    logic        dbg_resume_req;      // Debug resume request
    logic        dbg_resumeack;       // CPU resume acknowledge
    logic [4:0]  dbg_reg_addr;        // Debug register address
    logic [31:0] dbg_reg_wdata;       // Debug register write data
    logic        dbg_reg_we;          // Debug register write enable
    logic [31:0] dbg_reg_rdata;       // Debug register read data
    logic [31:0] dbg_pc;              // Current PC
    logic [31:0] dbg_pc_wdata;        // Debug PC write data
    logic        dbg_pc_we;           // Debug PC write enable
    logic        dbg_mem_req;         // Debug memory request (tied off for now)
    logic [31:0] dbg_mem_addr;        // Debug memory address (tied off for now)
    logic [3:0]  dbg_mem_we;          // Debug memory write enable (tied off for now)
    logic [31:0] dbg_mem_wdata;       // Debug memory write data (tied off for now)
    logic        dbg_mem_ready;       // Debug memory ready (tied off for now)
    logic [31:0] dbg_mem_rdata;       // Debug memory read data (tied off for now)
    // ndmreset/hartreset from DM — wired into cpu_rst_n / soc_rst_n below.
    logic        dbg_ndmreset;        // Non-debug module reset (resets CPU + peripherals)
    logic        dbg_hartreset;       // Hart reset (resets CPU only)

    // ========================================================================
    // WFI / Power Management Signals
    // ========================================================================
    logic        core_sleep;          // kv32_core is idle in WFI (all requests drained)
    logic        core_clk;            // Gated clock supplied to kv32_core by kv32_pm
    logic        core_wakeup;         // Wakeup pulse from kv32_pm to kv32_core
    logic        icache_idle;         // ICache has no AXI transaction in-flight

    // Tie off debug memory interface (not yet implemented - would need AXI master)
    assign dbg_mem_ready = 1'b0;
    assign dbg_mem_rdata = 32'h0;

    // Debug reset domains:
    //   cpu_rst_n: reset by external rst_n, ndmreset, or hartreset (core + instruction path)
    //   soc_rst_n: reset by external rst_n or ndmreset (peripherals + interconnect)
    /* verilator lint_off SYNCASYNCNET */
    logic cpu_rst_n;
    logic soc_rst_n;
    /* verilator lint_on SYNCASYNCNET */
    assign cpu_rst_n = rst_n && !dbg_ndmreset && !dbg_hartreset;
    assign soc_rst_n = rst_n && !dbg_ndmreset;

`ifndef SYNTHESIS
    logic        core_retire_instr;   // Instruction retirement pulse for trace-mode mtime
    logic        core_wb_store;       // Retiring store pulse for trace-mode CLINT bypass
    logic [31:0] core_wb_store_addr;  // Store effective address
    logic [31:0] core_wb_store_data;  // Store data word
    logic [3:0]  core_wb_store_strb;  // Store byte enables
`endif

    // external_irq is driven by the PLIC instance below
    // uart_irq / spi_irq / i2c_irq are connected to PLIC sources 1/2/3

    // ========================================================================
    // Power Manager Instance (kv32_pm)
    // ========================================================================
    // Gates the clock to kv32_core when the core executes WFI and all
    // outstanding instruction-fetch and store-buffer traffic has drained.
    // The CLINT and PLIC continue running on the ungated system clock so
    // that interrupts can wake the core.
    kv32_pm u_kv32_pm (
        .clk_i         (clk),
        .rst_n         (rst_n),
        .sleep_req_i   (core_sleep),
        .timer_irq_i   (timer_irq),
        .external_irq_i(external_irq),
        .software_irq_i(software_irq),
        .gated_clk_o   (core_clk),
        .wakeup_o      (core_wakeup)
    );

    // ========================================================================
    // RV32IMAC Processor Core Instance
    // ========================================================================
    // 5-stage pipelined RISC-V core implementing RV32IMAC ISA
    // Features: CSRs, interrupts, precise exceptions, performance counters
    // Configurable instruction buffer (IB_DEPTH) and store buffer (SB_DEPTH)
    kv32_core #(
        .IB_DEPTH(IB_DEPTH),
        .SB_DEPTH(SB_DEPTH),
        .FAST_MUL(FAST_MUL),
        .FAST_DIV(FAST_DIV)
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

        .timer_irq(timer_irq),
        .external_irq(external_irq),
        .software_irq(software_irq),

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

        // WFI / Power Management
        .core_sleep_o(core_sleep),
        .wakeup_i    (core_wakeup),

        // Debug interface
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
`endif
    );

    // ========================================================================
    // Instruction Memory Interface: I-Cache or Simple AXI Bridge
    // ========================================================================
    // ICACHE_EN=1: kv32_icache (AXI4 burst master, WPL=LINE_SIZE/4 beats)
    // ICACHE_EN=0: mem_axi_ro  (single-beat AXI4-Lite bridge, legacy path)
        if (ICACHE_EN) begin : g_icache

            // CMO interface: connect core directly to icache.
            logic        icache_cmo_ready_w;
            logic        icache_idle_w;

            assign core_cmo_ready = icache_cmo_ready_w;
            assign icache_idle    = icache_idle_w;

            kv32_icache #(
                .CACHE_SIZE     (ICACHE_SIZE),
                .CACHE_LINE_SIZE(ICACHE_LINE_SIZE),
                .CACHE_WAYS     (ICACHE_WAYS)
            ) icache (
                .clk    (core_clk),
                .rst_n  (cpu_rst_n),

                // CPU side
                .imem_req_valid (imem_req_valid),
                .imem_req_addr  (imem_req_addr),
                .imem_req_ready (imem_req_ready),
                .imem_req_addr_fill (imem_req_addr_fill),
                .imem_resp_valid(imem_resp_valid),
                .imem_resp_data (imem_resp_data),
                .imem_resp_error(imem_resp_error),
                .imem_resp_ready(imem_resp_ready),

                // AXI4 burst master side
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

                // CMO interface (core only)
                .cmo_valid  (core_cmo_valid),
                .cmo_addr   (core_cmo_addr),
                .cmo_op     (core_cmo_op),
                .cmo_ready  (icache_cmo_ready_w),

                // Power management
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

            // I-cache has no transaction-ID support; drive ID=0 on AR channel.
            // imem_axi_rid is an arbiter output — icache does not use it.
            assign imem_axi_arid = '0;

        end else begin : g_no_icache

            // Simple read-only AXI bridge (original behaviour)
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

            // mem_axi_ro issues single-beat reads; provide fixed burst fields
            assign imem_axi_arlen   = 8'h00;
            assign imem_axi_arsize  = 3'b010;  // 4 bytes
            assign imem_axi_arburst = 2'b01;   // INCR
            // imem_axi_rlast is driven by the arbiter (m0_axi_rlast); no local assign needed

            // No icache: CMO requests have nowhere to go; ack immediately
            assign core_cmo_ready  = 1'b1;
            // No icache: simple bridge has no AXI burst in-flight during WFI
            // (imem_req_valid is inhibited; !imem_resp_valid in core_sleep_o
            // already covers any last in-flight single-beat response).
            assign icache_idle     = 1'b1;
`ifndef SYNTHESIS
            assign icache_perf_req_cnt    = '0;
            assign icache_perf_hit_cnt    = '0;
            assign icache_perf_miss_cnt   = '0;
            assign icache_perf_bypass_cnt = '0;
            assign icache_perf_fill_cnt   = '0;
            assign icache_perf_cmo_cnt    = '0;
`endif

        end

    // ========================================================================
    // Data Memory to AXI Bridge (Read/Write)
    // ========================================================================
    // Converts core's simple request/response to full AXI4 (AW/W/B/AR/R) with ID support
    // Supports both loads and stores with byte-level write enables
    mem_axi #(
`ifndef SYNTHESIS
        .BRIDGE_NAME("DMEM_BRIDGE"),
`endif
        .OUTSTANDING_DEPTH(4)  // Conservative limit matching original system capability
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
        .rst_n(soc_rst_n),

        // Master 0: Instruction memory (Read-Only) with ID
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

        // Master 2: DMA engine (Read/Write)
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

        // Slave: to interconnect with ID
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
        .s_axi_bresp(arb_axi_bresp),
        .s_axi_bid(arb_axi_bid),
        .s_axi_bvalid(arb_axi_bvalid),
        .s_axi_bready(arb_axi_bready),
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

    // ========================================================================
    // AXI4 Interconnect (1-to-7 Crossbar)
    // ========================================================================
    // Routes transactions from arbiter to slave devices based on address with ID tracking:
    //   Slave 0 (0x8000_0000): External 2MB RAM
    //   Slave 1 (0x4000_0000): Magic device
    //   Slave 2 (0x0200_0000): CLINT timer peripheral
    //   Slave 3 (0x0C00_0000): PLIC interrupt controller
    //   Slave 4 (0x2000_0000): DMA controller
    //   Slave 5 (0x2001_0000): UART peripheral
    //   Slave 6 (0x2002_0000): I2C peripheral
    //   Slave 7 (0x2003_0000): SPI peripheral
    //   Slave 8 (0x2004_0000): Timer/PWM peripheral
    //   Slave 9 (0x2005_0000): GPIO peripheral
    // Returns DECERR response for unmapped addresses
    axi_xbar axi_intercon (
        .clk(clk),
        .rst_n(soc_rst_n),

        // Master (from arbiter) with ID support
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

        .m_axi_bresp(arb_axi_bresp),
        .m_axi_bid(arb_axi_bid),
        .m_axi_bvalid(arb_axi_bvalid),
        .m_axi_bready(arb_axi_bready),

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

        // Slave 0: External RAM
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

        // Slave 1: Magic Device
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

        // Slave 2: CLINT
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

        // Slave 3: PLIC
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

        // Slave 4: DMA Controller
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

        // Slave 5: UART
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

        // Slave 6: I2C
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

        // Slave 7: SPI
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

        // Slave 8: Timer
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

        // Slave 9: GPIO
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
        .s9_axi_rready  (gpio_axi_rready)
    );

    // ========================================================================
    // CLINT - Core Local Interruptor
    // ========================================================================
    // Provides timer (mtime) and timer comparator (mtimecmp) for timer interrupts
    // Also provides software interrupt control via memory-mapped registers
    // Memory map: 0x0200_0000 - 0x020B_FFFF (standard RISC-V CLINT base address)
    axi_clint clint (
        .clk(clk),
        .rst_n(soc_rst_n),

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
        ,.core_sleep_i(core_sleep)
        // Retire-store bypass: forward retiring store addresses/data directly
        // to the CLINT so that MSIP (and other CLINT regs) are updated on the
        // very cycle the store retires, matching SW-sim timing.
        // Only forward stores that target the CLINT address window.
        ,.trace_store_valid(core_wb_store &&
                            (core_wb_store_addr[31:20] == 12'h020) &&
                            (core_wb_store_addr[19:18] != 2'b11))
        ,.trace_store_addr(core_wb_store_addr)
        ,.trace_store_data(core_wb_store_data)
        ,.trace_store_strb(core_wb_store_strb)
`endif
    );

    // ========================================================================
    // PLIC - Platform-Level Interrupt Controller
    // ========================================================================
    // Base address: 0x0C00_0000 - 0x0FFF_FFFF
    // Interrupt sources (1..NUM_IRQ) - extend when peripherals gain IRQ outputs
    localparam int unsigned PLIC_NUM_IRQ = 7;
    logic [PLIC_NUM_IRQ:0] plic_irq_src;
    // PLIC interrupt source assignment:
    //   [1] = UART RX-not-empty / TX-empty
    //   [2] = SPI  RX-not-empty / TX-empty
    //   [3] = I2C  RX-not-empty / TX-empty / STOP-done
    //   [4] = DMA  transfer done / error
    //   [5] = GPIO edge/level interrupts
    //   [6] = Timer/PWM compare match
    //   [7]   = reserved (tied 0)
    assign plic_irq_src[0]   = 1'b0;      // source 0 reserved
    assign plic_irq_src[1]   = uart_irq;
    assign plic_irq_src[2]   = spi_irq;
    assign plic_irq_src[3]   = i2c_irq;
    assign plic_irq_src[4]   = dma_irq;
    assign plic_irq_src[5]   = gpio_irq;
    assign plic_irq_src[6]   = pwm_timer_irq;
    assign plic_irq_src[7]   = 1'b0;

    axi_plic #(
        .NUM_IRQ(PLIC_NUM_IRQ)
    ) u_plic (
        .clk         (clk),
        .rst_n       (soc_rst_n),
        .axi_awaddr  (plic_axi_awaddr),
        .axi_awvalid (plic_axi_awvalid),
        .axi_awready (plic_axi_awready),
        .axi_wdata   (plic_axi_wdata),
        .axi_wstrb   (plic_axi_wstrb),
        .axi_wvalid  (plic_axi_wvalid),
        .axi_wready  (plic_axi_wready),
        .axi_bresp   (plic_axi_bresp),
        .axi_bvalid  (plic_axi_bvalid),
        .axi_bready  (plic_axi_bready),
        .axi_araddr  (plic_axi_araddr),
        .axi_arvalid (plic_axi_arvalid),
        .axi_arready (plic_axi_arready),
        .axi_rdata   (plic_axi_rdata),
        .axi_rresp   (plic_axi_rresp),
        .axi_rvalid  (plic_axi_rvalid),
        .axi_rready  (plic_axi_rready),
        .irq_src     (plic_irq_src),
        .irq         (external_irq)
    );

    // ========================================================================
    // UART - Universal Asynchronous Receiver/Transmitter
    // ========================================================================
    // FIFO-based UART with TX/RX depths of 16.  IRQ goes to PLIC source 1.
    // Memory map: 0x2001_0000 (DATA, STATUS, IE, IS, LEVEL registers)
    // Configuration: 8N1 format, configurable baud rate
    // Current: 100 MHz clock, 25 Mbaud (CLKS_PER_BIT=4, maximum rate)
    axi_uart #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) uart (
        .clk(clk),
        .rst_n(soc_rst_n),

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

        .irq(uart_irq),

        .uart_rx(uart_rx),
        .uart_tx(uart_tx)
    );

    // ========================================================================
    // SPI - Serial Peripheral Interface
    // ========================================================================
    // FIFO-based SPI master.  IRQ goes to PLIC source 2.
    // Memory map: 0x2002_0000 (CTRL, DIV, DATA, STATUS, IE, IS)
    // Features: Configurable CPOL/CPHA, clock divider, 4 chip selects
    axi_spi #(
        .CLK_FREQ(CLK_FREQ)
    ) spi (
        .clk(clk),
        .rst_n(soc_rst_n),

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

        .irq(spi_irq),

        .spi_sclk(spi_sclk),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso),
        .spi_cs_n(spi_cs_n)
    );

    // ========================================================================
    // I2C - Inter-Integrated Circuit
    // ========================================================================
    // FIFO-based I2C master.  IRQ goes to PLIC source 3.
    // Memory map: 0x2001_0000 (CTRL, DIV, TX, RX, STATUS, IE, IS)
    // Features: Standard (100kHz) and Fast (400kHz) modes, 7-bit addressing
    axi_i2c #(
        .CLK_FREQ(CLK_FREQ)
    ) i2c (
        .clk(clk),
        .rst_n(soc_rst_n),

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

        .irq(i2c_irq),

        .i2c_scl_o(i2c_scl_o),
        .i2c_scl_i(i2c_scl_i),
        .i2c_scl_oe(i2c_scl_oe),
        .i2c_sda_o(i2c_sda_o),
        .i2c_sda_i(i2c_sda_i),
        .i2c_sda_oe(i2c_sda_oe)
    );

    // ========================================================================
    // Magic Addresses - Simulation Control
    // ========================================================================
    // DMA Controller (AXI4 DMA, slave 6 at 0x2003_0000)
    // ========================================================================
    axi_dma #(
        .NUM_CHANNELS  (4),
        .DATA_WIDTH    (32),
        .FIFO_DEPTH    (16),
        .MAX_BURST_LEN (16)
    ) u_dma (
        .clk     (clk),
        .rst_n   (soc_rst_n),

        // Config slave (AXI4-Lite from xbar s6)
        .cfg_awaddr  (dma_cfg_axi_awaddr),
        .cfg_awvalid (dma_cfg_axi_awvalid),
        .cfg_awready (dma_cfg_axi_awready),
        .cfg_wdata   (dma_cfg_axi_wdata),
        .cfg_wstrb   (dma_cfg_axi_wstrb),
        .cfg_wvalid  (dma_cfg_axi_wvalid),
        .cfg_wready  (dma_cfg_axi_wready),
        .cfg_bresp   (dma_cfg_axi_bresp),
        .cfg_bvalid  (dma_cfg_axi_bvalid),
        .cfg_bready  (dma_cfg_axi_bready),
        .cfg_araddr  (dma_cfg_axi_araddr),
        .cfg_arvalid (dma_cfg_axi_arvalid),
        .cfg_arready (dma_cfg_axi_arready),
        .cfg_rdata   (dma_cfg_axi_rdata),
        .cfg_rresp   (dma_cfg_axi_rresp),
        .cfg_rvalid  (dma_cfg_axi_rvalid),
        .cfg_rready  (dma_cfg_axi_rready),

        // Data master (AXI4 to arbiter M2)
        .dma_awaddr  (dma_m_axi_awaddr),
        .dma_awlen   (dma_m_axi_awlen),
        .dma_awsize  (dma_m_axi_awsize),
        .dma_awburst (dma_m_axi_awburst),
        .dma_awvalid (dma_m_axi_awvalid),
        .dma_awready (dma_m_axi_awready),
        .dma_wdata   (dma_m_axi_wdata),
        .dma_wstrb   (dma_m_axi_wstrb),
        .dma_wlast   (dma_m_axi_wlast),
        .dma_wvalid  (dma_m_axi_wvalid),
        .dma_wready  (dma_m_axi_wready),
        .dma_bresp   (dma_m_axi_bresp),
        .dma_bvalid  (dma_m_axi_bvalid),
        .dma_bready  (dma_m_axi_bready),
        .dma_araddr  (dma_m_axi_araddr),
        .dma_arlen   (dma_m_axi_arlen),
        .dma_arsize  (dma_m_axi_arsize),
        .dma_arburst (dma_m_axi_arburst),
        .dma_arvalid (dma_m_axi_arvalid),
        .dma_arready (dma_m_axi_arready),
        .dma_rdata   (dma_m_axi_rdata),
        .dma_rresp   (dma_m_axi_rresp),
        .dma_rlast   (dma_m_axi_rlast),
        .dma_rvalid  (dma_m_axi_rvalid),
        .dma_rready  (dma_m_axi_rready),

        .irq         (dma_irq)
    );

    // ========================================================================
    // GPIO Controller (slave 7 at 0x2004_0000)
    // ========================================================================
    // Configurable GPIO with up to 128 pins, interrupt support, and atomic SET/CLEAR
    // Memory map: 0x2004_0000 (DATA_OUT, SET, CLEAR, DATA_IN, DIR, IE, TRIGGER, POL, IS)
    // Features: Input synchronization, edge/level interrupts, parameterized pin count
    axi_gpio #(
        .NUM_PINS(GPIO_NUM_PINS)
    ) gpio (
        .clk(clk),
        .rst_n(soc_rst_n),

        .axi_awaddr(gpio_axi_awaddr),
        .axi_awvalid(gpio_axi_awvalid),
        .axi_awready(gpio_axi_awready),

        .axi_wdata(gpio_axi_wdata),
        .axi_wstrb(gpio_axi_wstrb),
        .axi_wvalid(gpio_axi_wvalid),
        .axi_wready(gpio_axi_wready),

        .axi_bresp(gpio_axi_bresp),
        .axi_bvalid(gpio_axi_bvalid),
        .axi_bready(gpio_axi_bready),

        .axi_araddr(gpio_axi_araddr),
        .axi_arvalid(gpio_axi_arvalid),
        .axi_arready(gpio_axi_arready),

        .axi_rdata(gpio_axi_rdata),
        .axi_rresp(gpio_axi_rresp),
        .axi_rvalid(gpio_axi_rvalid),
        .axi_rready(gpio_axi_rready),

        .irq(gpio_irq),

        .gpio_o(gpio_o),
        .gpio_i(gpio_i),
        .gpio_oe(gpio_oe)
    );

    // ========================================================================
    // Timer/PWM Controller (slave 8 at 0x2005_0000)
    // ========================================================================
    // Four independent 32-bit timers with PWM output generation
    // Memory map: 0x2005_0000 (TIMERx_COUNT, COMPARE, CTRL, PWM, PWM_MAX, INT_STATUS, INT_EN)
    // Features: Configurable prescaler, auto-reload, compare interrupts, PWM duty cycle control
    axi_timer timer (
        .clk(clk),
        .rst_n(soc_rst_n),

        .axi_awaddr(timer_axi_awaddr),
        .axi_awvalid(timer_axi_awvalid),
        .axi_awready(timer_axi_awready),

        .axi_wdata(timer_axi_wdata),
        .axi_wstrb(timer_axi_wstrb),
        .axi_wvalid(timer_axi_wvalid),
        .axi_wready(timer_axi_wready),

        .axi_bresp(timer_axi_bresp),
        .axi_bvalid(timer_axi_bvalid),
        .axi_bready(timer_axi_bready),

        .axi_araddr(timer_axi_araddr),
        .axi_arvalid(timer_axi_arvalid),
        .axi_arready(timer_axi_arready),

        .axi_rdata(timer_axi_rdata),
        .axi_rresp(timer_axi_rresp),
        .axi_rvalid(timer_axi_rvalid),
        .axi_rready(timer_axi_rready),

        .irq(pwm_timer_irq),

        .pwm_o(pwm_o)
    );

    // ========================================================================
    // Magic Device (simulation control, slave 9 at 0xFFFF_0000)
    // ========================================================================
    // Provides special memory-mapped addresses for testbench control:
    //   - Exit simulation
    //   - Report test pass/fail
    //   - Performance measurement triggers
    // Memory map: 0xFFFF_0000
    axi_magic magic (
        .clk(clk),
        .rst_n(soc_rst_n),

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

        .axi_rdata  (magic_axi_rdata),
        .axi_rresp  (magic_axi_rresp),
        .axi_rvalid (magic_axi_rvalid),
        .axi_rready (magic_axi_rready)
    );

    // ========================================================================
    // JTAG/cJTAG Debug Interface (Pin Multiplexing)
    // ========================================================================
    // Provides RISC-V debug transport module with configurable JTAG/cJTAG
    // interface. Supports 4-pin multiplexing where both modes share pins:
    //   Pin 0: TCK/TCKC (clock input)
    //   Pin 1: TMS/TMSC (bidirectional in cJTAG, input in JTAG)
    //   Pin 2: TDI (JTAG only)
    //   Pin 3: TDO (JTAG only)
    jtag_top #(
        .USE_CJTAG  (USE_CJTAG),
        .IDCODE     (JTAG_IDCODE),
        .IR_LEN     (5)
    ) u_jtag_debug (
        .clk_i          (clk),
        .rst_n_i        (rst_n),
        .ntrst_i        (rst_n),

        // Shared 4-pin interface (pin mux)
        .pin0_tck_i     (jtag_tck_i),
        .pin1_tms_i     (jtag_tms_i),
        .pin1_tms_o     (jtag_tms_o),
        .pin1_tms_oe    (jtag_tms_oe),
        .pin2_tdi_i     (jtag_tdi_i),
        .pin3_tdo_o     (jtag_tdo_o),
        .pin3_tdo_oe    (jtag_tdo_oe),

        // Status outputs
        .cjtag_online_o (cjtag_online_o),
        /* verilator lint_off PINCONNECTEMPTY */
        .cjtag_nsp_o    (),  // Unused in this design
        /* verilator lint_on PINCONNECTEMPTY */

        // Debug interface to CPU
        .halt_req_o      (dbg_halt_req),
        .halted_i        (dbg_halted),
        .resume_req_o    (dbg_resume_req),
        .resumeack_i     (dbg_resumeack),

        // Register access
        .dbg_reg_addr_o  (dbg_reg_addr),
        .dbg_reg_wdata_o (dbg_reg_wdata),
        .dbg_reg_we_o    (dbg_reg_we),
        .dbg_reg_rdata_i (dbg_reg_rdata),

        // PC access
        .dbg_pc_wdata_o  (dbg_pc_wdata),
        .dbg_pc_we_o     (dbg_pc_we),
        .dbg_pc_i        (dbg_pc),

        // Memory access (tied off for now - would need AXI master)
        .dbg_mem_req_o   (dbg_mem_req),
        .dbg_mem_addr_o  (dbg_mem_addr),
        .dbg_mem_we_o    (dbg_mem_we),
        .dbg_mem_wdata_o (dbg_mem_wdata),
        .dbg_mem_ready_i (dbg_mem_ready),
        .dbg_mem_rdata_i (dbg_mem_rdata),

        // System reset outputs (ndmreset/hartreset to SoC reset tree)
        .dbg_ndmreset_o  (dbg_ndmreset),
        .dbg_hartreset_o (dbg_hartreset)
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
        !arb_axi_awvalid || dmem_axi_awvalid || dma_m_axi_awvalid;
    endproperty
    assert property (p_arb_aw_from_dmem)
        else $error("[SOC] Arbiter AW valid without DMEM/DMA AW valid");

    property p_arb_w_from_dmem;
        @(posedge clk) disable iff (!rst_n)
        !arb_axi_wvalid || dmem_axi_wvalid || dma_m_axi_wvalid;
    endproperty
    assert property (p_arb_w_from_dmem)
        else $error("[SOC] Arbiter W valid without DMEM/DMA W valid");

    // Arbiter: Read channel must come from either IMEM, DMEM, or DMA
    property p_arb_ar_source;
        @(posedge clk) disable iff (!rst_n)
        !arb_axi_arvalid || imem_axi_arvalid || dmem_axi_arvalid || dma_m_axi_arvalid;
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

`ifndef SYNTHESIS
    // Lint sink (debug only): AXI RID/BID not needed at SoC level (point-to-point
    // ordering); debug memory interface ports wired but not yet connected.
    logic _unused_ok;
    assign _unused_ok = &{1'b0, imem_axi_rid, dma_m_axi_bid, dma_m_axi_rid,
                                dbg_mem_req, dbg_mem_addr, dbg_mem_we, dbg_mem_wdata};
`endif // SYNTHESIS

`endif // ASSERTION

endmodule


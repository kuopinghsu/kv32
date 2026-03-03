// ============================================================================
// File: ddr4_axi4_slave.sv
// Project: KV32 RISC-V Processor
// Description: DDR4 AXI4 Slave Interface Simulation Model
//
// Behavioural DDR4 memory model with a full AXI4 slave port.  Supports
// single-beat and burst transfers (INCR, FIXED, WRAP) with parameterisable
// memory density, data width, bank/row/column geometry, and DDR4 timing
// (CL, RCD, RP, RAS, etc.).  Intended for use in Verilator testbenches.
// ============================================================================

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off CASEINCOMPLETE */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */

module ddr4_axi4_slave #(
    //-------------------------------------------------------------------------
    // AXI4 Interface Parameters
    //-------------------------------------------------------------------------
    parameter AXI_ID_WIDTH      = 4,
    parameter AXI_ADDR_WIDTH    = 32,
    parameter AXI_DATA_WIDTH    = 64,
    parameter AXI_STRB_WIDTH    = AXI_DATA_WIDTH / 8,

    //-------------------------------------------------------------------------
    // DDR4 Memory Parameters
    //-------------------------------------------------------------------------
    parameter DDR4_DENSITY_GB   = 1,              // Memory density in GB (1, 2, 4, 8, 16)
    parameter DDR4_DQ_WIDTH     = 64,             // Data width (x4, x8, x16, x32, x64)
    parameter DDR4_BANKS        = 16,             // Number of banks (16 for DDR4)
    parameter DDR4_ROWS         = 65536,          // Number of rows per bank
    parameter DDR4_COLS         = 1024,           // Number of columns per row

    //-------------------------------------------------------------------------
    // DDR4 Timing Parameters (in clock cycles at memory clock)
    //-------------------------------------------------------------------------
    parameter DDR4_CL           = 16,             // CAS Latency
    parameter DDR4_RCD          = 16,             // RAS to CAS Delay
    parameter DDR4_RP           = 16,             // Row Precharge Time
    parameter DDR4_RAS          = 32,             // Row Active Time
    parameter DDR4_RC           = 48,             // Row Cycle Time
    parameter DDR4_WR           = 16,             // Write Recovery Time
    parameter DDR4_RTP          = 8,              // Read to Precharge
    parameter DDR4_WTR          = 8,              // Write to Read Delay
    parameter DDR4_FAW          = 32,             // Four Activate Window
    parameter DDR4_REFI         = 7800,           // Refresh Interval (ns)
    parameter DDR4_RFC          = 350,            // Refresh Cycle Time (ns)

    //-------------------------------------------------------------------------
    // Simulation Parameters
    //-------------------------------------------------------------------------
    parameter MEMORY_INIT_FILE  = "",             // Optional memory initialization file
    parameter ENABLE_TIMING_CHECK = 1,            // Enable DDR4 timing checks
    parameter ENABLE_ECC        = 0,              // Enable ECC (if DQ width supports)
    parameter RANDOM_DELAY_EN   = 0,              // Enable random response delays
    parameter MAX_RANDOM_DELAY  = 10,             // Maximum random delay cycles
    parameter VERBOSE_MODE      = 1,              // Enable verbose logging
    parameter BASE_ADDR         = 32'h80000000    // Base address of this memory in AXI address space
)(
    //-------------------------------------------------------------------------
    // Global Signals
    //-------------------------------------------------------------------------
    input  logic                        aclk,
    input  logic                        aresetn,

    //-------------------------------------------------------------------------
    // AXI4 Write Address Channel
    //-------------------------------------------------------------------------
    input  logic [AXI_ID_WIDTH-1:0]     s_axi_awid,
    input  logic [AXI_ADDR_WIDTH-1:0]   s_axi_awaddr,
    input  logic [7:0]                  s_axi_awlen,
    input  logic [2:0]                  s_axi_awsize,
    input  logic [1:0]                  s_axi_awburst,
    input  logic                        s_axi_awlock,
    input  logic [3:0]                  s_axi_awcache,
    input  logic [2:0]                  s_axi_awprot,
    input  logic [3:0]                  s_axi_awqos,
    input  logic                        s_axi_awvalid,
    output logic                        s_axi_awready,

    //-------------------------------------------------------------------------
    // AXI4 Write Data Channel
    //-------------------------------------------------------------------------
    input  logic [AXI_DATA_WIDTH-1:0]   s_axi_wdata,
    input  logic [AXI_STRB_WIDTH-1:0]   s_axi_wstrb,
    input  logic                        s_axi_wlast,
    input  logic                        s_axi_wvalid,
    output logic                        s_axi_wready,

    //-------------------------------------------------------------------------
    // AXI4 Write Response Channel
    //-------------------------------------------------------------------------
    output logic [AXI_ID_WIDTH-1:0]     s_axi_bid,
    output logic [1:0]                  s_axi_bresp,
    output logic                        s_axi_bvalid,
    input  logic                        s_axi_bready,

    //-------------------------------------------------------------------------
    // AXI4 Read Address Channel
    //-------------------------------------------------------------------------
    input  logic [AXI_ID_WIDTH-1:0]     s_axi_arid,
    input  logic [AXI_ADDR_WIDTH-1:0]   s_axi_araddr,
    input  logic [7:0]                  s_axi_arlen,
    input  logic [2:0]                  s_axi_arsize,
    input  logic [1:0]                  s_axi_arburst,
    input  logic                        s_axi_arlock,
    input  logic [3:0]                  s_axi_arcache,
    input  logic [2:0]                  s_axi_arprot,
    input  logic [3:0]                  s_axi_arqos,
    input  logic                        s_axi_arvalid,
    output logic                        s_axi_arready,

    //-------------------------------------------------------------------------
    // AXI4 Read Data Channel
    //-------------------------------------------------------------------------
    output logic [AXI_ID_WIDTH-1:0]     s_axi_rid,
    output logic [AXI_DATA_WIDTH-1:0]   s_axi_rdata,
    output logic [1:0]                  s_axi_rresp,
    output logic                        s_axi_rlast,
    output logic                        s_axi_rvalid,
    input  logic                        s_axi_rready
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam BYTES_PER_BEAT = AXI_DATA_WIDTH / 8;
    localparam ADDR_LSB = $clog2(BYTES_PER_BEAT);

    // Memory size calculation
    localparam MEM_SIZE_BYTES = DDR4_DENSITY_GB * 1024 * 1024 * 1024;
    localparam MEM_DEPTH = MEM_SIZE_BYTES / BYTES_PER_BEAT;
    localparam MEM_ADDR_WIDTH = $clog2(MEM_DEPTH);

    // AXI Burst Types
    localparam BURST_FIXED = 2'b00;
    localparam BURST_INCR  = 2'b01;
    localparam BURST_WRAP  = 2'b10;

    // AXI Response Types
    localparam RESP_OKAY   = 2'b00;
    localparam RESP_EXOKAY = 2'b01;
    localparam RESP_SLVERR = 2'b10;
    localparam RESP_DECERR = 2'b11;

    //=========================================================================
    // Memory Array
    //=========================================================================
    logic [AXI_DATA_WIDTH-1:0] memory [0:MEM_DEPTH-1];

    //=========================================================================
    // Statistics Counters
    //=========================================================================
    typedef struct packed {
        longint unsigned total_read_transactions;
        longint unsigned total_write_transactions;
        longint unsigned total_read_bytes;
        longint unsigned total_write_bytes;
        longint unsigned single_read_count;
        longint unsigned single_write_count;
        longint unsigned burst_incr_read_count;
        longint unsigned burst_incr_write_count;
        longint unsigned burst_wrap_read_count;
        longint unsigned burst_wrap_write_count;
        longint unsigned burst_fixed_read_count;
        longint unsigned burst_fixed_write_count;
        longint unsigned read_latency_total;
        longint unsigned write_latency_total;
        longint unsigned min_read_latency;
        longint unsigned max_read_latency;
        longint unsigned min_write_latency;
        longint unsigned max_write_latency;
        longint unsigned address_errors;
        longint unsigned protocol_errors;
        longint unsigned total_clock_cycles;
        longint unsigned busy_cycles;
        time             sim_start_time;
        time             sim_end_time;
    } stats_t;

    stats_t stats;

    //=========================================================================
    // Internal Signals - Write Path
    //=========================================================================
    typedef enum logic [2:0] {
        WR_IDLE,
        WR_ADDR_WAIT,
        WR_DATA,
        WR_RESP,
        WR_DELAY
    } wr_state_t;

    wr_state_t wr_state, wr_next_state;

    logic [AXI_ID_WIDTH-1:0]   wr_id_reg;
    logic [AXI_ADDR_WIDTH-1:0] wr_addr_reg;
    logic [7:0]                wr_len_reg;
    logic [2:0]                wr_size_reg;
    logic [1:0]                wr_burst_reg;
    logic [7:0]                wr_beat_cnt;
    logic [AXI_ADDR_WIDTH-1:0] wr_addr_next;
    logic [AXI_ADDR_WIDTH-1:0] wr_wrap_boundary;
    logic [AXI_ADDR_WIDTH-1:0] wr_wrap_size;
    time                       wr_start_time;
    logic [7:0]                wr_delay_cnt;

    //=========================================================================
    // Internal Signals - Read Path
    //=========================================================================
    typedef enum logic [2:0] {
        RD_IDLE,
        RD_ADDR_WAIT,
        RD_DATA,
        RD_DELAY
    } rd_state_t;

    rd_state_t rd_state, rd_next_state;

    logic [AXI_ID_WIDTH-1:0]   rd_id_reg;
    logic [AXI_ADDR_WIDTH-1:0] rd_addr_reg;
    logic [7:0]                rd_len_reg;
    logic [2:0]                rd_size_reg;
    logic [1:0]                rd_burst_reg;
    logic [7:0]                rd_beat_cnt;
    logic [AXI_ADDR_WIDTH-1:0] rd_addr_next;
    logic [AXI_ADDR_WIDTH-1:0] rd_wrap_boundary;
    logic [AXI_ADDR_WIDTH-1:0] rd_wrap_size;
    time                       rd_start_time;
    logic [7:0]                rd_delay_cnt;

    //=========================================================================
    // DDR4 Timing Model Signals
    //=========================================================================
    logic [15:0] bank_active [0:DDR4_BANKS-1];
    logic [31:0] last_activate_time [0:DDR4_BANKS-1];
    logic [31:0] faw_tracker [0:3];
    integer      faw_index;

    //=========================================================================
    // Random Delay Generation
    //=========================================================================
    function automatic int get_random_delay();
        if (RANDOM_DELAY_EN)
            return $urandom_range(0, MAX_RANDOM_DELAY);
        else
            return 0;
    endfunction

    //=========================================================================
    // Address Calculation Functions
    //=========================================================================

    // Calculate next address for burst transactions
    function automatic [AXI_ADDR_WIDTH-1:0] calc_next_addr(
        input [AXI_ADDR_WIDTH-1:0] current_addr,
        input [2:0]                size,
        input [1:0]                burst,
        input [7:0]                len,
        input [AXI_ADDR_WIDTH-1:0] start_addr
    );
        logic [AXI_ADDR_WIDTH-1:0] size_bytes;
        logic [AXI_ADDR_WIDTH-1:0] aligned_addr;
        logic [AXI_ADDR_WIDTH-1:0] wrap_boundary;
        logic [AXI_ADDR_WIDTH-1:0] wrap_size;

        size_bytes = 1 << size;

        case (burst)
            BURST_FIXED: begin
                // Fixed burst - address stays the same
                calc_next_addr = current_addr;
            end

            BURST_INCR: begin
                // Incrementing burst - address increments by size
                calc_next_addr = current_addr + size_bytes;
            end

            BURST_WRAP: begin
                // Wrapping burst - address wraps at boundary
                wrap_size = size_bytes * (len + 1);
                wrap_boundary = (start_addr / wrap_size) * wrap_size;
                aligned_addr = current_addr + size_bytes;

                if (aligned_addr >= wrap_boundary + wrap_size)
                    calc_next_addr = wrap_boundary;
                else
                    calc_next_addr = aligned_addr;
            end

            default: begin
                calc_next_addr = current_addr + size_bytes;
            end
        endcase
    endfunction

    // Convert AXI address to memory index (subtract BASE_ADDR first)
    function automatic [MEM_ADDR_WIDTH-1:0] addr_to_mem_index(
        input [AXI_ADDR_WIDTH-1:0] addr
    );
        addr_to_mem_index = (addr - BASE_ADDR) >> ADDR_LSB;
    endfunction

    // Check if address is valid
    function automatic logic is_valid_address(
        input [AXI_ADDR_WIDTH-1:0] addr
    );
        is_valid_address = (addr >= BASE_ADDR) && (addr < BASE_ADDR + MEM_SIZE_BYTES);
    endfunction

    //=========================================================================
    // Memory Initialization
    //=========================================================================
    initial begin
        // Initialize statistics
        stats = '0;
        stats.min_read_latency = '1;  // Set to max value
        stats.min_write_latency = '1;
        stats.sim_start_time = $time;

        // Initialize memory
        for (int i = 0; i < MEM_DEPTH; i++) begin
            memory[i] = '0;
        end

        // Load initialization file if specified
        if (MEMORY_INIT_FILE != "") begin
            $readmemh(MEMORY_INIT_FILE, memory);
            if (VERBOSE_MODE)
                $display("[%0t] DDR4_MODEL: Loaded memory from file: %s", $time, MEMORY_INIT_FILE);
        end

        // Initialize bank tracking
        for (int i = 0; i < DDR4_BANKS; i++) begin
            bank_active[i] = 0;
            last_activate_time[i] = 0;
        end

        for (int i = 0; i < 4; i++) begin
            faw_tracker[i] = 0;
        end
        faw_index = 0;

        if (VERBOSE_MODE) begin
            $display("[%0t] DDR4_MODEL: Initialized with following parameters:", $time);
            $display("  - Density: %0d GB", DDR4_DENSITY_GB);
            $display("  - Data Width: %0d bits", DDR4_DQ_WIDTH);
            $display("  - Banks: %0d", DDR4_BANKS);
            $display("  - Rows: %0d", DDR4_ROWS);
            $display("  - Columns: %0d", DDR4_COLS);
            $display("  - AXI Data Width: %0d bits", AXI_DATA_WIDTH);
            $display("  - Memory Depth: %0d entries", MEM_DEPTH);
            $display("  - CAS Latency (CL): %0d", DDR4_CL);
            $display("  - RAS to CAS Delay (tRCD): %0d", DDR4_RCD);
            $display("  - Row Precharge (tRP): %0d", DDR4_RP);
        end
    end

    //=========================================================================
    // Clock Cycle Counter
    //=========================================================================
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            stats.total_clock_cycles <= 0;
        end else begin
            stats.total_clock_cycles <= stats.total_clock_cycles + 1;
        end
    end

    //=========================================================================
    // Write State Machine
    //=========================================================================
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            wr_state <= WR_IDLE;
        end else begin
            wr_state <= wr_next_state;
        end
    end

    always_comb begin
        wr_next_state = wr_state;

        case (wr_state)
            WR_IDLE: begin
                if (s_axi_awvalid)
                    wr_next_state = WR_ADDR_WAIT;
            end

            WR_ADDR_WAIT: begin
                wr_next_state = WR_DATA;
            end

            WR_DATA: begin
                if (s_axi_wvalid && s_axi_wlast) begin
                    if (RANDOM_DELAY_EN && get_random_delay() > 0)
                        wr_next_state = WR_DELAY;
                    else
                        wr_next_state = WR_RESP;
                end
            end

            WR_DELAY: begin
                if (wr_delay_cnt == 0)
                    wr_next_state = WR_RESP;
            end

            WR_RESP: begin
                if (s_axi_bready)
                    wr_next_state = WR_IDLE;
            end

            default: wr_next_state = WR_IDLE;
        endcase
    end

    // Write Path Data Handling
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            wr_id_reg <= '0;
            wr_addr_reg <= '0;
            wr_len_reg <= '0;
            wr_size_reg <= '0;
            wr_burst_reg <= '0;
            wr_beat_cnt <= '0;
            wr_addr_next <= '0;
            wr_delay_cnt <= '0;
            s_axi_awready <= 1'b1;
            s_axi_wready <= 1'b0;
            s_axi_bvalid <= 1'b0;
            s_axi_bid <= '0;
            s_axi_bresp <= RESP_OKAY;
        end else begin
            case (wr_state)
                WR_IDLE: begin
                    s_axi_awready <= 1'b1;
                    s_axi_wready <= 1'b0;
                    s_axi_bvalid <= 1'b0;

                    if (s_axi_awvalid && s_axi_awready) begin
                        wr_id_reg <= s_axi_awid;
                        wr_addr_reg <= s_axi_awaddr;
                        wr_len_reg <= s_axi_awlen;
                        wr_size_reg <= s_axi_awsize;
                        wr_burst_reg <= s_axi_awburst;
                        wr_beat_cnt <= '0;
                        wr_addr_next <= s_axi_awaddr;
                        wr_start_time <= $time;
                        s_axi_awready <= 1'b0;

                        // Update statistics
                        stats.total_write_transactions <= stats.total_write_transactions + 1;
                        case (s_axi_awburst)
                            BURST_FIXED: stats.burst_fixed_write_count <= stats.burst_fixed_write_count + 1;
                            BURST_INCR: begin
                                if (s_axi_awlen == 0)
                                    stats.single_write_count <= stats.single_write_count + 1;
                                else
                                    stats.burst_incr_write_count <= stats.burst_incr_write_count + 1;
                            end
                            BURST_WRAP: stats.burst_wrap_write_count <= stats.burst_wrap_write_count + 1;
                        endcase

                        if (VERBOSE_MODE)
                            $display("[%0t] DDR4_MODEL: Write transaction started - ID=%0d, ADDR=0x%h, LEN=%0d, BURST=%0d",
                                    $time, s_axi_awid, s_axi_awaddr, s_axi_awlen, s_axi_awburst);
                    end
                end

                WR_ADDR_WAIT: begin
                    s_axi_wready <= 1'b1;
                end

                WR_DATA: begin
                    s_axi_wready <= 1'b1;

                    if (s_axi_wvalid && s_axi_wready) begin
                        // Write data to memory with byte strobes
                        if (is_valid_address(wr_addr_next)) begin
                            for (int i = 0; i < BYTES_PER_BEAT; i++) begin
                                if (s_axi_wstrb[i]) begin
                                    memory[addr_to_mem_index(wr_addr_next)][i*8 +: 8] <= s_axi_wdata[i*8 +: 8];
                                end
                            end

                            // Count bytes written
                            for (int i = 0; i < BYTES_PER_BEAT; i++) begin
                                if (s_axi_wstrb[i])
                                    stats.total_write_bytes <= stats.total_write_bytes + 1;
                            end

                            if (VERBOSE_MODE)
                                $display("[%0t] DDR4_MODEL: Write beat %0d - ADDR=0x%h, DATA=0x%h, STRB=0x%h",
                                        $time, wr_beat_cnt, wr_addr_next, s_axi_wdata, s_axi_wstrb);
                        end else begin
                            stats.address_errors <= stats.address_errors + 1;
                            if (VERBOSE_MODE)
                                $display("[%0t] DDR4_MODEL: ERROR - Write address out of range: 0x%h", $time, wr_addr_next);
                        end

                        wr_beat_cnt <= wr_beat_cnt + 1;
                        wr_addr_next <= calc_next_addr(wr_addr_next, wr_size_reg, wr_burst_reg, wr_len_reg, wr_addr_reg);

                        if (s_axi_wlast) begin
                            s_axi_wready <= 1'b0;
                            wr_delay_cnt <= get_random_delay();
                        end
                    end
                end

                WR_DELAY: begin
                    if (wr_delay_cnt > 0)
                        wr_delay_cnt <= wr_delay_cnt - 1;
                end

                WR_RESP: begin
                    s_axi_bvalid <= 1'b1;
                    s_axi_bid <= wr_id_reg;
                    s_axi_bresp <= is_valid_address(wr_addr_reg) ? RESP_OKAY : RESP_SLVERR;

                    if (s_axi_bready && s_axi_bvalid) begin
                        s_axi_bvalid <= 1'b0;

                        // Calculate and update latency statistics
                        stats.write_latency_total <= stats.write_latency_total + ($time - wr_start_time);
                        if (($time - wr_start_time) < stats.min_write_latency)
                            stats.min_write_latency <= $time - wr_start_time;
                        if (($time - wr_start_time) > stats.max_write_latency)
                            stats.max_write_latency <= $time - wr_start_time;

                        if (VERBOSE_MODE)
                            $display("[%0t] DDR4_MODEL: Write transaction completed - ID=%0d, Latency=%0t",
                                    $time, wr_id_reg, $time - wr_start_time);
                    end
                end
            endcase
        end
    end

    //=========================================================================
    // Read State Machine
    //=========================================================================
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            rd_state <= RD_IDLE;
        end else begin
            rd_state <= rd_next_state;
        end
    end

    always_comb begin
        rd_next_state = rd_state;

        case (rd_state)
            RD_IDLE: begin
                if (s_axi_arvalid)
                    rd_next_state = RD_ADDR_WAIT;
            end

            RD_ADDR_WAIT: begin
                if (RANDOM_DELAY_EN && get_random_delay() > 0)
                    rd_next_state = RD_DELAY;
                else
                    rd_next_state = RD_DATA;
            end

            RD_DELAY: begin
                if (rd_delay_cnt == 0)
                    rd_next_state = RD_DATA;
            end

            RD_DATA: begin
                if (s_axi_rready && s_axi_rvalid && s_axi_rlast)
                    rd_next_state = RD_IDLE;
            end

            default: rd_next_state = RD_IDLE;
        endcase
    end

    // Read Path Data Handling
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            rd_id_reg <= '0;
            rd_addr_reg <= '0;
            rd_len_reg <= '0;
            rd_size_reg <= '0;
            rd_burst_reg <= '0;
            rd_beat_cnt <= '0;
            rd_addr_next <= '0;
            rd_delay_cnt <= '0;
            s_axi_arready <= 1'b1;
            s_axi_rvalid <= 1'b0;
            s_axi_rid <= '0;
            s_axi_rdata <= '0;
            s_axi_rresp <= RESP_OKAY;
            s_axi_rlast <= 1'b0;
        end else begin
            case (rd_state)
                RD_IDLE: begin
                    s_axi_arready <= 1'b1;
                    s_axi_rvalid <= 1'b0;
                    s_axi_rlast <= 1'b0;

                    if (s_axi_arvalid && s_axi_arready) begin
                        rd_id_reg <= s_axi_arid;
                        rd_addr_reg <= s_axi_araddr;
                        rd_len_reg <= s_axi_arlen;
                        rd_size_reg <= s_axi_arsize;
                        rd_burst_reg <= s_axi_arburst;
                        rd_beat_cnt <= '0;
                        rd_addr_next <= s_axi_araddr;
                        rd_start_time <= $time;
                        rd_delay_cnt <= get_random_delay();
                        s_axi_arready <= 1'b0;

                        // Update statistics
                        stats.total_read_transactions <= stats.total_read_transactions + 1;
                        case (s_axi_arburst)
                            BURST_FIXED: stats.burst_fixed_read_count <= stats.burst_fixed_read_count + 1;
                            BURST_INCR: begin
                                if (s_axi_arlen == 0)
                                    stats.single_read_count <= stats.single_read_count + 1;
                                else
                                    stats.burst_incr_read_count <= stats.burst_incr_read_count + 1;
                            end
                            BURST_WRAP: stats.burst_wrap_read_count <= stats.burst_wrap_read_count + 1;
                        endcase

                        if (VERBOSE_MODE)
                            $display("[%0t] DDR4_MODEL: Read transaction started - ID=%0d, ADDR=0x%h, LEN=%0d, BURST=%0d",
                                    $time, s_axi_arid, s_axi_araddr, s_axi_arlen, s_axi_arburst);
                    end
                end

                RD_ADDR_WAIT: begin
                    // Prepare for data phase
                end

                RD_DELAY: begin
                    if (rd_delay_cnt > 0)
                        rd_delay_cnt <= rd_delay_cnt - 1;
                end

                RD_DATA: begin
                    s_axi_rvalid <= 1'b1;
                    s_axi_rid <= rd_id_reg;

                    if (is_valid_address(rd_addr_next)) begin
                        s_axi_rdata <= memory[addr_to_mem_index(rd_addr_next)];
                        s_axi_rresp <= RESP_OKAY;
                    end else begin
                        s_axi_rdata <= '0;
                        s_axi_rresp <= RESP_SLVERR;
                        stats.address_errors <= stats.address_errors + 1;
                    end

                    s_axi_rlast <= (rd_beat_cnt == rd_len_reg);

                    if (s_axi_rready && s_axi_rvalid) begin
                        // Count bytes read
                        stats.total_read_bytes <= stats.total_read_bytes + (1 << rd_size_reg);

                        if (VERBOSE_MODE)
                            $display("[%0t] DDR4_MODEL: Read beat %0d - ADDR=0x%h, DATA=0x%h",
                                    $time, rd_beat_cnt, rd_addr_next, memory[addr_to_mem_index(rd_addr_next)]);

                        if (rd_beat_cnt == rd_len_reg) begin
                            // Last beat
                            s_axi_rvalid <= 1'b0;

                            // Calculate and update latency statistics
                            stats.read_latency_total <= stats.read_latency_total + ($time - rd_start_time);
                            if (($time - rd_start_time) < stats.min_read_latency)
                                stats.min_read_latency <= $time - rd_start_time;
                            if (($time - rd_start_time) > stats.max_read_latency)
                                stats.max_read_latency <= $time - rd_start_time;

                            if (VERBOSE_MODE)
                                $display("[%0t] DDR4_MODEL: Read transaction completed - ID=%0d, Latency=%0t",
                                        $time, rd_id_reg, $time - rd_start_time);
                        end else begin
                            rd_beat_cnt <= rd_beat_cnt + 1;
                            rd_addr_next <= calc_next_addr(rd_addr_next, rd_size_reg, rd_burst_reg, rd_len_reg, rd_addr_reg);
                        end
                    end
                end
            endcase
        end
    end

    //=========================================================================
    // Busy Cycle Tracking
    //=========================================================================
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            stats.busy_cycles <= 0;
        end else begin
            if (wr_state != WR_IDLE || rd_state != RD_IDLE)
                stats.busy_cycles <= stats.busy_cycles + 1;
        end
    end

    //=========================================================================
    // Statistics Reporting Task
    //=========================================================================
    task print_statistics();
        real avg_read_latency;
        real avg_write_latency;
        real utilization;
        real read_bandwidth;
        real write_bandwidth;
        time sim_duration;

        stats.sim_end_time = $time;
        sim_duration = stats.sim_end_time - stats.sim_start_time;

        if (stats.total_read_transactions > 0)
            avg_read_latency = real'(stats.read_latency_total) / real'(stats.total_read_transactions);
        else
            avg_read_latency = 0;

        if (stats.total_write_transactions > 0)
            avg_write_latency = real'(stats.write_latency_total) / real'(stats.total_write_transactions);
        else
            avg_write_latency = 0;

        if (stats.total_clock_cycles > 0)
            utilization = (real'(stats.busy_cycles) / real'(stats.total_clock_cycles)) * 100.0;
        else
            utilization = 0;

        // Calculate bandwidth (bytes per nanosecond = GB/s)
        if (sim_duration > 0) begin
            read_bandwidth = real'(stats.total_read_bytes) / real'(sim_duration);
            write_bandwidth = real'(stats.total_write_bytes) / real'(sim_duration);
        end else begin
            read_bandwidth = 0;
            write_bandwidth = 0;
        end

        $display("\n");
        $display("╔══════════════════════════════════════════════════════════════════════════════╗");
        $display("║                    DDR4 AXI4 SLAVE SIMULATION STATISTICS                     ║");
        $display("╠══════════════════════════════════════════════════════════════════════════════╣");
        $display("║  CONFIGURATION                                                               ║");
        $display("║    Memory Density:        %4d GB                                            ║", DDR4_DENSITY_GB);
        $display("║    AXI Data Width:        %4d bits                                          ║", AXI_DATA_WIDTH);
        $display("║    AXI Address Width:     %4d bits                                          ║", AXI_ADDR_WIDTH);
        $display("╠══════════════════════════════════════════════════════════════════════════════╣");
        $display("║  SIMULATION DURATION                                                         ║");
        $display("║    Start Time:            %0t                                                ", stats.sim_start_time);
        $display("║    End Time:              %0t                                                ", stats.sim_end_time);
        $display("║    Total Duration:        %0t                                                ", sim_duration);
        $display("║    Total Clock Cycles:    %0d                                                ", stats.total_clock_cycles);
        $display("╠══════════════════════════════════════════════════════════════════════════════╣");
        $display("║  TRANSACTION SUMMARY                                                         ║");
        $display("║    Total Read Transactions:     %10d                                    ║", stats.total_read_transactions);
        $display("║    Total Write Transactions:    %10d                                    ║", stats.total_write_transactions);
        $display("║    Total Read Bytes:            %10d                                    ║", stats.total_read_bytes);
        $display("║    Total Write Bytes:           %10d                                    ║", stats.total_write_bytes);
        $display("╠══════════════════════════════════════════════════════════════════════════════╣");
        $display("║  TRANSACTION TYPE BREAKDOWN                                                  ║");
        $display("║    Single Reads:                %10d                                    ║", stats.single_read_count);
        $display("║    Single Writes:               %10d                                    ║", stats.single_write_count);
        $display("║    Burst INCR Reads:            %10d                                    ║", stats.burst_incr_read_count);
        $display("║    Burst INCR Writes:           %10d                                    ║", stats.burst_incr_write_count);
        $display("║    Burst WRAP Reads:            %10d                                    ║", stats.burst_wrap_read_count);
        $display("║    Burst WRAP Writes:           %10d                                    ║", stats.burst_wrap_write_count);
        $display("║    Burst FIXED Reads:           %10d                                    ║", stats.burst_fixed_read_count);
        $display("║    Burst FIXED Writes:          %10d                                    ║", stats.burst_fixed_write_count);
        $display("╠══════════════════════════════════════════════════════════════════════════════╣");
        $display("║  LATENCY STATISTICS                                                          ║");
        $display("║    Average Read Latency:        %10.2f ns                                 ║", avg_read_latency);
        $display("║    Min Read Latency:            %10d ns                                 ║", (stats.total_read_transactions > 0) ? stats.min_read_latency : 0);
        $display("║    Max Read Latency:            %10d ns                                 ║", stats.max_read_latency);
        $display("║    Average Write Latency:       %10.2f ns                                 ║", avg_write_latency);
        $display("║    Min Write Latency:           %10d ns                                 ║", (stats.total_write_transactions > 0) ? stats.min_write_latency : 0);
        $display("║    Max Write Latency:           %10d ns                                 ║", stats.max_write_latency);
        $display("╠══════════════════════════════════════════════════════════════════════════════╣");
        $display("║  PERFORMANCE METRICS                                                         ║");
        $display("║    Bus Utilization:             %10.2f %%                                  ║", utilization);
        $display("║    Read Bandwidth:              %10.4f GB/s                               ║", read_bandwidth);
        $display("║    Write Bandwidth:             %10.4f GB/s                               ║", write_bandwidth);
        $display("║    Total Bandwidth:             %10.4f GB/s                               ║", read_bandwidth + write_bandwidth);
        $display("╠══════════════════════════════════════════════════════════════════════════════╣");
        $display("║  ERROR STATISTICS                                                            ║");
        $display("║    Address Errors:              %10d                                    ║", stats.address_errors);
        $display("║    Protocol Errors:             %10d                                    ║", stats.protocol_errors);
        $display("╚══════════════════════════════════════════════════════════════════════════════╝");
        $display("\n");
    endtask

    //=========================================================================
    // Memory Access Tasks for Debug
    //=========================================================================
    task write_memory(
        input [AXI_ADDR_WIDTH-1:0] addr,
        input [AXI_DATA_WIDTH-1:0] data
    );
        if (is_valid_address(addr)) begin
            memory[addr_to_mem_index(addr)] = data;
            if (VERBOSE_MODE)
                $display("[%0t] DDR4_MODEL: Direct memory write - ADDR=0x%h, DATA=0x%h", $time, addr, data);
        end else begin
            $display("[%0t] DDR4_MODEL: ERROR - Direct write address out of range: 0x%h", $time, addr);
        end
    endtask

    task read_memory(
        input  [AXI_ADDR_WIDTH-1:0] addr,
        output [AXI_DATA_WIDTH-1:0] data
    );
        if (is_valid_address(addr)) begin
            data = memory[addr_to_mem_index(addr)];
            if (VERBOSE_MODE)
                $display("[%0t] DDR4_MODEL: Direct memory read - ADDR=0x%h, DATA=0x%h", $time, addr, data);
        end else begin
            data = '0;
            $display("[%0t] DDR4_MODEL: ERROR - Direct read address out of range: 0x%h", $time, addr);
        end
    endtask

    task dump_memory_region(
        input [AXI_ADDR_WIDTH-1:0] start_addr,
        input integer              num_words
    );
        $display("[%0t] DDR4_MODEL: Memory dump from 0x%h, %0d words:", $time, start_addr, num_words);
        for (int i = 0; i < num_words; i++) begin
            if (is_valid_address(start_addr + i * BYTES_PER_BEAT))
                $display("  [0x%h]: 0x%h", start_addr + i * BYTES_PER_BEAT,
                        memory[addr_to_mem_index(start_addr + i * BYTES_PER_BEAT)]);
        end
    endtask

    //=========================================================================
    // Final Statistics Report
    //=========================================================================
    final begin
        print_statistics();
    end

    //=========================================================================
    // DPI-C Memory Access Interface (compatible with elfloader / tb_kv32_soc.cpp)
    //
    // elfloader.cpp subtracts g_mem_base (0x80000000) before calling these
    // functions, so addr=0 corresponds to BASE_ADDR in AXI space.
    //=========================================================================
    export "DPI-C" function mem_write_byte;
    export "DPI-C" function mem_read_byte;
    export "DPI-C" function mem_get_stat_ar_requests;
    export "DPI-C" function mem_get_stat_r_responses;
    export "DPI-C" function mem_get_stat_aw_requests;
    export "DPI-C" function mem_get_stat_w_data;
    export "DPI-C" function mem_get_stat_w_expected;
    export "DPI-C" function mem_get_stat_b_responses;
    export "DPI-C" function mem_get_stat_max_outstanding_reads;
    export "DPI-C" function mem_get_stat_max_outstanding_writes;

    function void mem_write_byte(input int addr, input byte data);
        automatic int word_idx = addr / BYTES_PER_BEAT;
        automatic int byte_lane = addr % BYTES_PER_BEAT;
        if (word_idx >= 0 && word_idx < MEM_DEPTH) begin
            memory[word_idx][byte_lane*8 +: 8] = data;
        end
    endfunction

    function byte mem_read_byte(input int addr);
        automatic int word_idx = addr / BYTES_PER_BEAT;
        automatic int byte_lane = addr % BYTES_PER_BEAT;
        if (word_idx >= 0 && word_idx < MEM_DEPTH)
            return memory[word_idx][byte_lane*8 +: 8];
        else
            return 8'hFF;
    endfunction

    // Stat stubs — return transaction counts so tb_kv32_soc.cpp can compile
    // and link with either MEM_TYPE=sram or MEM_TYPE=ddr4.
    function int mem_get_stat_ar_requests();  return int'(stats.total_read_transactions);  endfunction
    function int mem_get_stat_r_responses();  return int'(stats.total_read_transactions);  endfunction
    function int mem_get_stat_aw_requests();  return int'(stats.total_write_transactions); endfunction
    function int mem_get_stat_w_data();       return int'(stats.total_write_transactions); endfunction
    function int mem_get_stat_w_expected();   return int'(stats.total_write_transactions); endfunction
    function int mem_get_stat_b_responses();  return int'(stats.total_write_transactions); endfunction
    function int mem_get_stat_max_outstanding_reads();  return 0; endfunction
    function int mem_get_stat_max_outstanding_writes(); return 0; endfunction

endmodule
/* verilator lint_on WIDTHTRUNC */
/* verilator lint_on WIDTHEXPAND */
/* verilator lint_on CASEINCOMPLETE */
/* verilator lint_on UNUSEDSIGNAL */

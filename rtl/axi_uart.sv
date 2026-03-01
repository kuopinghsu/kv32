// ============================================================================
// File: axi_uart.sv
// Project: KV32 RISC-V Processor
// Description: AXI4-Lite UART Peripheral with TX/RX FIFOs and IRQ
//
// Memory-mapped UART with AXI4-Lite interface. Provides serial communication
// with configurable baud rate and 8N1 format (8 data bits, no parity, 1 stop).
// TX and RX paths each have a FIFO_DEPTH-entry FIFO.  An interrupt is raised
// whenever an enabled FIFO condition is true.
//
// Register Map (relative to base 0x2000_0000):
//   0x00: DATA   - write: push to TX FIFO; read: pop from RX FIFO
//   0x04: STATUS - [0]=tx_full (busy: 1=can't-write, 0=ready), [1]=tx_full (full flag),
//                   [2]=rx_not_empty (rx_ready), [3]=rx_full (overrun flag)
//                  [2]=tx_empty, [3]=rx_full
//   0x08: IE     - Interrupt Enable: [0]=rx_not_empty_ie, [1]=tx_empty_ie
//   0x0C: IS     - Interrupt Status (read-only, level): [0]=rx_not_empty, [1]=tx_empty
//   0x10: LEVEL  - [3:0]=rx_count, [11:8]=tx_count
//   0x14: CTRL   - [0]=loopback_en (1=internal TX->RX loopback for hardware testing)
//
// Interrupt (irq): asserted when (IE & IS) != 0
//
// Features:
//   - Configurable clock frequency and baud rate
//   - Parameterised TX/RX FIFOs (default depth 16)
//   - PLIC-compatible IRQ output
//   - Integrated UART TX and RX state machines
//
// Clock Requirements:
//   UART Baud Divisor: CLKS_PER_BIT ≥ 4 (absolute minimum)
//
//   The UART RX receiver requires a minimum of 4 clock cycles per bit for
//   reliable sampling at the bit center. This is a hardware timing constraint
//   in the receive state machine that samples at the midpoint of the start bit
//   and data bits.
//
//   Formula: CLKS_PER_BIT = CLK_FREQ / BAUD_RATE
//   Baud Rate = CLK_FREQ / CLKS_PER_BIT
//
//   Hardware Constraint: CLKS_PER_BIT ≥ 4
//   Maximum Theoretical Baud Rate = CLK_FREQ / 4
//
//   Recommended: CLKS_PER_BIT ≥ 8 for production use
//   (Provides margin for clock tolerance, jitter, and asynchronous timing)
//
//   Example at 50 MHz clock:
//     - Absolute minimum: CLKS_PER_BIT = 4 → Max = 12.5 Mbaud (lab only)
//     - Recommended min: CLKS_PER_BIT = 8 → Max = 6.25 Mbaud
//     - Common 115200 baud: CLKS_PER_BIT = 434 (plenty of margin)
//     - Common 921600 baud: CLKS_PER_BIT = 54 (good for most cases)
//
//   Technical Details:
//     RX uses (CLKS_PER_BIT-1)/2 to reach start bit center
//     CLKS_PER_BIT=4: waits 1 clock, samples at center (minimal)
//     CLKS_PER_BIT=3: waits 1 clock, samples off-center (fails)
//     CLKS_PER_BIT=2: waits 0 clocks (immediate sample, fails)
//
//   Violating this constraint will result in incorrect data reception due to
//   insufficient sampling resolution and poor center alignment.
// ============================================================================

module axi_uart #(
    parameter CLK_FREQ   = 100_000_000,
    parameter BAUD_RATE  = 25_000_000,
    parameter FIFO_DEPTH = 16           // Must be a power of 2
)(
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

    // Interrupt output
    output logic        irq,

    // UART pins
    input  logic        uart_rx,
    output logic        uart_tx
);

    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;
    localparam FIFO_BITS    = $clog2(FIFO_DEPTH);

    // Capability register
    localparam logic [15:0] UART_VERSION = 16'h0001;
    localparam logic [31:0] CAPABILITY_REG = {UART_VERSION, 8'(FIFO_DEPTH), 8'(FIFO_DEPTH)};

    // Register address space: offsets 0x00–0x18 (7 word-aligned registers)
    // Any access with byte-offset > 0x18 is out-of-range → AXI SLVERR (2'b10)
    localparam logic [5:0] ADDR_MAX = 6'h06;            // 0x18 >> 2
    wire wr_addr_valid = (axi_awaddr[7:2] <= ADDR_MAX); // write address in range
    wire rd_addr_valid = (axi_araddr[7:2] <= ADDR_MAX); // read address in range

    // ========================================================================
    // TX FIFO
    // ========================================================================
    logic [7:0]           txf_mem  [0:FIFO_DEPTH-1];
    logic [FIFO_BITS-1:0] txf_wr_ptr, txf_rd_ptr;
    logic [FIFO_BITS:0]   txf_count;
    logic txf_empty, txf_full;
    assign txf_empty = (txf_count == '0);
    assign txf_full  = (txf_count == FIFO_DEPTH);

    // TX FIFO pop: feed TX state machine when it is ready and FIFO has data
    logic txf_push, txf_pop;

    // TX state machine signals (driven from TX FIFO)
    logic [7:0] tx_data;
    logic       tx_valid;
    logic       tx_ready;

    assign txf_pop  = tx_ready && !txf_empty;
    assign tx_valid = txf_pop;
    assign tx_data  = txf_mem[txf_rd_ptr];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            txf_wr_ptr <= '0;
            txf_rd_ptr <= '0;
            txf_count  <= '0;
        end else begin
            if (txf_push && !txf_pop)
                txf_count <= txf_count + 1;
            else if (!txf_push && txf_pop)
                txf_count <= txf_count - 1;
            if (txf_push) begin
                txf_mem[txf_wr_ptr] <= axi_wdata[7:0];
                txf_wr_ptr          <= txf_wr_ptr + 1;
            end
            if (txf_pop)
                txf_rd_ptr <= txf_rd_ptr + 1;
        end
    end

    // ========================================================================
    // RX FIFO
    // ========================================================================
    logic [7:0]           rxf_mem  [0:FIFO_DEPTH-1];
    logic [FIFO_BITS-1:0] rxf_wr_ptr, rxf_rd_ptr;
    logic [FIFO_BITS:0]   rxf_count;
    logic rxf_empty, rxf_full;
    assign rxf_empty = (rxf_count == '0);
    assign rxf_full  = (rxf_count == FIFO_DEPTH);

    logic rxf_push, rxf_pop;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rxf_wr_ptr <= '0;
            rxf_rd_ptr <= '0;
            rxf_count  <= '0;
        end else begin
            if (rxf_push && !rxf_pop)
                rxf_count <= rxf_count + 1;
            else if (!rxf_push && rxf_pop)
                rxf_count <= rxf_count - 1;
            if (rxf_push) begin
                rxf_mem[rxf_wr_ptr] <= rx_data;
                rxf_wr_ptr          <= rxf_wr_ptr + 1;
            end
            if (rxf_pop)
                rxf_rd_ptr <= rxf_rd_ptr + 1;
        end
    end

    // ========================================================================
    // Interrupt
    // ========================================================================
    logic [1:0] ie_r;
    logic [1:0] is_wire;
    assign is_wire[0] = !rxf_empty;   // RX not empty
    assign is_wire[1] = txf_empty;    // TX FIFO drained
    assign irq = |(ie_r & is_wire);

    // RX state machine output signals
    logic [7:0] rx_data;
    logic       rx_valid;

    // ========================================================================
    // UART TX State Machine
    // ========================================================================
    typedef enum logic [2:0] {
        TX_IDLE,
        TX_START_BIT,
        TX_DATA_BITS,
        TX_STOP_BIT
    } tx_state_e;

    tx_state_e tx_state;
    logic [$clog2(CLKS_PER_BIT)-1:0] tx_clk_count;
    logic [2:0] tx_bit_index;
    logic [7:0] tx_data_reg;

    /* verilator lint_off WIDTHEXPAND */
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state     <= TX_IDLE;
            tx_clk_count <= 0;
            tx_bit_index <= 0;
            tx_data_reg  <= 8'd0;
            uart_tx      <= 1'b1;
            tx_ready     <= 1'b1;
        end else begin
            case (tx_state)
                TX_IDLE: begin
                    uart_tx      <= 1'b1;
                    tx_ready     <= 1'b1;
                    tx_clk_count <= 0;
                    tx_bit_index <= 0;

                    if (tx_valid) begin
                        tx_data_reg <= tx_data;
                        tx_ready    <= 1'b0;
                        tx_state    <= TX_START_BIT;
                    end
                end

                TX_START_BIT: begin
                    uart_tx <= 1'b0;

                    if (tx_clk_count < CLKS_PER_BIT - 1) begin
                        tx_clk_count <= tx_clk_count + 1;
                    end else begin
                        tx_clk_count <= 0;
                        tx_state     <= TX_DATA_BITS;
                    end
                end

                TX_DATA_BITS: begin
                    uart_tx <= tx_data_reg[tx_bit_index];

                    if (tx_clk_count < CLKS_PER_BIT - 1) begin
                        tx_clk_count <= tx_clk_count + 1;
                    end else begin
                        tx_clk_count <= 0;

                        if (tx_bit_index < 7) begin
                            tx_bit_index <= tx_bit_index + 1;
                        end else begin
                            tx_bit_index <= 0;
                            tx_state     <= TX_STOP_BIT;
                        end
                    end
                end

                TX_STOP_BIT: begin
                    uart_tx <= 1'b1;
                    if (tx_clk_count < CLKS_PER_BIT - 1)
                        tx_clk_count <= tx_clk_count + 1;
                    else begin
                        tx_ready <= 1'b1;
                        tx_state <= TX_IDLE;
                    end
                end

                default: tx_state <= TX_IDLE;
            endcase
        end
    end
    /* verilator lint_on WIDTHEXPAND */

    // ========================================================================
    // UART RX State Machine
    // ========================================================================
    typedef enum logic [2:0] {
        RX_IDLE,
        RX_START_BIT,
        RX_DATA_BITS,
        RX_STOP_BIT
    } rx_state_e;

    rx_state_e rx_state;
    logic [$clog2(CLKS_PER_BIT)-1:0] rx_clk_count;
    logic [2:0] rx_bit_index;
    logic [7:0] rx_data_buf;

    // Synchronize input
    logic uart_rx_sync1, uart_rx_sync2;

    // When loopback_en is set, feed uart_tx back into the RX synchronizer
    // so the receive path samples the core's own transmitted signal.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_rx_sync1 <= 1'b1;
            uart_rx_sync2 <= 1'b1;
        end else begin
            uart_rx_sync1 <= loopback_en ? uart_tx : uart_rx;
            uart_rx_sync2 <= uart_rx_sync1;
        end
    end

    /* verilator lint_off WIDTHEXPAND */
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state     <= RX_IDLE;
            rx_clk_count <= 0;
            rx_bit_index <= 0;
            rx_data_buf  <= 8'd0;
            rx_data      <= 8'd0;
            rx_valid     <= 1'b0;
        end else begin
            rx_valid <= 1'b0;

            case (rx_state)
                RX_IDLE: begin
                    rx_clk_count <= 0;
                    rx_bit_index <= 0;

                    if (uart_rx_sync2 == 1'b0) begin
                        rx_state <= RX_START_BIT;
                    end
                end

                RX_START_BIT: begin
                    if (rx_clk_count < (CLKS_PER_BIT - 1) / 2) begin
                        rx_clk_count <= rx_clk_count + 1;
                    end else begin
                        if (uart_rx_sync2 == 1'b0) begin
                            rx_clk_count <= 0;
                            rx_state     <= RX_DATA_BITS;
                        end else begin
                            rx_state <= RX_IDLE;
                        end
                    end
                end

                RX_DATA_BITS: begin
                    if (rx_clk_count < CLKS_PER_BIT - 1) begin
                        rx_clk_count <= rx_clk_count + 1;
                    end else begin
                        rx_clk_count <= 0;
                        rx_data_buf[rx_bit_index] <= uart_rx_sync2;

                        if (rx_bit_index < 7) begin
                            rx_bit_index <= rx_bit_index + 1;
                        end else begin
                            rx_bit_index <= 0;
                            rx_state     <= RX_STOP_BIT;
                        end
                    end
                end

                RX_STOP_BIT: begin
                    if (rx_clk_count < CLKS_PER_BIT - 1)
                        rx_clk_count <= rx_clk_count + 1;
                    else begin
                        rx_data  <= rx_data_buf;
                        rx_valid <= 1'b1;
                        rx_state <= RX_IDLE;
                    end
                end

                default: rx_state <= RX_IDLE;
            endcase
        end
    end
    /* verilator lint_on WIDTHEXPAND */

    // RX FIFO push: one-cycle rx_valid pulse; drop byte silently if FIFO full
    assign rxf_push = rx_valid && !rxf_full;

    // ========================================================================
    // AXI4-Lite Interface
    // ========================================================================
    // Always-ready channels (single-cycle); TX FIFO push/RX FIFO pop are combinational
    assign axi_awready = 1'b1;
    assign axi_wready  = 1'b1;
    assign axi_arready = 1'b1;

    // TX FIFO push: AXI write to offset 0x00 (drop if FIFO full)
    assign txf_push = axi_awvalid && axi_wvalid && (axi_awaddr[7:0] == 8'h00) && !txf_full;

    // RX FIFO pop: AXI read of offset 0x00 (advance pointer)
    assign rxf_pop = axi_arvalid && (axi_araddr[7:0] == 8'h00) && !rxf_empty;

    // ── Loopback control ──────────────────────────────────────────────────────
    logic loopback_en;

    // ── Write Response + IE/CTRL registers ───────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_bvalid  <= 1'b0;
            axi_bresp   <= 2'b00;
            ie_r        <= 2'b00;
            loopback_en <= 1'b0;
        end else begin
            if (axi_bvalid && axi_bready)
                axi_bvalid <= 1'b0;

            if (axi_awvalid && axi_wvalid && axi_awready && axi_wready) begin
                case (axi_awaddr[7:0])
                    8'h08: ie_r        <= axi_wdata[1:0];
                    8'h14: loopback_en <= axi_wdata[0];
                    default: ;
                endcase
                axi_bvalid <= 1'b1;
                axi_bresp  <= wr_addr_valid ? 2'b00 : 2'b10;  // OKAY or SLVERR
            end
        end
    end

    // ── Read Response ─────────────────────────────────────────────────────────
    logic [31:0] read_data;
    always_comb begin
        case (axi_araddr[7:0])
            8'h00: read_data = {24'h0, rxf_mem[rxf_rd_ptr]};    // RX pop
            8'h04: read_data = {28'h0,
                                rxf_full,                        // [3] RX_OVERRUN
                                !rxf_empty,                      // [2] RX_READY
                                txf_full,                        // [1] TX_FULL
                                txf_full};                       // [0] TX_BUSY (full=can't write)
            8'h08: read_data = {30'h0, ie_r};                    // IE
            8'h0C: read_data = {30'h0, is_wire};                 // IS (level)
            /* verilator lint_off WIDTHEXPAND */
            8'h10: read_data = {4'h0, txf_count,
                                4'h0, rxf_count};                // LEVEL
            /* verilator lint_on WIDTHEXPAND */
            8'h14: read_data = {31'h0, loopback_en};             // CTRL
            8'h18: read_data = CAPABILITY_REG;                   // CAPABILITY (RO)
            default: read_data = 32'h0;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_rdata  <= 32'h0;
            axi_rresp  <= 2'b00;
            axi_rvalid <= 1'b0;
        end else begin
            if (axi_rvalid && axi_rready)
                axi_rvalid <= 1'b0;

            if (axi_arvalid && axi_arready) begin
                axi_rdata  <= read_data;
                axi_rresp  <= rd_addr_valid ? 2'b00 : 2'b10;  // OKAY or SLVERR
                axi_rvalid <= 1'b1;
            end
        end
    end

    // Suppress unused-signal lint warnings: upper address/data bits and byte-enable
    // are not needed for this byte-wide register file.
    logic _unused_ok;
    assign _unused_ok = &{1'b0, axi_wstrb, axi_awaddr[31:8],
                                axi_wdata[31:8], axi_araddr[31:8]};

endmodule

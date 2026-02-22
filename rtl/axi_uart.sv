// ============================================================================
// File: axi_uart.sv
// Project: RV32 RISC-V Processor
// Description: AXI4-Lite UART Peripheral with integrated TX/RX logic
//
// Memory-mapped UART with AXI4-Lite interface. Provides serial communication
// with configurable baud rate and 8N1 format (8 data bits, no parity, 1 stop).
//
// Register Map:
//   0x00: TX Data Register (write), RX Data Register (read)
//   0x04: Status Register (bit 0: TX ready, bit 1: RX valid)
//
// Features:
//   - Configurable clock frequency and baud rate
//   - Status flags for polling-based I/O
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
    parameter CLK_FREQ = 100_000_000,
    parameter BAUD_RATE = 25_000_000
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

    // UART pins
    input  logic        uart_rx,
    output logic        uart_tx
);

    localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;

    // UART memory map (relative to base 0x0201_0000)
    // 0x00: TX data register
    // 0x04: RX data register
    // 0x08: Status register (bit 0: tx_ready, bit 1: rx_valid)

    // TX signals
    logic [7:0]  tx_data;
    logic        tx_valid;
    logic        tx_ready;

    // RX signals
    logic [7:0]  rx_data;
    logic        rx_valid;
    logic [7:0]  rx_data_reg;
    logic        rx_data_valid;

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

                    if (tx_clk_count < CLKS_PER_BIT - 1) begin
                        tx_clk_count <= tx_clk_count + 1;
                    end else begin
                        tx_ready     <= 1'b1;
                        tx_state     <= TX_IDLE;
                    end
                end

                default: tx_state <= TX_IDLE;
            endcase
        end
    end

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

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_rx_sync1 <= 1'b1;
            uart_rx_sync2 <= 1'b1;
        end else begin
            uart_rx_sync1 <= uart_rx;
            uart_rx_sync2 <= uart_rx_sync1;
        end
    end

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
                    if (rx_clk_count < CLKS_PER_BIT - 1) begin
                        rx_clk_count <= rx_clk_count + 1;
                    end else begin
                        rx_data  <= rx_data_buf;
                        rx_valid <= 1'b1;
                        rx_state <= RX_IDLE;
                    end
                end

                default: rx_state <= RX_IDLE;
            endcase
        end
    end

    // ========================================================================
    // RX Data Register
    // ========================================================================
    logic [31:0] araddr_offset;

    always_comb begin
        araddr_offset = axi_araddr - 32'h0201_0000;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_data_reg   <= 8'd0;
            rx_data_valid <= 1'b0;
        end else begin
            if (rx_valid) begin
                rx_data_reg   <= rx_data;
                rx_data_valid <= 1'b1;
            end else if (axi_arvalid && (araddr_offset[7:0] == 8'h04)) begin
                rx_data_valid <= 1'b0;
            end
        end
    end

    // ========================================================================
    // AXI4-Lite State Machine
    // ========================================================================
    // AXI4-Lite Interface - Simple register access (always ready)
    // ========================================================================
    // Like CLINT, keep ready signals always high for truly independent R/W channels
    assign axi_awready = 1'b1;  // Always ready to accept write address
    assign axi_wready  = 1'b1;  // Always ready to accept write data
    assign axi_arready = 1'b1;  // Always ready to accept read address

    // Combinational read data mux
    logic [31:0] read_data;
    always_comb begin
        case (axi_araddr[7:0])
            8'h00:   read_data = {24'd0, rx_data_reg};  // RX data
            8'h04:   read_data = {29'd0, rx_data_valid, 1'b0, !tx_ready};  // STATUS: bit0=tx_busy, bit2=rx_ready
            default: read_data = 32'd0;
        endcase
    end

    // ========================================================================
    // Write Channel (AW + W → B)
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_bresp   <= 2'b00;
            axi_bvalid  <= 1'b0;
            tx_data     <= 8'd0;
            tx_valid    <= 1'b0;
        end else begin
            tx_valid <= 1'b0;

            // Handle write response
            if (axi_bvalid && axi_bready) begin
                axi_bvalid <= 1'b0;
            end

            // Accept write when both AW and W channels are valid
            if (axi_awvalid && axi_wvalid && axi_awready && axi_wready) begin
                // Write to UART TX register
                if (axi_awaddr[7:0] == 8'h00) begin
                    tx_data  <= axi_wdata[7:0];
                    tx_valid <= 1'b1;
                end

                // Generate write response
                axi_bresp  <= 2'b00;
                axi_bvalid <= 1'b1;
            end
        end
    end

    // ========================================================================
    // Read Channel (AR → R)
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_rdata   <= 32'h0;
            axi_rresp   <= 2'b00;
            axi_rvalid  <= 1'b0;
        end else begin
            // Handle read response
            if (axi_rvalid && axi_rready) begin
                axi_rvalid <= 1'b0;
            end

            // Accept read when AR channel is valid
            if (axi_arvalid && axi_arready) begin
                axi_rdata  <= read_data;
                axi_rresp  <= 2'b00;
                axi_rvalid <= 1'b1;
            end
        end
    end

endmodule

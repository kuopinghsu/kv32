// ============================================================================
// File: axi_spi.sv
// Project: RV32 RISC-V Processor
// Description: AXI4-Lite SPI Master Controller
//
// Provides memory-mapped SPI master interface for serial peripheral control.
// Supports standard SPI modes with configurable clock polarity and phase.
//
// Register Map (relative to base 0x0202_0000):
//   0x00: Control Register
//         [0]: Enable (1=enable SPI, 0=disable)
//         [1]: CPOL (Clock Polarity: 0=idle low, 1=idle high)
//         [2]: CPHA (Clock Phase: 0=sample on leading edge, 1=trailing edge)
//         [7:4]: CS (Chip Select, active low)
//   0x04: Clock Divider (SCLK = CLK / (2 * (DIV + 1)))
//   0x08: TX Data Register (write to transmit)
//   0x0C: RX Data Register (read received data)
//   0x10: Status Register
//         [0]: Busy (1=transfer in progress)
//         [1]: TX Ready (1=can accept new data)
//         [2]: RX Valid (1=received data available)
//
// Features:
//   - Configurable clock divider for SPI clock generation
//   - Support for SPI modes 0-3 (CPOL/CPHA)
//   - 8-bit data transfers
//   - Up to 4 chip select lines
//   - Status flags for polling-based operation
// ============================================================================

module axi_spi #(
    parameter CLK_FREQ = 100_000_000  // System clock frequency
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

    // SPI pins
    output logic        spi_sclk,     // SPI clock
    output logic        spi_mosi,     // Master Out Slave In
    input  logic        spi_miso,     // Master In Slave Out
    output logic [3:0]  spi_cs_n      // Chip Select (active low)
);

    import rv32_pkg::*;

    // Register offsets
    localparam CTRL_OFFSET  = 16'h0000;
    localparam DIV_OFFSET   = 16'h0004;
    localparam TX_OFFSET    = 16'h0008;
    localparam RX_OFFSET    = 16'h000C;
    localparam STAT_OFFSET  = 16'h0010;

    // Control register fields
    logic        spi_enable;
    logic        cpol;          // Clock polarity
    logic        cpha;          // Clock phase
    logic [3:0]  cs_select;     // Chip select

    // Clock divider
    logic [15:0] clk_div;
    logic [15:0] clk_counter;
    logic        sclk_edge;

    // Data registers
    logic [7:0]  tx_data;
    logic [7:0]  rx_data;
    logic        tx_valid;

    // Status flags
    logic        busy;
    logic        tx_ready;
    logic        rx_valid;

    // SPI transfer state machine
    typedef enum logic [2:0] {
        IDLE,
        START,
        TRANSFER,
        FINISH
    } spi_state_t;

    spi_state_t state;
    logic [3:0]  bit_counter;
    logic [7:0]  shift_reg_tx;
    logic [7:0]  shift_reg_rx;
    logic        sclk_int;

    // ========================================================================
    // AXI4-Lite Interface - Always ready for register access
    // ========================================================================
    assign axi_awready = 1'b1;
    assign axi_wready = 1'b1;

    // Write transaction
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_enable  <= 1'b0;
            cpol        <= 1'b0;
            cpha        <= 1'b0;
            cs_select   <= 4'b1111;
            clk_div     <= 16'd49;  // Default: 1MHz SPI at 100MHz system clock
            tx_valid    <= 1'b0;
        end else begin
            tx_valid <= 1'b0;  // Pulse

            if (axi_awvalid && axi_wvalid) begin
                case (axi_awaddr[15:0])
                    CTRL_OFFSET: begin
                        spi_enable <= axi_wdata[0];
                        cpol       <= axi_wdata[1];
                        cpha       <= axi_wdata[2];
                        cs_select  <= axi_wdata[7:4];
                    end
                    DIV_OFFSET: begin
                        clk_div <= axi_wdata[15:0];
                    end
                    TX_OFFSET: begin
                        if (!busy && spi_enable) begin
                            tx_data  <= axi_wdata[7:0];
                            tx_valid <= 1'b1;
                        end
                    end
                    default: begin
                        // Ignore writes to unknown addresses
                    end
                endcase
            end
        end
    end

    // ========================================================================
    // AXI Write Response Channel
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_bvalid <= 1'b0;
            axi_bresp  <= 2'b00;
        end else begin
            if (axi_awvalid && axi_wvalid && !axi_bvalid) begin
                axi_bvalid <= 1'b1;
                axi_bresp  <= 2'b00;  // OKAY
            end else if (axi_bvalid && axi_bready) begin
                axi_bvalid <= 1'b0;
            end
        end
    end

    // ========================================================================
    // AXI Read Channels - Always ready
    // ========================================================================
    assign axi_arready = 1'b1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_rvalid <= 1'b0;
            axi_rdata  <= 32'h0;
            axi_rresp  <= 2'b00;
            rx_valid   <= 1'b0;
        end else begin
            if (axi_arvalid && !axi_rvalid) begin
                axi_rvalid <= 1'b1;
                axi_rresp  <= 2'b00;  // OKAY
                case (axi_araddr[15:0])
                    CTRL_OFFSET: begin
                        axi_rdata <= {24'h0, cs_select, 1'b0, cpha, cpol, spi_enable};
                    end
                    DIV_OFFSET: begin
                        axi_rdata <= {16'h0, clk_div};
                    end
                    TX_OFFSET: begin
                        axi_rdata <= {24'h0, tx_data};
                    end
                    RX_OFFSET: begin
                        axi_rdata <= {24'h0, rx_data};
                        rx_valid  <= 1'b0;  // Clear on read
                    end
                    STAT_OFFSET: begin
                        axi_rdata <= {29'h0, rx_valid, tx_ready, busy};
                    end
                    default: begin
                        axi_rdata <= 32'h0;
                    end
                endcase
            end else if (axi_rvalid && axi_rready) begin
                axi_rvalid <= 1'b0;
            end

            // Set rx_valid when transfer completes
            if (state == FINISH) begin
                rx_valid <= 1'b1;
            end
        end
    end

    // ========================================================================
    // SPI Clock Generation
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_counter <= 16'h0;
            sclk_edge   <= 1'b0;
        end else begin
            sclk_edge <= 1'b0;
            if (busy) begin
                if (clk_counter >= clk_div) begin
                    clk_counter <= 16'h0;
                    sclk_edge   <= 1'b1;
                end else begin
                    clk_counter <= clk_counter + 1;
                end
            end else begin
                clk_counter <= 16'h0;
            end
        end
    end

    // ========================================================================
    // SPI Transfer State Machine
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            busy         <= 1'b0;
            tx_ready     <= 1'b1;
            bit_counter  <= 4'h0;
            shift_reg_tx <= 8'h0;
            shift_reg_rx <= 8'h0;
            sclk_int     <= 1'b0;
            rx_data      <= 8'h0;
        end else begin
            case (state)
                IDLE: begin
                    tx_ready    <= 1'b1;
                    busy        <= 1'b0;
                    sclk_int    <= cpol;  // Idle state
                    bit_counter <= 4'h0;

                    if (tx_valid && spi_enable) begin
                        shift_reg_tx <= tx_data;
                        state        <= START;
                        busy         <= 1'b1;
                        tx_ready     <= 1'b0;
                    end
                end

                START: begin
                    if (sclk_edge) begin
                        state <= TRANSFER;
                    end
                end

                TRANSFER: begin
                    if (sclk_edge) begin
                        sclk_int <= ~sclk_int;

                        // Sample or shift based on CPHA
                        if (cpha == 0) begin
                            // Mode 0,2: Sample on leading edge, shift on trailing
                            if (sclk_int == cpol) begin
                                // Leading edge - sample MISO
                                shift_reg_rx <= {shift_reg_rx[6:0], spi_miso};
                            end else begin
                                // Trailing edge - shift MOSI
                                shift_reg_tx <= {shift_reg_tx[6:0], 1'b0};
                                bit_counter  <= bit_counter + 1;
                            end
                        end else begin
                            // Mode 1,3: Shift on leading edge, sample on trailing
                            if (sclk_int == cpol) begin
                                // Leading edge - shift MOSI
                                shift_reg_tx <= {shift_reg_tx[6:0], 1'b0};
                            end else begin
                                // Trailing edge - sample MISO
                                shift_reg_rx <= {shift_reg_rx[6:0], spi_miso};
                                bit_counter  <= bit_counter + 1;
                            end
                        end

                        if (bit_counter >= 4'd8) begin
                            state <= FINISH;
                        end
                    end
                end

                FINISH: begin
                    rx_data  <= shift_reg_rx;
                    sclk_int <= cpol;  // Return to idle
                    state    <= IDLE;
                end

                default: begin
                    // Should not reach here
                    state <= IDLE;
                end
            endcase
        end
    end

    // ========================================================================
    // SPI Output Signals
    // ========================================================================
    assign spi_sclk = sclk_int;
    assign spi_mosi = shift_reg_tx[7];
    assign spi_cs_n = spi_enable ? cs_select : 4'b1111;

endmodule

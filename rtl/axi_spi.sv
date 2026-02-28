// ============================================================================
// File: axi_spi.sv
// Project: KV32 RISC-V Processor
// Description: AXI4-Lite SPI Master Controller with TX/RX FIFOs and IRQ
//
// Provides memory-mapped SPI master interface for serial peripheral control.
// Supports standard SPI modes with configurable clock polarity and phase.
// TX and RX paths each have a FIFO_DEPTH-entry FIFO.
//
// Register Map (relative to base 0x2002_0000):
//   0x00: Control Register
//         [0]: Enable (1=enable SPI, 0=disable)
//         [1]: CPOL (Clock Polarity: 0=idle low, 1=idle high)
//         [2]: CPHA (Clock Phase: 0=sample on leading edge, 1=trailing edge)
//         [3]: Loopback Enable (1=internal MOSI->MISO loopback for hardware testing)
//         [7:4]: CS (Chip Select, active low)
//   0x04: Clock Divider (SCLK = CLK / (2 * (DIV + 1)))
//   0x08: TX Data   - write: push to TX FIFO (read: returns 0)
//   0x0C: RX Data   - read: pop from RX FIFO
//   0x10: Status Register
//         [0]: Busy     (1=transfer in progress)
//         [1]: TX_READY (!tx_full - can accept new TX data)
//         [2]: RX_VALID (!rx_empty - received data available)
//         [3]: tx_empty
//         [4]: rx_full
//   0x14: IE - Interrupt Enable: [0]=rx_not_empty_ie, [1]=tx_empty_ie
//   0x18: IS - Interrupt Status (read-only, level): [0]=rx_not_empty, [1]=tx_empty
//
// Interrupt (irq): asserted when (IE & IS) != 0
//
// Features:
//   - Configurable clock divider for SPI clock generation
//   - Support for SPI modes 0-3 (CPOL/CPHA)
//   - 8-bit data transfers
//   - Up to 4 chip select lines
//   - Parameterised TX/RX FIFOs (default depth 8)
//   - PLIC-compatible IRQ output
// ============================================================================

`ifdef SYNTHESIS
import kv32_pkg::*;
`endif
module axi_spi #(
    parameter CLK_FREQ   = 100_000_000,  // System clock frequency
    parameter FIFO_DEPTH = 8             // Must be a power of 2
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

    // SPI pins
    output logic        spi_sclk,     // SPI clock
    output logic        spi_mosi,     // Master Out Slave In
    input  logic        spi_miso,     // Master In Slave Out
    output logic [3:0]  spi_cs_n      // Chip Select (active low)
);
`ifndef SYNTHESIS
    import kv32_pkg::*;
`endif

    // Register offsets
    localparam CTRL_OFFSET  = 16'h0000;
    localparam DIV_OFFSET   = 16'h0004;
    localparam TX_OFFSET    = 16'h0008;  // TX data push (write-only)
    localparam RX_OFFSET    = 16'h000C;  // RX data pop  (read-only)
    localparam STAT_OFFSET  = 16'h0010;
    localparam IE_OFFSET    = 16'h0014;
    localparam IS_OFFSET    = 16'h0018;

    localparam FIFO_BITS = $clog2(FIFO_DEPTH);

    // ========================================================================
    // TX FIFO
    // ========================================================================
    logic [7:0]           txf_mem  [0:FIFO_DEPTH-1];
    logic [FIFO_BITS-1:0] txf_wr_ptr, txf_rd_ptr;
    logic [FIFO_BITS:0]   txf_count;
    logic txf_empty, txf_full;
    assign txf_empty = (txf_count == '0);
    assign txf_full  = (txf_count == FIFO_DEPTH);

    logic txf_push, txf_pop;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            txf_wr_ptr <= '0;
            txf_rd_ptr <= '0;
            txf_count  <= '0;
        end else begin
            if (txf_push && !txf_pop)       txf_count <= txf_count + 1;
            else if (!txf_push && txf_pop)  txf_count <= txf_count - 1;
            if (txf_push) begin
                txf_mem[txf_wr_ptr] <= axi_wdata[7:0];
                txf_wr_ptr          <= txf_wr_ptr + 1;
            end
            if (txf_pop) txf_rd_ptr <= txf_rd_ptr + 1;
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
            if (rxf_push && !rxf_pop)       rxf_count <= rxf_count + 1;
            else if (!rxf_push && rxf_pop)  rxf_count <= rxf_count - 1;
            if (rxf_push) begin
                rxf_mem[rxf_wr_ptr] <= shift_reg_rx;  // use shift_reg_rx directly; rx_data is registered one cycle later
                rxf_wr_ptr          <= rxf_wr_ptr + 1;
            end
            if (rxf_pop) rxf_rd_ptr <= rxf_rd_ptr + 1;
        end
    end

    // ========================================================================
    // Interrupt
    // ========================================================================
    logic [1:0] ie_r;
    logic [1:0] is_wire;
    assign is_wire[0] = !rxf_empty;
    assign is_wire[1] = txf_empty;
    assign irq = |(ie_r & is_wire);

    // Control register fields
    logic        spi_enable;
    logic        cpol;          // Clock polarity
    logic        cpha;          // Clock phase
    logic        loopback_en;   // Internal MOSI->MISO loopback
    logic [3:0]  cs_select;     // Chip select

    // Clock divider
    logic [15:0] clk_div;
    logic [15:0] clk_counter;
    logic        sclk_edge;

    // TX state machine signals fed from FIFO
    logic [7:0]  tx_data;
    logic        tx_valid;
    logic [7:0]  rx_data;

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
    logic        busy;
    logic        tx_ready;

    // When loopback_en is set, MOSI is fed back to MISO internally,
    // bypassing the external spi_miso pin.
    logic spi_miso_in;
    assign spi_miso_in = loopback_en ? spi_mosi : spi_miso;

    // TX FIFO feeds the state machine: pop when IDLE and FIFO not empty
    assign txf_pop = (state == IDLE) && !txf_empty && spi_enable;
    assign tx_valid = txf_pop;
    assign tx_data  = txf_mem[txf_rd_ptr];

    // RX FIFO is pushed when a transfer finishes (drop if full)
    assign rxf_push = (state == FINISH) && !rxf_full;
    // RX FIFO pop on AXI read of RX_OFFSET
    assign rxf_pop  = axi_arvalid && (axi_araddr[15:0] == RX_OFFSET) && !rxf_empty;

    // ========================================================================
    // AXI4-Lite Interface - Always ready for register access
    // ========================================================================
    assign axi_awready = 1'b1;
    assign axi_wready  = 1'b1;

    // TX FIFO push on AXI write to TX_OFFSET
    assign txf_push = axi_awvalid && axi_wvalid && (axi_awaddr[15:0] == TX_OFFSET) && !txf_full;

    // Write transaction (control/divider/IE registers)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spi_enable  <= 1'b0;
            cpol        <= 1'b0;
            cpha        <= 1'b0;
            loopback_en <= 1'b0;
            cs_select   <= 4'b1111;
            clk_div     <= 16'd49;  // Default: 1MHz SPI at 100MHz system clock
            ie_r        <= 2'b00;
            axi_bvalid  <= 1'b0;
            axi_bresp   <= 2'b00;
        end else begin
            if (axi_bvalid && axi_bready)
                axi_bvalid <= 1'b0;

            if (axi_awvalid && axi_wvalid) begin
                case (axi_awaddr[15:0])
                    CTRL_OFFSET: begin
                        spi_enable  <= axi_wdata[0];
                        cpol        <= axi_wdata[1];
                        cpha        <= axi_wdata[2];
                        loopback_en <= axi_wdata[3];
                        cs_select   <= axi_wdata[7:4];
                    end
                    DIV_OFFSET: clk_div <= axi_wdata[15:0];
                    IE_OFFSET:  ie_r    <= axi_wdata[1:0];
                    default: ; // TX_OFFSET push handled by txf_push assign
                endcase
                axi_bvalid <= 1'b1;
                axi_bresp  <= 2'b00;
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
        end else begin
            if (axi_arvalid && !axi_rvalid) begin
                axi_rvalid <= 1'b1;
                axi_rresp  <= 2'b00;
                case (axi_araddr[15:0])
                    CTRL_OFFSET: axi_rdata <= {24'h0, cs_select, loopback_en, cpha, cpol, spi_enable};
                    DIV_OFFSET:  axi_rdata <= {16'h0, clk_div};
                    TX_OFFSET:   axi_rdata <= 32'h0;             // TX-only, read returns 0
                    RX_OFFSET:   axi_rdata <= {24'h0, rxf_mem[rxf_rd_ptr]}; // RX pop
                    STAT_OFFSET: axi_rdata <= {27'h0,
                                               rxf_full,     // [4] rx_full
                                               txf_empty,    // [3] tx_empty
                                               !rxf_empty,   // [2] RX_VALID
                                               !txf_full,    // [1] TX_READY
                                               busy};        // [0] BUSY
                    IE_OFFSET:   axi_rdata <= {30'h0, ie_r};
                    IS_OFFSET:   axi_rdata <= {30'h0, is_wire};
                    default:     axi_rdata <= 32'h0;
                endcase
            end else if (axi_rvalid && axi_rready) begin
                axi_rvalid <= 1'b0;
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
                    tx_ready     <= 1'b1;
                    busy         <= 1'b0;
                    sclk_int     <= cpol;
                    bit_counter  <= 4'h0;
                    shift_reg_rx <= 8'h0;

                    if (tx_valid && spi_enable) begin
                        shift_reg_tx <= tx_data;
                        state        <= START;
                        busy         <= 1'b1;
                        tx_ready     <= 1'b0;
                    end
                end

                START: begin
                    if (sclk_edge) state <= TRANSFER;
                end

                TRANSFER: begin
                    if (sclk_edge) begin
                        sclk_int <= ~sclk_int;
                        if (cpha == 0) begin
                            if (sclk_int == cpol)
                                shift_reg_rx <= {shift_reg_rx[6:0], spi_miso_in};
                            else begin
                                shift_reg_tx <= {shift_reg_tx[6:0], 1'b0};
                                bit_counter  <= bit_counter + 1;
                                if (bit_counter >= 4'd7) state <= FINISH;
                            end
                        end else begin
                            if (sclk_int == cpol)
                                shift_reg_tx <= {shift_reg_tx[6:0], 1'b0};
                            else begin
                                shift_reg_rx <= {shift_reg_rx[6:0], spi_miso_in};
                                bit_counter  <= bit_counter + 1;
                                if (bit_counter >= 4'd7) state <= FINISH;
                            end
                        end
                    end
                end

                FINISH: begin
                    rx_data  <= shift_reg_rx;  // captured; rxf_push is combinational
                    sclk_int <= cpol;
                    state    <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    // ========================================================================
    // Combinatorial TX-write detection (kept for symmetry, unused in FIFO mode)
    // ========================================================================
    logic tx_being_written;  // unused but kept to avoid breaking any ifdef code
    assign tx_being_written = 1'b0;

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
                end else
                    clk_counter <= clk_counter + 1;
            end else
                clk_counter <= 16'h0;
        end
    end

    //  State machine (after clock gen so busy is defined)
    assign spi_sclk = sclk_int;
    assign spi_mosi = shift_reg_tx[7];
    assign spi_cs_n = spi_enable ? cs_select : 4'b1111;

endmodule

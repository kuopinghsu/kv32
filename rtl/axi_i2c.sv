// ============================================================================
// File: axi_i2c.sv
// Project: KV32 RISC-V Processor
// Description: AXI4-Lite I2C Master Controller with TX/RX FIFOs and IRQ
//
// Provides memory-mapped I2C master interface for interfacing with I2C devices.
// Supports standard (100kHz) and fast (400kHz) I2C modes.
// TX and RX paths each have a FIFO_DEPTH-entry FIFO.
//
// Register Map (relative to base 0x2001_0000):
//   0x00: Control Register
//         [0]: Enable (1=enable I2C, 0=disable)
//         [1]: Start (write 1 to send START condition)
//         [2]: Stop (write 1 to send STOP condition)
//         [3]: Read (1=read from slave, 0=write to slave)
//         [4]: ACK (for read: 0=ACK, 1=NACK to end read)
//   0x04: Clock Divider (SCL period = CLK / (4 * (DIV + 1)))
//   0x08: TX Data Register - write: push byte to TX FIFO
//   0x0C: RX Data Register - read: pop byte from RX FIFO
//   0x10: Status Register
//         [0]: Busy (1=transfer in progress)
//         [1]: !tx_full  (TX FIFO ready to accept data)
//         [2]: !rx_empty (RX FIFO has data available)
//         [3]: ACK Received
//   0x14: IE - Interrupt Enable: [0]=rx_not_empty_ie, [1]=tx_empty_ie, [2]=done_ie
//   0x18: IS - Interrupt Status (read-only, level):
//         [0]=rx_not_empty, [1]=tx_empty, [2]=done (STOP completed)
//
// Interrupt (irq): asserted when (IE & IS) != 0
//
// Features:
//   - Configurable clock divider for SCL generation
//   - Standard (100kHz) and Fast (400kHz) mode support
//   - 7-bit addressing
//   - START/STOP condition generation
//   - ACK/NACK detection and generation
//   - Parameterised TX/RX FIFOs (default depth 8)
//   - PLIC-compatible IRQ output
// ============================================================================

`ifdef SYNTHESIS
import kv32_pkg::*;
`endif

module axi_i2c #(
    parameter int unsigned CLK_FREQ   = 100_000_000,  // System clock frequency
    parameter int unsigned FIFO_DEPTH = 8             // Must be a power of 2
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

    // I2C pins (open-drain, requires external pull-ups)
    output logic        i2c_scl_o,    // SCL output
    input  logic        i2c_scl_i,    // SCL input (for clock stretching)
    output logic        i2c_scl_oe,   // SCL tristate (1=output disabled/high-Z)
    output logic        i2c_sda_o,    // SDA output
    input  logic        i2c_sda_i,    // SDA input
    output logic        i2c_sda_oe    // SDA tristate (1=output disabled/high-Z)
);
`ifndef SYNTHESIS
    import kv32_pkg::*;
`endif

    // Register offsets
    localparam CTRL_OFFSET  = 16'h0000;
    localparam DIV_OFFSET   = 16'h0004;
    localparam TX_OFFSET    = 16'h0008;
    localparam RX_OFFSET    = 16'h000C;
    localparam STAT_OFFSET  = 16'h0010;
    localparam IE_OFFSET    = 16'h0014;
    localparam IS_OFFSET    = 16'h0018;
    localparam CAP_OFFSET   = 16'h001C;

    // I2C state machine
    typedef enum logic [3:0] {
        IDLE,
        START,
        ADDR,
        WRITE,
        READ,
        ACK_CHECK,
        ACK_SEND,
        STOP
    } i2c_state_t;

    i2c_state_t state;

    // Register address space: offsets 0x0000–0x001C (8 word-aligned registers)
    // Accesses with byte-offset > CAP_OFFSET are out-of-range → AXI SLVERR (2'b10)
    wire wr_addr_valid = (axi_awaddr[15:0] <= CAP_OFFSET); // write address in range
    wire rd_addr_valid = (axi_araddr[15:0] <= CAP_OFFSET); // read address in range

    // Capability register
    localparam logic [15:0] I2C_VERSION     = 16'h0001;
    localparam logic [31:0] CAPABILITY_REG  = {I2C_VERSION, 8'(FIFO_DEPTH), 8'(FIFO_DEPTH)};

    localparam FIFO_BITS = $clog2(FIFO_DEPTH);

    // ========================================================================
    // TX FIFO
    // ========================================================================
    logic [7:0]           txf_mem  [0:FIFO_DEPTH-1];
    logic [FIFO_BITS-1:0] txf_wr_ptr, txf_rd_ptr;
    logic [FIFO_BITS:0]   txf_count;
    logic txf_empty, txf_full;
    assign txf_empty = (txf_count == '0);
    assign txf_full  = (txf_count == (FIFO_BITS+1)'(FIFO_DEPTH));

    // txf_push: AXI write to TX_OFFSET; txf_pop: state machine pops in IDLE
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
    logic [7:0]  rx_data;             // forward declaration (used below, declared later)
    logic [7:0]           rxf_mem  [0:FIFO_DEPTH-1];
    logic [FIFO_BITS-1:0] rxf_wr_ptr, rxf_rd_ptr;
    logic [FIFO_BITS:0]   rxf_count;
    logic rxf_empty, rxf_full;
    assign rxf_empty = (rxf_count == '0);
    assign rxf_full  = (rxf_count == (FIFO_BITS+1)'(FIFO_DEPTH));

    // rxf_push: 1-cycle delayed after READ byte captured; rxf_pop: AXI read of RX_OFFSET
    logic rxf_push, rxf_pop;
    logic rxf_push_r;  // 1-cycle delayed so rx_data is valid
    assign rxf_push = rxf_push_r && !rxf_full;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rxf_wr_ptr <= '0;
            rxf_rd_ptr <= '0;
            rxf_count  <= '0;
            // rxf_push_r reset is handled in the I2C state machine always_ff
        end else begin
            // rxf_push_r default clear is handled in the I2C state machine always_ff
            if (rxf_push && !rxf_pop)       rxf_count <= rxf_count + 1;
            else if (!rxf_push && rxf_pop)  rxf_count <= rxf_count - 1;
            if (rxf_push) begin
                rxf_mem[rxf_wr_ptr] <= rx_data;
                rxf_wr_ptr          <= rxf_wr_ptr + 1;
            end
            if (rxf_pop) rxf_rd_ptr <= rxf_rd_ptr + 1;
        end
    end

    // ========================================================================
    // Interrupt
    // ========================================================================
    logic [2:0] ie_r;
    logic        stop_done_r;  // pulses 1 when STOP completes
    logic [2:0] is_wire;
    assign is_wire[0] = !rxf_empty;
    assign is_wire[1] = txf_empty;
    assign is_wire[2] = stop_done_r;
    assign irq = |(ie_r & is_wire);

    // Control register fields
    logic        i2c_enable;
    logic        start_cmd;
    logic        stop_cmd;
    logic        read_cmd;
    logic        ack_cmd;

    // Clock divider
    logic [15:0] clk_div;
    logic [15:0] clk_counter;
    logic        scl_tick;

    // TX state machine signals fed from FIFO or ctrl read trigger
    logic [7:0]  tx_data;
    logic        tx_valid;
    logic        ctrl_read_trigger;  // 1-cycle trigger for READ from CTRL write

    // TX FIFO pop: state machine idle and FIFO has data (for WRITE ops)
    assign txf_pop  = (state == IDLE) && !txf_empty && !start_cmd && !ctrl_read_trigger && i2c_enable;
    assign txf_push = axi_awvalid && axi_wvalid && (axi_awaddr[15:0] == TX_OFFSET) && !txf_full && axi_wstrb[0];
    assign tx_valid = ctrl_read_trigger || txf_pop;
    assign tx_data  = txf_mem[txf_rd_ptr];

    // RX FIFO pop: AXI read of RX_OFFSET
    assign rxf_pop  = axi_arvalid && (axi_araddr[15:0] == RX_OFFSET) && !rxf_empty;

    // Status flags
    logic        busy;
    logic        ack_received;

    logic [3:0]  bit_counter;
    logic [7:0]  shift_reg;
    logic [1:0]  scl_phase;  // 0=low, 1=rising, 2=high, 3=falling
    // rx_data: declared earlier (forward declaration before RX FIFO section)

    // ========================================================================
    // AXI4-Lite Interface - Always ready for register access
    // ========================================================================
    assign axi_awready = 1'b1;
    assign axi_wready  = 1'b1;

    // Write transaction
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i2c_enable         <= 1'b0;
            start_cmd          <= 1'b0;
            stop_cmd           <= 1'b0;
            read_cmd           <= 1'b0;
            ack_cmd            <= 1'b0;
            clk_div            <= 16'd249;  // Default: 100kHz at 100MHz system clock
            ctrl_read_trigger  <= 1'b0;
            ie_r               <= 3'b000;
            axi_bvalid         <= 1'b0;
            axi_bresp          <= 2'b00;
        end else begin
            // Auto-clear command bits
            start_cmd         <= 1'b0;
            stop_cmd          <= 1'b0;
            ctrl_read_trigger <= 1'b0;

            if (axi_bvalid && axi_bready)
                axi_bvalid <= 1'b0;

            if (axi_awvalid && axi_wvalid) begin
                case (axi_awaddr[15:0])
                    CTRL_OFFSET: begin
                        if (axi_wstrb[0]) begin
                            i2c_enable <= axi_wdata[0];
                            start_cmd  <= axi_wdata[1];
                            stop_cmd   <= axi_wdata[2];
                            read_cmd   <= axi_wdata[3];
                            ack_cmd    <= axi_wdata[4];
                            // Trigger READ operation directly (not through TX FIFO)
                            if (axi_wdata[3] && !busy && i2c_enable)
                                ctrl_read_trigger <= 1'b1;
                            `DEBUG2(`DBG_GRP_I2C, ("CTRL write: data=0x%02h, enable=%b, start=%b, stop=%b",
                                   axi_wdata[7:0], axi_wdata[0], axi_wdata[1], axi_wdata[2]));
                        end
                    end
                    DIV_OFFSET: begin
                        if (axi_wstrb[0]) clk_div[7:0]  <= axi_wdata[7:0];
                        if (axi_wstrb[1]) clk_div[15:8] <= axi_wdata[15:8];
                    end
                    IE_OFFSET: if (axi_wstrb[0]) ie_r <= axi_wdata[2:0];
                    // TX_OFFSET push is handled combinationally via txf_push
                    default: ;
                endcase
                axi_bvalid <= 1'b1;
                axi_bresp  <= wr_addr_valid ? 2'b00 : 2'b10;  // OKAY or SLVERR
            end
        end
    end

    // ========================================================================
    // AXI Read Channel
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
                axi_rresp  <= rd_addr_valid ? 2'b00 : 2'b10;  // OKAY or SLVERR
                case (axi_araddr[15:0])
                    CTRL_OFFSET: axi_rdata <= {27'h0, ack_cmd, read_cmd, stop_cmd, start_cmd, i2c_enable};
                    DIV_OFFSET:  axi_rdata <= {16'h0, clk_div};
                    TX_OFFSET:   axi_rdata <= txf_empty ? 32'h0 : {24'h0, txf_mem[txf_rd_ptr]};
                    RX_OFFSET:   axi_rdata <= {24'h0, rxf_mem[rxf_rd_ptr]};  // pop via rxf_pop assign
                    STAT_OFFSET: axi_rdata <= {28'h0, ack_received,
                                               !rxf_empty,   // [2] rx_valid compat
                                               !txf_full,    // [1] tx_not_full
                                               busy};
                    IE_OFFSET:   axi_rdata <= {29'h0, ie_r};
                    IS_OFFSET:   axi_rdata <= {29'h0, is_wire};
                    CAP_OFFSET:  axi_rdata <= CAPABILITY_REG;  // CAPABILITY (RO)
                    default:     axi_rdata <= 32'h0;
                endcase
            end else if (axi_rvalid && axi_rready) begin
                axi_rvalid <= 1'b0;
            end
        end
    end

    // ========================================================================
    // I2C Clock Generation
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_counter <= 16'h0;
            scl_tick    <= 1'b0;
        end else begin
            scl_tick <= 1'b0;
            if (busy) begin
                if (clk_counter >= clk_div) begin
                    clk_counter <= 16'h0;
                    scl_tick    <= 1'b1;
                end else begin
                    clk_counter <= clk_counter + 1;
                end
            end else begin
                clk_counter <= 16'h0;
            end
        end
    end

    // ========================================================================
    // I2C State Machine
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            busy         <= 1'b0;
            bit_counter  <= 4'h0;
            shift_reg    <= 8'h0;
            scl_phase    <= 2'b00;
            rx_data      <= 8'h0;
            ack_received <= 1'b0;
            stop_done_r  <= 1'b0;
            rxf_push_r   <= 1'b0;
            i2c_scl_o    <= 1'b0;
            i2c_scl_oe   <= 1'b1;  // Tristate (high-Z)
            i2c_sda_o    <= 1'b0;
            i2c_sda_oe   <= 1'b1;  // Tristate (high-Z)
        end else begin
            stop_done_r <= 1'b0;  // auto-clear each cycle
            rxf_push_r  <= 1'b0;  // default clear each cycle (set below when byte captured)
            case (state)
                IDLE: begin
                    busy        <= 1'b0;
                    scl_phase   <= 2'b00;
                    bit_counter <= 4'h0;

                    if (start_cmd && i2c_enable) begin
                        state    <= START;
                        busy     <= 1'b1;
                        `DEBUG2(`DBG_GRP_I2C, ("START command"));
                    end else if (tx_valid && i2c_enable) begin
                        shift_reg <= tx_data;
                        state     <= read_cmd ? READ : WRITE;
                        busy      <= 1'b1;
                        // tx_valid is combinational; txf_pop or ctrl_read_trigger auto-clears
                        `DEBUG2(`DBG_GRP_I2C, ("TX byte 0x%02h, mode=%s", tx_data, read_cmd ? "READ" : "WRITE"));
                    end else if (stop_cmd && i2c_enable) begin
                        state    <= STOP;
                        busy     <= 1'b1;
                        `DEBUG2(`DBG_GRP_I2C, ("STOP command"));
                    end
                end

                START: begin
                    if (scl_tick) begin
                        case (scl_phase)
                            2'b00: begin  // Step 1: Ensure SDA is high (release)
                                i2c_sda_oe <= 1'b1;  // Release SDA
                                scl_phase <= 2'b01;
                            end
                            2'b01: begin  // Step 2: Release SCL high
                                i2c_scl_oe <= 1'b1;  // Release SCL (high)
                                if (i2c_scl_i)        // Wait if slave is clock-stretching
                                    scl_phase <= 2'b10;
                            end
                            2'b10: begin  // Step 3: Pull SDA low (START condition)
                                i2c_sda_o <= 1'b0;
                                i2c_sda_oe <= 1'b0;
                                scl_phase <= 2'b11;
                            end
                            2'b11: begin  // Step 4: Pull SCL low
                                i2c_scl_o <= 1'b0;
                                i2c_scl_oe <= 1'b0;
                                scl_phase <= 2'b00;
                                state     <= IDLE;
                            end
                            default: ;
                        endcase
                    end
                end

                WRITE: begin
                    if (scl_tick) begin
                        case (scl_phase)
                            2'b00: begin  // SCL low - set SDA
                                i2c_scl_o   <= 1'b0;
                                i2c_scl_oe   <= 1'b0;
                                i2c_sda_o   <= shift_reg[7];
                                i2c_sda_oe   <= shift_reg[7];  // 0=drive low, 1=release high
                                scl_phase   <= 2'b01;
                            end
                            2'b01: begin  // SCL high - data stable
                                i2c_scl_oe <= 1'b1;
                                if (i2c_scl_i)  // Wait if slave is clock-stretching
                                    scl_phase <= 2'b10;
                            end
                            2'b10: begin  // SCL high continued
                                scl_phase <= 2'b11;
                            end
                            2'b11: begin  // SCL falling - shift
                                shift_reg   <= {shift_reg[6:0], 1'b0};
                                bit_counter <= bit_counter + 1;
                                scl_phase   <= 2'b00;
                                if (bit_counter >= 4'd7) begin
                                    bit_counter <= 4'h0;
                                    state       <= ACK_CHECK;
                                end
                            end
                            default: ;
                        endcase
                    end
                end

                READ: begin
                    if (scl_tick) begin
                        case (scl_phase)
                            2'b00: begin  // SCL low - release SDA
                                i2c_scl_o <= 1'b0;
                                i2c_scl_oe <= 1'b0;
                                i2c_sda_oe <= 1'b1;  // Release for slave to drive
                                scl_phase <= 2'b01;
                            end
                            2'b01: begin  // SCL high - sample SDA
                                i2c_scl_oe <= 1'b1;
                                if (i2c_scl_i)  // Wait if slave is clock-stretching
                                    scl_phase <= 2'b10;
                            end
                            2'b10: begin  // SCL high - sample data
                                shift_reg <= {shift_reg[6:0], i2c_sda_i};
                                scl_phase <= 2'b11;
                            end
                            2'b11: begin  // SCL falling
                                bit_counter <= bit_counter + 1;
                                scl_phase   <= 2'b00;
                                if (bit_counter >= 4'd7) begin
                                    bit_counter <= 4'h0;
                                    rx_data     <= shift_reg;  // capture byte
                                    rxf_push_r  <= 1'b1;       // push to RX FIFO next cycle
                                    state       <= ACK_SEND;
                                    `DEBUG2(`DBG_GRP_I2C, ("READ byte captured: 0x%02h", shift_reg));
                                end
                            end
                            default: ;
                        endcase
                    end
                end

                ACK_CHECK: begin  // Check ACK from slave
                    if (scl_tick) begin
                        case (scl_phase)
                            2'b00: begin  // SCL low - release SDA for slave to drive
                                i2c_scl_o <= 1'b0;
                                i2c_scl_oe <= 1'b0;
                                i2c_sda_oe <= 1'b1;
                                scl_phase <= 2'b01;
                            end
                            2'b01: begin  // SCL high - slave drives ACK
                                i2c_scl_oe <= 1'b1;
                                if (i2c_scl_i)  // Wait if slave is clock-stretching
                                    scl_phase <= 2'b10;
                            end
                            2'b10: begin  // SCL high - sample ACK
                                ack_received <= ~i2c_sda_i;  // ACK=0, NACK=1
                                scl_phase    <= 2'b11;
                                `DEBUG2(`DBG_GRP_I2C, ("ACK_CHECK: sda_i=%b, ack=%b", i2c_sda_i, ~i2c_sda_i));
                            end
                            2'b11: begin  // SCL falling - lower SCL before returning to IDLE
                                i2c_scl_o <= 1'b0;
                                i2c_scl_oe <= 1'b0;  // Pull SCL low
                                scl_phase <= 2'b00;
                                state     <= IDLE;
                            end
                            default: ;
                        endcase
                    end
                end

                ACK_SEND: begin  // Send ACK/NACK to slave
                    if (scl_tick) begin
                        case (scl_phase)
                            2'b00: begin  // SCL low - set ACK/NACK
                                i2c_scl_o <= 1'b0;
                                i2c_scl_oe <= 1'b0;
                                i2c_sda_o <= ack_cmd;  // 0=ACK, 1=NACK
                                i2c_sda_oe <= ack_cmd;
                                scl_phase <= 2'b01;
                            end
                            2'b01: begin  // SCL high
                                i2c_scl_oe <= 1'b1;
                                if (i2c_scl_i)  // Wait if slave is clock-stretching
                                    scl_phase <= 2'b10;
                            end
                            2'b10: begin  // SCL high continued
                                scl_phase <= 2'b11;
                            end
                            2'b11: begin  // SCL falling - lower SCL before returning to IDLE
                                i2c_scl_o <= 1'b0;
                                i2c_scl_oe <= 1'b0;  // Pull SCL low
                                scl_phase <= 2'b00;
                                state     <= IDLE;
                            end
                            default: ;
                        endcase
                    end
                end

                STOP: begin
                    if (scl_tick) begin
                        case (scl_phase)
                            2'b00: begin  // SDA low, SCL low
                                i2c_sda_o  <= 1'b0;
                                i2c_sda_oe <= 1'b0;
                                i2c_scl_o  <= 1'b0;
                                i2c_scl_oe <= 1'b0;
                                scl_phase  <= 2'b01;
                            end
                            2'b01: begin  // SCL high
                                i2c_scl_oe <= 1'b1;
                                if (i2c_scl_i)  // Wait if slave is clock-stretching
                                    scl_phase  <= 2'b10;
                            end
                            2'b10: begin  // SDA high (STOP condition)
                                i2c_sda_oe  <= 1'b1;
                                stop_done_r <= 1'b1;  // signal IS[2]
                                scl_phase   <= 2'b00;
                                state       <= IDLE;
                            end
                            default: scl_phase <= 2'b00;
                        endcase
                    end
                end

                default: begin
                    // Should not reach here
                    state <= IDLE;
                end
            endcase
        end
    end

`ifndef SYNTHESIS
    // Lint sink (debug only): wstrb[3:2] unused (no register maps to bytes 2-3);
    // upper address/data bits decoded by crossbar, not this module.
    logic _unused_ok;
    assign _unused_ok = &{1'b0, axi_wstrb[3:2], axi_awaddr[31:16], axi_wdata[31:16],
                                axi_araddr[31:16]};
`endif // SYNTHESIS

endmodule


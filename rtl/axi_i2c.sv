// ============================================================================
// File: axi_i2c.sv
// Project: RV32 RISC-V Processor
// Description: AXI4-Lite I2C Master Controller
//
// Provides memory-mapped I2C master interface for interfacing with I2C devices.
// Supports standard (100kHz) and fast (400kHz) I2C modes.
//
// Register Map (relative to base 0x0203_0000):
//   0x00: Control Register
//         [0]: Enable (1=enable I2C, 0=disable)
//         [1]: Start (write 1 to send START condition)
//         [2]: Stop (write 1 to send STOP condition)
//         [3]: Read (1=read from slave, 0=write to slave)
//         [4]: ACK (for read: 0=ACK, 1=NACK to end read)
//   0x04: Clock Divider (SCL period = CLK / (4 * (DIV + 1)))
//   0x08: TX Data Register (slave address or data byte to transmit)
//   0x0C: RX Data Register (received data byte)
//   0x10: Status Register
//         [0]: Busy (1=transfer in progress)
//         [1]: TX Ready (1=can accept new data)
//         [2]: RX Valid (1=received data available)
//         [3]: ACK Received (1=slave ACKed, 0=slave NACKed)
//
// Features:
//   - Configurable clock divider for SCL generation
//   - Standard (100kHz) and Fast (400kHz) mode support
//   - 7-bit addressing
//   - START/STOP condition generation
//   - ACK/NACK detection and generation
//   - Status flags for polling-based operation
// ============================================================================

module axi_i2c #(
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

    // I2C pins (open-drain, requires external pull-ups)
    output logic        i2c_scl_o,    // SCL output
    input  logic        i2c_scl_i,    // SCL input (for clock stretching)
    output logic        i2c_scl_t,    // SCL tristate (1=output disabled/high-Z)
    output logic        i2c_sda_o,    // SDA output
    input  logic        i2c_sda_i,    // SDA input
    output logic        i2c_sda_t     // SDA tristate (1=output disabled/high-Z)
);

    import rv32_pkg::*;

    // Register offsets
    localparam CTRL_OFFSET  = 16'h0000;
    localparam DIV_OFFSET   = 16'h0004;
    localparam TX_OFFSET    = 16'h0008;
    localparam RX_OFFSET    = 16'h000C;
    localparam STAT_OFFSET  = 16'h0010;

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

    // Data registers
    logic [7:0]  tx_data;
    logic [7:0]  rx_data;
    logic        tx_valid;

    // Status flags
    logic        busy;
    logic        tx_ready;
    logic        rx_valid;
    logic        ack_received;

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
    logic [3:0]  bit_counter;
    logic [7:0]  shift_reg;
    logic [1:0]  scl_phase;  // 0=low, 1=rising, 2=high, 3=falling

    // ========================================================================
    // AXI4-Lite Interface - Always ready for register access
    // ========================================================================
    assign axi_awready = 1'b1;
    assign axi_wready = 1'b1;

    // Write transaction
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i2c_enable  <= 1'b0;
            start_cmd   <= 1'b0;
            stop_cmd    <= 1'b0;
            read_cmd    <= 1'b0;
            ack_cmd     <= 1'b0;
            clk_div     <= 16'd249;  // Default: 100kHz at 100MHz system clock
            tx_valid    <= 1'b0;
        end else begin
            // Auto-clear command bits
            start_cmd <= 1'b0;
            stop_cmd  <= 1'b0;
            tx_valid  <= 1'b0;

            if (axi_awvalid && axi_wvalid) begin
                case (axi_awaddr[15:0])
                    CTRL_OFFSET: begin
                        i2c_enable <= axi_wdata[0];
                        start_cmd  <= axi_wdata[1];
                        stop_cmd   <= axi_wdata[2];
                        read_cmd   <= axi_wdata[3];
                        ack_cmd    <= axi_wdata[4];
                        `DBG2(("[I2C] CTRL write: data=0x%02h, enable=%b, start=%b, stop=%b",
                               axi_wdata[7:0], axi_wdata[0], axi_wdata[1], axi_wdata[2]));
                    end
                    DIV_OFFSET: begin
                        clk_div <= axi_wdata[15:0];
                    end
                    TX_OFFSET: begin
                        if (!busy && i2c_enable) begin
                            tx_data  <= axi_wdata[7:0];
                            tx_valid <= 1'b1;
                            `DBG2(("[I2C] TX write accepted: data=0x%02h, busy=%b, enable=%b",
                                   axi_wdata[7:0], busy, i2c_enable));
                        end else begin
                            `DBG2(("[I2C] TX write REJECTED: data=0x%02h, busy=%b, enable=%b",
                                   axi_wdata[7:0], busy, i2c_enable));
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
    // AXI Read Channel
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
                        axi_rdata <= {27'h0, ack_cmd, read_cmd, stop_cmd, start_cmd, i2c_enable};
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
                        axi_rdata <= {28'h0, ack_received, rx_valid, tx_ready, busy};
                    end
                    default: begin
                        axi_rdata <= 32'h0;
                    end
                endcase
            end else if (axi_rvalid && axi_rready) begin
                axi_rvalid <= 1'b0;
            end

            // Set rx_valid when byte received
            if (state == ACK_SEND && scl_phase == 2'b11) begin
                rx_valid <= 1'b1;
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
            tx_ready     <= 1'b1;
            bit_counter  <= 4'h0;
            shift_reg    <= 8'h0;
            scl_phase    <= 2'b00;
            rx_data      <= 8'h0;
            ack_received <= 1'b0;
            i2c_scl_o    <= 1'b0;
            i2c_scl_t    <= 1'b1;  // Tristate (high-Z)
            i2c_sda_o    <= 1'b0;
            i2c_sda_t    <= 1'b1;  // Tristate (high-Z)
        end else begin
            case (state)
                IDLE: begin
                    tx_ready    <= 1'b1;
                    busy        <= 1'b0;
                    i2c_scl_t   <= 1'b1;  // Release SCL
                    i2c_sda_t   <= 1'b1;  // Release SDA
                    scl_phase   <= 2'b00;
                    bit_counter <= 4'h0;

                    if (start_cmd && i2c_enable) begin
                        state    <= START;
                        busy     <= 1'b1;
                        tx_ready <= 1'b0;
                        `DBG2(("[I2C] START command"));
                    end else if (tx_valid && i2c_enable) begin
                        shift_reg <= tx_data;
                        state     <= read_cmd ? READ : WRITE;
                        busy      <= 1'b1;
                        tx_ready  <= 1'b0;
                        `DBG2(("[I2C] TX byte 0x%02h, mode=%s", tx_data, read_cmd ? "READ" : "WRITE"));
                    end else if (stop_cmd && i2c_enable) begin
                        state    <= STOP;
                        busy     <= 1'b1;
                        `DBG2(("[I2C] STOP command"));
                    end
                end

                START: begin
                    if (scl_tick) begin
                        case (scl_phase)
                            2'b00: begin  // SDA high, SCL high
                                i2c_sda_t <= 1'b1;
                                i2c_scl_t <= 1'b1;
                                scl_phase <= 2'b01;
                            end
                            2'b01: begin  // SDA low (START condition)
                                i2c_sda_o <= 1'b0;
                                i2c_sda_t <= 1'b0;
                                scl_phase <= 2'b10;
                            end
                            2'b10: begin  // SCL low
                                i2c_scl_o <= 1'b0;
                                i2c_scl_t <= 1'b0;
                                scl_phase <= 2'b00;
                                state     <= IDLE;
                            end
                            default: begin
                                scl_phase <= 2'b00;
                            end
                        endcase
                    end
                end

                WRITE: begin
                    if (scl_tick) begin
                        case (scl_phase)
                            2'b00: begin  // SCL low - set SDA
                                i2c_scl_o   <= 1'b0;
                                i2c_scl_t   <= 1'b0;
                                i2c_sda_o   <= shift_reg[7];
                                i2c_sda_t   <= shift_reg[7];  // 0=drive low, 1=release high
                                scl_phase   <= 2'b01;
                            end
                            2'b01: begin  // SCL high - data stable
                                i2c_scl_t <= 1'b1;
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
                        endcase
                    end
                end

                READ: begin
                    if (scl_tick) begin
                        case (scl_phase)
                            2'b00: begin  // SCL low - release SDA
                                i2c_scl_o <= 1'b0;
                                i2c_scl_t <= 1'b0;
                                i2c_sda_t <= 1'b1;  // Release for slave to drive
                                scl_phase <= 2'b01;
                            end
                            2'b01: begin  // SCL high - sample SDA
                                i2c_scl_t <= 1'b1;
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
                                    rx_data     <= {shift_reg[6:0], i2c_sda_i};
                                    state       <= ACK_SEND;
                                end
                            end
                        endcase
                    end
                end

                ACK_CHECK: begin  // Check ACK from slave
                    if (scl_tick) begin
                        case (scl_phase)
                            2'b00: begin  // SCL low - release SDA
                                i2c_scl_o <= 1'b0;
                                i2c_scl_t <= 1'b0;
                                i2c_sda_t <= 1'b1;
                                scl_phase <= 2'b01;
                            end
                            2'b01: begin  // SCL high - sample ACK
                                i2c_scl_t <= 1'b1;
                                scl_phase <= 2'b10;
                            end
                            2'b10: begin  // SCL high - read ACK
                                ack_received <= ~i2c_sda_i;  // ACK=0, NACK=1
                                scl_phase    <= 2'b11;
                                `DBG2(("[I2C] ACK_CHECK: sda_i=%b, ack=%b", i2c_sda_i, ~i2c_sda_i));
                            end
                            2'b11: begin  // SCL falling
                                scl_phase <= 2'b00;
                                state     <= IDLE;
                            end
                        endcase
                    end
                end

                ACK_SEND: begin  // Send ACK/NACK to slave
                    if (scl_tick) begin
                        case (scl_phase)
                            2'b00: begin  // SCL low - set ACK/NACK
                                i2c_scl_o <= 1'b0;
                                i2c_scl_t <= 1'b0;
                                i2c_sda_o <= ack_cmd;  // 0=ACK, 1=NACK
                                i2c_sda_t <= ack_cmd;
                                scl_phase <= 2'b01;
                            end
                            2'b01: begin  // SCL high
                                i2c_scl_t <= 1'b1;
                                scl_phase <= 2'b10;
                            end
                            2'b10: begin  // SCL high continued
                                scl_phase <= 2'b11;
                            end
                            2'b11: begin  // SCL falling
                                scl_phase <= 2'b00;
                                state     <= IDLE;
                            end
                        endcase
                    end
                end

                STOP: begin
                    if (scl_tick) begin
                        case (scl_phase)
                            2'b00: begin  // SDA low, SCL low
                                i2c_sda_o <= 1'b0;
                                i2c_sda_t <= 1'b0;
                                i2c_scl_o <= 1'b0;
                                i2c_scl_t <= 1'b0;
                                scl_phase <= 2'b01;
                            end
                            2'b01: begin  // SCL high
                                i2c_scl_t <= 1'b1;
                                scl_phase <= 2'b10;
                            end
                            2'b10: begin  // SDA high (STOP condition)
                                i2c_sda_t <= 1'b1;
                                scl_phase <= 2'b00;
                                state     <= IDLE;
                            end
                            default: begin
                                scl_phase <= 2'b00;
                            end
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

endmodule

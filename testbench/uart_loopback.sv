// ============================================================================
// File: uart_loopback.sv
// Project: RV32 RISC-V Processor
// Description: UART Loopback Target for Testbench
//
// Echoes back any received character on UART TX.
// Useful for testing UART transmit and receive functionality.
// ============================================================================

module uart_loopback #(
    parameter CLKS_PER_BIT = 4  // Should match UART baud rate
)(
    input  logic clk,
    input  logic rst_n,
    input  logic rx,
    output logic tx
);

    // RX state
    typedef enum logic [2:0] {
        RX_IDLE,
        RX_START,
        RX_DATA,
        RX_STOP
    } rx_state_t;

    rx_state_t rx_state;
    logic [7:0] rx_data;
    logic [2:0] rx_bit_idx;
    logic [15:0] rx_clk_count;
    logic rx_valid;

    // TX state
    typedef enum logic [2:0] {
        TX_IDLE,
        TX_START,
        TX_DATA,
        TX_STOP
    } tx_state_t;

    tx_state_t tx_state;
    logic [7:0] tx_data;
    logic [2:0] tx_bit_idx;
    logic [15:0] tx_clk_count;

    // RX logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state <= RX_IDLE;
            rx_data <= 8'h0;
            rx_bit_idx <= 3'h0;
            rx_clk_count <= 16'h0;
            rx_valid <= 1'b0;
        end else begin
            rx_valid <= 1'b0;

            case (rx_state)
                RX_IDLE: begin
                    rx_clk_count <= 16'h0;
                    rx_bit_idx <= 3'h0;
                    if (rx == 1'b0) begin  // Start bit
                        rx_state <= RX_START;
                    end
                end

                RX_START: begin
                    if (rx_clk_count < (CLKS_PER_BIT - 1) / 2) begin
                        rx_clk_count <= rx_clk_count + 1;
                    end else begin
                        rx_clk_count <= 16'h0;
                        rx_state <= RX_DATA;
                    end
                end

                RX_DATA: begin
                    if (rx_clk_count < (CLKS_PER_BIT - 1)) begin
                        rx_clk_count <= rx_clk_count + 1;
                    end else begin
                        rx_clk_count <= 16'h0;
                        rx_data[rx_bit_idx] <= rx;
                        if (rx_bit_idx < 7) begin
                            rx_bit_idx <= rx_bit_idx + 1;
                        end else begin
                            rx_bit_idx <= 3'h0;
                            rx_state <= RX_STOP;
                        end
                    end
                end

                RX_STOP: begin
                    if (rx_clk_count < (CLKS_PER_BIT - 1)) begin
                        rx_clk_count <= rx_clk_count + 1;
                    end else begin
                        rx_clk_count <= 16'h0;
                        rx_valid <= 1'b1;
                        rx_state <= RX_IDLE;
                        // Echo printable characters and newlines
                        if ((rx_data >= 32 && rx_data < 127) || rx_data == 10 || rx_data == 13) begin
                            $write("%c", rx_data);
                            $fflush();
                        end
                    end
                end

                default: rx_state <= RX_IDLE;
            endcase
        end
    end

    // TX logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state <= TX_IDLE;
            tx <= 1'b1;
            tx_data <= 8'h0;
            tx_bit_idx <= 3'h0;
            tx_clk_count <= 16'h0;
        end else begin
            case (tx_state)
                TX_IDLE: begin
                    tx <= 1'b1;
                    tx_clk_count <= 16'h0;
                    tx_bit_idx <= 3'h0;
                    if (rx_valid) begin
                        tx_data <= rx_data;
                        tx_state <= TX_START;
                    end
                end

                TX_START: begin
                    tx <= 1'b0;  // Start bit
                    if (tx_clk_count < (CLKS_PER_BIT - 1)) begin
                        tx_clk_count <= tx_clk_count + 1;
                    end else begin
                        tx_clk_count <= 16'h0;
                        tx_state <= TX_DATA;
                    end
                end

                TX_DATA: begin
                    tx <= tx_data[tx_bit_idx];
                    if (tx_clk_count < (CLKS_PER_BIT - 1)) begin
                        tx_clk_count <= tx_clk_count + 1;
                    end else begin
                        tx_clk_count <= 16'h0;
                        if (tx_bit_idx < 7) begin
                            tx_bit_idx <= tx_bit_idx + 1;
                        end else begin
                            tx_bit_idx <= 3'h0;
                            tx_state <= TX_STOP;
                        end
                    end
                end

                TX_STOP: begin
                    tx <= 1'b1;  // Stop bit
                    if (tx_clk_count < (CLKS_PER_BIT - 1)) begin
                        tx_clk_count <= tx_clk_count + 1;
                    end else begin
                        tx_clk_count <= 16'h0;
                        tx_state <= TX_IDLE;
                    end
                end

                default: tx_state <= TX_IDLE;
            endcase
        end
    end

endmodule

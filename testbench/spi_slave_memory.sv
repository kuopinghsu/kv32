// ============================================================================
// File: spi_slave_memory.sv
// Project: KV32 RISC-V Processor
// Description: SPI Slave Memory Target for Testbench
//
// 256-byte memory with SPI slave interface for testing SPI master.
// Protocol:
//   - First byte: Command (0x02=Write, 0x03=Read)
//   - Second byte: Address (0x00-0xFF)
//   - Data bytes: Write data (for write) or read data (for read)
//
// Supports SPI Mode 0 (CPOL=0, CPHA=0) by default.
// ============================================================================

module spi_slave_memory (
    input  logic       rst_n,
    input  logic       sclk,
    input  logic       cs_n,
    input  logic       mosi,
    output logic       miso
);

    // Memory
    logic [7:0] memory [0:255];

    // SPI shift register
    logic [7:0] shift_reg;
    logic [2:0] bit_count;

    // Command and address
    logic [7:0] command;
    logic [7:0] address;
    logic [1:0] byte_count;  // 0=cmd, 1=addr, 2+=data

    // State
    typedef enum logic [1:0] {
        IDLE,
        CMD,
        ADDR,
        DATA
    } state_t;

    state_t state;

    // Initialize memory with test pattern
    initial begin
        for (int i = 0; i < 256; i++) begin
            memory[i] = i[7:0];
        end
    end

    // SPI slave logic (samples on rising edge of SCLK for Mode 0)
    // State is reset asynchronously on cs_n to ensure clean start per transaction.
    always_ff @(posedge sclk or posedge cs_n or negedge rst_n) begin
        if (!rst_n) begin
            shift_reg  <= 8'h0;
            bit_count  <= 3'h0;
            command    <= 8'h0;
            address    <= 8'h0;
            byte_count <= 2'h0;
            state      <= IDLE;
        end else if (cs_n) begin
            // Chip deselected - reset for next transaction
            shift_reg  <= 8'h0;
            bit_count  <= 3'h0;
            byte_count <= 2'h0;
            state      <= IDLE;
        end else begin
            // Shift in MOSI bit
            shift_reg <= {shift_reg[6:0], mosi};
            bit_count <= bit_count + 1;

            if (bit_count == 7) begin
                // Full byte received
                bit_count <= 3'h0;

                case (state)
                    IDLE, CMD: begin
                        command <= {shift_reg[6:0], mosi};
                        state <= ADDR;
                    end

                    ADDR: begin
                        address <= {shift_reg[6:0], mosi};
                        state <= DATA;
                        // Prepare data for read command
                        if (command == 8'h03) begin
                            shift_reg <= memory[{shift_reg[6:0], mosi}];
                        end
                    end

                    DATA: begin
                        if (command == 8'h02) begin
                            // Write command
                            memory[address] <= {shift_reg[6:0], mosi};
                            address <= address + 1;
                        end else if (command == 8'h03) begin
                            // Read command - prepare next byte
                            address <= address + 1;
                            shift_reg <= memory[address + 1];
                        end
                    end

                    default: state <= IDLE;
                endcase
            end
        end
    end

    // MISO output: combinatorial from shift_reg MSB (no negedge delay needed)
    assign miso = cs_n ? 1'b0 : shift_reg[7];

endmodule

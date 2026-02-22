// ============================================================================
// File: i2c_slave_eeprom.sv
// Project: RV32 RISC-V Processor
// Description: I2C EEPROM Slave Target for Testbench
//
// Emulates 24C02-style I2C EEPROM with 256 bytes for testing I2C master.
// Device address: 0x50 (7-bit address)
// Memory: 256 bytes (addressable 0x00-0xFF)
//
// Protocol:
//   Write: START + ADDR(W) + ACK + MEM_ADDR + ACK + DATA + ACK + ... + STOP
//   Read:  START + ADDR(W) + ACK + MEM_ADDR + ACK +
//          START + ADDR(R) + ACK + DATA + ACK/NACK + ... + STOP
// ============================================================================

module i2c_slave_eeprom #(
    parameter DEVICE_ADDR = 7'h50  // 7-bit I2C address
)(
    input  logic rst_n,
    input  logic scl,
    input  logic sda_in,
    output logic sda_out,
    output logic sda_oe    // Output enable (1=drive low, 0=release/high-Z)
);

    // Memory
    logic [7:0] memory [0:255];

    // I2C state machine
    typedef enum logic [3:0] {
        IDLE,
        START,
        ADDR,
        ACK_ADDR,
        REG_ADDR,
        ACK_REG,
        WRITE_DATA,
        ACK_WRITE,
        READ_DATA,
        ACK_READ,
        STOP
    } state_t;

    state_t state, next_state;

    // Registers
    logic [7:0] shift_reg;
    logic [2:0] bit_count;
    logic [7:0] mem_addr;
    logic       rw_bit;  // 0=write, 1=read
    logic       addr_match;

    // Edge detection
    logic scl_prev, sda_prev;
    logic scl_rising, scl_falling;
    logic sda_rising, sda_falling;

    // Initialize memory with test pattern
    initial begin
        for (int i = 0; i < 256; i++) begin
            memory[i] = 8'hA0 + i[7:0];  // Different pattern from SPI
        end
    end

    // Edge detection
    always_ff @(posedge scl or negedge rst_n) begin
        if (!rst_n) begin
            scl_prev <= 1'b1;
            sda_prev <= 1'b1;
        end else begin
            scl_prev <= scl;
            sda_prev <= sda_in;
        end
    end

    assign scl_rising = scl && !scl_prev;
    assign scl_falling = !scl && scl_prev;
    assign sda_rising = sda_in && !sda_prev;
    assign sda_falling = !sda_in && sda_prev;

    // Detect START and STOP conditions
    logic start_cond, stop_cond;
    assign start_cond = scl && sda_falling;
    assign stop_cond = scl && sda_rising;

    // State machine
    always_ff @(posedge scl or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            shift_reg <= 8'h0;
            bit_count <= 3'h0;
            mem_addr <= 8'h0;
            rw_bit <= 1'b0;
            addr_match <= 1'b0;
            sda_out <= 1'b0;
            sda_oe <= 1'b0;
        end else begin
            if (start_cond) begin
                // START condition detected
                state <= ADDR;
                bit_count <= 3'h0;
                sda_oe <= 1'b0;
`ifdef DEBUG
                $display("[I2C_SLAVE] START condition detected");
`endif
            end else if (stop_cond) begin
                // STOP condition detected
                state <= IDLE;
                sda_oe <= 1'b0;
`ifdef DEBUG
                $display("[I2C_SLAVE] STOP condition detected");
`endif
            end else begin
                case (state)
                    IDLE: begin
                        sda_oe <= 1'b0;
                        bit_count <= 3'h0;
                    end

                    ADDR: begin
                        // Receiving address + R/W bit
                        shift_reg <= {shift_reg[6:0], sda_in};
                        bit_count <= bit_count + 1;
                        if (bit_count == 7) begin
                            // Check if address matches
                            addr_match <= (shift_reg[7:1] == DEVICE_ADDR);
                            rw_bit <= sda_in;
                            state <= ACK_ADDR;
                            bit_count <= 3'h0;
`ifdef DEBUG
                            $display("[I2C_SLAVE] Address received: 0x%02h, match=%b (expected=0x%02h)",
                                     {shift_reg[6:0], sda_in}, (shift_reg[7:1] == DEVICE_ADDR), DEVICE_ADDR);
`endif
                        end
                    end

                    ACK_ADDR: begin
                        if (addr_match) begin
                            sda_out <= 1'b0;  // ACK
                            sda_oe <= 1'b1;
                            if (rw_bit == 1'b0) begin
                                state <= REG_ADDR;  // Write: get register address
                            end else begin
                                state <= READ_DATA;  // Read: send data
                                shift_reg <= memory[mem_addr];
                            end
                        end else begin
                            sda_oe <= 1'b0;  // NACK
                            state <= IDLE;
                        end
                    end

                    REG_ADDR: begin
                        sda_oe <= 1'b0;
                        shift_reg <= {shift_reg[6:0], sda_in};
                        bit_count <= bit_count + 1;
                        if (bit_count == 7) begin
                            mem_addr <= {shift_reg[6:0], sda_in};
                            state <= ACK_REG;
                            bit_count <= 3'h0;
                        end
                    end

                    ACK_REG: begin
                        sda_out <= 1'b0;  // ACK
                        sda_oe <= 1'b1;
                        state <= WRITE_DATA;
                    end

                    WRITE_DATA: begin
                        sda_oe <= 1'b0;
                        shift_reg <= {shift_reg[6:0], sda_in};
                        bit_count <= bit_count + 1;
                        if (bit_count == 7) begin
                            memory[mem_addr] <= {shift_reg[6:0], sda_in};
                            mem_addr <= mem_addr + 1;
                            state <= ACK_WRITE;
                            bit_count <= 3'h0;
                        end
                    end

                    ACK_WRITE: begin
                        sda_out <= 1'b0;  // ACK
                        sda_oe <= 1'b1;
                        state <= WRITE_DATA;  // Continue receiving data
                    end

                    READ_DATA: begin
                        sda_out <= shift_reg[7];
                        sda_oe <= 1'b1;
                        shift_reg <= {shift_reg[6:0], 1'b0};
                        bit_count <= bit_count + 1;
                        if (bit_count == 7) begin
                            state <= ACK_READ;
                            bit_count <= 3'h0;
                        end
                    end

                    ACK_READ: begin
                        sda_oe <= 1'b0;  // Release SDA for master ACK/NACK
                        if (sda_in == 1'b0) begin
                            // Master sent ACK, continue reading
                            mem_addr <= mem_addr + 1;
                            shift_reg <= memory[mem_addr + 1];
                            state <= READ_DATA;
                        end else begin
                            // Master sent NACK, stop reading
                            state <= IDLE;
                        end
                    end

                    default: state <= IDLE;
                endcase
            end
        end
    end

endmodule

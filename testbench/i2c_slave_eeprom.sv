// ============================================================================
// File: i2c_slave_eeprom.sv
// Project: KV32 RISC-V Processor
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
//
// NOTE: Uses system clock (clk) for proper I2C START/STOP detection.
//       START (SDA falls while SCL high) and STOP (SDA rises while SCL high)
//       conditions occur between SCL edges and cannot be detected reliably on
//       posedge SCL alone, so the system clock is used for all sampling.
// ============================================================================

module i2c_slave_eeprom #(
    parameter DEVICE_ADDR    = 7'h50, // 7-bit I2C address
    parameter integer STRETCH_CYCLES = 0  // Clock-stretch duration per ACK (0=disabled)
)(
    input  logic clk,      // System clock for proper edge detection
    input  logic rst_n,
    input  logic scl,
    input  logic sda_in,
    output logic sda_out,
    output logic sda_oe,   // SDA output enable (1=drive low, 0=release/high-Z)
    output logic scl_oe    // SCL output enable: 1=hold SCL low (clock-stretch)
);

    // Memory
    logic [7:0] memory [0:255];

    // I2C state machine
    typedef enum logic [3:0] {
        IDLE,
        RECV_ADDR,   // Receiving 8 bits: 7-bit address + R/W bit
        ACK_ADDR,    // Sending ACK/NACK for address
        RECV_REG,    // Receiving 8-bit memory address
        ACK_REG,     // Sending ACK for register address
        WRITE_DATA,  // Receiving data byte(s)
        ACK_WRITE,   // Sending ACK for written data
        READ_DATA,   // Sending data byte(s) to master
        ACK_READ     // Waiting for master's ACK/NACK after a read byte
    } state_t;

    state_t state;

    // Shift register and counters
    logic [7:0] shift_reg;
    logic [2:0] bit_count;
    logic [7:0] mem_addr;
    logic       rw_bit;
    logic       addr_match;
    logic       rd_addr_acked;  // Set after scl_rising in ACK_ADDR for reads

    // Clock-stretch state
    logic        stretching;    // 1 while SCL is being held low
    logic [15:0] stretch_cnt;   // Countdown timer
    assign scl_oe = stretching;

    // Previous SCL/SDA values sampled on every system clock for edge detection
    logic scl_prev, sda_prev;

    // Edge / condition detection (combinational)
    wire scl_rising  =  scl    && !scl_prev;
    wire scl_falling = !scl    &&  scl_prev;
    // START: SDA falls while SCL has been (and still is) high
    wire start_cond  = !sda_in &&  sda_prev &&  scl && scl_prev;
    // STOP:  SDA rises while SCL has been (and still is) high
    wire stop_cond   =  sda_in && !sda_prev &&  scl && scl_prev;

    // Initialize memory with test pattern
    initial begin
        for (int i = 0; i < 256; i++) begin
            memory[i] = 8'hA0 + i[7:0];
        end
    end

    // Sample SCL/SDA on every system clock for edge detection
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_prev <= 1'b1;
            sda_prev <= 1'b1;
        end else begin
            scl_prev <= scl;
            sda_prev <= sda_in;
        end
    end

    // Main I2C slave state machine (system-clock driven)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= IDLE;
            shift_reg     <= 8'h0;
            bit_count     <= 3'h0;
            mem_addr      <= 8'h0;
            rw_bit        <= 1'b0;
            addr_match    <= 1'b0;
            rd_addr_acked <= 1'b0;
            sda_out       <= 1'b0;
            sda_oe        <= 1'b0;
            stretching    <= 1'b0;
            stretch_cnt   <= 16'h0;
        end else begin
            // --- Clock-stretch countdown (runs every clock while stretching) ---
            if (stretching) begin
                if (stretch_cnt == 16'h0)
                    stretching <= 1'b0;
                else
                    stretch_cnt <= stretch_cnt - 1;
            end
            // START / STOP conditions take priority over data reception
            if (start_cond) begin
                state         <= RECV_ADDR;
                bit_count     <= 3'h0;
                rd_addr_acked <= 1'b0;
                sda_oe        <= 1'b0;
                `DEBUG2(`DBG_GRP_I2C, ("[SLAVE] START condition detected"));
            end else if (stop_cond) begin
                state         <= IDLE;
                rd_addr_acked <= 1'b0;
                sda_oe        <= 1'b0;
                `DEBUG2(`DBG_GRP_I2C, ("[SLAVE] STOP condition detected"));
            end else begin
                case (state)

                    // ---------------------------------------------------------
                    IDLE: begin
                        sda_oe <= 1'b0;
                    end

                    // ---------------------------------------------------------
                    // Receive 8 bits MSB-first: 7-bit address then R/W bit.
                    // After 7 SCL rises: shift_reg[6:0] = address[6:0].
                    // On the 8th SCL rise (bit_count==7): sda_in = R/W bit.
                    RECV_ADDR: begin
                        if (scl_rising) begin
                            shift_reg <= {shift_reg[6:0], sda_in};
                            if (bit_count < 3'd7) begin
                                bit_count <= bit_count + 1;
                            end else begin
                                addr_match <= (shift_reg[6:0] == DEVICE_ADDR);
                                rw_bit     <= sda_in;
                                state      <= ACK_ADDR;
                                bit_count  <= 3'h0;
                                `DEBUG2(`DBG_GRP_I2C, ("[SLAVE] Address received: 0x%02h, match=%b (expected=0x%02h)",
                                         {shift_reg[6:0], sda_in}, (shift_reg[6:0] == DEVICE_ADDR), DEVICE_ADDR));
                            end
                        end
                    end

                    // ---------------------------------------------------------
                    // ACK_ADDR: drive ACK for the address byte.
                    // For write (rw_bit=0): first scl_falling drives ACK,
                    //   scl_rising transitions to RECV_REG.
                    // For read (rw_bit=1):  first scl_falling drives ACK,
                    //   scl_rising loads shift_reg and sets rd_addr_acked,
                    //   second scl_falling drives MSB and enters READ_DATA.
                    //   This ensures the data MSB is stable before the master
                    //   raises SCL for the first data bit.
                    ACK_ADDR: begin
                        if (scl_falling) begin
                            if (addr_match) begin
                                if (!rd_addr_acked) begin
                                    // First scl_falling: drive ACK (SDA low)
                                    sda_out <= 1'b0;
                                    sda_oe  <= 1'b1;
                                    // Clock-stretch: hold SCL low while processing
                                    if (STRETCH_CYCLES > 0) begin
                                        stretching  <= 1'b1;
                                        stretch_cnt <= 16'(STRETCH_CYCLES) - 1;
                                    end
                                    `DEBUG2(`DBG_GRP_I2C, ("[SLAVE] ACK_ADDR: driving ACK, rw=%b, mem_addr=0x%02h", rw_bit, mem_addr));
                                end else begin
                                    // Second scl_falling (read only): drive MSB, enter READ_DATA
                                    sda_out       <= shift_reg[7];
                                    sda_oe        <= 1'b1;
                                    rd_addr_acked <= 1'b0;
                                    state         <= READ_DATA;
                                    bit_count     <= 3'h0;
                                    `DEBUG2(`DBG_GRP_I2C, ("[SLAVE] ACK_ADDR: first data bit=%b, entering READ_DATA (mem_addr=0x%02h, data=0x%02h)", shift_reg[7], mem_addr, shift_reg));
                                end
                            end else begin
                                sda_oe <= 1'b0;   // Release = NACK
                                state  <= IDLE;
                                `DEBUG2(`DBG_GRP_I2C, ("[SLAVE] ACK_ADDR: NACK (no addr match), addr_match=%b", addr_match));
                            end
                        end else if (scl_rising && !stretching) begin
                            // ACK bit sampled by master
                            if (addr_match) begin
                                if (rw_bit == 1'b0) begin
                                    // Write: transition to RECV_REG
                                    state     <= RECV_REG;
                                    bit_count <= 3'h0;
                                end else begin
                                    // Read: load shift_reg, set flag, wait for next scl_falling
                                    shift_reg     <= memory[mem_addr];
                                    rd_addr_acked <= 1'b1;
                                    `DEBUG2(`DBG_GRP_I2C, ("[SLAVE] ACK_ADDR rising (read): mem_addr=0x%02h, data=0x%02h, waiting for scl_falling", mem_addr, memory[mem_addr]));
                                end
                            end
                        end
                    end

                    // ---------------------------------------------------------
                    // Receive 8-bit memory address from master (MSB first)
                    RECV_REG: begin
                        if (scl_falling) begin
                            sda_oe <= 1'b0;  // Release SDA for master to drive
                        end else if (scl_rising) begin
                            shift_reg <= {shift_reg[6:0], sda_in};
                            if (bit_count < 3'd7) begin
                                bit_count <= bit_count + 1;
                            end else begin
                                mem_addr  <= {shift_reg[6:0], sda_in};
                                bit_count <= 3'h0;
                                state     <= ACK_REG;
                            end
                        end
                    end

                    // ---------------------------------------------------------
                    // ACK the register address byte
                    ACK_REG: begin
                        if (scl_falling) begin
                            sda_out <= 1'b0;
                            sda_oe  <= 1'b1;  // ACK
                            if (STRETCH_CYCLES > 0) begin
                                stretching  <= 1'b1;
                                stretch_cnt <= 16'(STRETCH_CYCLES) - 1;
                            end
                        end else if (scl_rising && !stretching) begin
                            state     <= WRITE_DATA;
                            bit_count <= 3'h0;
                        end
                    end

                    // ---------------------------------------------------------
                    // Receive data bytes from master and write to memory
                    WRITE_DATA: begin
                        if (scl_falling) begin
                            sda_oe <= 1'b0;  // Release SDA for master to drive
                        end else if (scl_rising) begin
                            shift_reg <= {shift_reg[6:0], sda_in};
                            if (bit_count < 3'd7) begin
                                bit_count <= bit_count + 1;
                            end else begin
                                memory[mem_addr] <= {shift_reg[6:0], sda_in};
                                mem_addr  <= mem_addr + 1;
                                bit_count <= 3'h0;
                                state     <= ACK_WRITE;
                                `DEBUG2(`DBG_GRP_I2C, ("[SLAVE] Wrote 0x%02h to addr 0x%02h",
                                        {shift_reg[6:0], sda_in}, mem_addr));
                            end
                        end
                    end

                    // ---------------------------------------------------------
                    // ACK the written data byte; loop back for burst writes
                    ACK_WRITE: begin
                        if (scl_falling) begin
                            sda_out <= 1'b0;
                            sda_oe  <= 1'b1;  // ACK
                            if (STRETCH_CYCLES > 0) begin
                                stretching  <= 1'b1;
                                stretch_cnt <= 16'(STRETCH_CYCLES) - 1;
                            end
                        end else if (scl_rising && !stretching) begin
                            state     <= WRITE_DATA;
                            bit_count <= 3'h0;
                        end
                    end

                    // ---------------------------------------------------------
                    // Send a data byte MSB-first to the master.
                    // The MSB (bit 0) is pre-driven in ACK_ADDR or ACK_READ on
                    // scl_rising (before the first SCL clock of the read cycle).
                    // On each subsequent scl_falling, drive the NEXT bit by
                    // outputting shift_reg[6] (which becomes [7] after the shift).
                    // After 7 scl_fallings (bit_count 0-6), all 8 bits have been
                    // sent; the 8th scl_falling transitions to ACK_READ.
                    READ_DATA: begin
                        if (scl_falling) begin
                            if (bit_count < 3'd7) begin
                                // Drive next bit: shift_reg[6] = bit N+1 before shift
                                `DEBUG2(`DBG_GRP_I2C, ("[SLAVE] READ_DATA: bit_count=%0d, next_sda=%b (shift_reg=0x%02h)", bit_count, shift_reg[6], shift_reg));
                                sda_out   <= shift_reg[6];
                                sda_oe    <= 1'b1;
                                shift_reg <= {shift_reg[6:0], 1'b0};
                                bit_count <= bit_count + 1;
                            end else begin
                                // bit_count == 7: all 8 bits sent, transition to ACK_READ
                                `DEBUG2(`DBG_GRP_I2C, ("[SLAVE] READ_DATA: bit_count=7 done (shift_reg=0x%02h)", shift_reg));
                                bit_count <= 3'h0;
                                state     <= ACK_READ;
                                // ACK_READ will release sda_oe
                            end
                        end
                    end

                    // ---------------------------------------------------------
                    // Release SDA unconditionally so master can drive ACK/NACK.
                    // On scl_rising (master ACK): load next byte into shift_reg
                    //   and set rd_addr_acked; stay in ACK_READ.
                    // On next scl_falling: drive next byte's MSB and enter READ_DATA.
                    ACK_READ: begin
                        if (!rd_addr_acked) begin
                            sda_oe <= 1'b0;  // Release SDA for master to drive ACK/NACK
                        end
                        if (scl_falling) begin
                            if (rd_addr_acked) begin
                                // Drive MSB of next byte and enter READ_DATA
                                sda_out       <= shift_reg[7];
                                sda_oe        <= 1'b1;
                                rd_addr_acked <= 1'b0;
                                state         <= READ_DATA;
                                bit_count     <= 3'h0;
                                `DEBUG2(`DBG_GRP_I2C, ("[SLAVE] ACK_READ: driving next MSB=%b, entering READ_DATA", shift_reg[7]));
                            end
                        end else if (scl_rising) begin
                            if (sda_in == 1'b0) begin
                                // Master ACK: load next byte, set flag
                                mem_addr      <= mem_addr + 1;
                                shift_reg     <= memory[mem_addr + 1];
                                rd_addr_acked <= 1'b1;
                                `DEBUG2(`DBG_GRP_I2C, ("[SLAVE] ACK_READ: master ACK, loading next byte mem_addr+1=0x%02h", mem_addr + 1));
                            end else begin
                                // Master NACK: stop sending
                                state <= IDLE;
                                `DEBUG2(`DBG_GRP_I2C, ("[SLAVE] ACK_READ: master NACK, going IDLE"));
                            end
                        end
                    end

                    // ---------------------------------------------------------
                    default: state <= IDLE;

                endcase
            end
        end
    end

endmodule

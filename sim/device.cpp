// Device Driver Implementations for RV32 Simulator

#include "device.h"
#include <algorithm>
#include <iostream>
#include <iomanip>
#include <cstring>

// ============================================================================
// Memory Device Implementation
// ============================================================================

MemoryDevice::MemoryDevice(uint32_t size) : bytes(size, 0) {}

void MemoryDevice::reset() {
    std::fill(bytes.begin(), bytes.end(), 0);
}

uint32_t MemoryDevice::read(uint32_t offset, int size) {
    if (size <= 0 || offset + (uint32_t)size > bytes.size()) {
        return 0;
    }

    if (size == 1) {
        return bytes[offset];
    }
    if (size == 2) {
        return bytes[offset] | (bytes[offset + 1] << 8);
    }
    if (size == 4) {
        return bytes[offset] | (bytes[offset + 1] << 8) |
               (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24);
    }
    return 0;
}

void MemoryDevice::write(uint32_t offset, uint32_t value, int size) {
    if (size <= 0 || offset + (uint32_t)size > bytes.size()) {
        return;
    }

    if (size == 1) {
        bytes[offset] = value & 0xFF;
    } else if (size == 2) {
        bytes[offset] = value & 0xFF;
        bytes[offset + 1] = (value >> 8) & 0xFF;
    } else if (size == 4) {
        bytes[offset] = value & 0xFF;
        bytes[offset + 1] = (value >> 8) & 0xFF;
        bytes[offset + 2] = (value >> 16) & 0xFF;
        bytes[offset + 3] = (value >> 24) & 0xFF;
    }
}

// ============================================================================
// Magic Device Implementation
// ============================================================================

MagicDevice::MagicDevice() : exit_pending(false), exit_code(0) {
    reset();
}

void MagicDevice::reset() {
    exit_pending = false;
    exit_code = 0;
}

uint32_t MagicDevice::read(uint32_t offset, int size) {
    (void)size;
    if (offset == RV_MAGIC_CONSOLE_OFF) {
        return 0;
    }
    if (offset == RV_MAGIC_EXIT_OFF) {
        return 0;
    }
    return 0;
}

void MagicDevice::write(uint32_t offset, uint32_t value, int size) {
    (void)size;
    if (offset == RV_MAGIC_CONSOLE_OFF) {
        char c = value & 0xFF;
        std::cout << c << std::flush;
        return;
    }

    if (offset == RV_MAGIC_EXIT_OFF) {
        exit_code = (value >> 1) & 0x7FFFFFFF;
        exit_pending = true;
    }
}

bool MagicDevice::consume_exit_request(int* code_out) {
    if (!exit_pending) {
        return false;
    }

    if (code_out) {
        *code_out = exit_code;
    }

    exit_pending = false;
    return true;
}

// ============================================================================
// UART Device Implementation  (FIFO-based, matches axi_uart.sv)
// ============================================================================

UARTDevice::UARTDevice() : ie_reg(0) {
    reset();
}

void UARTDevice::reset() {
    rx_fifo.clear();
    tx_fifo.clear();
    ie_reg = 0;
    loopback_en = false;
}

// IS signals (level, read-only) – bit layout matches rv_platform.h RV_UART_IE_*
//   IS[0] = !rx_fifo.empty()  (rx_not_empty  → RV_UART_IE_RX_READY)
//   IS[1] = tx_fifo.empty()   (tx_empty      → RV_UART_IE_TX_EMPTY; always 1 since sim TX is instant)
static uint32_t uart_is(const std::vector<uint8_t>& rx_fifo, const std::vector<uint8_t>& tx_fifo) {
    uint32_t r = 0;
    if (!rx_fifo.empty())  r |= RV_UART_IE_RX_READY;
    if (tx_fifo.empty())   r |= RV_UART_IE_TX_EMPTY;
    return r;
}

bool UARTDevice::get_irq() const {
    return (ie_reg & uart_is(rx_fifo, tx_fifo)) != 0;
}

uint32_t UARTDevice::read(uint32_t offset, int size) {
    (void)size;
    switch (offset) {
        case RV_UART_DATA_OFF:  // RX FIFO pop
            if (!rx_fifo.empty()) {
                uint8_t val = rx_fifo.front();
                rx_fifo.erase(rx_fifo.begin());
                return val;
            }
            return 0;

        case RV_UART_STATUS_OFF: {
            // [0]/[1] = tx_full  (sim TX is instant → never full → 0)
            // [2]     = rx_not_empty  (RV_UART_ST_RX_READY)
            // [3]     = rx_full       (RV_UART_ST_RX_FULL)
            bool rx_ne   = !rx_fifo.empty();
            bool rx_full = ((int)rx_fifo.size() >= FIFO_DEPTH);
            return (rx_full ? RV_UART_ST_RX_FULL  : 0u) |
                   (rx_ne   ? RV_UART_ST_RX_READY : 0u);
        }

        case RV_UART_IE_OFF:
            return ie_reg;

        case RV_UART_IS_OFF:
            return uart_is(rx_fifo, tx_fifo);

        case RV_UART_LEVEL_OFF: {
            uint32_t rx_cnt = (uint32_t)rx_fifo.size() & 0x1F;
            uint32_t tx_cnt = (uint32_t)tx_fifo.size() & 0x1F;
            return (tx_cnt << 8) | rx_cnt;
        }

        case RV_UART_CTRL_OFF:   // CTRL register: [0]=loopback_en
            return loopback_en ? RV_UART_CTRL_LOOPBACK : 0u;

        default:
            return 0;
    }
}

void UARTDevice::write(uint32_t offset, uint32_t value, int size) {
    (void)size;
    switch (offset) {
        case RV_UART_DATA_OFF: {  // TX FIFO push → print immediately in simulation
            char c = (char)(value & 0xFF);
            std::cout << c << std::flush;
            // Echo TX → RX FIFO in simulation.
            // When loopback_en is set this matches the RTL internal loopback path.
            // When loopback_en is clear the sim still echoes to model the external
            // uart_loopback.sv testbench (always-echo hardware wire in the RTL TB).
            if ((int)rx_fifo.size() < FIFO_DEPTH)
                rx_fifo.push_back((uint8_t)c);
            break;
        }
        // RV_UART_STATUS_OFF is read-only

        case RV_UART_IE_OFF:
            ie_reg = value & (RV_UART_IE_RX_READY | RV_UART_IE_TX_EMPTY);
            break;

        // RV_UART_IS_OFF is read-only level; no W1C in simulation

        case RV_UART_CTRL_OFF:  // CTRL register: bit[0] = loopback_en
            loopback_en = (value & RV_UART_CTRL_LOOPBACK) != 0;
            break;

        default:
            break;
    }
}

void UARTDevice::add_rx_data(uint8_t data) {
    if ((int)rx_fifo.size() < FIFO_DEPTH) {
        rx_fifo.push_back(data);
    }
}

// ============================================================================
// I2C Device Implementation
// ============================================================================

I2CDevice::I2CDevice() {
    reset();
}

void I2CDevice::reset() {
    i2c_enable = false;
    start_cmd = false;
    stop_cmd = false;
    read_cmd = false;
    ack_cmd = false;
    clk_div = 249;  // Default: 100kHz at 100MHz
    clk_counter = 0;
    tx_data = 0;
    rx_data = 0;
    tx_valid = false;
    tx_fifo.clear();
    rx_fifo.clear();
    busy = false;
    tx_ready = true;
    rx_valid = false;
    ack_received = false;
    state = State::IDLE;
    shift_reg = 0;
    bit_counter = 0;
    scl_phase = 0;
    eeprom_addr = 0;
    eeprom_addr_set = false;
    ie_reg = 0;
    stop_done = false;

    // Initialize EEPROM with pattern 0xA0 + address
    for (int i = 0; i < 256; i++) {
        eeprom_memory[i] = 0xA0 + i;
    }
}

uint32_t I2CDevice::read(uint32_t offset, int size) {
    (void)size;
    switch (offset) {
        case RV_I2C_CTRL_OFF:  // Control register
            return (ack_cmd   ? RV_I2C_CTRL_NACK  : 0u) |
                   (read_cmd  ? RV_I2C_CTRL_READ  : 0u) |
                   (stop_cmd  ? RV_I2C_CTRL_STOP  : 0u) |
                   (start_cmd ? RV_I2C_CTRL_START : 0u) |
                   (i2c_enable ? RV_I2C_CTRL_ENABLE : 0u);

        case RV_I2C_DIV_OFF:  // Clock divider
            return clk_div;

        case RV_I2C_TX_OFF:  // TX FIFO (write-only; reading not meaningful)
            return tx_data;

        case RV_I2C_RX_OFF:  // RX FIFO pop
            if (!rx_fifo.empty()) {
                uint8_t val = rx_fifo.front();
                rx_fifo.erase(rx_fifo.begin());
                rx_valid = !rx_fifo.empty();
                return val;
            }
            rx_valid = false;
            return 0;

        case RV_I2C_STATUS_OFF:  // Status register
            // [0]=busy (RV_I2C_ST_BUSY), [1]=tx_ready (RV_I2C_ST_TX_READY),
            // [2]=rx_valid (RV_I2C_ST_RX_VALID), [3]=ack_received (RV_I2C_ST_ACK_RECV)
            rx_valid = !rx_fifo.empty();
            tx_ready = (int)tx_fifo.size() < FIFO_DEPTH;
            return (ack_received ? RV_I2C_ST_ACK_RECV : 0u) |
                   (rx_valid     ? RV_I2C_ST_RX_VALID : 0u) |
                   (tx_ready     ? RV_I2C_ST_TX_READY : 0u) |
                   (busy         ? RV_I2C_ST_BUSY     : 0u);

        case RV_I2C_IE_OFF:  // Interrupt enable
            return ie_reg;

        case RV_I2C_IS_OFF:  // Interrupt status (level – read-only, matches RTL is_wire)
            {
                // IS[0] = rx_fifo not empty      (RV_I2C_IE_RX_READY)
                // IS[1] = tx_fifo empty+not busy (RV_I2C_IE_TX_EMPTY)
                // IS[2] = stop_done pulse        (RV_I2C_IE_STOP_DONE; latched by PLIC)
                uint32_t is = 0;
                if (!rx_fifo.empty())        is |= RV_I2C_IE_RX_READY;
                if (tx_fifo.empty() && !busy) is |= RV_I2C_IE_TX_EMPTY;
                if (stop_done)               is |= RV_I2C_IE_STOP_DONE;
                return is;
            }

        default:
            return 0;
    }
}

void I2CDevice::write(uint32_t offset, uint32_t value, int size) {
    (void)size;
    switch (offset) {
        case RV_I2C_CTRL_OFF:  // Control register
            i2c_enable = (value & RV_I2C_CTRL_ENABLE) != 0;
            start_cmd  = (value & RV_I2C_CTRL_START)  != 0;
            stop_cmd   = (value & RV_I2C_CTRL_STOP)   != 0;
            read_cmd   = (value & RV_I2C_CTRL_READ)   != 0;
            ack_cmd    = (value & RV_I2C_CTRL_NACK)   != 0;

            // Execute commands (command bits auto-clear at next tick, like RTL)
            if (start_cmd && i2c_enable) {
                state = State::START;
                busy = true;
                tx_ready = false;
                // NOTE: do NOT reset eeprom_addr_set here — a repeated START
                // (read phase) must keep the address set by the prior write phase.
            } else if (stop_cmd && i2c_enable) {
                state = State::STOP;
                busy = true;
            } else if (read_cmd && i2c_enable && state == State::IDLE) {
                // Explicit READ command via CTRL: start a read transaction.
                state = State::READ;
                busy = true;
                tx_ready = false;
            }
            break;

        case RV_I2C_DIV_OFF:  // Clock divider
            clk_div = value & 0xFFFF;
            break;

        case RV_I2C_TX_OFF:  // TX FIFO push
            // Push bytes regardless of i2c_enable state – matches RTL where the
            // TX FIFO accepts writes at any time; the controller drains it
            // automatically once enabled and START is issued.
            if ((int)tx_fifo.size() < FIFO_DEPTH)
                tx_fifo.push_back(value & 0xFF);
            break;

        case RV_I2C_IE_OFF:  // Interrupt enable
            ie_reg = value & (RV_I2C_IE_RX_READY | RV_I2C_IE_TX_EMPTY | RV_I2C_IE_STOP_DONE);
            break;

        // RV_I2C_IS_OFF is read-only level
        default:
            break;
    }
}

bool I2CDevice::get_irq() const {
    uint32_t is = 0;
    if (!rx_fifo.empty())          is |= RV_I2C_IE_RX_READY;
    if (tx_fifo.empty() && !busy)  is |= RV_I2C_IE_TX_EMPTY;
    if (stop_done)                 is |= RV_I2C_IE_STOP_DONE;
    return (ie_reg & is) != 0;
}

void I2CDevice::tick() {
    // stop_done is a 1-cycle pulse – auto-clear at the start of every tick
    // so it doesn't keep the PLIC IRQ line asserted across multiple cycles.
    // The PLIC latch fix ensures the single-cycle assertion is still captured.
    stop_done = false;

    // Clear auto-clearing command bits (simulating RTL auto-clear)
    start_cmd = false;
    stop_cmd = false;

    if (!i2c_enable) {
        state = State::IDLE;
        busy = false;
        tx_ready = true;
        tx_valid = false;
        return;
    }

    // Match RTL IDLE behaviour: when TX FIFO has data and not busy, automatically
    // pop the next byte and start the appropriate transfer.
    if (state == State::IDLE && !tx_fifo.empty()) {
        tx_data = tx_fifo.front();
        tx_fifo.erase(tx_fifo.begin());
        tx_valid = true;
        shift_reg = tx_data;
        if (read_cmd) {
            state = State::READ;
        } else {
            state = State::WRITE;
        }
        busy = true;
        tx_ready = (int)tx_fifo.size() < FIFO_DEPTH;
    }

    if (!busy)
        return;

    process_i2c_transaction();
}

void I2CDevice::process_i2c_transaction() {
    // Simplified I2C state machine for simulation
    switch (state) {
        case State::IDLE:
            tx_ready = true;
            busy = false;
            break;

        case State::START:
            // START condition executed
            state = State::IDLE;
            busy = false;
            tx_ready = (int)tx_fifo.size() < FIFO_DEPTH;
            // NOTE: do NOT reset eeprom_addr_set here – a repeated START
            // (read phase) must keep the address set by the prior write phase.
            break;

        case State::WRITE:
            // Write byte to EEPROM
            handle_eeprom_write(tx_data);
            ack_received = true;  // Simulate ACK from slave
            tx_valid = false;
            state = State::IDLE;
            busy = false;
            tx_ready = (int)tx_fifo.size() < FIFO_DEPTH;
            break;

        case State::READ:
            // Read byte from EEPROM and push to RX FIFO
            rx_data = handle_eeprom_read();
            if ((int)rx_fifo.size() < FIFO_DEPTH)
                rx_fifo.push_back(rx_data);
            rx_valid = !rx_fifo.empty();
            tx_valid = false;
            state = State::IDLE;
            busy = false;
            tx_ready = (int)tx_fifo.size() < FIFO_DEPTH;
            break;

        case State::STOP:
            // STOP condition executed — end of full I2C transaction.
            // Reset address tracking so the next transaction's write-phase
            // will correctly re-set the EEPROM memory pointer.
            eeprom_addr_set = false;
            stop_done = true;   // 1-cycle pulse; auto-cleared at start of next tick()
            state = State::IDLE;
            busy = false;
            tx_ready = (int)tx_fifo.size() < FIFO_DEPTH;
            break;

        default:
            state = State::IDLE;
            break;
    }
}

void I2CDevice::handle_eeprom_write(uint8_t data) {
    if ((data & 0xFE) == 0xA0) {
        // Device address byte:
        //   0xA0 (write direction) — a memory address byte follows next.
        //   0xA1 (read  direction) — address was already set in the write
        //                            phase; keep eeprom_addr_set as-is.
        if (!(data & 0x01)) {
            eeprom_addr_set = false;  // Prepare to receive memory address
        }
        return;
    }
    if (!eeprom_addr_set) {
        // Memory address byte
        eeprom_addr = data;
        eeprom_addr_set = true;
    } else {
        // Data byte — write to EEPROM
        eeprom_memory[eeprom_addr] = data;
        eeprom_addr = (eeprom_addr + 1) & 0xFF;
    }
}

uint8_t I2CDevice::handle_eeprom_read() {
    // By the time a READ state is processed, the EEPROM memory pointer
    // (eeprom_addr) has already been set by the preceding write phase.
    // Just return the byte at the current pointer and advance it.
    uint8_t data = eeprom_memory[eeprom_addr];
    eeprom_addr = (eeprom_addr + 1) & 0xFF;
    return data;
}

// ============================================================================
// SPI Device Implementation
// ============================================================================

SPIDevice::SPIDevice() {
    reset();
}

void SPIDevice::reset() {
    spi_enable = false;
    cpol = false;
    cpha = false;
    loopback_en = false;
    clk_div = 99;  // Default: 1MHz at 100MHz
    clk_counter = 0;
    tx_data = 0;
    rx_data = 0;
    tx_valid = false;
    busy = false;
    tx_ready = true;
    rx_valid = false;
    chip_select = 0x0F;  // All CS high (inactive)
    state = State::IDLE;
    shift_reg = 0;
    bit_counter = 0;
    sclk_phase = 0;
    transfer_ticks = 0;
    ie_reg = 0;
    rx_fifo.clear();

    // Initialize SPI flash with pattern (address value)
    for (int cs = 0; cs < 4; cs++) {
        for (int i = 0; i < 4096; i++) {
            flash_memory[cs][i] = (i & 0xFF);  // Same pattern for all CS lines
        }
        flash_addr[cs] = 0;
        flash_addr_set[cs] = false;
        flash_addr_bytes[cs] = 0;
        flash_cmd[cs] = 0;
    }
}

bool SPIDevice::get_irq() const {
    uint32_t is = 0;
    if (!rx_fifo.empty())  is |= RV_SPI_IE_RX_READY;
    if (!tx_valid)         is |= RV_SPI_IE_TX_EMPTY;
    return (ie_reg & is) != 0;
}

uint32_t SPIDevice::read(uint32_t offset, int size) {
    (void)size;
    switch (offset) {
        case RV_SPI_CTRL_OFF:  // Control register
            return ((chip_select & 0xFu) << 4) |
                   (loopback_en ? RV_SPI_CTRL_LOOPBACK : 0u) |
                   (cpha       ? RV_SPI_CTRL_CPHA   : 0u) |
                   (cpol       ? RV_SPI_CTRL_CPOL   : 0u) |
                   (spi_enable ? RV_SPI_CTRL_ENABLE : 0u);

        case RV_SPI_DIV_OFF:  // Clock divider
            return clk_div;

        case RV_SPI_TX_OFF:  // TX FIFO (write-only in RTL; return 0)
            return 0;

        case RV_SPI_RX_OFF:  // RX FIFO pop
            if (!rx_fifo.empty()) {
                uint8_t val = rx_fifo.front();
                rx_fifo.erase(rx_fifo.begin());
                rx_valid = !rx_fifo.empty();  // update valid flag
                return val;
            }
            rx_valid = false;
            return 0;

        case RV_SPI_STATUS_OFF:  // Status register
            // [0]=busy (RV_SPI_ST_BUSY), [1]=tx_ready (RV_SPI_ST_TX_READY),
            // [2]=rx_valid (RV_SPI_ST_RX_VALID)
            return (rx_valid ? RV_SPI_ST_RX_VALID  : 0u) |
                   (!busy    ? RV_SPI_ST_TX_READY  : 0u) |
                   (busy     ? RV_SPI_ST_BUSY      : 0u);

        case RV_SPI_IE_OFF:
            return ie_reg;

        case RV_SPI_IS_OFF: {
            uint32_t is = 0;
            if (!rx_fifo.empty())  is |= RV_SPI_IE_RX_READY;
            if (!busy)             is |= RV_SPI_IE_TX_EMPTY;
            return is;
        }

        default:
            return 0;
    }
}

void SPIDevice::write(uint32_t offset, uint32_t value, int size) {
    (void)size;
    switch (offset) {
        case RV_SPI_CTRL_OFF:  // Control register
            spi_enable  = (value & RV_SPI_CTRL_ENABLE)   != 0;
            cpol        = (value & RV_SPI_CTRL_CPOL)     != 0;
            cpha        = (value & RV_SPI_CTRL_CPHA)     != 0;
            loopback_en = (value & RV_SPI_CTRL_LOOPBACK) != 0;
            chip_select = (value >> 4) & 0x0F;
            // Reset flash state when CS de-selects
            for (int cs = 0; cs < 4; cs++) {
                if (chip_select & (1 << cs)) {
                    flash_addr_set[cs] = false;
                    flash_addr_bytes[cs] = 0;
                    flash_cmd[cs] = 0;
                }
            }
            break;

        case RV_SPI_DIV_OFF:  // Clock divider
            clk_div = value & 0xFFFF;
            break;

        case RV_SPI_TX_OFF:  // TX FIFO push
            if (!busy && spi_enable) {
                tx_data = value & 0xFF;
                tx_valid = true;
                shift_reg = tx_data;
                state = State::TRANSFER;
                busy = true;
                tx_ready = false;
                transfer_ticks = 4;  // Hold busy for >=1 visible cycle before completing
            }
            break;

        case RV_SPI_IE_OFF:
            ie_reg = value & (RV_SPI_IE_RX_READY | RV_SPI_IE_TX_EMPTY);
            break;

        // RV_SPI_RX_OFF and RV_SPI_IS_OFF are read-only
        default:
            break;
    }
}

void SPIDevice::tick() {
    if (!busy || !spi_enable)
        return;

    if (transfer_ticks > 0) {
        transfer_ticks--;
        if (transfer_ticks == 0)
            process_spi_transfer();
    }
}

void SPIDevice::process_spi_transfer() {
    // Simplified SPI transfer for simulation
    if (state == State::TRANSFER) {
        uint8_t recv;

        if (loopback_en) {
            // Internal loopback: MOSI bit-pattern comes straight back as MISO.
            // Matches RTL axi_spi.sv when CTRL[3]=1.
            recv = tx_data;
        } else {
            // Normal mode: route through the simulated flash slave.
            // Determine which CS is active (0 = active)
            int active_cs = -1;
            for (int cs = 0; cs < 4; cs++) {
                if (!(chip_select & (1 << cs))) {
                    active_cs = cs;
                    break;
                }
            }

            if (active_cs >= 0) {
                if (!flash_addr_set[active_cs]) {
                    handle_flash_command(active_cs, tx_data);
                    recv = 0xFF;  // dummy byte while sending command/addr
                } else {
                    recv = handle_flash_data(active_cs, tx_data);
                }
            } else {
                recv = 0xFF;  // No device selected
            }
        }

        rx_data = recv;
        rx_fifo.push_back(recv);
        rx_valid = true;

        tx_valid = false;
        state = State::IDLE;
        busy = false;
        tx_ready = true;
    }
}

void SPIDevice::handle_flash_command(int cs, uint8_t cmd) {
    // Simple flash commands:
    // 0x03: Read data
    // 0x02: Write data
    // First byte after command is address

    if (flash_addr_bytes[cs] == 0) {
        // This is the command byte
        if (cmd == 0x03 || cmd == 0x02) {
            flash_cmd[cs] = cmd;
            flash_addr_bytes[cs] = 1;
        }
    } else if (flash_addr_bytes[cs] == 1) {
        // This is the address (1-byte, covers 256-byte space)
        flash_addr[cs] = cmd;
        flash_addr_set[cs] = true;
        flash_addr_bytes[cs] = 0;
    }
}

uint8_t SPIDevice::handle_flash_data(int cs, uint8_t tx_byte) {
    uint32_t addr = flash_addr[cs] & 0xFFFu;
    uint8_t recv;
    if (flash_cmd[cs] == 0x02) {
        // Write command: store the byte, return 0xFF (flash outputs high-Z)
        flash_memory[cs][addr] = tx_byte;
        recv = 0xFF;
    } else {
        // Read command (0x03) or unknown: return stored byte
        recv = flash_memory[cs][addr];
    }
    flash_addr[cs] = (flash_addr[cs] + 1) & 0xFFFu;
    return recv;
}

// ============================================================================
// PLIC Device Implementation  (matches RTL rv32_plic.sv)
// ============================================================================

PLICDevice::PLICDevice() {
    reset();
}

void PLICDevice::reset() {
    for (int i = 0; i <= NUM_IRQ; i++) {
        priority_r[i] = 0;
        enable_r[i]   = false;
        pending_r[i]  = false;
        claimed_r[i]  = false;
    }
    threshold_r  = 0;
    irq_src_mask = 0;
}

int PLICDevice::best_claim() const {
    int best_id  = 0;
    uint32_t best_pri = 0;
    for (int i = 1; i <= NUM_IRQ; i++) {
        if (enable_r[i] && pending_r[i] && priority_r[i] > threshold_r) {
            if (priority_r[i] >= best_pri) {
                best_pri = priority_r[i];
                best_id  = i;
            }
        }
    }
    return best_id;
}

void PLICDevice::update_irq_sources(uint32_t mask) {
    irq_src_mask = mask;
    // Level-triggered: ONLY set pending when source is asserted, never clear it here.
    // Pending is cleared exclusively via the complete write (CLAIM_0) when the source
    // is low — matching RTL rv32_plic.sv: `if (irq_src[i]) pending_r[i] <= 1`.
    // This ensures 1-cycle pulse sources (e.g. I2C stop_done_r) are latched correctly
    // even when the source de-asserts before the handler has a chance to claim.
    for (int i = 1; i <= NUM_IRQ; i++) {
        if (mask & (1u << i))
            pending_r[i] = true;
    }
}

bool PLICDevice::get_external_interrupt() const {
    return best_claim() != 0;
}

uint32_t PLICDevice::read(uint32_t offset, int size) {
    (void)size;

    // Priority registers: RV_PLIC_PRIORITY_OFF + 4*i  (source 0 always reads 0)
    if (offset >= RV_PLIC_PRIORITY_OFF && offset < RV_PLIC_PENDING_OFF) {
        int src = offset >> 2;
        if (src >= 1 && src <= NUM_IRQ)
            return priority_r[src];
        return 0;
    }

    // Pending register: RV_PLIC_PENDING_OFF (one 32-bit word for sources 1..31)
    if (offset == RV_PLIC_PENDING_OFF) {
        uint32_t pend = 0;
        for (int i = 1; i <= NUM_IRQ; i++) {
            if (pending_r[i]) pend |= (1u << i);
        }
        return pend;
    }

    // Enable register: RV_PLIC_ENABLE_OFF for context 0
    if (offset == RV_PLIC_ENABLE_OFF) {
        uint32_t en = 0;
        for (int i = 1; i <= NUM_IRQ; i++) {
            if (enable_r[i]) en |= (1u << i);
        }
        return en;
    }

    // Threshold: RV_PLIC_THRESHOLD_OFF
    if (offset == RV_PLIC_THRESHOLD_OFF)
        return threshold_r;

    // Claim/Complete: RV_PLIC_CLAIM_OFF — reading performs a claim
    if (offset == RV_PLIC_CLAIM_OFF) {
        int id = best_claim();
        if (id > 0) {
            claimed_r[id] = true;
        }
        return (uint32_t)id;
    }

    return 0;
}

void PLICDevice::write(uint32_t offset, uint32_t value, int size) {
    (void)size;

    // Priority registers
    if (offset >= RV_PLIC_PRIORITY_OFF && offset < RV_PLIC_PENDING_OFF) {
        int src = offset >> 2;
        if (src >= 1 && src <= NUM_IRQ)
            priority_r[src] = value & 0x7;
        return;
    }

    // Enable register for context 0
    if (offset == RV_PLIC_ENABLE_OFF) {
        for (int i = 1; i <= NUM_IRQ; i++) {
            enable_r[i] = (value >> i) & 1;
        }
        return;
    }

    // Threshold
    if (offset == RV_PLIC_THRESHOLD_OFF) {
        threshold_r = value & 0x7;
        return;
    }

    // Claim/Complete: RV_PLIC_CLAIM_OFF — writing completes the interrupt
    if (offset == RV_PLIC_CLAIM_OFF) {
        int id = (int)(value & 0x1F);
        if (id >= 1 && id <= NUM_IRQ) {
            claimed_r[id] = false;
            // If source is still asserted after complete, re-set pending
            if (irq_src_mask & (1u << id)) {
                pending_r[id] = true;
            } else {
                pending_r[id] = false;
            }
        }
        return;
    }
}

// ============================================================================
// CLINT Device Implementation
// ============================================================================

CLINTDevice::CLINTDevice() {
    reset();
}

void CLINTDevice::reset() {
    msip = 0;
    mtimecmp = 0xFFFFFFFFFFFFFFFFULL;  // Prevent spurious timer interrupt until explicitly set
    mtime = 0;
}

uint32_t CLINTDevice::read(uint32_t offset, int size) {
    (void)size;
    if (offset == RV_CLINT_MSIP_OFF) {
        return msip;
    } else if (offset == RV_CLINT_MTIMECMP_LO_OFF) {
        return mtimecmp & 0xFFFFFFFF;
    } else if (offset == RV_CLINT_MTIMECMP_HI_OFF) {
        return (mtimecmp >> 32) & 0xFFFFFFFF;
    } else if (offset == RV_CLINT_MTIME_LO_OFF) {
        return mtime & 0xFFFFFFFF;
    } else if (offset == RV_CLINT_MTIME_HI_OFF) {
        return (mtime >> 32) & 0xFFFFFFFF;
    }
    return 0;
}

void CLINTDevice::write(uint32_t offset, uint32_t value, int size) {
    (void)size;
    if (offset == RV_CLINT_MSIP_OFF) {
        msip = value & 0x1;
    } else if (offset == RV_CLINT_MTIMECMP_LO_OFF) {
        mtimecmp = (mtimecmp & 0xFFFFFFFF00000000ULL) | value;
    } else if (offset == RV_CLINT_MTIMECMP_HI_OFF) {
        mtimecmp = (mtimecmp & 0x00000000FFFFFFFFULL) | ((uint64_t)value << 32);
    }
}

void CLINTDevice::tick() {
    mtime++;
}

bool CLINTDevice::get_timer_interrupt() {
    return mtime >= mtimecmp;
}

bool CLINTDevice::get_software_interrupt() {
    return msip & 0x1;
}

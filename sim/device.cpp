// Device Driver Implementations for KV32 Simulator

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
    // Clear the non-cacheable instruction memory
    for (int i = 0; i < 128; i++) ncm[i] = 0;
}

uint32_t MagicDevice::read(uint32_t offset, int size) {
    (void)size;
    if (offset == KV_MAGIC_CONSOLE_OFF) {
        return 0;
    }
    if (offset == KV_MAGIC_EXIT_OFF) {
        return 0;
    }
    // NCM: 512-byte non-cacheable instruction RAM at offset 0x1000–0x11FF
    // Instruction fetch bypass reads land here when the icache issues a
    // single-beat INCR AXI transaction to any NCM address (PMA bit[31]=0).
    if (offset >= KV_NCM_OFF && offset < KV_NCM_OFF + KV_NCM_SIZE) {
        uint32_t word_idx = (offset - KV_NCM_OFF) / 4;
        return ncm[word_idx];
    }
    last_bus_error = true;  // only EXIT, CONSOLE, and NCM offsets are valid
    return 0;
}

void MagicDevice::write(uint32_t offset, uint32_t value, int size) {
    (void)size;
    if (offset == KV_MAGIC_CONSOLE_OFF) {
        char c = value & 0xFF;
        std::cout << c << std::flush;
        return;
    }

    if (offset == KV_MAGIC_EXIT_OFF) {
        exit_code = (value >> 1) & 0x7FFFFFFF;
        exit_pending = true;
        return;
    }

    // NCM: firmware writes machine-code words here before calling via fptr
    if (offset >= KV_NCM_OFF && offset < KV_NCM_OFF + KV_NCM_SIZE) {
        uint32_t word_idx = (offset - KV_NCM_OFF) / 4;
        ncm[word_idx] = value;
        return;
    }

    last_bus_error = true;  // only EXIT, CONSOLE, and NCM offsets are valid
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

// IS signals (level, read-only) – bit layout matches kv_platform.h KV_UART_IE_*
//   IS[0] = !rx_fifo.empty()  (rx_not_empty  → KV_UART_IE_RX_READY)
//   IS[1] = tx_fifo.empty()   (tx_empty      → KV_UART_IE_TX_EMPTY; always 1 since sim TX is instant)
static uint32_t uart_is(const std::vector<uint8_t>& rx_fifo, const std::vector<uint8_t>& tx_fifo) {
    uint32_t r = 0;
    if (!rx_fifo.empty())  r |= KV_UART_IE_RX_READY;
    if (tx_fifo.empty())   r |= KV_UART_IE_TX_EMPTY;
    return r;
}

bool UARTDevice::get_irq() const {
    return (ie_reg & uart_is(rx_fifo, tx_fifo)) != 0;
}

uint32_t UARTDevice::read(uint32_t offset, int size) {
    (void)size;
    // Offsets beyond CAP are out-of-range (mirrors RTL addr[7:2] <= 6 check)
    if (offset > KV_UART_CAP_OFF) { last_bus_error = true; return 0; }
    switch (offset) {
        case KV_UART_DATA_OFF:  // RX FIFO pop
            if (!rx_fifo.empty()) {
                uint8_t val = rx_fifo.front();
                rx_fifo.erase(rx_fifo.begin());
                return val;
            }
            return 0;

        case KV_UART_STATUS_OFF: {
            // [0]/[1] = tx_full  (sim TX is instant → never full → 0)
            // [2]     = rx_not_empty  (KV_UART_ST_RX_READY)
            // [3]     = rx_full       (KV_UART_ST_RX_FULL)
            bool rx_ne   = !rx_fifo.empty();
            bool rx_full = ((int)rx_fifo.size() >= FIFO_DEPTH);
            return (rx_full ? KV_UART_ST_RX_FULL  : 0u) |
                   (rx_ne   ? KV_UART_ST_RX_READY : 0u);
        }

        case KV_UART_IE_OFF:
            return ie_reg;

        case KV_UART_IS_OFF:
            return uart_is(rx_fifo, tx_fifo);

        case KV_UART_LEVEL_OFF: {
            uint32_t rx_cnt = (uint32_t)rx_fifo.size() & 0x1F;
            uint32_t tx_cnt = (uint32_t)tx_fifo.size() & 0x1F;
            return (tx_cnt << 8) | rx_cnt;
        }

        case KV_UART_CTRL_OFF:   // CTRL register: [0]=loopback_en
            return loopback_en ? KV_UART_CTRL_LOOPBACK : 0u;

        case KV_UART_CAP_OFF:  // CAPABILITY (RO): [7:0]=TX_FIFO, [15:8]=RX_FIFO, [31:16]=VERSION
            return (0x0001u << 16) | (FIFO_DEPTH << 8) | FIFO_DEPTH;  // v0.0001, RX=16, TX=16

        default:
            return 0;
    }
}

void UARTDevice::write(uint32_t offset, uint32_t value, int size) {
    (void)size;
    // Offsets beyond CAP are out-of-range (mirrors RTL addr[7:2] <= 6 check)
    if (offset > KV_UART_CAP_OFF) { last_bus_error = true; return; }
    switch (offset) {
        case KV_UART_DATA_OFF: {  // TX FIFO push → print immediately in simulation
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
        // KV_UART_STATUS_OFF is read-only

        case KV_UART_IE_OFF:
            ie_reg = value & (KV_UART_IE_RX_READY | KV_UART_IE_TX_EMPTY);
            break;

        // KV_UART_IS_OFF is read-only level; no W1C in simulation

        case KV_UART_CTRL_OFF:  // CTRL register: bit[0] = loopback_en
            loopback_en = (value & KV_UART_CTRL_LOOPBACK) != 0;
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
    eeprom_tx_state  = EepromTxState::IDLE;
    eeprom_write_mode = false;
    eeprom_addr = 0;
    eeprom_addr_set = false;
    stretch_ticks_per_ack = 0;
    stretch_remaining = 0;
    ie_reg = 0;
    stop_done = false;

    // Initialize EEPROM with pattern 0xA0 + address
    for (int i = 0; i < 256; i++) {
        eeprom_memory[i] = 0xA0 + i;
    }
}

uint32_t I2CDevice::read(uint32_t offset, int size) {
    (void)size;
    // Offsets beyond CAP are out-of-range
    if (offset > KV_I2C_CAP_OFF) { last_bus_error = true; return 0; }
    switch (offset) {
        case KV_I2C_CTRL_OFF:  // Control register
            return (ack_cmd   ? KV_I2C_CTRL_NACK  : 0u) |
                   (read_cmd  ? KV_I2C_CTRL_READ  : 0u) |
                   (stop_cmd  ? KV_I2C_CTRL_STOP  : 0u) |
                   (start_cmd ? KV_I2C_CTRL_START : 0u) |
                   (i2c_enable ? KV_I2C_CTRL_ENABLE : 0u);

        case KV_I2C_DIV_OFF:  // Clock divider
            return clk_div;

        case KV_I2C_TX_OFF:  // TX FIFO (write-only; reading not meaningful)
            return tx_data;

        case KV_I2C_RX_OFF:  // RX FIFO pop
            if (!rx_fifo.empty()) {
                uint8_t val = rx_fifo.front();
                rx_fifo.erase(rx_fifo.begin());
                rx_valid = !rx_fifo.empty();
                return val;
            }
            rx_valid = false;
            return 0;

        case KV_I2C_STATUS_OFF:  // Status register
            // [0]=busy (KV_I2C_ST_BUSY), [1]=tx_ready (KV_I2C_ST_TX_READY),
            // [2]=rx_valid (KV_I2C_ST_RX_VALID), [3]=ack_received (KV_I2C_ST_ACK_RECV)
            rx_valid = !rx_fifo.empty();
            tx_ready = (int)tx_fifo.size() < FIFO_DEPTH;
            return (ack_received ? KV_I2C_ST_ACK_RECV : 0u) |
                   (rx_valid     ? KV_I2C_ST_RX_VALID : 0u) |
                   (tx_ready     ? KV_I2C_ST_TX_READY : 0u) |
                   (busy         ? KV_I2C_ST_BUSY     : 0u);

        case KV_I2C_IE_OFF:  // Interrupt enable
            return ie_reg;

        case KV_I2C_IS_OFF:  // Interrupt status (level – read-only, matches RTL is_wire)
            {
                // IS[0] = rx_fifo not empty      (KV_I2C_IE_RX_READY)
                // IS[1] = tx_fifo empty+not busy (KV_I2C_IE_TX_EMPTY)
                // IS[2] = stop_done pulse        (KV_I2C_IE_STOP_DONE; latched by PLIC)
                uint32_t is = 0;
                if (!rx_fifo.empty())        is |= KV_I2C_IE_RX_READY;
                if (tx_fifo.empty() && !busy) is |= KV_I2C_IE_TX_EMPTY;
                if (stop_done)               is |= KV_I2C_IE_STOP_DONE;
                return is;
            }

        case KV_I2C_CAP_OFF:  // CAPABILITY (RO): [7:0]=TX_FIFO, [15:8]=RX_FIFO, [31:16]=VERSION
            return (0x0001u << 16) | (FIFO_DEPTH << 8) | FIFO_DEPTH;  // v0.0001, RX=8, TX=8

        default:
            return 0;
    }
}

void I2CDevice::write(uint32_t offset, uint32_t value, int size) {
    (void)size;
    // Offsets beyond CAP are out-of-range
    if (offset > KV_I2C_CAP_OFF) { last_bus_error = true; return; }
    switch (offset) {
        case KV_I2C_CTRL_OFF:  // Control register
            i2c_enable = (value & KV_I2C_CTRL_ENABLE) != 0;
            start_cmd  = (value & KV_I2C_CTRL_START)  != 0;
            stop_cmd   = (value & KV_I2C_CTRL_STOP)   != 0;
            read_cmd   = (value & KV_I2C_CTRL_READ)   != 0;
            ack_cmd    = (value & KV_I2C_CTRL_NACK)   != 0;

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

        case KV_I2C_DIV_OFF:  // Clock divider
            clk_div = value & 0xFFFF;
            break;

        case KV_I2C_TX_OFF:  // TX FIFO push
            // Push bytes regardless of i2c_enable state – matches RTL where the
            // TX FIFO accepts writes at any time; the controller drains it
            // automatically once enabled and START is issued.
            if ((int)tx_fifo.size() < FIFO_DEPTH)
                tx_fifo.push_back(value & 0xFF);
            break;

        case KV_I2C_IE_OFF:  // Interrupt enable
            ie_reg = value & (KV_I2C_IE_RX_READY | KV_I2C_IE_TX_EMPTY | KV_I2C_IE_STOP_DONE);
            break;

        // KV_I2C_IS_OFF is read-only level
        default:
            break;
    }
}

bool I2CDevice::get_irq() const {
    uint32_t is = 0;
    if (!rx_fifo.empty())          is |= KV_I2C_IE_RX_READY;
    if (tx_fifo.empty() && !busy)  is |= KV_I2C_IE_TX_EMPTY;
    if (stop_done)                 is |= KV_I2C_IE_STOP_DONE;
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
            // START condition executed; reset EEPROM transaction state so the
            // first TX byte is treated as a fresh device-address byte.
            eeprom_tx_state = EepromTxState::IDLE;
            state = State::IDLE;
            busy = false;
            tx_ready = (int)tx_fifo.size() < FIFO_DEPTH;
            // NOTE: do NOT reset eeprom_addr here — a repeated START
            // (read phase) must keep the address set by the prior write phase.
            break;

        case State::WRITE:
            // Write byte to EEPROM
            handle_eeprom_write(tx_data);
            ack_received = true;  // Simulate ACK from slave
            tx_valid = false;
            // Model clock-stretch: hold BUSY for stretch_ticks_per_ack extra
            // ticks before returning to IDLE (byte ACK phase delay).
            if (stretch_ticks_per_ack > 0) {
                state = State::ACK_STRETCH;
                stretch_remaining = stretch_ticks_per_ack;
                // busy stays true
            } else {
                state = State::IDLE;
                busy = false;
                tx_ready = (int)tx_fifo.size() < FIFO_DEPTH;
            }
            break;

        case State::ACK_STRETCH:
            // Hold BUSY while simulating the slave's clock-stretch window.
            if (--stretch_remaining <= 0) {
                state = State::IDLE;
                busy = false;
                tx_ready = (int)tx_fifo.size() < FIFO_DEPTH;
            }
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
            // STOP condition: end of transaction.
            // Reset EEPROM transaction state and address-set flag so the next
            // transaction's write-phase will set a fresh memory pointer.
            eeprom_tx_state  = EepromTxState::IDLE;
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
    // State-machine-based EEPROM protocol tracking.
    // The previous value-pattern approach (checking whether data == 0xA0)
    // incorrectly treats data bytes 0xA0/0xA1 as device-address bytes.
    // This mirrors the spike plugin's I2cTxState machine.
    switch (eeprom_tx_state) {
    case EepromTxState::IDLE:
        // First byte after START: 7-bit device address + R/W bit.
        if ((data >> 1) == 0x50u) {
            eeprom_write_mode = !(data & 0x01u);
            eeprom_tx_state   = EepromTxState::GOT_ADDR;
        }
        // If address does not match we still ACK (single-device sim).
        break;

    case EepromTxState::GOT_ADDR:
        // Second byte: EEPROM memory address.
        eeprom_addr     = data;
        eeprom_addr_set = true;
        eeprom_tx_state = EepromTxState::DATA;
        break;

    case EepromTxState::DATA:
        // Subsequent bytes: data payload (write direction only).
        if (eeprom_write_mode) {
            eeprom_memory[eeprom_addr] = data;
            eeprom_addr = (uint8_t)(eeprom_addr + 1u);
        }
        break;
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
    if (!rx_fifo.empty())  is |= KV_SPI_IE_RX_READY;
    if (!tx_valid)         is |= KV_SPI_IE_TX_EMPTY;
    return (ie_reg & is) != 0;
}

uint32_t SPIDevice::read(uint32_t offset, int size) {
    (void)size;
    // Offsets beyond CAP are out-of-range
    if (offset > KV_SPI_CAP_OFF) { last_bus_error = true; return 0; }
    switch (offset) {
        case KV_SPI_CTRL_OFF:  // Control register
            return ((chip_select & 0xFu) << 4) |
                   (loopback_en ? KV_SPI_CTRL_LOOPBACK : 0u) |
                   (cpha       ? KV_SPI_CTRL_CPHA   : 0u) |
                   (cpol       ? KV_SPI_CTRL_CPOL   : 0u) |
                   (spi_enable ? KV_SPI_CTRL_ENABLE : 0u);

        case KV_SPI_DIV_OFF:  // Clock divider
            return clk_div;

        case KV_SPI_TX_OFF:  // TX FIFO (write-only in RTL; return 0)
            return 0;

        case KV_SPI_RX_OFF:  // RX FIFO pop
            if (!rx_fifo.empty()) {
                uint8_t val = rx_fifo.front();
                rx_fifo.erase(rx_fifo.begin());
                rx_valid = !rx_fifo.empty();  // update valid flag
                return val;
            }
            rx_valid = false;
            return 0;

        case KV_SPI_STATUS_OFF:  // Status register
            // [0]=busy (KV_SPI_ST_BUSY), [1]=tx_ready (KV_SPI_ST_TX_READY),
            // [2]=rx_valid (KV_SPI_ST_RX_VALID)
            return (rx_valid ? KV_SPI_ST_RX_VALID  : 0u) |
                   (!busy    ? KV_SPI_ST_TX_READY  : 0u) |
                   (busy     ? KV_SPI_ST_BUSY      : 0u);

        case KV_SPI_IE_OFF:
            return ie_reg;

        case KV_SPI_IS_OFF: {
            uint32_t is = 0;
            if (!rx_fifo.empty())  is |= KV_SPI_IE_RX_READY;
            if (!busy)             is |= KV_SPI_IE_TX_EMPTY;
            return is;
        }

        case KV_SPI_CAP_OFF:  // CAPABILITY (RO): [7:0]=TX_FIFO, [15:8]=RX_FIFO, [23:16]=NUM_CS, [31:24]=VERSION
            return (0x01u << 24) | (4u << 16) | (8u << 8) | 8u;  // v0.01, 4 CS, RX=8, TX=8

        default:
            return 0;
    }
}

void SPIDevice::write(uint32_t offset, uint32_t value, int size) {
    (void)size;
    // Offsets beyond CAP are out-of-range
    if (offset > KV_SPI_CAP_OFF) { last_bus_error = true; return; }
    switch (offset) {
        case KV_SPI_CTRL_OFF:  // Control register
            spi_enable  = (value & KV_SPI_CTRL_ENABLE)   != 0;
            cpol        = (value & KV_SPI_CTRL_CPOL)     != 0;
            cpha        = (value & KV_SPI_CTRL_CPHA)     != 0;
            loopback_en = (value & KV_SPI_CTRL_LOOPBACK) != 0;
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

        case KV_SPI_DIV_OFF:  // Clock divider
            clk_div = value & 0xFFFF;
            break;

        case KV_SPI_TX_OFF:  // TX FIFO push
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

        case KV_SPI_IE_OFF:
            ie_reg = value & (KV_SPI_IE_RX_READY | KV_SPI_IE_TX_EMPTY);
            break;

        // KV_SPI_RX_OFF and KV_SPI_IS_OFF are read-only
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
// PLIC Device Implementation  (matches RTL kv32_plic.sv)
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
        if (enable_r[i] && pending_r[i] && !claimed_r[i] && priority_r[i] > threshold_r) {
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
    // is low — matching RTL kv32_plic.sv: `if (irq_src[i]) pending_r[i] <= 1`.
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

    // Priority registers: KV_PLIC_PRIORITY_OFF + 4*i  (source 0 always reads 0)
    if (offset >= KV_PLIC_PRIORITY_OFF && offset < KV_PLIC_PENDING_OFF) {
        int src = offset >> 2;
        if (src >= 1 && src <= NUM_IRQ)
            return priority_r[src];
        return 0;
    }

    // Pending register: KV_PLIC_PENDING_OFF (one 32-bit word for sources 1..31)
    if (offset == KV_PLIC_PENDING_OFF) {
        uint32_t pend = 0;
        for (int i = 1; i <= NUM_IRQ; i++) {
            if (pending_r[i]) pend |= (1u << i);
        }
        return pend;
    }

    // Enable register: KV_PLIC_ENABLE_OFF for context 0
    if (offset == KV_PLIC_ENABLE_OFF) {
        uint32_t en = 0;
        for (int i = 1; i <= NUM_IRQ; i++) {
            if (enable_r[i]) en |= (1u << i);
        }
        return en;
    }

    // Threshold: KV_PLIC_THRESHOLD_OFF
    if (offset == KV_PLIC_THRESHOLD_OFF)
        return threshold_r;

    // Claim/Complete: KV_PLIC_CLAIM_OFF — reading performs a claim
    if (offset == KV_PLIC_CLAIM_OFF) {
        int id = best_claim();
        if (id > 0) {
            claimed_r[id] = true;
        }
        return (uint32_t)id;
    }

    last_bus_error = true;  // unrecognised PLIC offset
    return 0;
}

void PLICDevice::write(uint32_t offset, uint32_t value, int size) {
    (void)size;

    // Priority registers
    if (offset >= KV_PLIC_PRIORITY_OFF && offset < KV_PLIC_PENDING_OFF) {
        int src = offset >> 2;
        if (src >= 1 && src <= NUM_IRQ)
            priority_r[src] = value & 0xF;
        return;
    }

    // Enable register for context 0
    // Disabling a source immediately clears its pending and claimed bits,
    // matching Spike plic.cc context_enable_write() behaviour.
    if (offset == KV_PLIC_ENABLE_OFF) {
        for (int i = 1; i <= NUM_IRQ; i++) {
            bool was_enabled = enable_r[i];
            enable_r[i] = (value >> i) & 1;
            if (was_enabled && !enable_r[i]) {
                pending_r[i] = false;
                claimed_r[i] = false;
            }
        }
        return;
    }

    // Threshold
    if (offset == KV_PLIC_THRESHOLD_OFF) {
        threshold_r = value & 0xF;
        return;
    }

    // Claim/Complete: KV_PLIC_CLAIM_OFF — writing completes the interrupt
    if (offset == KV_PLIC_CLAIM_OFF) {
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

    last_bus_error = true;  // unrecognised PLIC offset
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
    if (offset == KV_CLINT_MSIP_OFF) {
        return msip;
    } else if (offset == KV_CLINT_MTIMECMP_LO_OFF) {
        return mtimecmp & 0xFFFFFFFF;
    } else if (offset == KV_CLINT_MTIMECMP_HI_OFF) {
        return (mtimecmp >> 32) & 0xFFFFFFFF;
    } else if (offset == KV_CLINT_MTIME_LO_OFF) {
        return mtime & 0xFFFFFFFF;
    } else if (offset == KV_CLINT_MTIME_HI_OFF) {
        return (mtime >> 32) & 0xFFFFFFFF;
    }
    last_bus_error = true;  // not one of the 5 valid CLINT offsets
    return 0;
}

void CLINTDevice::write(uint32_t offset, uint32_t value, int size) {
    (void)size;
    if (offset == KV_CLINT_MSIP_OFF) {
        msip = value & 0x1;
    } else if (offset == KV_CLINT_MTIMECMP_LO_OFF) {
        mtimecmp = (mtimecmp & 0xFFFFFFFF00000000ULL) | value;
    } else if (offset == KV_CLINT_MTIMECMP_HI_OFF) {
        mtimecmp = (mtimecmp & 0x00000000FFFFFFFFULL) | ((uint64_t)value << 32);
    } else if (offset == KV_CLINT_MTIME_LO_OFF) {
        mtime = (mtime & 0xFFFFFFFF00000000ULL) | value;
    } else if (offset == KV_CLINT_MTIME_HI_OFF) {
        mtime = (mtime & 0x00000000FFFFFFFFULL) | ((uint64_t)value << 32);
    } else {
        last_bus_error = true;  // not one of the 5 valid CLINT offsets
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
// ============================================================================
// DMA Device Implementation
// ============================================================================

DMADevice::DMADevice(ReadFn rfn, WriteFn wfn)
    : mem_read(rfn), mem_write(wfn)
{
    reset();
}

void DMADevice::reset() {
    for (int i = 0; i < NUM_CH; i++) {
        ch[i] = Chan{};
    }
    irq_stat     = 0;
    irq_en       = 0;
    perf_enable   = false;
    perf_cycles   = 0;
    perf_rd_bytes = 0;
    perf_wr_bytes = 0;
    perf_xfer_acc = 0;
}

// Returns true if addr is accessible by DMA (in RAM address space).
bool DMADevice::is_valid_addr(uint32_t addr) const {
    return (addr >= KV_RAM_BASE && addr < (KV_RAM_BASE + KV_RAM_SIZE));
}

// Copy cnt bytes from src to dst.  Address validity is checked before copy.
// Returns false on error (invalid source address).
bool DMADevice::do_1d_copy(uint32_t src, uint32_t dst, uint32_t cnt,
                            bool src_inc, bool dst_inc)
{
    // Validate address range for the full read window
    if (!is_valid_addr(src)) return false;
    if (src_inc && cnt > 0 && !is_valid_addr(src + cnt - 1)) return false;

    for (uint32_t i = 0; i < cnt; i++) {
        uint32_t v = mem_read(src, 1);
        mem_write(dst, v, 1);
        if (src_inc) src++;
        if (dst_inc) dst++;
    }
    if (perf_enable)
        perf_xfer_acc += cnt;
    return true;
}

// Execute the active transfer for channel n.  Returns false on error.
bool DMADevice::execute_transfer(int n)
{
    Chan& c = ch[n];
    uint32_t ctrl  = c.ctrl;
    uint32_t mode  = (ctrl >> 3) & 0x3u;   // bits [4:3]
    bool src_inc   = (ctrl & KV_DMA_CTRL_SRC_INC) != 0;
    bool dst_inc   = (ctrl & KV_DMA_CTRL_DST_INC) != 0;

    switch (mode) {
    case 0: {   // 1D flat
        return do_1d_copy(c.src_addr, c.dst_addr, c.xfer_cnt, src_inc, dst_inc);
    }
    case 1: {   // 2D strided
        for (uint32_t r = 0; r < c.row_cnt; r++) {
            uint32_t s = c.src_addr + r * c.src_stride;
            uint32_t d = c.dst_addr + r * c.dst_stride;
            if (!do_1d_copy(s, d, c.xfer_cnt, src_inc, dst_inc)) return false;
        }
        return true;
    }
    case 2: {   // 3D planar
        for (uint32_t p = 0; p < c.plane_cnt; p++) {
            for (uint32_t r = 0; r < c.row_cnt; r++) {
                uint32_t s = c.src_addr + p * c.src_pstride + r * c.src_stride;
                uint32_t d = c.dst_addr + p * c.dst_pstride + r * c.dst_stride;
                if (!do_1d_copy(s, d, c.xfer_cnt, src_inc, dst_inc)) return false;
            }
        }
        return true;
    }
    case 3: {   // Scatter-Gather
        uint32_t desc = c.sg_addr;
        for (uint32_t i = 0; i < c.sg_cnt; i++) {
            if (!is_valid_addr(desc + 12)) return false;
            uint32_t sg_src  = mem_read(desc +  0, 4);
            uint32_t sg_dst  = mem_read(desc +  4, 4);
            uint32_t sg_cnt  = mem_read(desc +  8, 4);
            uint32_t sg_ctrl = mem_read(desc + 12, 4);
            bool s_inc = (sg_ctrl >> 2) & 1u;
            bool d_inc = (sg_ctrl >> 3) & 1u;
            if (!do_1d_copy(sg_src, sg_dst, sg_cnt, s_inc, d_inc)) return false;
            desc += 16;
        }
        return true;
    }
    default:
        return false;
    }
}

// Set channel completion state, clear BUSY, and raise IRQ if configured.
void DMADevice::finish_channel(int n, bool ok)
{
    Chan& c = ch[n];
    c.stat &= ~0x7u;                        // clear busy / done / err
    c.stat |= ok ? KV_DMA_STAT_DONE        // bit 1
                 : KV_DMA_STAT_ERR;         // bit 2
    c.ctrl &= ~(uint32_t)KV_DMA_CTRL_START; // START auto-clears

    // Raise IRQ if channel IE and global IRQ_EN[n] are both set
    if ((c.ctrl & KV_DMA_CTRL_IE) && (irq_en & (1u << n))) {
        irq_stat |= (1u << n);
    }
}

uint32_t DMADevice::read(uint32_t offset, int size)
{
    (void)size;

    // Global registers
    if (offset == KV_DMA_IRQ_STAT_OFF)      return irq_stat;
    if (offset == KV_DMA_IRQ_EN_OFF)        return irq_en;
    if (offset == KV_DMA_ID_OFF)            return DMA_ID;
    if (offset == KV_DMA_CAP_OFF)           return (0x0001u << 16) | (NUM_CH << 8) | 16u;  // v0.0001, 4 ch, burst=16
    if (offset == KV_DMA_PERF_CTRL_OFF)     return perf_enable ? 1u : 0u;
    if (offset == KV_DMA_PERF_CYCLES_OFF)   return perf_cycles;
    if (offset == KV_DMA_PERF_RD_BYTES_OFF) return perf_rd_bytes;
    if (offset == KV_DMA_PERF_WR_BYTES_OFF) return perf_wr_bytes;

    // Per-channel registers
    if (offset < (uint32_t)(NUM_CH * (int)KV_DMA_CH_STRIDE)) {
        int      n   = (int)(offset / KV_DMA_CH_STRIDE);
        uint32_t reg = offset % KV_DMA_CH_STRIDE;
        const Chan& c = ch[n];
        switch (reg) {
        case KV_DMA_CH_CTRL_OFF:     return c.ctrl;
        case KV_DMA_CH_STAT_OFF:     return c.stat;
        case KV_DMA_CH_SRC_OFF:      return c.src_addr;
        case KV_DMA_CH_DST_OFF:      return c.dst_addr;
        case KV_DMA_CH_XFER_OFF:     return c.xfer_cnt;
        case KV_DMA_CH_SSTRIDE_OFF:  return c.src_stride;
        case KV_DMA_CH_DSTRIDE_OFF:  return c.dst_stride;
        case KV_DMA_CH_ROWCNT_OFF:   return c.row_cnt;
        case KV_DMA_CH_SPSTRIDE_OFF: return c.src_pstride;
        case KV_DMA_CH_DPSTRIDE_OFF: return c.dst_pstride;
        case KV_DMA_CH_PLANECNT_OFF: return c.plane_cnt;
        case KV_DMA_CH_SGADDR_OFF:   return c.sg_addr;
        case KV_DMA_CH_SGCNT_OFF:    return c.sg_cnt;
        default: return 0;
        }
    }
    last_bus_error = true;  // offset in the hole between ch-regs/global-regs, or beyond global area
    return 0;
}

void DMADevice::write(uint32_t offset, uint32_t value, int size)
{
    (void)size;

    // Global registers
    if (offset == KV_DMA_IRQ_STAT_OFF) { irq_stat &= ~value; return; }  // W1C
    if (offset == KV_DMA_IRQ_EN_OFF)   { irq_en    = value;  return; }
    if (offset == KV_DMA_ID_OFF)       { return; }                      // read-only
    if (offset == KV_DMA_CAP_OFF)      { return; }                      // read-only
    if (offset == KV_DMA_PERF_CTRL_OFF) {
        if (value & 2u) {                   // bit[1] = RESET
            perf_enable   = false;
            perf_cycles   = 0;
            perf_rd_bytes = 0;
            perf_wr_bytes = 0;
        } else {
            perf_enable = (value & 1u) != 0; // bit[0] = ENABLE
        }
        return;
    }
    // PERF_CYCLES / RD_BYTES / WR_BYTES are read-only
    if (offset == KV_DMA_PERF_CYCLES_OFF)   { return; }
    if (offset == KV_DMA_PERF_RD_BYTES_OFF) { return; }
    if (offset == KV_DMA_PERF_WR_BYTES_OFF) { return; }

    // Per-channel registers
    if (offset < (uint32_t)(NUM_CH * (int)KV_DMA_CH_STRIDE)) {
        int      n   = (int)(offset / KV_DMA_CH_STRIDE);
        uint32_t reg = offset % KV_DMA_CH_STRIDE;
        Chan& c = ch[n];

        switch (reg) {
        case KV_DMA_CH_CTRL_OFF:
            c.ctrl = value;
            if ((value & KV_DMA_CTRL_EN) && (value & KV_DMA_CTRL_START)) {
                c.stat = KV_DMA_STAT_BUSY;
                perf_xfer_acc = 0;
                bool ok = execute_transfer(n);
                finish_channel(n, ok);
                if (perf_enable) {
                    // Each byte is both read and written; simulate 1 cycle/beat (BPB=4)
                    perf_rd_bytes += perf_xfer_acc;
                    perf_wr_bytes += perf_xfer_acc;
                    perf_cycles   += (perf_xfer_acc + 3u) / 4u * 2u;  // 2 phases × beats
                }
            }
            if (value & KV_DMA_CTRL_STOP) {
                c.stat &= ~(uint32_t)KV_DMA_STAT_BUSY;
                c.ctrl &= ~(uint32_t)KV_DMA_CTRL_STOP;
            }
            break;
        case KV_DMA_CH_STAT_OFF:
            // W1C: clear DONE(bit1) and ERR(bit2); BUSY(bit0) is read-only
            c.stat &= ~(value & 0x6u);
            break;
        case KV_DMA_CH_SRC_OFF:      c.src_addr   = value; break;
        case KV_DMA_CH_DST_OFF:      c.dst_addr   = value; break;
        case KV_DMA_CH_XFER_OFF:     c.xfer_cnt   = value; break;
        case KV_DMA_CH_SSTRIDE_OFF:  c.src_stride = value; break;
        case KV_DMA_CH_DSTRIDE_OFF:  c.dst_stride = value; break;
        case KV_DMA_CH_ROWCNT_OFF:   c.row_cnt    = value; break;
        case KV_DMA_CH_SPSTRIDE_OFF: c.src_pstride = value; break;
        case KV_DMA_CH_DPSTRIDE_OFF: c.dst_pstride = value; break;
        case KV_DMA_CH_PLANECNT_OFF: c.plane_cnt  = value; break;
        case KV_DMA_CH_SGADDR_OFF:   c.sg_addr    = value; break;
        case KV_DMA_CH_SGCNT_OFF:    c.sg_cnt     = value; break;
        default: break;
        }
    }

    // Offset in the hole between per-channel area and global registers, or beyond
    // global registers — mirrors the coarse RTL validity check for SLVERR.
    else { last_bus_error = true; }
}

// ============================================================================
// GPIO Device
// ============================================================================

GPIODevice::GPIODevice() {
    reset();
}

void GPIODevice::reset() {
    for (int i = 0; i < MAX_BANKS; i++) {
        data_out_r[i] = 0;
        dir_r[i] = 0;           // All pins as inputs
        ie_r[i] = 0;
        trigger_r[i] = 0;       // Level-triggered
        polarity_r[i] = 0;      // Falling/low
        is_r[i] = 0;
        loopback_r[i] = 0;
        gpio_i_sync[i] = 0;
        gpio_i_prev[i] = 0;
        external_input[i] = 0;
    }
}

void GPIODevice::tick() {
    // Input synchronization (2-stage)
    for (int i = 0; i < MAX_BANKS; i++) {
        uint32_t gpio_i_ext = 0;

        // Apply loopback: when loopback enabled, use output data instead of external input
        for (int bit = 0; bit < 32; bit++) {
            if (loopback_r[i] & (1u << bit)) {
                if (data_out_r[i] & (1u << bit))
                    gpio_i_ext |= (1u << bit);
            } else {
                if (external_input[i] & (1u << bit))
                    gpio_i_ext |= (1u << bit);
            }
        }

        // Two-stage synchronization
        gpio_i_sync[i] = gpio_i_ext;

        // Edge detection
        for (int bit = 0; bit < 32; bit++) {
            uint32_t mask = (1u << bit);
            bool curr = (gpio_i_sync[i] & mask) != 0;
            bool prev = (gpio_i_prev[i] & mask) != 0;
            bool trig = (trigger_r[i] & mask) != 0;     // 1=edge, 0=level
            bool pol = (polarity_r[i] & mask) != 0;     // 1=rising/high, 0=falling/low

            if (trig) {
                // Edge-triggered
                bool edge = pol ? (curr && !prev) : (!curr && prev);
                if (edge) {
                    is_r[i] |= mask;  // Set interrupt status (sticky)
                }
            }
        }

        gpio_i_prev[i] = gpio_i_sync[i];
    }
}

bool GPIODevice::get_irq() const {
    for (int i = 0; i < MAX_BANKS; i++) {
        uint32_t int_pending = 0;
        for (int bit = 0; bit < 32; bit++) {
            uint32_t mask = (1u << bit);
            bool trig = (trigger_r[i] & mask) != 0;
            bool pol = (polarity_r[i] & mask) != 0;

            if (trig) {
                // Edge-triggered: sticky status
                if (is_r[i] & mask)
                    int_pending |= mask;
            } else {
                // Level-triggered: live input check
                bool curr = (gpio_i_sync[i] & mask) != 0;
                if (pol ? curr : !curr)
                    int_pending |= mask;
            }
        }

        if (ie_r[i] & int_pending)
            return true;
    }
    return false;
}

void GPIODevice::set_external_input(uint32_t bank, uint32_t value) {
    if (bank < MAX_BANKS) {
        external_input[bank] = value;
    }
}

uint32_t GPIODevice::read(uint32_t offset, int size) {
    (void)size;  // Always 32-bit
    uint32_t bank = (offset >> 2) & 3;
    uint32_t reg = offset >> 4;

    switch (reg) {
    case 0x0: return data_out_r[bank];       // DATA_OUT
    case 0x1: return data_out_r[bank];       // SET (read returns current DATA_OUT)
    case 0x2: return data_out_r[bank];       // CLEAR (read returns current DATA_OUT)
    case 0x3: return gpio_i_sync[bank];      // DATA_IN
    case 0x4: return dir_r[bank];            // DIR
    case 0x5: return ie_r[bank];             // IE
    case 0x6: return trigger_r[bank];        // TRIGGER
    case 0x7: return polarity_r[bank];       // POLARITY
    case 0x8: return is_r[bank];             // IS
    case 0x9: return loopback_r[bank];       // LOOPBACK
    case 0xA: return (0x0001u << 16) | (1u << 8) | 4u;  // CAPABILITY: v0.0001, 1 bank, 4 pins
    default:
        last_bus_error = true;  // reg_sel > 0xA is out-of-range
        return 0;
    }
}

void GPIODevice::write(uint32_t offset, uint32_t value, int size) {
    (void)size;  // Always 32-bit
    uint32_t bank = (offset >> 2) & 3;
    uint32_t reg = offset >> 4;

    switch (reg) {
    case 0x0: data_out_r[bank] = value; break;                     // DATA_OUT
    case 0x1: data_out_r[bank] |= value; break;                    // SET (W1S)
    case 0x2: data_out_r[bank] &= ~value; break;                   // CLEAR (W1C)
    case 0x4: dir_r[bank] = value; break;                          // DIR
    case 0x5: ie_r[bank] = value; break;                           // IE
    case 0x6: trigger_r[bank] = value; break;                      // TRIGGER
    case 0x7: polarity_r[bank] = value; break;                     // POLARITY
    case 0x8: is_r[bank] &= ~value; break;                         // IS (W1C)
    case 0x9: loopback_r[bank] = value; break;                     // LOOPBACK
    default:
        last_bus_error = true;  // reg_sel > 0xA is out-of-range
        break;
    }
}

// ============================================================================
// Timer Device
// ============================================================================

TimerDevice::TimerDevice() {
    reset();
}

void TimerDevice::reset() {
    for (int i = 0; i < NUM_TIMERS; i++) {
        ch[i].count_r = 0;
        ch[i].compare1_r = 0;
        ch[i].compare2_r = 0xFFFFFFFFu;
        ch[i].ctrl_r = 0;
        ch[i].timer_en = false;
        ch[i].pwm_en = false;
        ch[i].int_en = false;
        ch[i].pwm_pol = false;
        ch[i].prescale = 0;
        ch[i].prescale_cnt = 0;
        ch[i].pwm_output_raw = false;
    }
    int_status_r = 0;
    int_enable_r = 0;
}

void TimerDevice::tick() {
    for (int i = 0; i < NUM_TIMERS; i++) {
        if (!ch[i].timer_en)
            continue;

        // Prescaler
        bool timer_tick = false;
        if (ch[i].prescale_cnt >= ch[i].prescale) {
            ch[i].prescale_cnt = 0;
            timer_tick = true;
        } else {
            ch[i].prescale_cnt++;
        }

        if (!timer_tick)
            continue;

        // Compare matches
        bool compare1_match = (ch[i].count_r == ch[i].compare1_r);
        bool compare2_match = (ch[i].count_r == ch[i].compare2_r);

        // Counter reload
        bool reload = compare2_match;

        // Update counter
        if (reload) {
            ch[i].count_r = 0;
            ch[i].pwm_output_raw = false;  // Clear on reload for clean period start
        } else {
            ch[i].count_r++;
        }

        // PWM output generation
        if (ch[i].pwm_en) {
            if (compare1_match) {
                ch[i].pwm_output_raw = true;   // Set on COMPARE1
            }
            if (compare2_match) {
                ch[i].pwm_output_raw = false;  // Clear on COMPARE2
            }
        } else {
            ch[i].pwm_output_raw = false;
        }

        // Interrupt generation (both COMPARE1 and COMPARE2 can trigger)
        if ((compare1_match || compare2_match) && ch[i].int_en) {
            int_status_r |= (1u << i);
        }
    }
}

bool TimerDevice::get_irq() const {
    return (int_status_r & int_enable_r) != 0;
}

bool TimerDevice::get_irq_ch(int ch) const {
    if (ch < 0 || ch >= NUM_TIMERS) return false;
    return ((int_status_r >> ch) & 1u) && ((int_enable_r >> ch) & 1u);
}

bool TimerDevice::get_pwm_output(int timer_num) const {
    if (timer_num < 0 || timer_num >= NUM_TIMERS)
        return false;
    return ch[timer_num].pwm_pol ? ch[timer_num].pwm_output_raw : !ch[timer_num].pwm_output_raw;
}

uint32_t TimerDevice::read(uint32_t offset, int size) {
    (void)size;  // Always 32-bit

    // Global registers
    if (offset == KV_TIMER_INT_STATUS_OFF) {
        return int_status_r;
    }
    if (offset == KV_TIMER_INT_ENABLE_OFF) {
        return int_enable_r;
    }
    if (offset == KV_TIMER_CAP_OFF) {  // CAPABILITY (RO): [7:0]=NUM_CHANNELS, [15:8]=COUNTER_WIDTH, [31:16]=VERSION
        return (0x0001u << 16) | (32u << 8) | NUM_TIMERS;  // v0.0001, 32-bit, 4 timers
    }

    // Per-channel registers
    uint32_t timer_num = offset / KV_TIMER_CH_STRIDE;
    uint32_t reg_off = offset % KV_TIMER_CH_STRIDE;

    if (timer_num >= NUM_TIMERS) {
        last_bus_error = true;  // offset beyond last timer channel (and not a global reg)
        return 0;
    }

    switch (reg_off) {
    case KV_TIMER_COUNT_OFF:    return ch[timer_num].count_r;
    case KV_TIMER_COMPARE1_OFF: return ch[timer_num].compare1_r;
    case KV_TIMER_COMPARE2_OFF: return ch[timer_num].compare2_r;
    case KV_TIMER_CTRL_OFF:     return ch[timer_num].ctrl_r;
    default: return 0;
    }
}

void TimerDevice::write(uint32_t offset, uint32_t value, int size) {
    (void)size;  // Always 32-bit

    // Global registers
    if (offset == KV_TIMER_INT_STATUS_OFF) {
        int_status_r &= ~value;  // W1C
        return;
    }
    if (offset == KV_TIMER_INT_ENABLE_OFF) {
        int_enable_r = value & 0xFu;  // 4 timers
        return;
    }

    // Per-channel registers
    uint32_t timer_num = offset / KV_TIMER_CH_STRIDE;
    uint32_t reg_off = offset % KV_TIMER_CH_STRIDE;

    if (timer_num >= NUM_TIMERS) {
        last_bus_error = true;  // offset beyond last timer channel (and not a global reg)
        return;
    }

    switch (reg_off) {
    case KV_TIMER_COUNT_OFF:
        ch[timer_num].count_r = value;
        break;
    case KV_TIMER_COMPARE1_OFF:
        ch[timer_num].compare1_r = value;
        break;
    case KV_TIMER_COMPARE2_OFF:
        ch[timer_num].compare2_r = value;
        break;
    case KV_TIMER_CTRL_OFF:
        ch[timer_num].ctrl_r = value;
        // Decode control bits
        ch[timer_num].timer_en = (value & (1u << 0)) != 0;
        ch[timer_num].pwm_en   = (value & (1u << 1)) != 0;
        ch[timer_num].int_en   = (value & (1u << 3)) != 0;
        ch[timer_num].pwm_pol  = (value & (1u << 4)) != 0;
        ch[timer_num].prescale = (value >> 16) & 0xFFFFu;

        // Reset prescaler counter when disabled
        if (!ch[timer_num].timer_en) {
            ch[timer_num].prescale_cnt = 0;
        }
        break;
    default:
        break;
    }
}

// ============================================================================
// Watchdog Timer Device Implementation
// ============================================================================

WatchdogDevice::WatchdogDevice() {
    reset();
}

void WatchdogDevice::reset() {
    ctrl_r        = 0;
    load_r        = 0xFFFFFFFFu;
    count_r       = 0xFFFFFFFFu;
    status_r      = 0;
    reset_pending = false;
}

void WatchdogDevice::tick() {
    if (!(ctrl_r & 1u)) return;  // EN=0: stopped
    if (count_r == 0)   return;  // Already expired; latch held until KICK
    count_r--;
    if (count_r == 0) {
        // Expiry event
        if (ctrl_r & 2u) {
            status_r |= 1u;     // INTR_EN=1: set WDT_INT
        } else {
            reset_pending = true; // INTR_EN=0: hardware reset
        }
    }
}

bool WatchdogDevice::get_irq() const {
    return ((status_r & 1u) && (ctrl_r & 2u));
}

bool WatchdogDevice::consume_reset() {
    bool v = reset_pending;
    reset_pending = false;
    return v;
}

uint32_t WatchdogDevice::read(uint32_t offset, int size) {
    (void)size;
    switch (offset) {
    case KV_WDT_CTRL_OFF:   return ctrl_r;
    case KV_WDT_LOAD_OFF:   return load_r;
    case KV_WDT_COUNT_OFF:  return count_r;
    case KV_WDT_KICK_OFF:   return 0u;          // WO: reads return 0
    case KV_WDT_STATUS_OFF: return status_r;
    case KV_WDT_CAP_OFF:    return 0x00010020u;  // version=1, width=32
    default:
        last_bus_error = true;
        return 0u;
    }
}

void WatchdogDevice::write(uint32_t offset, uint32_t value, int size) {
    (void)size;
    switch (offset) {
    case KV_WDT_CTRL_OFF:
        ctrl_r = value & 3u;    // Only bits [1:0] are writable
        break;
    case KV_WDT_LOAD_OFF:
        load_r = value;
        break;
    case KV_WDT_COUNT_OFF:
        break;                  // COUNT is RO
    case KV_WDT_KICK_OFF:
        count_r = load_r;       // Any write reloads COUNT from LOAD
        break;
    case KV_WDT_STATUS_OFF:
        status_r &= ~value;     // W1C
        break;
    case KV_WDT_CAP_OFF:
        break;                  // CAP is RO
    default:
        last_bus_error = true;
        break;
    }
}


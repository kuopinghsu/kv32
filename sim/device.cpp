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
    if (offset == MAGIC_CONSOLE_REG) {
        return 0;
    }
    if (offset == MAGIC_EXIT_REG) {
        return 0;
    }
    return 0;
}

void MagicDevice::write(uint32_t offset, uint32_t value, int size) {
    (void)size;
    if (offset == MAGIC_CONSOLE_REG) {
        char c = value & 0xFF;
        std::cout << c << std::flush;
        return;
    }

    if (offset == MAGIC_EXIT_REG) {
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
// UART Device Implementation
// ============================================================================

UARTDevice::UARTDevice() : tx_data(0), rx_data(0), tx_busy(false) {
    reset();
}

void UARTDevice::reset() {
    tx_data = 0;
    rx_data = 0;
    tx_busy = false;
    rx_fifo.clear();
    tx_fifo.clear();
}

uint32_t UARTDevice::read(uint32_t offset, int size) {
    (void)size;
    switch (offset) {
        case UART_DATA_REG:  // Data register (RX)
            if (!rx_fifo.empty()) {
                rx_data = rx_fifo.front();
                rx_fifo.erase(rx_fifo.begin());
                return rx_data;
            }
            return 0;

        case UART_STATUS_REG:  // Status register
            {
                uint32_t status = 0;
                if (tx_busy)
                    status |= 0x01;  // TX busy
                if (!rx_fifo.empty())
                    status |= 0x04;  // RX ready
                return status;
            }

        default:
            return 0;
    }
}

void UARTDevice::write(uint32_t offset, uint32_t value, int size) {
    (void)size;
    switch (offset) {
        case UART_DATA_REG:  // Data register (TX)
            {
                char c = value & 0xFF;
                std::cout << c << std::flush;
                tx_fifo.push_back(c);
                tx_data = c;
                tx_busy = false;  // Instant TX for simulation
            }
            break;

        default:
            break;
    }
}

void UARTDevice::add_rx_data(uint8_t data) {
    rx_fifo.push_back(data);
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

    // Initialize EEPROM with pattern 0xA0 + address
    for (int i = 0; i < 256; i++) {
        eeprom_memory[i] = 0xA0 + i;
    }
}

uint32_t I2CDevice::read(uint32_t offset, int size) {
    (void)size;
    switch (offset) {
        case I2C_CONTROL_REG:  // Control register
            return (ack_cmd << 4) | (read_cmd << 3) | (stop_cmd << 2) |
                   (start_cmd << 1) | i2c_enable;

        case I2C_CLKDIV_REG:  // Clock divider
            return clk_div;

        case I2C_TXDATA_REG:  // TX data
            return tx_data;

        case I2C_RXDATA_REG:  // RX data
            rx_valid = false;  // Clear on read
            return rx_data;

        case I2C_STATUS_REG:  // Status register
            return (ack_received << 3) | (rx_valid << 2) | (tx_ready << 1) | busy;

        default:
            return 0;
    }
}

void I2CDevice::write(uint32_t offset, uint32_t value, int size) {
    (void)size;
    switch (offset) {
        case I2C_CONTROL_REG:  // Control register
            i2c_enable = value & 0x01;
            start_cmd = value & 0x02;
            stop_cmd = value & 0x04;
            read_cmd = value & 0x08;
            ack_cmd = value & 0x10;

            // Auto-clear command bits (simulating RTL behavior)
            if (start_cmd || stop_cmd) {
                // These will be cleared in next tick
            }

            // Execute commands
            if (start_cmd && i2c_enable) {
                state = State::START;
                busy = true;
                tx_ready = false;
                eeprom_addr_set = false;
            } else if (stop_cmd && i2c_enable) {
                state = State::STOP;
                busy = true;
            }
            break;

        case I2C_CLKDIV_REG:  // Clock divider
            clk_div = value & 0xFFFF;
            break;

        case I2C_TXDATA_REG:  // TX data
            // Accept TX data only when not busy and enabled (matches RTL)
            if (!busy && i2c_enable) {
                tx_data = value & 0xFF;
                tx_valid = true;
                shift_reg = tx_data;
                // RTL automatically starts transaction when tx_valid is set
                // This will be processed in next tick
            }
            break;

        default:
            break;
    }
}

void I2CDevice::tick() {
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

    // Match RTL behavior: when tx_valid is set in IDLE, automatically start transaction
    if (state == State::IDLE && tx_valid) {
        if (read_cmd) {
            state = State::READ;
        } else {
            state = State::WRITE;
        }
        busy = true;
        tx_ready = false;
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
            tx_ready = true;
            break;

        case State::WRITE:
            // Write byte to EEPROM
            handle_eeprom_write(tx_data);
            ack_received = true;  // Simulate ACK from slave
            tx_valid = false;
            state = State::IDLE;
            busy = false;
            tx_ready = true;
            break;

        case State::READ:
            // Read byte from EEPROM
            rx_data = handle_eeprom_read();
            rx_valid = true;
            tx_valid = false;
            state = State::IDLE;
            busy = false;
            tx_ready = true;
            break;

        case State::STOP:
            // STOP condition executed
            state = State::IDLE;
            busy = false;
            break;

        default:
            state = State::IDLE;
            break;
    }
}

void I2CDevice::handle_eeprom_write(uint8_t data) {
    if (!eeprom_addr_set) {
        // First byte is the EEPROM address
        if ((tx_data & 0xFE) == 0xA0) {
            // This is device address (0x50 << 1) - ignore R/W bit
            return;
        }
        eeprom_addr = data;
        eeprom_addr_set = true;
    } else {
        // Subsequent bytes are data
        eeprom_memory[eeprom_addr] = data;
        eeprom_addr = (eeprom_addr + 1) & 0xFF;
    }
}

uint8_t I2CDevice::handle_eeprom_read() {
    if ((tx_data & 0xFE) == 0xA0) {
        // This is device address with read bit
        return 0;
    }

    if (!eeprom_addr_set) {
        // First byte should be address
        eeprom_addr = tx_data;
        eeprom_addr_set = true;
        return 0;
    }

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

    // Initialize SPI flash with pattern (address value)
    for (int cs = 0; cs < 4; cs++) {
        for (int i = 0; i < 4096; i++) {
            flash_memory[cs][i] = (i & 0xFF);  // Same pattern for all CS lines
        }
        flash_addr[cs] = 0;
        flash_addr_set[cs] = false;
        flash_addr_bytes[cs] = 0;
    }
}

uint32_t SPIDevice::read(uint32_t offset, int size) {
    (void)size;
    switch (offset) {
        case SPI_CONTROL_REG:  // Control register
            return (chip_select << 4) | (cpha << 2) | (cpol << 1) | spi_enable;

        case SPI_CLKDIV_REG:  // Clock divider
            return clk_div;

        case SPI_TXDATA_REG:  // TX data
            return tx_data;

        case SPI_RXDATA_REG:  // RX data
            rx_valid = false;  // Clear on read
            return rx_data;

        case SPI_STATUS_REG:  // Status register
            return (rx_valid << 2) | (tx_ready << 1) | busy;

        case SPI_CS_REG:  // Chip select
            return chip_select;

        default:
            return 0;
    }
}

void SPIDevice::write(uint32_t offset, uint32_t value, int size) {
    (void)size;
    switch (offset) {
        case SPI_CONTROL_REG:  // Control register
            spi_enable = value & 0x01;
            cpol = value & 0x02;
            cpha = value & 0x04;
            chip_select = (value >> 4) & 0x0F;
            // Reset flash state when CS changes
            for (int cs = 0; cs < 4; cs++) {
                if (chip_select & (1 << cs)) {
                    flash_addr_set[cs] = false;
                    flash_addr_bytes[cs] = 0;
                }
            }
            break;

        case SPI_CLKDIV_REG:  // Clock divider
            clk_div = value & 0xFFFF;
            break;

        case SPI_TXDATA_REG:  // TX data
            if (!busy && spi_enable) {
                tx_data = value & 0xFF;
                tx_valid = true;
                shift_reg = tx_data;
                state = State::TRANSFER;
                busy = true;
                tx_ready = false;
            }
            break;

        case SPI_CS_REG:  // Chip select
            chip_select = value & 0x0F;
            // Reset flash state when CS changes
            for (int cs = 0; cs < 4; cs++) {
                if (chip_select & (1 << cs)) {
                    flash_addr_set[cs] = false;
                    flash_addr_bytes[cs] = 0;
                }
            }
            break;

        default:
            break;
    }
}

void SPIDevice::tick() {
    if (!busy || !spi_enable)
        return;

    process_spi_transfer();
}

void SPIDevice::process_spi_transfer() {
    // Simplified SPI transfer for simulation
    if (state == State::TRANSFER) {
        // Determine which CS is active (0 = active)
        int active_cs = -1;
        for (int cs = 0; cs < 4; cs++) {
            if (!(chip_select & (1 << cs))) {
                active_cs = cs;
                break;
            }
        }

        if (active_cs >= 0) {
            // Handle flash command/data
            if (!flash_addr_set[active_cs]) {
                handle_flash_command(active_cs, tx_data);
            } else {
                rx_data = handle_flash_read(active_cs);
                rx_valid = true;
            }
        } else {
            rx_data = 0xFF;  // No device selected
            rx_valid = true;
        }

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
            flash_addr_bytes[cs] = 1;
        }
    } else if (flash_addr_bytes[cs] == 1) {
        // This is the address (simplified: 1 byte address for 256 byte space)
        flash_addr[cs] = cmd;
        flash_addr_set[cs] = true;
        flash_addr_bytes[cs] = 0;
    }
}

uint8_t SPIDevice::handle_flash_read(int cs) {
    uint8_t data = flash_memory[cs][flash_addr[cs] & 0xFFF];
    flash_addr[cs] = (flash_addr[cs] + 1) & 0xFFF;
    return data;
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
    if (offset == CLINT_MSIP) {
        return msip;
    } else if (offset == CLINT_MTIMECMP) {
        return mtimecmp & 0xFFFFFFFF;
    } else if (offset == CLINT_MTIMECMPH) {
        return (mtimecmp >> 32) & 0xFFFFFFFF;
    } else if (offset == CLINT_MTIME) {
        return mtime & 0xFFFFFFFF;
    } else if (offset == CLINT_MTIMEH) {
        return (mtime >> 32) & 0xFFFFFFFF;
    }
    return 0;
}

void CLINTDevice::write(uint32_t offset, uint32_t value, int size) {
    (void)size;
    if (offset == CLINT_MSIP) {
        msip = value & 0x1;
    } else if (offset == CLINT_MTIMECMP) {
        mtimecmp = (mtimecmp & 0xFFFFFFFF00000000ULL) | value;
    } else if (offset == CLINT_MTIMECMPH) {
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

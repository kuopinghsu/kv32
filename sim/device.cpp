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
// UART Device Implementation  (FIFO-based, matches axi_uart.sv)
// ============================================================================

UARTDevice::UARTDevice() : ie_reg(0) {
    reset();
}

void UARTDevice::reset() {
    rx_fifo.clear();
    tx_fifo.clear();
    ie_reg = 0;
}

// IS signals (level, read-only)
//   IS[0] = !rx_fifo.empty()  (rx_not_empty)
//   IS[1] = tx_fifo.empty()   (tx_empty; always 1 since sim TX is instant)
static uint32_t uart_is(const std::vector<uint8_t>& rx_fifo, const std::vector<uint8_t>& tx_fifo) {
    uint32_t r = 0;
    if (!rx_fifo.empty())       r |= (1u << 0);  // rx_not_empty
    if (tx_fifo.empty())        r |= (1u << 1);  // tx_empty
    return r;
}

bool UARTDevice::get_irq() const {
    return (ie_reg & uart_is(rx_fifo, tx_fifo)) != 0;
}

uint32_t UARTDevice::read(uint32_t offset, int size) {
    (void)size;
    switch (offset) {
        case UART_DATA_REG:  // RX FIFO pop
            if (!rx_fifo.empty()) {
                uint8_t val = rx_fifo.front();
                rx_fifo.erase(rx_fifo.begin());
                return val;
            }
            return 0;

        case UART_STATUS_REG: {
            // [0] = tx_full (sim TX FIFO is unbounded → never full → 0)
            // [1] = tx_full (same)
            // [2] = rx_not_empty
            // [3] = rx_full
            bool rx_ne = !rx_fifo.empty();
            bool rx_full = ((int)rx_fifo.size() >= FIFO_DEPTH);
            return (rx_full ? 0x08u : 0u) |
                   (rx_ne  ? 0x04u : 0u);
        }

        case UART_IE_REG:
            return ie_reg;

        case UART_IS_REG:
            return uart_is(rx_fifo, tx_fifo);

        case UART_LEVEL_REG: {
            uint32_t rx_cnt = (uint32_t)rx_fifo.size() & 0x1F;
            uint32_t tx_cnt = (uint32_t)tx_fifo.size() & 0x1F;
            return (tx_cnt << 8) | rx_cnt;
        }

        default:
            return 0;
    }
}

void UARTDevice::write(uint32_t offset, uint32_t value, int size) {
    (void)size;
    switch (offset) {
        case UART_DATA_REG: {  // TX FIFO push → print immediately in simulation
            char c = (char)(value & 0xFF);
            std::cout << c << std::flush;
            tx_fifo.push_back((uint8_t)c);
            break;
        }
        // UART_STATUS_REG is read-only

        case UART_IE_REG:
            ie_reg = value & 0x03;
            break;

        // UART_IS_REG is read-only level; no W1C in simulation
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
            // [0]=busy, [1]=tx_ready, [2]=rx_valid, [3]=ack_received
            return (ack_received << 3) | (rx_valid << 2) | (tx_ready << 1) | busy;

        case I2C_IE_REG:  // Interrupt enable
            return ie_reg;

        case I2C_IS_REG:  // Interrupt status (level)
            {
                uint32_t is = 0;
                if (rx_valid)       is |= (1u << 0);  // rx_not_empty
                if (!busy)          is |= (1u << 1);  // tx_empty (FIFO effectively empty when idle)
                if (stop_done)      is |= (1u << 2);  // stop/done
                stop_done = false;  // clear on IS read (like a W1C)
                return is;
            }

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

        case I2C_IE_REG:  // Interrupt enable
            ie_reg = value & 0x07;
            break;

        // I2C_IS_REG is read-only level
        default:
            break;
    }
}

bool I2CDevice::get_irq() const {
    uint32_t is = 0;
    if (rx_valid)   is |= (1u << 0);
    if (!busy)      is |= (1u << 1);
    if (stop_done)  is |= (1u << 2);
    return (ie_reg & is) != 0;
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
            // STOP condition executed — end of full I2C transaction.
            // Reset address tracking so the next transaction's write-phase
            // will correctly re-set the EEPROM memory pointer.
            eeprom_addr_set = false;
            stop_done = true;   // level signal; cleared when IS is read
            state = State::IDLE;
            busy = false;
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
    }
}

bool SPIDevice::get_irq() const {
    uint32_t is = 0;
    if (!rx_fifo.empty())   is |= (1u << 0);  // rx_not_empty
    if (tx_valid == false)  is |= (1u << 1);  // tx_empty
    return (ie_reg & is) != 0;
}

uint32_t SPIDevice::read(uint32_t offset, int size) {
    (void)size;
    switch (offset) {
        case SPI_CONTROL_REG:  // Control register
            return (chip_select << 4) | (cpha << 2) | (cpol << 1) | spi_enable;

        case SPI_CLKDIV_REG:  // Clock divider
            return clk_div;

        case SPI_TXDATA_REG:  // TX data (write-only in RTL; return 0)
            return 0;

        case SPI_RXDATA_REG:  // RX FIFO pop
            if (!rx_fifo.empty()) {
                uint8_t val = rx_fifo.front();
                rx_fifo.erase(rx_fifo.begin());
                rx_valid = !rx_fifo.empty();  // update valid flag
                return val;
            }
            rx_valid = false;
            return 0;

        case SPI_STATUS_REG:  // Status register
            // [0]=busy, [1]=tx_ready(!full), [2]=rx_valid(!empty),
            // [3]=tx_empty, [4]=rx_full
            return (rx_valid ? 0x04u : 0u) |
                   (!busy   ? 0x02u : 0u) |  // tx_ready ≈ !busy
                   (busy    ? 0x01u : 0u);

        case SPI_IE_REG:
            return ie_reg;

        case SPI_IS_REG: {
            uint32_t is = 0;
            if (!rx_fifo.empty())   is |= (1u << 0);
            if (!busy)              is |= (1u << 1);
            return is;
        }

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

        case SPI_TXDATA_REG:  // TX FIFO push
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

        case SPI_IE_REG:
            ie_reg = value & 0x03;
            break;

        // SPI_RXDATA_REG and SPI_IS_REG are read-only
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
        // Determine which CS is active (0 = active)
        int active_cs = -1;
        for (int cs = 0; cs < 4; cs++) {
            if (!(chip_select & (1 << cs))) {
                active_cs = cs;
                break;
            }
        }

        uint8_t recv;
        if (active_cs >= 0) {
            // Handle flash command/data
            if (!flash_addr_set[active_cs]) {
                handle_flash_command(active_cs, tx_data);
                recv = 0xFF;  // dummy byte while sending command/addr
            } else {
                recv = handle_flash_read(active_cs);
            }
        } else {
            recv = 0xFF;  // No device selected
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
    // Level-triggered: set pending whenever irq_src is asserted
    // Re-assert after complete if source still high (matches RTL)
    for (int i = 1; i <= NUM_IRQ; i++) {
        if (mask & (1u << i)) {
            pending_r[i] = true;
        } else if (!claimed_r[i]) {
            // If source de-asserts and not currently claimed, clear pending
            // (RTL clears pending on complete when irq_src=0; here we approximate
            //  by clearing when source is low and not in flight)
            pending_r[i] = false;
        }
    }
}

bool PLICDevice::get_external_interrupt() const {
    return best_claim() != 0;
}

uint32_t PLICDevice::read(uint32_t offset, int size) {
    (void)size;

    // Priority registers: 0x000000 + 4*i  (source 0 always reads 0)
    if (offset >= 0x000000 && offset < 0x001000) {
        int src = offset >> 2;
        if (src >= 1 && src <= NUM_IRQ)
            return priority_r[src];
        return 0;
    }

    // Pending register: 0x001000 (one 32-bit word for sources 1..31)
    if (offset == PLIC_PENDING_0) {
        uint32_t pend = 0;
        for (int i = 1; i <= NUM_IRQ; i++) {
            if (pending_r[i]) pend |= (1u << i);
        }
        return pend;
    }

    // Enable register: 0x002000 for context 0
    if (offset == PLIC_ENABLE_0) {
        uint32_t en = 0;
        for (int i = 1; i <= NUM_IRQ; i++) {
            if (enable_r[i]) en |= (1u << i);
        }
        return en;
    }

    // Threshold: 0x200000
    if (offset == PLIC_THRESHOLD_0)
        return threshold_r;

    // Claim/Complete: 0x200004 — reading performs a claim
    if (offset == PLIC_CLAIM_0) {
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
    if (offset >= 0x000000 && offset < 0x001000) {
        int src = offset >> 2;
        if (src >= 1 && src <= NUM_IRQ)
            priority_r[src] = value & 0x7;
        return;
    }

    // Enable register for context 0
    if (offset == PLIC_ENABLE_0) {
        for (int i = 1; i <= NUM_IRQ; i++) {
            enable_r[i] = (value >> i) & 1;
        }
        return;
    }

    // Threshold
    if (offset == PLIC_THRESHOLD_0) {
        threshold_r = value & 0x7;
        return;
    }

    // Claim/Complete: 0x200004 — writing completes the interrupt
    if (offset == PLIC_CLAIM_0) {
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

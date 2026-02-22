// Device Driver Interface for RV32 Simulator
// Provides abstract interface for peripheral devices (UART, I2C, SPI, etc.)

#ifndef DEVICE_H
#define DEVICE_H

#include <stdint.h>
#include <vector>
#include <string>

// =============================================================================
// Memory Interface Address Map (Universal Slave Interface)
// =============================================================================

// Main memory
#define MEM_BASE            0x80000000
#define MEM_SIZE            (2 * 1024 * 1024)  // 2MB

// CLINT slave window
#define CLINT_BASE          0x02000000
#define CLINT_SIZE          0x00010000

// UART slave window
#define UART_BASE           0x02010000
#define UART_SIZE           0x00010000

// SPI slave window
#define SPI_BASE            0x02020000
#define SPI_SIZE            0x00010000

// I2C slave window
#define I2C_BASE            0x02030000
#define I2C_SIZE            0x00010000

// Magic slave window
#define MAGIC_BASE          0xFFFF0000
#define MAGIC_SIZE          0x00010000

// =============================================================================
// Device Register Offsets (window-relative)
// =============================================================================

// Magic device registers
#define MAGIC_EXIT_REG      0xFFF0
#define MAGIC_CONSOLE_REG   0xFFF4

// UART registers
#define UART_DATA_REG       0x00
#define UART_STATUS_REG     0x04

// SPI registers
#define SPI_CONTROL_REG     0x00
#define SPI_CLKDIV_REG      0x04
#define SPI_TXDATA_REG      0x08
#define SPI_RXDATA_REG      0x0C
#define SPI_STATUS_REG      0x10
#define SPI_CS_REG          0x14

// I2C registers
#define I2C_CONTROL_REG     0x00
#define I2C_CLKDIV_REG      0x04
#define I2C_TXDATA_REG      0x08
#define I2C_RXDATA_REG      0x0C
#define I2C_STATUS_REG      0x10

// CLINT registers
#define CLINT_MSIP          0x0000
#define CLINT_MTIMECMP      0x4000
#define CLINT_MTIMECMPH     0x4004
#define CLINT_MTIME         0xBFF8
#define CLINT_MTIMEH        0xBFFC

// Abstract base class for all peripheral devices
class Device {
public:
    virtual ~Device() {}

    // Read from device register (offset relative to device base)
    virtual uint32_t read(uint32_t offset, int size) = 0;

    // Write to device register (offset relative to device base)
    virtual void write(uint32_t offset, uint32_t value, int size) = 0;

    // Get device name for debugging
    virtual const char* name() const = 0;

    // Tick the device (called every cycle for time-based operations)
    virtual void tick() {}
    virtual void untick() {}  // Undo a tick (default: no-op)

    // Reset the device
    virtual void reset() {}
};

// Main memory as a slave device
class MemoryDevice : public Device {
private:
    std::vector<uint8_t> bytes;

public:
    explicit MemoryDevice(uint32_t size);
    virtual ~MemoryDevice() {}

    virtual uint32_t read(uint32_t offset, int size) override;
    virtual void write(uint32_t offset, uint32_t value, int size) override;
    virtual const char* name() const override { return "RAM"; }
    virtual void reset() override;
    uint32_t size() const { return (uint32_t)bytes.size(); }
};

// Magic Device Driver
// Base address: 0xFFFF0000 (64KB window)
// Registers (window-relative offsets):
//   0xFFF4: Console output (write low byte)
//   0xFFF0: Exit magic (write exit code encoding)
class MagicDevice : public Device {
private:
    bool exit_pending;
    int exit_code;

public:
    MagicDevice();
    virtual ~MagicDevice() {}

    virtual uint32_t read(uint32_t offset, int size) override;
    virtual void write(uint32_t offset, uint32_t value, int size) override;
    virtual const char* name() const override { return "MAGIC"; }
    virtual void reset() override;

    bool consume_exit_request(int* code_out = nullptr);
};

// UART Device Driver
// Base address: 0x02010000
// Registers:
//   0x00: TX/RX Data
//   0x04: Status (bit[0]=tx_busy, bit[2]=rx_ready)
class UARTDevice : public Device {
private:
    uint8_t tx_data;
    uint8_t rx_data;
    bool tx_busy;
    std::vector<uint8_t> rx_fifo;
    std::vector<uint8_t> tx_fifo;

public:
    UARTDevice();
    virtual ~UARTDevice() {}

    virtual uint32_t read(uint32_t offset, int size) override;
    virtual void write(uint32_t offset, uint32_t value, int size) override;
    virtual const char* name() const override { return "UART"; }
    virtual void reset() override;

    // Add data to RX FIFO (for loopback or external input)
    void add_rx_data(uint8_t data);

    // Get TX FIFO contents (for testing)
    const std::vector<uint8_t>& get_tx_fifo() const { return tx_fifo; }
};

// I2C Device Driver
// Base address: 0x02030000
// Registers:
//   0x00: Control (enable, start, stop, read, ack)
//   0x04: Clock Divider
//   0x08: TX Data
//   0x0C: RX Data
//   0x10: Status (busy, tx_ready, rx_valid, ack_received)
class I2CDevice : public Device {
private:
    // Control register fields
    bool i2c_enable;
    bool start_cmd;
    bool stop_cmd;
    bool read_cmd;
    bool ack_cmd;

    // Clock divider
    uint16_t clk_div;
    uint16_t clk_counter;

    // Data registers
    uint8_t tx_data;
    uint8_t rx_data;
    bool tx_valid;

    // Status flags
    bool busy;
    bool tx_ready;
    bool rx_valid;
    bool ack_received;

    // State machine
    enum class State {
        IDLE,
        START,
        ADDR,
        WRITE,
        READ,
        ACK_CHECK,
        ACK_SEND,
        STOP
    };
    State state;

    // I2C transaction tracking
    uint8_t shift_reg;
    int bit_counter;
    int scl_phase;

    // Simulated EEPROM (256 bytes at address 0x50)
    uint8_t eeprom_memory[256];
    uint8_t eeprom_addr;
    bool eeprom_addr_set;

public:
    I2CDevice();
    virtual ~I2CDevice() {}

    virtual uint32_t read(uint32_t offset, int size) override;
    virtual void write(uint32_t offset, uint32_t value, int size) override;
    virtual const char* name() const override { return "I2C"; }
    virtual void tick() override;
    virtual void reset() override;

private:
    void process_i2c_transaction();
    void handle_eeprom_write(uint8_t data);
    uint8_t handle_eeprom_read();
};

// SPI Device Driver
// Base address: 0x02020000
// Registers:
//   0x00: Control (enable, cpol, cpha)
//   0x04: Clock Divider
//   0x08: TX Data
//   0x0C: RX Data
//   0x10: Status (busy, tx_ready, rx_valid)
//   0x14: Chip Select (4-bit CS mask)
class SPIDevice : public Device {
private:
    // Control register fields
    bool spi_enable;
    bool cpol;  // Clock polarity
    bool cpha;  // Clock phase

    // Clock divider
    uint16_t clk_div;
    uint16_t clk_counter;

    // Data registers
    uint8_t tx_data;
    uint8_t rx_data;
    bool tx_valid;

    // Status flags
    bool busy;
    bool tx_ready;
    bool rx_valid;

    // Chip select
    uint8_t chip_select;

    // State machine
    enum class State {
        IDLE,
        TRANSFER
    };
    State state;

    // Transfer tracking
    uint8_t shift_reg;
    int bit_counter;
    int sclk_phase;

    // Simulated SPI flash memory (4KB per CS)
    uint8_t flash_memory[4][4096];
    uint32_t flash_addr[4];
    bool flash_addr_set[4];
    int flash_addr_bytes[4];

public:
    SPIDevice();
    virtual ~SPIDevice() {}

    virtual uint32_t read(uint32_t offset, int size) override;
    virtual void write(uint32_t offset, uint32_t value, int size) override;
    virtual const char* name() const override { return "SPI"; }
    virtual void tick() override;
    virtual void reset() override;

private:
    void process_spi_transfer();
    void handle_flash_command(int cs, uint8_t cmd);
    uint8_t handle_flash_read(int cs);
};

// CLINT Device Driver (for completeness)
// Base address: 0x02000000
class CLINTDevice : public Device {
private:
    uint32_t msip;
    uint64_t mtimecmp;
    uint64_t mtime;

public:
    CLINTDevice();
    virtual ~CLINTDevice() {}

    virtual uint32_t read(uint32_t offset, int size) override;
    virtual void write(uint32_t offset, uint32_t value, int size) override;
    virtual const char* name() const override { return "CLINT"; }
    virtual void tick() override;
    virtual void reset() override;

    // Undo a tick (used when an instruction fires an exception and is not retired)
    void untick() override { if (mtime > 0) mtime--; }

    bool get_timer_interrupt();
    bool get_software_interrupt();
};

#endif // DEVICE_H

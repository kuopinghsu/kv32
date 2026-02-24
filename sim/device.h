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
#define CLINT_SIZE          0x000C0000

// PLIC slave window
#define PLIC_BASE           0x0C000000
#define PLIC_SIZE           0x04000000

// UART slave window
#define UART_BASE           0x20000000
#define UART_SIZE           0x00010000

// I2C slave window
#define I2C_BASE            0x20010000
#define I2C_SIZE            0x00010000

// SPI slave window
#define SPI_BASE            0x20020000
#define SPI_SIZE            0x00010000

// Magic slave window
#define MAGIC_BASE          0xFFFF0000
#define MAGIC_SIZE          0x00010000

// =============================================================================
// Device Register Offsets (window-relative)
// =============================================================================

// Magic device registers
#define MAGIC_EXIT_REG      0xFFF0
#define MAGIC_CONSOLE_REG   0xFFF4

// UART registers (FIFO-based, matches RTL axi_uart.sv)
#define UART_DATA_REG       0x00   // TX push (write) / RX pop (read)
#define UART_STATUS_REG     0x04   // [0]=tx_full(busy), [1]=tx_full, [2]=rx_not_empty, [3]=rx_full
#define UART_IE_REG         0x08   // [0]=rx_not_empty_ie, [1]=tx_empty_ie
#define UART_IS_REG         0x0C   // [0]=rx_not_empty, [1]=tx_empty (read-only level)
#define UART_LEVEL_REG      0x10   // [4:0]=rx_count, [12:8]=tx_count

// SPI registers (FIFO-based, matches RTL axi_spi.sv)
#define SPI_CONTROL_REG     0x00
#define SPI_CLKDIV_REG      0x04
#define SPI_TXDATA_REG      0x08   // TX push (write)
#define SPI_RXDATA_REG      0x0C   // RX pop  (read)
#define SPI_STATUS_REG      0x10   // [0]=busy, [1]=tx_ready, [2]=rx_valid, [3]=tx_empty, [4]=rx_full
#define SPI_IE_REG          0x14   // [0]=rx_not_empty_ie, [1]=tx_empty_ie
#define SPI_IS_REG          0x18   // [0]=rx_not_empty, [1]=tx_empty (read-only level)

// I2C registers (FIFO-based, matches RTL axi_i2c.sv)
#define I2C_CONTROL_REG     0x00
#define I2C_CLKDIV_REG      0x04
#define I2C_TXDATA_REG      0x08   // TX FIFO push (write)
#define I2C_RXDATA_REG      0x0C   // RX FIFO pop  (read)
#define I2C_STATUS_REG      0x10   // [0]=busy, [1]=tx_ready, [2]=rx_valid, [3]=ack_received
#define I2C_IE_REG          0x14   // [0]=rx_not_empty_ie, [1]=tx_empty_ie, [2]=done_ie
#define I2C_IS_REG          0x18   // [0]=rx_not_empty, [1]=tx_empty, [2]=stop_done (read-only level)

// PLIC registers (offsets from PLIC_BASE 0x0C000000)
// Compatible with RTL rv32_plic.sv
#define PLIC_PRIORITY_BASE  0x000000  // +4*src: source i priority (i=1..7)
#define PLIC_PENDING_0      0x001000  // Pending bits [7:1]
#define PLIC_ENABLE_0       0x002000  // Enable bits  [7:1] for context 0 (hart 0 M-mode)
#define PLIC_THRESHOLD_0    0x200000  // Priority threshold for context 0
#define PLIC_CLAIM_0        0x200004  // Claim/Complete for context 0

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
// Base address: 0x20000000
// FIFO-based; matches RTL axi_uart.sv register map.
// Registers:
//   0x00: TX/RX Data (write=TX push, read=RX pop)
//   0x04: Status [0]=tx_full(busy), [1]=tx_full, [2]=rx_not_empty, [3]=rx_full
//   0x08: IE     [0]=rx_not_empty_ie, [1]=tx_empty_ie
//   0x0C: IS     (read-only level)
//   0x10: LEVEL  [4:0]=rx_count, [12:8]=tx_count
class UARTDevice : public Device {
private:
    static const int FIFO_DEPTH = 16;
    std::vector<uint8_t> rx_fifo;
    std::vector<uint8_t> tx_fifo;   // printed immediately; kept for level/stats
    uint8_t ie_reg;                  // [0]=rx_ne_ie, [1]=tx_e_ie

public:
    UARTDevice();
    virtual ~UARTDevice() {}

    virtual uint32_t read(uint32_t offset, int size) override;
    virtual void write(uint32_t offset, uint32_t value, int size) override;
    virtual const char* name() const override { return "UART"; }
    virtual void reset() override;

    // IRQ: level-based, asserted when (IE & IS) != 0
    bool get_irq() const;

    // Inject a byte into the RX FIFO (for loopback or test input)
    void add_rx_data(uint8_t data);

    // Get TX FIFO contents (for testing)
    const std::vector<uint8_t>& get_tx_fifo() const { return tx_fifo; }
};

// I2C Device Driver
// Base address: 0x20010000
// FIFO-based; matches RTL axi_i2c.sv register map.
// Registers:
//   0x00: Control
//   0x04: Clock Divider
//   0x08: TX Data (write = TX FIFO push)
//   0x0C: RX Data (read  = RX FIFO pop)
//   0x10: Status  [0]=busy, [1]=tx_ready, [2]=rx_valid, [3]=ack_received
//   0x14: IE      [0]=rx_not_empty_ie, [1]=tx_empty_ie, [2]=done_ie
//   0x18: IS      (read-only level)
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

    // IE/IS registers
    uint8_t ie_reg;      // [0]=rx_ne_ie, [1]=tx_e_ie, [2]=done_ie
    bool stop_done;      // level signal: set when a STOP completes (drives IS[2])

public:
    I2CDevice();
    virtual ~I2CDevice() {}

    virtual uint32_t read(uint32_t offset, int size) override;
    virtual void write(uint32_t offset, uint32_t value, int size) override;
    virtual const char* name() const override { return "I2C"; }
    virtual void tick() override;
    virtual void reset() override;

    // IRQ: level-based
    bool get_irq() const;

private:
    void process_i2c_transaction();
    void handle_eeprom_write(uint8_t data);
    uint8_t handle_eeprom_read();
};

// SPI Device Driver
// Base address: 0x20020000
// FIFO-based; matches RTL axi_spi.sv register map.
// Registers:
//   0x00: Control
//   0x04: Clock Divider
//   0x08: TX Data (write = TX FIFO push)
//   0x0C: RX Data (read  = RX FIFO pop)
//   0x10: Status  [0]=busy, [1]=tx_ready(!full), [2]=rx_valid(!empty), [3]=tx_empty, [4]=rx_full
//   0x14: IE      [0]=rx_not_empty_ie, [1]=tx_empty_ie
//   0x18: IS      (read-only level)
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
    int transfer_ticks;   // countdown: complete transfer when this reaches 0

    // Simulated SPI flash memory (4KB per CS)
    uint8_t flash_memory[4][4096];
    uint32_t flash_addr[4];
    bool flash_addr_set[4];
    int flash_addr_bytes[4];

    // IE register
    uint8_t ie_reg;     // [0]=rx_ne_ie, [1]=tx_e_ie

    // RX FIFO (one entry is enough for simulation)
    std::vector<uint8_t> rx_fifo;

public:
    SPIDevice();
    virtual ~SPIDevice() {}

    virtual uint32_t read(uint32_t offset, int size) override;
    virtual void write(uint32_t offset, uint32_t value, int size) override;
    virtual const char* name() const override { return "SPI"; }
    virtual void tick() override;
    virtual void reset() override;

    // IRQ: level-based
    bool get_irq() const;

private:
    void process_spi_transfer();
    void handle_flash_command(int cs, uint8_t cmd);
    uint8_t handle_flash_read(int cs);
};

// PLIC Device Driver
// Base address: 0x0C000000
// Implements standard SiFive PLIC register layout (7 sources, 1 context = hart 0 M-mode).
// Matches RTL rv32_plic.sv:
//   priority[i] at PLIC_BASE + 4*i          (i = 1..7)
//   pending     at PLIC_BASE + 0x001000      (bits [7:1])
//   enable      at PLIC_BASE + 0x002000      (bits [7:1], context 0)
//   threshold   at PLIC_BASE + 0x200000      (context 0)
//   claim/cmplt at PLIC_BASE + 0x200004      (context 0)
class PLICDevice : public Device {
private:
    static const int NUM_IRQ = 7;

    uint32_t priority_r[NUM_IRQ + 1];  // [0] unused; [1..7] per-source priority
    bool     enable_r  [NUM_IRQ + 1];  // [1..7] enable for context 0
    bool     pending_r [NUM_IRQ + 1];  // [1..7] pending bits
    bool     claimed_r [NUM_IRQ + 1];  // [1..7] claimed (between claim and complete)
    uint32_t threshold_r;              // context 0 threshold
    uint32_t irq_src_mask;             // current raw IRQ input mask [7:1]

    // Find highest-priority enabled-pending source above threshold
    int best_claim() const;

public:
    PLICDevice();
    virtual ~PLICDevice() {}

    virtual uint32_t read(uint32_t offset, int size) override;
    virtual void write(uint32_t offset, uint32_t value, int size) override;
    virtual const char* name() const override { return "PLIC"; }
    virtual void reset() override;

    // Called every cycle with current raw IRQ inputs from peripherals
    // mask bit i (i=1..7) = 1 means source i is asserting its IRQ
    void update_irq_sources(uint32_t mask);

    // Returns true if PLIC should drive external interrupt to the core
    bool get_external_interrupt() const;
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

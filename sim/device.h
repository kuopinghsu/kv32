// Device Driver Interface for KV32 Simulator
// Provides abstract interface for peripheral devices (UART, I2C, SPI, etc.)

#ifndef DEVICE_H
#define DEVICE_H

#include <stdint.h>
#include <vector>
#include <string>
#include <functional>

// HAL register map – base addresses, register offsets, and bit-field constants
// are sourced from the firmware header so simulator and firmware always agree.
// Note: KV_REG32 (volatile pointer accessor used only by firmware) is defined
// by kv_platform.h but is never called by simulator code.
#include "../sw/include/kv_platform.h"

// =============================================================================
// Simulator address-space layout
// Window sizes and base addresses are all sourced from kv_platform.h.
// Short aliases below are kept for kv32sim.cpp which uses the unprefixed names.
// =============================================================================

#define MEM_BASE            KV_RAM_BASE
#define MEM_SIZE            KV_RAM_SIZE
#define CLINT_BASE          KV_CLINT_BASE
#define CLINT_SIZE          KV_CLINT_SIZE
#define PLIC_BASE           KV_PLIC_BASE
#define PLIC_SIZE           KV_PLIC_SIZE
#define UART_BASE           KV_UART_BASE
#define UART_SIZE           KV_UART_SIZE
#define I2C_BASE            KV_I2C_BASE
#define I2C_SIZE            KV_I2C_SIZE
#define SPI_BASE            KV_SPI_BASE
#define SPI_SIZE            KV_SPI_SIZE
#define DMA_BASE            KV_DMA_BASE
#define DMA_SIZE            KV_DMA_SIZE
#define GPIO_BASE           KV_GPIO_BASE
#define GPIO_SIZE           KV_GPIO_SIZE
#define TIMER_BASE          KV_TIMER_BASE
#define TIMER_SIZE          KV_TIMER_SIZE
#define MAGIC_BASE          KV_MAGIC_BASE
#define MAGIC_SIZE          KV_MAGIC_SIZE

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
//   0x14: CTRL   [0]=loopback_en
class UARTDevice : public Device {
private:
    static const int FIFO_DEPTH = 16;
    std::vector<uint8_t> rx_fifo;
    std::vector<uint8_t> tx_fifo;   // printed immediately; kept for level/stats
    uint8_t ie_reg;                  // [0]=rx_ne_ie, [1]=tx_e_ie
    bool loopback_en;               // CTRL[0]: TX→RX loopback (mirrors RTL axi_uart.sv)

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
    static const int FIFO_DEPTH = 8;

    // Control register fields
    bool i2c_enable;
    bool start_cmd;
    bool stop_cmd;
    bool read_cmd;
    bool ack_cmd;

    // Clock divider
    uint16_t clk_div;
    uint16_t clk_counter;

    // Data registers (current byte being processed)
    uint8_t tx_data;
    uint8_t rx_data;
    bool tx_valid;

    // TX / RX FIFOs
    std::vector<uint8_t> tx_fifo;   // depth = FIFO_DEPTH
    std::vector<uint8_t> rx_fifo;   // depth = FIFO_DEPTH

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
    bool stop_done;      // 1-cycle pulse flag (auto-cleared at start of tick)

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
//   0x00: Control [0]=enable,[1]=cpol,[2]=cpha,[3]=loopback_en,[7:4]=CS
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
    bool loopback_en; // CTRL[3]: MOSI→MISO loopback (mirrors RTL axi_spi.sv)

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
    uint8_t flash_cmd[4];   // current command per CS (0x02=write, 0x03=read, 0=none)

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
    uint8_t handle_flash_data(int cs, uint8_t tx_byte);  // read or write based on flash_cmd[cs]
};

// PLIC Device Driver
// Base address: 0x0C000000
// Implements standard SiFive PLIC register layout (7 sources, 1 context = hart 0 M-mode).
// Matches RTL kv32_plic.sv:
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

// DMA Device Driver
// Base address: 0x2003_0000 (4KB aperture)
// Emulates axi_dma.sv register map with immediate-execution semantics:
//   when CTRL.START + CTRL.EN are written, the transfer runs synchronously
//   so polling and IRQ-driven tests both work correctly.
// Supports transfer modes: 1D, 2D (strided), 3D (planar), Scatter-Gather.
class DMADevice : public Device {
public:
    using ReadFn  = std::function<uint32_t(uint32_t addr, int size)>;
    using WriteFn = std::function<void(uint32_t addr, uint32_t value, int size)>;

    static const int     NUM_CH = 4;
    static const uint32_t DMA_ID = 0xD4A00100u;

    struct Chan {
        uint32_t ctrl        = 0;
        uint32_t stat        = 0;   // [0]=busy(RO), [1]=done(W1C), [2]=err(W1C)
        uint32_t src_addr    = 0;
        uint32_t dst_addr    = 0;
        uint32_t xfer_cnt    = 0;
        uint32_t src_stride  = 0;
        uint32_t dst_stride  = 0;
        uint32_t row_cnt     = 0;
        uint32_t src_pstride = 0;
        uint32_t dst_pstride = 0;
        uint32_t plane_cnt   = 0;
        uint32_t sg_addr     = 0;
        uint32_t sg_cnt      = 0;
    };

    Chan     ch[NUM_CH];
    uint32_t irq_stat    = 0;
    uint32_t irq_en      = 0;

    // Performance counters (mirrors axi_dma.sv PERF_CTRL/CYCLES/RD_BYTES/WR_BYTES)
    bool     perf_enable   = false;  // PERF_CTRL bit[0]
    uint32_t perf_cycles   = 0;      // PERF_CYCLES  (+0xF14)
    uint32_t perf_rd_bytes = 0;      // PERF_RD_BYTES (+0xF18)
    uint32_t perf_wr_bytes = 0;      // PERF_WR_BYTES (+0xF1C)

    DMADevice(ReadFn rfn, WriteFn wfn);
    virtual ~DMADevice() {}

    virtual uint32_t read(uint32_t offset, int size) override;
    virtual void write(uint32_t offset, uint32_t value, int size) override;
    virtual const char* name() const override { return "DMA"; }
    virtual void reset() override;

    bool get_irq() const { return (irq_stat & irq_en) != 0; }

private:
    ReadFn  mem_read;
    WriteFn mem_write;

    uint32_t perf_xfer_acc = 0;  // bytes accumulated during one execute_transfer

    bool is_valid_addr(uint32_t addr) const;
    bool do_1d_copy(uint32_t src, uint32_t dst, uint32_t cnt,
                    bool src_inc, bool dst_inc);
    bool execute_transfer(int n);
    void finish_channel(int n, bool ok);
};

// GPIO Device Driver
// Base address: 0x20040000
// Matches RTL axi_gpio.sv register map.
// Supports 4 banks of 32 pins each (128 pins total, configurable via NUM_PINS parameter).
// Features: direction control, atomic set/clear, interrupts, loopback mode.
class GPIODevice : public Device {
private:
    static const int MAX_PINS = 128;
    static const int MAX_BANKS = 4;

    uint32_t data_out_r[MAX_BANKS];      // Output data
    uint32_t dir_r[MAX_BANKS];           // Direction (1=output, 0=input)
    uint32_t ie_r[MAX_BANKS];            // Interrupt enable
    uint32_t trigger_r[MAX_BANKS];       // Trigger mode (1=edge, 0=level)
    uint32_t polarity_r[MAX_BANKS];      // Polarity
    uint32_t is_r[MAX_BANKS];            // Interrupt status
    uint32_t loopback_r[MAX_BANKS];      // Loopback enable

    uint32_t gpio_i_sync[MAX_BANKS];     // Synchronized input (2-stage)
    uint32_t gpio_i_prev[MAX_BANKS];     // Previous input for edge detection

    uint32_t external_input[MAX_BANKS];  // External pin input

public:
    GPIODevice();
    virtual ~GPIODevice() {}

    virtual uint32_t read(uint32_t offset, int size) override;
    virtual void write(uint32_t offset, uint32_t value, int size) override;
    virtual const char* name() const override { return "GPIO"; }
    virtual void tick() override;
    virtual void reset() override;

    // IRQ: asserted when any enabled interrupt is pending
    bool get_irq() const;

    // Set external input pins (for testing)
    void set_external_input(uint32_t bank, uint32_t value);
};

// Timer Device Driver
// Base address: 0x20050000
// Matches RTL axi_timer.sv register map.
// 4 independent 32-bit timers with compare-match interrupts and PWM output.
class TimerDevice : public Device {
private:
    static const int NUM_TIMERS = 4;

    struct TimerChannel {
        uint32_t count_r;           // Counter value
        uint32_t compare1_r;        // Compare 1 (interrupt / PWM set)
        uint32_t compare2_r;        // Compare 2 (PWM clear + reload)
        uint32_t ctrl_r;            // Control register

        // Decoded control bits
        bool     timer_en;
        bool     pwm_en;
        bool     int_en;
        bool     pwm_pol;
        uint16_t prescale;

        // Prescaler counter
        uint16_t prescale_cnt;

        // PWM output state
        bool     pwm_output_raw;
    };

    TimerChannel ch[NUM_TIMERS];
    uint32_t int_status_r;              // Global interrupt status (W1C)
    uint32_t int_enable_r;              // Global interrupt enable

public:
    TimerDevice();
    virtual ~TimerDevice() {}

    virtual uint32_t read(uint32_t offset, int size) override;
    virtual void write(uint32_t offset, uint32_t value, int size) override;
    virtual const char* name() const override { return "TIMER"; }
    virtual void tick() override;
    virtual void reset() override;

    // IRQ: asserted when (int_status_r & int_enable_r) != 0
    bool get_irq() const;

    // Get PWM output state (for testing)
    bool get_pwm_output(int timer_num) const;
};

#endif // DEVICE_H

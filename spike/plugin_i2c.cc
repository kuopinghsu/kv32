// ============================================================================
// File: plugin_i2c.cc
// Project: KV32 RISC-V Processor
// Description: Spike MMIO plugin for the KV32 I2C master peripheral
//              with simulated 256-byte EEPROM at I2C address 0x50.
//
// Register Map (relative to KV_I2C_BASE = 0x2002_0000):
//   0x00  CTRL    - Control (R/W): [0]=enable, [1]=start, [2]=stop, [3]=read, [4]=nack
//   0x04  DIV     - Clock divider (R/W)
//   0x08  TX      - TX data byte (W): push to TX FIFO
//   0x0C  RX      - RX data byte (R): pop from RX FIFO
//   0x10  STATUS  - [0]=busy, [1]=tx_ready, [2]=rx_valid, [3]=ack_recv
//   0x14  IE      - Interrupt enable (R/W)
//   0x18  IS      - Interrupt status (W1C): [0]=rx_ready, [1]=tx_empty, [2]=stop_done
//   0x1C  CAP     - Capability (RO): version=0x0001, RX_DEPTH=8, TX_DEPTH=8
//   >0x1C  —      - Bus error
//
// Simulation behaviour:
//   TX bytes are processed instantly through an EEPROM state machine that uses
//   proper transaction-position tracking (IDLE → GOT_ADDR → DATA) identical to
//   the kv32sim I2CDevice state machine.  This correctly handles data bytes
//   whose value happens to coincide with 0xA0/0xA1 (the default EEPROM pattern).
//   STATUS[3] (ack_recv) is set after each TX byte (slave always ACKs in sim).
//   CTRL_READ fetches one byte from the EEPROM into the RX FIFO.
//   CTRL_STOP sets IS[2] (stop_done) which is auto-cleared when IS is read
//   (models the 1-cycle pulse behaviour of the RTL).
//   IS[1] (tx_empty) is set whenever the TX queue is drained (instant).
//
// Clock-stretching note:
//   The RTL STRETCH=N knob makes the i2c_slave_eeprom testbench hold SCL
//   low for N system-clock cycles after each byte ACK.  Spike simulates all
//   operations synchronously (no clock concept), so clock-stretch has no effect
//   here — the EEPROM state machine is still functionally correct regardless of
//   the STRETCH value used in RTL simulation.
//
// Interrupt routing:
//   MEIP is asserted via PLIC set_interrupt_level(KV_PLIC_SRC_I2C) when
//   any enabled IS bit is set.  Only STOP_DONE and RX_READY are wired;
//   TX_EMPTY is reflected in IS but IE[1] is not expected to be enabled
//   (instant TX would cause an IRQ flood).
// ============================================================================

#include <riscv/abstract_device.h>

#ifdef SPIKE_INCLUDE
#include <riscv/sim.h>
#include <riscv/devices.h>
#endif

#include <cstring>
#include <queue>
#include <string>
#include <vector>

#include "kv_platform.h"

static constexpr uint32_t I2C_FIFO_DEPTH  = 8;
static constexpr uint32_t EEPROM_SIZE     = 256;
static constexpr uint8_t  EEPROM_I2C_ADDR = 0x50;   // 7-bit I2C address

static constexpr uint32_t I2C_CAP_VAL =
    (0x0001u << 16) | (I2C_FIFO_DEPTH << 8) | I2C_FIFO_DEPTH;
static constexpr reg_t I2C_ADDR_MAX = KV_I2C_CAP_OFF;

// I2C transaction state: tracks which byte of the protocol we expect next.
enum class I2cTxState {
    IDLE,       // waiting for device-address byte after START
    GOT_ADDR,   // device address received; next byte is memory address
    DATA,       // memory address set; subsequent bytes are data (write mode)
};

class plugin_i2c_t : public abstract_device_t {
public:
    explicit plugin_i2c_t(sim_t *sim = nullptr)
        : sim_(sim), ctrl_(0), div_(0), ie_(0), is_(0),
          tx_state_(I2cTxState::IDLE), write_mode_(false),
          eeprom_addr_(0), ack_recv_(false)
    {
        // Pre-fill EEPROM with default pattern: eeprom[i] = 0xA0 + i
        for (uint32_t i = 0; i < EEPROM_SIZE; i++)
            eeprom_[i] = (uint8_t)(0xA0u + i);
    }

    bool load(reg_t addr, size_t len, uint8_t *bytes) override
    {
        if (addr > I2C_ADDR_MAX) return false;
        uint32_t val = reg_read(addr);
        memset(bytes, 0, len);
        if (len >= 4) memcpy(bytes, &val, 4);
        else           memcpy(bytes, &val, len);
        return true;
    }

    bool store(reg_t addr, size_t len, const uint8_t *bytes) override
    {
        if (addr > I2C_ADDR_MAX) return false;
        uint32_t val = 0;
        if (len >= 4) memcpy(&val, bytes, 4);
        else           memcpy(&val, bytes, len);
        reg_write(addr, val);
        return true;
    }

    reg_t size() override { return (reg_t)KV_I2C_SIZE; }

private:
    sim_t               *sim_;
    uint32_t             ctrl_, div_, ie_, is_;

    // EEPROM state machine
    I2cTxState           tx_state_;
    bool                 write_mode_;
    uint8_t              eeprom_addr_;   // current EEPROM byte pointer
    bool                 ack_recv_;      // mirrors STATUS[3]

    uint8_t              eeprom_[EEPROM_SIZE];
    std::queue<uint8_t>  rx_fifo_;

    // ── IRQ routing ──────────────────────────────────────────────────────────

    // update_meip() is intentionally non-const: it auto-consumes IS[STOP_DONE].
    //
    // STOP_DONE is a one-shot pulse.  Once we assert the PLIC level for it, we
    // immediately clear the bit and lower the level so that after the handler
    // calls plic_complete() the PLIC sees level=0 and does NOT re-assert MEIP.
    //
    // The caller's STATUS-register read is what drives this: the handler calls
    // kv_i2c_rx_valid() → STATUS load → reg_read(STATUS) → update_meip() here.
    // By the time update_meip() is called from STATUS, STOP_DONE has already
    // been consumed and pending==false, so we lower the level before complete().
    //
    // RX_READY is level-triggered (fifo non-empty keeps level high) so no
    // special handling is needed there.
    void update_meip()
    {
#ifdef SPIKE_INCLUDE
        if (!sim_) return;
        // Consume STOP_DONE if pending and enabled.
        // After asserting we clear the bit so the next update_meip call
        // (from STATUS read inside the handler) lowers the level to 0.
        const bool stop_pending =
            (ie_ & KV_I2C_IE_STOP_DONE) && (is_ & KV_I2C_IE_STOP_DONE);
        if (stop_pending)
            is_ &= ~KV_I2C_IE_STOP_DONE;   // consumed – one-shot

        const bool rx_pending =
            (ie_ & KV_I2C_IE_RX_READY) && !rx_fifo_.empty();

        const bool overall = stop_pending || rx_pending;
        sim_->get_intctrl()->set_interrupt_level(
            (uint32_t)KV_PLIC_SRC_I2C, overall ? 1 : 0);
#endif
    }

    // ── RX FIFO helpers ──────────────────────────────────────────────────────

    void push_rx(uint8_t byte)
    {
        if (rx_fifo_.size() < I2C_FIFO_DEPTH) {
            rx_fifo_.push(byte);
            is_ |= KV_I2C_IE_RX_READY;   // new byte arrived
            update_meip();
        }
    }

    // ── EEPROM state machine ─────────────────────────────────────────────────

    // Process one TX byte.  Returns true if the simulated slave ACKs.
    bool process_tx_byte(uint8_t byte)
    {
        switch (tx_state_) {
        case I2cTxState::IDLE:
            // First byte after START is the device address (7-bit) + R/W bit.
            if ((byte >> 1) == EEPROM_I2C_ADDR) {
                write_mode_ = !(byte & 1u);
                tx_state_   = I2cTxState::GOT_ADDR;
                return true;   // ACK
            }
            return false;      // NACK – unknown device

        case I2cTxState::GOT_ADDR:
            // Next byte is the memory address.
            eeprom_addr_ = byte;
            tx_state_    = I2cTxState::DATA;
            return true;

        case I2cTxState::DATA:
            // Subsequent bytes: write data (write mode) or ignore (read mode).
            if (write_mode_) {
                eeprom_[eeprom_addr_] = byte;
                eeprom_addr_ = (uint8_t)(eeprom_addr_ + 1u);
            }
            return true;

        default:
            return true;
        }
    }

    // ── Register access ──────────────────────────────────────────────────────

    uint32_t reg_read(reg_t addr)
    {
        switch (addr) {
        case KV_I2C_CTRL_OFF:
            return ctrl_;

        case KV_I2C_DIV_OFF:
            return div_;

        case KV_I2C_TX_OFF:
            return 0u;   // write-only

        case KV_I2C_RX_OFF: {
            uint8_t byte = 0xFFu;
            if (!rx_fifo_.empty()) {
                byte = rx_fifo_.front();
                rx_fifo_.pop();
            }
            if (rx_fifo_.empty())
                is_ &= ~KV_I2C_IE_RX_READY;
            update_meip();
            return byte;
        }

        case KV_I2C_STATUS_OFF: {
            uint32_t st = KV_I2C_ST_TX_READY;   // TX always ready (instant)
            if (!rx_fifo_.empty()) st |= KV_I2C_ST_RX_VALID;
            if (ack_recv_)         st |= KV_I2C_ST_ACK_RECV;
            // BUSY is always 0 – everything resolves in the same cycle.
            // Also drives MEIP update: the handler calls kv_i2c_rx_valid() which
            // reads STATUS, giving us a chance to lower the PLIC level for
            // the already-consumed STOP_DONE before plic_complete() re-checks.
            update_meip();
            return st;
        }

        case KV_I2C_IE_OFF:
            return ie_;

        case KV_I2C_IS_OFF: {
            // Return current IS; update_meip() consumes STOP_DONE on its next
            // call (triggered by STATUS read inside the handler).  W1C clears
            // are handled in reg_write(IS_OFF).
            return is_;
        }

        case KV_I2C_CAP_OFF:
            return I2C_CAP_VAL;

        default:
            return 0u;
        }
    }

    void reg_write(reg_t addr, uint32_t val)
    {
        switch (addr) {
        case KV_I2C_CTRL_OFF: {
            ctrl_ = val & ~(KV_I2C_CTRL_START | KV_I2C_CTRL_STOP | KV_I2C_CTRL_READ);

            if (val & KV_I2C_CTRL_START) {
                // START condition: reset transaction; eeprom_addr_ kept so that
                // a repeated-start read uses the pointer set by the write phase.
                tx_state_  = I2cTxState::IDLE;
                ack_recv_  = false;
                // TX FIFO is empty right after START.
                is_ |= KV_I2C_IE_TX_EMPTY;
            }

            if (val & KV_I2C_CTRL_READ) {
                // Fetch one byte from the EEPROM into the RX FIFO.
                uint8_t byte = eeprom_[eeprom_addr_];
                eeprom_addr_ = (uint8_t)(eeprom_addr_ + 1u);
                push_rx(byte);
            }

            if (val & KV_I2C_CTRL_STOP) {
                tx_state_  = I2cTxState::IDLE;
                ack_recv_  = false;
                is_ |= KV_I2C_IE_STOP_DONE;
                is_ |= KV_I2C_IE_TX_EMPTY;
                update_meip();
            }
            break;
        }

        case KV_I2C_TX_OFF:
            // Process the byte immediately through the EEPROM state machine.
            ack_recv_ = process_tx_byte((uint8_t)(val & 0xFFu));
            // TX FIFO drains instantly.
            is_ |= KV_I2C_IE_TX_EMPTY;
            // No IRQ for TX_EMPTY (avoid floods); update only for completeness.
            update_meip();
            break;

        case KV_I2C_DIV_OFF:
            div_ = val;
            break;

        case KV_I2C_IE_OFF:
            ie_ = val & 0x7u;
            update_meip();
            break;

        case KV_I2C_IS_OFF:
            is_ &= ~val;   // W1C
            update_meip();
            break;

        case KV_I2C_RX_OFF:   // read-only
        case KV_I2C_CAP_OFF:  // read-only
        default:
            break;
        }
    }
};

static plugin_i2c_t *
plugin_i2c_parse(const void *, const sim_t *sim, reg_t *base,
                 const std::vector<std::string> &sargs)
{
    if (!sargs.empty()) *base = strtoull(sargs[0].c_str(), nullptr, 0);
    return new plugin_i2c_t(const_cast<sim_t *>(sim));
}

static std::string
plugin_i2c_generate_dts(const sim_t *, const std::vector<std::string> &)
{ return ""; }

REGISTER_DEVICE(plugin_i2c, plugin_i2c_parse, plugin_i2c_generate_dts)

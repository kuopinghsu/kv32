// ============================================================================
// File: plugin_spi.cc
// Project: KV32 RISC-V Processor
// Description: Spike MMIO plugin for the KV32 SPI master peripheral
//              with simulated flash (address-pattern content) and PLIC IRQ.
//
// Register Map (relative to KV_SPI_BASE = 0x2002_0000):
//   0x00  CTRL    - Control (R/W): [0]=enable, [1]=CPOL, [2]=CPHA, [3]=loopback,
//                   [7:4]=CS_n (active-low chip selects)
//   0x04  DIV     - Clock divider (R/W)
//   0x08  TX      - TX FIFO push (W): byte to transmit
//   0x0C  RX      - RX FIFO pop  (R): received byte
//   0x10  STATUS  - [0]=busy, [1]=tx_ready, [2]=rx_valid, [3]=tx_empty, [4]=rx_full
//   0x14  IE      - Interrupt enable (R/W)
//   0x18  IS      - Interrupt status (RO): [0]=rx_ready, [1]=tx_empty
//   0x1C  CAP     - Capability (RO): version=0x0001, NUM_CS=4, RX=16, TX=16
//   >0x1C  —      - Bus error
//
// Simulation behaviour:
//   Flash model: 256-byte flash at each CS, content[i] = (uint8_t)i.
//   READ command (0x03): CMD byte → ADDR byte → data reads (addr+offset pattern).
//   BUSY toggles: one STATUS read after TX shows busy, second shows idle.
//   Loopback (CTRL[3]=1): each TX byte is immediately echoed to the RX FIFO.
//   RX FIFO non-empty fires PLIC KV_PLIC_SRC_SPI when KV_SPI_IE_RX_READY is set.
// ============================================================================

#include <riscv/abstract_device.h>

#ifdef SPIKE_INCLUDE
#include <riscv/sim.h>
#include <riscv/devices.h>
#endif

#include <cstring>
#include <deque>
#include <string>
#include <vector>

#include "kv_platform.h"

static constexpr uint32_t SPI_FIFO_DEPTH = 16;
static constexpr uint32_t SPI_FLASH_SIZE = 256;
static constexpr uint8_t  SPI_FLASH_CMD_READ = 0x03u;

static constexpr uint32_t SPI_CAP_VAL =
    (0x01u << 24) | (4u << 16) | (SPI_FIFO_DEPTH << 8) | SPI_FIFO_DEPTH;
static constexpr reg_t SPI_ADDR_MAX = KV_SPI_CAP_OFF;

// Flash state machine: tracks protocol phase for SPI flash reads.
enum class SpiFlashState { IDLE, GOT_CMD, DATA };

class plugin_spi_t : public abstract_device_t {
public:
    explicit plugin_spi_t(sim_t *sim = nullptr)
        : sim_(sim), ctrl_(KV_SPI_CTRL_CS_ALL | KV_SPI_CTRL_ENABLE), div_(0), ie_(0),
          busy_cnt_(0), flash_state_(SpiFlashState::IDLE), flash_addr_(0)
    {
        // Flash content: flash_[i] = (uint8_t)i (address-as-data pattern)
        for (uint32_t i = 0; i < SPI_FLASH_SIZE; i++)
            flash_[i] = (uint8_t)i;
    }

    bool load(reg_t addr, size_t len, uint8_t *bytes) override
    {
        if (addr > SPI_ADDR_MAX) return false;
        uint32_t val = reg_read(addr);
        memset(bytes, 0, len);
        if (len >= 4) memcpy(bytes, &val, 4);
        else           memcpy(bytes, &val, len);
        return true;
    }

    bool store(reg_t addr, size_t len, const uint8_t *bytes) override
    {
        if (addr > SPI_ADDR_MAX) return false;
        uint32_t val = 0;
        if (len >= 4) memcpy(&val, bytes, 4);
        else           memcpy(&val, bytes, len);
        reg_write(addr, val);
        return true;
    }

    void tick(reg_t /*rtc_ticks*/) override { update_meip(); }

    reg_t size() override { return (reg_t)KV_SPI_SIZE; }

private:
    sim_t              *sim_;
    uint32_t            ctrl_, div_, ie_;
    uint32_t            busy_cnt_;         // 2 → BUSY on STATUS read, then clears
    SpiFlashState       flash_state_;
    uint8_t             flash_addr_;       // current flash read pointer
    uint8_t             flash_[SPI_FLASH_SIZE];
    std::deque<uint8_t> rx_fifo_;

    bool loopback() const { return (ctrl_ & KV_SPI_CTRL_LOOPBACK) != 0; }

    // ── PLIC IRQ ─────────────────────────────────────────────────────────────

    void update_meip() const
    {
#ifdef SPIKE_INCLUDE
        if (!sim_) return;
        const bool pending = (ie_ & KV_SPI_IE_RX_READY) && !rx_fifo_.empty();
        sim_->get_intctrl()->set_interrupt_level(
            (uint32_t)KV_PLIC_SRC_SPI, pending ? 1 : 0);
#endif
    }

    // ── STATUS ───────────────────────────────────────────────────────────────

    // Compute STATUS and decrement the busy countdown.
    // BUSY: set for two consecutive STATUS reads after a TX write (simulates
    //       the brief in-transit time that spi_transfer() waits for).
    // TX_READY: high only when the RX FIFO has space to absorb the next byte.
    //   Since each TX write immediately produces an RX byte, we back-pressure
    //   TX when RX is full — this prevents the TX burst-loop from overrunning.
    uint32_t read_status()
    {
        uint32_t st = KV_SPI_ST_TX_EMPTY;
        if (busy_cnt_ > 1)                         st |= KV_SPI_ST_BUSY;
        if (rx_fifo_.size() < SPI_FIFO_DEPTH)      st |= KV_SPI_ST_TX_READY;
        if (!rx_fifo_.empty())                     st |= KV_SPI_ST_RX_VALID;
        if (rx_fifo_.size() >= SPI_FIFO_DEPTH)     st |= KV_SPI_ST_RX_FULL;
        if (busy_cnt_ > 0) busy_cnt_--;
        return st;
    }

    // ── Flash state machine ──────────────────────────────────────────────────

    // CS deselect (all CS bits high) resets flash state.
    void on_ctrl_write(uint32_t old_ctrl, uint32_t new_ctrl)
    {
        const uint32_t cs_bits = 0xFu << 4;
        if ((new_ctrl & cs_bits) == cs_bits && (old_ctrl & cs_bits) != cs_bits)
            flash_state_ = SpiFlashState::IDLE;
    }

    // Compute the RX byte for a given TX byte based on current state.
    uint8_t process_tx(uint8_t tx_byte)
    {
        if (loopback())
            return tx_byte;   // loopback: echo TX → RX

        switch (flash_state_) {
        case SpiFlashState::IDLE:
            if (tx_byte == SPI_FLASH_CMD_READ)
                flash_state_ = SpiFlashState::GOT_CMD;
            return 0u;   // don't-care echo

        case SpiFlashState::GOT_CMD:
            flash_addr_  = tx_byte;
            flash_state_ = SpiFlashState::DATA;
            return 0u;   // don't-care echo

        case SpiFlashState::DATA:
        default:
            return flash_[flash_addr_++];
        }
    }

    // ── Register access ──────────────────────────────────────────────────────

    uint32_t reg_read(reg_t addr)
    {
        switch (addr) {
        case KV_SPI_CTRL_OFF:   return ctrl_;
        case KV_SPI_DIV_OFF:    return div_;
        case KV_SPI_TX_OFF:     return 0u;   // write-only
        case KV_SPI_RX_OFF: {
            uint8_t b = rx_fifo_.empty() ? 0u : (uint8_t)(rx_fifo_.front());
            if (!rx_fifo_.empty()) rx_fifo_.pop_front();
            update_meip();
            return b;
        }
        case KV_SPI_STATUS_OFF: return read_status();
        case KV_SPI_IE_OFF:     return ie_;
        case KV_SPI_IS_OFF: {
            uint32_t is = KV_SPI_IE_TX_EMPTY;
            if (!rx_fifo_.empty()) is |= KV_SPI_IE_RX_READY;
            return is;
        }
        case KV_SPI_CAP_OFF:    return SPI_CAP_VAL;
        default:                return 0u;
        }
    }

    void reg_write(reg_t addr, uint32_t val)
    {
        switch (addr) {
        case KV_SPI_CTRL_OFF: {
            uint32_t old = ctrl_;
            ctrl_ = val;
            on_ctrl_write(old, val);
            break;
        }
        case KV_SPI_DIV_OFF:
            div_ = val;
            break;
        case KV_SPI_TX_OFF: {
            uint8_t rx = process_tx((uint8_t)(val & 0xFFu));
            if (rx_fifo_.size() < SPI_FIFO_DEPTH)
                rx_fifo_.push_back(rx);
            busy_cnt_ = 2;   // BUSY on next STATUS read, clear on the one after
            update_meip();
            break;
        }
        case KV_SPI_IE_OFF:
            ie_ = val & 0x3u;
            update_meip();
            break;
        case KV_SPI_IS_OFF:  // read-only (W1C in RTL, nothing to clear here)
        case KV_SPI_RX_OFF:  // read-only
        case KV_SPI_CAP_OFF: // read-only
        default:
            break;
        }
    }
};

static plugin_spi_t *
plugin_spi_parse(const void *, const sim_t *sim, reg_t *base,
                 const std::vector<std::string> &sargs)
{
    if (!sargs.empty()) *base = strtoull(sargs[0].c_str(), nullptr, 0);
    return new plugin_spi_t(const_cast<sim_t *>(sim));
}

static std::string
plugin_spi_generate_dts(const sim_t *, const std::vector<std::string> &)
{ return ""; }

REGISTER_DEVICE(plugin_spi, plugin_spi_parse, plugin_spi_generate_dts)

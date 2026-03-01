// ============================================================================
// File: plugin_spi.cc
// Project: KV32 RISC-V Processor
// Description: Spike MMIO plugin for the KV32 SPI master peripheral
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
//   TX always ready (STATUS[1] always set, STATUS[0] never set).
//   Loopback (CTRL[3]=1): each TX byte is also pushed to the RX FIFO, so
//   SPI loopback tests pass exactly as they do against the RTL.
//   Without loopback: RX FIFO stays empty (RX reads return 0).
// ============================================================================

#include <riscv/abstract_device.h>

#include <cstring>
#include <deque>
#include <string>
#include <vector>

#include "kv_platform.h"

static constexpr uint32_t SPI_FIFO_DEPTH = 16;
static constexpr uint32_t SPI_CAP_VAL =
    (0x01u << 24) | (4u << 16) | (SPI_FIFO_DEPTH << 8) | SPI_FIFO_DEPTH;
static constexpr reg_t SPI_ADDR_MAX = KV_SPI_CAP_OFF;

class plugin_spi_t : public abstract_device_t {
public:
    plugin_spi_t() : ctrl_(KV_SPI_CTRL_CS_ALL), div_(0), ie_(0) {}

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

    reg_t size() override { return (reg_t)KV_SPI_SIZE; }

private:
    uint32_t ctrl_, div_, ie_;
    std::deque<uint8_t> rx_fifo_;

    bool loopback() const { return (ctrl_ & KV_SPI_CTRL_LOOPBACK) != 0; }

    uint32_t status() const
    {
        uint32_t st = KV_SPI_ST_TX_READY; // TX always ready
        if (!rx_fifo_.empty())                    st |= KV_SPI_ST_RX_VALID;
        if (rx_fifo_.size() >= SPI_FIFO_DEPTH)    st |= KV_SPI_ST_RX_FULL;
        st |= KV_SPI_ST_TX_EMPTY; // TX FIFO always empty (instant transmit)
        return st;
    }

    uint32_t is_val() const
    {
        uint32_t is = KV_SPI_IE_TX_EMPTY; // TX always drained
        if (!rx_fifo_.empty()) is |= KV_SPI_IE_RX_READY;
        return is;
    }

    uint32_t reg_read(reg_t addr)
    {
        switch (addr) {
        case KV_SPI_CTRL_OFF:   return ctrl_;
        case KV_SPI_DIV_OFF:    return div_;
        case KV_SPI_TX_OFF:     return 0u;   // write-only in RTL
        case KV_SPI_RX_OFF:
            if (!rx_fifo_.empty()) {
                uint8_t b = rx_fifo_.front(); rx_fifo_.pop_front(); return b;
            }
            return 0u;
        case KV_SPI_STATUS_OFF: return status();
        case KV_SPI_IE_OFF:     return ie_;
        case KV_SPI_IS_OFF:     return is_val();
        case KV_SPI_CAP_OFF:    return SPI_CAP_VAL;
        default:                return 0u;
        }
    }

    void reg_write(reg_t addr, uint32_t val)
    {
        switch (addr) {
        case KV_SPI_CTRL_OFF: ctrl_ = val; break;
        case KV_SPI_DIV_OFF:  div_  = val; break;
        case KV_SPI_TX_OFF:
            if (loopback() && rx_fifo_.size() < SPI_FIFO_DEPTH)
                rx_fifo_.push_back((uint8_t)(val & 0xFF));
            break;
        case KV_SPI_RX_OFF:   /* read-only */               break;
        case KV_SPI_IE_OFF:   ie_ = val & 0x3u;             break;
        case KV_SPI_IS_OFF:   /* read-only (W1C in RTL) */  break;
        case KV_SPI_CAP_OFF:  /* read-only */                break;
        default: break;
        }
    }
};

static plugin_spi_t *
plugin_spi_parse(const void *, const sim_t *, reg_t *base,
                 const std::vector<std::string> &sargs)
{
    if (!sargs.empty()) *base = strtoull(sargs[0].c_str(), nullptr, 0);
    return new plugin_spi_t();
}

static std::string
plugin_spi_generate_dts(const sim_t *, const std::vector<std::string> &)
{ return ""; }

REGISTER_DEVICE(plugin_spi, plugin_spi_parse, plugin_spi_generate_dts)

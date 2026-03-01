// ============================================================================
// File: plugin_i2c.cc
// Project: KV32 RISC-V Processor
// Description: Spike MMIO plugin for the KV32 I2C master peripheral
//
// Register Map (relative to KV_I2C_BASE = 0x2001_0000):
//   0x00  CTRL    - Control (R/W): [0]=enable, [1]=start, [2]=stop, [3]=read, [4]=nack
//   0x04  DIV     - Clock divider (R/W)
//   0x08  TX      - TX data byte (W): push to TX FIFO (discarded in stub)
//   0x0C  RX      - RX data byte (R): pop from RX FIFO (always returns 0xFF in stub)
//   0x10  STATUS  - [0]=busy, [1]=tx_ready, [2]=rx_valid, [3]=ack_recv
//   0x14  IE      - Interrupt enable (R/W)
//   0x18  IS      - Interrupt status (RO): [0]=rx_ready, [1]=tx_empty, [2]=stop_done
//   0x1C  CAP     - Capability (RO): version=0x0001, RX_DEPTH=4, TX_DEPTH=4
//   >0x1C  —      - Bus error
//
// In simulation there is no real I2C bus.  TX writes are accepted (discarded).
// RX reads return 0xFF (bus idle / NACK).  STATUS[1] (tx_ready) is always set.
// CTRL[1] START clears START bit immediately (no real transaction).
// CTRL[2] STOP  sets IS[2] (stop_done) to notify software the bus is free.
// ============================================================================

#include <riscv/abstract_device.h>

#include <cstring>
#include <string>
#include <vector>

#include "kv_platform.h"

static constexpr uint32_t I2C_FIFO_DEPTH = 4;
static constexpr uint32_t I2C_CAP_VAL =
    (0x0001u << 16) | (I2C_FIFO_DEPTH << 8) | I2C_FIFO_DEPTH;
static constexpr reg_t I2C_ADDR_MAX = KV_I2C_CAP_OFF;

class plugin_i2c_t : public abstract_device_t {
public:
    plugin_i2c_t() : ctrl_(0), div_(0), ie_(0), is_(0) {}

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
    uint32_t ctrl_, div_, ie_, is_;

    uint32_t reg_read(reg_t addr)
    {
        switch (addr) {
        case KV_I2C_CTRL_OFF:   return ctrl_;
        case KV_I2C_DIV_OFF:    return div_;
        case KV_I2C_TX_OFF:     return 0u;   // write-only in RTL; return 0
        case KV_I2C_RX_OFF:     return 0xFFu; // no real bus; return idle byte
        case KV_I2C_STATUS_OFF:
            // tx_ready always set (no hardware busy-wait needed in sim)
            return KV_I2C_ST_TX_READY;
        case KV_I2C_IE_OFF:     return ie_;
        case KV_I2C_IS_OFF:     return is_;
        case KV_I2C_CAP_OFF:    return I2C_CAP_VAL;
        default:                return 0u;
        }
    }

    void reg_write(reg_t addr, uint32_t val)
    {
        switch (addr) {
        case KV_I2C_CTRL_OFF:
            // START issued: clear it immediately (no real transaction)
            ctrl_ = val & ~(uint32_t)KV_I2C_CTRL_START;
            // STOP issued: set stop_done interrupt flag
            if (val & KV_I2C_CTRL_STOP)
                is_ |= KV_I2C_IE_STOP_DONE;
            break;
        case KV_I2C_DIV_OFF:  div_ = val;              break;
        case KV_I2C_TX_OFF:   /* TX discarded */        break;
        case KV_I2C_RX_OFF:   /* read-only */           break;
        case KV_I2C_IE_OFF:   ie_  = val & 0x7u;       break;
        case KV_I2C_IS_OFF:   is_ &= ~val;             break; // W1C
        case KV_I2C_CAP_OFF:  /* read-only */           break;
        default: break;
        }
    }
};

static plugin_i2c_t *
plugin_i2c_parse(const void *, const sim_t *, reg_t *base,
                 const std::vector<std::string> &sargs)
{
    if (!sargs.empty()) *base = strtoull(sargs[0].c_str(), nullptr, 0);
    return new plugin_i2c_t();
}

static std::string
plugin_i2c_generate_dts(const sim_t *, const std::vector<std::string> &)
{ return ""; }

REGISTER_DEVICE(plugin_i2c, plugin_i2c_parse, plugin_i2c_generate_dts)

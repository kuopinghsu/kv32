// ============================================================================
// File: plugin_uart.cc
// Project: KV32 RISC-V Processor
// Description: Spike MMIO plugin for the KV32 UART peripheral
//
// Register Map (relative to KV_UART_BASE = 0x2000_0000):
//   0x00  DATA    - write: byte → stdout;  read: byte ← stdin (non-blocking)
//   0x04  STATUS  - [0/1]=tx_full (0=ready), [2]=rx_ready, [3]=rx_full
//   0x08  IE      - Interrupt enable (R/W)
//   0x0C  IS      - Interrupt status (RO level): [0]=rx_ready, [1]=tx_empty
//   0x10  LEVEL   - [3:0]=rx_count, [11:8]=tx_count (both reported as 0)
//   0x14  CTRL    - [0]=loopback_en (R/W)
//   0x18  CAP     - Capability (RO): version=0x0001, RX_DEPTH=16, TX_DEPTH=16
//   >0x18  —      - Bus error (load/store access-fault)
//
// Simulation behaviour:
//   TX always succeeds immediately (STATUS never shows tx_full).
//   TX data is written to stdout.
//   RX: non-blocking stdin poll via select(); returns 0 if no input available.
//   With loopback enabled (CTRL[0]=1), each TX byte is also pushed to the RX
//   FIFO so software loopback tests work correctly.
// ============================================================================

#include <riscv/abstract_device.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

#include <fcntl.h>
#include <sys/select.h>
#include <unistd.h>

#include "kv_platform.h"

static constexpr uint32_t UART_FIFO_DEPTH = 16;
static constexpr uint32_t UART_CAP_VAL =
    (0x0001u << 16) | (UART_FIFO_DEPTH << 8) | UART_FIFO_DEPTH;
// Last valid register offset
static constexpr reg_t UART_ADDR_MAX = KV_UART_CAP_OFF;

// Non-blocking stdin: try to read one byte without blocking.
static bool stdin_try_read(uint8_t *ch)
{
    fd_set fds;
    FD_ZERO(&fds);
    FD_SET(STDIN_FILENO, &fds);
    struct timeval tv = {0, 0};
    if (select(STDIN_FILENO + 1, &fds, nullptr, nullptr, &tv) <= 0) return false;
    int c = fgetc(stdin);
    if (c == EOF) return false;
    *ch = (uint8_t)c;
    return true;
}

class plugin_uart_t : public abstract_device_t {
public:
    plugin_uart_t() : ie_(0), loopback_(false) {}

    bool load(reg_t addr, size_t len, uint8_t *bytes) override
    {
        if (addr > UART_ADDR_MAX) return false;  // bus error
        uint32_t val = reg_read(addr);
        memset(bytes, 0, len);
        if (len >= 4) memcpy(bytes, &val, 4);
        else           memcpy(bytes, &val, len);
        return true;
    }

    bool store(reg_t addr, size_t len, const uint8_t *bytes) override
    {
        if (addr > UART_ADDR_MAX) return false;  // bus error
        uint32_t val = 0;
        if (len >= 4) memcpy(&val, bytes, 4);
        else           memcpy(&val, bytes, len);
        reg_write(addr, val);
        return true;
    }

    reg_t size() override { return (reg_t)KV_UART_SIZE; }

private:
    std::deque<uint8_t> rx_fifo_;
    uint32_t ie_;
    bool     loopback_;

    // Poll stdin for any pending bytes and drain them into rx_fifo_.
    void poll_stdin()
    {
        uint8_t ch;
        while (rx_fifo_.size() < UART_FIFO_DEPTH && stdin_try_read(&ch))
            rx_fifo_.push_back(ch);
    }

    uint32_t rx_is()   const { return rx_fifo_.empty() ? 0u : KV_UART_IE_RX_READY; }
    uint32_t is_val()  const { return rx_is() | KV_UART_IE_TX_EMPTY; } // tx always empty

    uint32_t reg_read(reg_t addr)
    {
        switch (addr) {
        case KV_UART_DATA_OFF: {
            poll_stdin();
            if (!rx_fifo_.empty()) {
                uint8_t b = rx_fifo_.front(); rx_fifo_.pop_front();
                return b;
            }
            return 0u;
        }
        case KV_UART_STATUS_OFF: {
            poll_stdin();
            uint32_t st = 0;
            if (!rx_fifo_.empty())                     st |= KV_UART_ST_RX_READY;
            if (rx_fifo_.size() >= UART_FIFO_DEPTH)    st |= KV_UART_ST_RX_FULL;
            // TX never full in simulation
            return st;
        }
        case KV_UART_IE_OFF:    return ie_;
        case KV_UART_IS_OFF:    poll_stdin(); return is_val();
        case KV_UART_LEVEL_OFF: {
            poll_stdin();
            return (uint32_t)rx_fifo_.size() & 0x1Fu; // tx_count=0, rx_count in [3:0]
        }
        case KV_UART_CTRL_OFF:  return loopback_ ? KV_UART_CTRL_LOOPBACK : 0u;
        case KV_UART_CAP_OFF:   return UART_CAP_VAL;
        default:                return 0u;
        }
    }

    void reg_write(reg_t addr, uint32_t val)
    {
        switch (addr) {
        case KV_UART_DATA_OFF: {
            char ch = (char)(val & 0xFF);
            fputc(ch, stdout);
            fflush(stdout);
            if (loopback_ && rx_fifo_.size() < UART_FIFO_DEPTH)
                rx_fifo_.push_back((uint8_t)ch);
            break;
        }
        case KV_UART_IE_OFF:   ie_      = val & 0x3u; break;
        case KV_UART_IS_OFF:   break;  // IS is read-only (W1C in RTL, no-op here)
        case KV_UART_LEVEL_OFF: break; // LEVEL is read-only
        case KV_UART_CTRL_OFF: loopback_ = (val & KV_UART_CTRL_LOOPBACK) != 0; break;
        case KV_UART_CAP_OFF:  break;  // CAP is read-only
        default: break;
        }
    }
};

static plugin_uart_t *
plugin_uart_parse(const void *, const sim_t *, reg_t *base,
                  const std::vector<std::string> &sargs)
{
    if (!sargs.empty()) *base = strtoull(sargs[0].c_str(), nullptr, 0);
    return new plugin_uart_t();
}

static std::string
plugin_uart_generate_dts(const sim_t *, const std::vector<std::string> &)
{ return ""; }

REGISTER_DEVICE(plugin_uart, plugin_uart_parse, plugin_uart_generate_dts)

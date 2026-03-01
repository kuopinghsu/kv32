// ============================================================================
// File: plugin_dma.cc
// Project: KV32 RISC-V Processor
// Description: Spike MMIO plugin for the KV32 DMA controller
//
// Register Map (relative to KV_DMA_BASE = 0x2003_0000, size 4 KB):
//
//   Per-channel registers (up to NUM_CHANNELS, each block 0x40 bytes):
//     ch*0x40 + 0x00  CTRL     - [0]=en, [1]=start, [2]=stop, [3:4]=mode, [7]=irq_en
//     ch*0x40 + 0x04  STAT     - [0]=busy(RO), [1]=done(W1C), [2]=err(W1C)
//     ch*0x40 + 0x08  SRC      - Source address (R/W)
//     ch*0x40 + 0x0C  DST      - Destination address (R/W)
//     ch*0x40 + 0x10  XFER     - Transfer size in bytes (R/W)
//     ch*0x40 + 0x14-0x30 stride/scatter-gather (R/W, stored but not used)
//
//   Global registers:
//     0xF00  IRQ_STAT  - Per-channel done/err flags (W1C)
//     0xF04  IRQ_EN    - Per-channel IRQ global enable (R/W)
//     0xF08  ID        - 0xD4A00100 (read-only)
//     0xF0C  CAP       - [7:0]=NUM_CHANNELS, [15:8]=MAX_BURST, [31:16]=VERSION
//     0xF10-0xF1C      - Performance counters (stub: return 0)
//   outside [0, 0xFFF]  — Bus error
//
// Simulation behaviour:
//   Transfers are not actually executed (Spike plugins have no system-memory
//   access).  When software writes CTRL with START set, the DMA "completes"
//   immediately: STAT[1] (done) is set and IRQ_STAT[ch] is raised.
//   Software can also poll STAT[0] (busy) — it is always 0 in simulation.
// ============================================================================

#include <riscv/abstract_device.h>

#include <cstring>
#include <string>
#include <vector>

#include "kv_platform.h"

static constexpr uint32_t DMA_NUM_CHANNELS = 8;
static constexpr uint32_t DMA_ID_VAL       = 0xD4A00100u;
static constexpr uint32_t DMA_CAP_VAL      =
    (0x0001u << 16) | (4u << 8) | DMA_NUM_CHANNELS; // version=1, burst=4, N_CH=8
static constexpr reg_t DMA_ADDR_MAX        = 0xFFFu; // 4 KB window

// Number of 32-bit words per channel (stride = 0x40 = 16 words)
static constexpr uint32_t CH_WORDS = KV_DMA_CH_STRIDE / 4;

class plugin_dma_t : public abstract_device_t {
public:
    plugin_dma_t()
    {
        memset(ch_regs_,   0, sizeof(ch_regs_));
        memset(glb_regs_,  0, sizeof(glb_regs_));
        glb_regs_[DMA_ID_IDX]  = DMA_ID_VAL;
        glb_regs_[DMA_CAP_IDX] = DMA_CAP_VAL;
    }

    bool load(reg_t addr, size_t len, uint8_t *bytes) override
    {
        if (addr > DMA_ADDR_MAX || (addr & 3u)) return false;
        uint32_t val = reg_read(addr);
        memset(bytes, 0, len);
        if (len >= 4) memcpy(bytes, &val, 4);
        else           memcpy(bytes, &val, len);
        return true;
    }

    bool store(reg_t addr, size_t len, const uint8_t *bytes) override
    {
        if (addr > DMA_ADDR_MAX || (addr & 3u)) return false;
        uint32_t val = 0;
        if (len >= 4) memcpy(&val, bytes, 4);
        else           memcpy(&val, bytes, len);
        reg_write(addr, val);
        return true;
    }

    reg_t size() override { return (reg_t)KV_DMA_SIZE; }

private:
    // Channel register file: [channel][word_index]
    uint32_t ch_regs_[DMA_NUM_CHANNELS][CH_WORDS];

    // Global register file indexed by enum
    enum GlbIdx { DMA_IRQSTAT_IDX = 0, DMA_IRQEN_IDX, DMA_ID_IDX, DMA_CAP_IDX,
                  DMA_PERFCTRL_IDX, DMA_PERFCYC_IDX, DMA_PERFRDBYTES_IDX,
                  DMA_PERFWRBYTES_IDX, DMA_GLB_COUNT };
    uint32_t glb_regs_[DMA_GLB_COUNT];

    // Map global offset to glb_regs_ index
    static int glb_idx(reg_t off)
    {
        switch (off) {
        case KV_DMA_IRQ_STAT_OFF:     return DMA_IRQSTAT_IDX;
        case KV_DMA_IRQ_EN_OFF:       return DMA_IRQEN_IDX;
        case KV_DMA_ID_OFF:           return DMA_ID_IDX;
        case KV_DMA_CAP_OFF:          return DMA_CAP_IDX;
        case KV_DMA_PERF_CTRL_OFF:    return DMA_PERFCTRL_IDX;
        case KV_DMA_PERF_CYCLES_OFF:  return DMA_PERFCYC_IDX;
        case KV_DMA_PERF_RD_BYTES_OFF:return DMA_PERFRDBYTES_IDX;
        case KV_DMA_PERF_WR_BYTES_OFF:return DMA_PERFWRBYTES_IDX;
        default: return -1;
        }
    }

    uint32_t reg_read(reg_t addr)
    {
        if (addr >= KV_DMA_IRQ_STAT_OFF) {
            int idx = glb_idx(addr);
            return (idx >= 0) ? glb_regs_[idx] : 0u;
        }
        // Per-channel
        uint32_t ch  = (uint32_t)(addr / KV_DMA_CH_STRIDE);
        uint32_t off = (uint32_t)(addr % KV_DMA_CH_STRIDE);
        if (ch >= DMA_NUM_CHANNELS || (off & 3u)) return 0u;
        return ch_regs_[ch][off / 4];
    }

    void reg_write(reg_t addr, uint32_t val)
    {
        if (addr >= KV_DMA_IRQ_STAT_OFF) {
            int idx = glb_idx(addr);
            if (idx < 0) return;
            if (idx == DMA_IRQSTAT_IDX)
                glb_regs_[idx] &= ~val; // W1C
            else if (idx == DMA_ID_IDX || idx == DMA_CAP_IDX)
                return;  // read-only
            else
                glb_regs_[idx] = val;
            return;
        }
        // Per-channel
        uint32_t ch  = (uint32_t)(addr / KV_DMA_CH_STRIDE);
        uint32_t off = (uint32_t)(addr % KV_DMA_CH_STRIDE);
        if (ch >= DMA_NUM_CHANNELS || (off & 3u)) return;

        uint32_t word = off / 4;

        if (off == KV_DMA_CH_STAT_OFF) {
            // STAT: W1C for done/err bits
            ch_regs_[ch][word] &= ~(val & (KV_DMA_STAT_DONE | KV_DMA_STAT_ERR));
            // If done/err cleared, also clear corresponding IRQ_STAT bit
            if (val & (KV_DMA_STAT_DONE | KV_DMA_STAT_ERR))
                glb_regs_[DMA_IRQSTAT_IDX] &= ~(1u << ch);
            return;
        }

        ch_regs_[ch][word] = val;

        if (off == KV_DMA_CH_CTRL_OFF && (val & KV_DMA_CTRL_START)) {
            // Simulate instant transfer completion
            ch_regs_[ch][word] &= ~(uint32_t)KV_DMA_CTRL_START; // auto-clear START
            // Set STAT[busy=0, done=1]
            uint32_t &stat = ch_regs_[ch][KV_DMA_CH_STAT_OFF / 4];
            stat &= ~(uint32_t)KV_DMA_STAT_BUSY;
            stat |=  KV_DMA_STAT_DONE;
            // Raise global IRQ_STAT if channel IRQ enabled
            if (val & KV_DMA_CTRL_IE)
                glb_regs_[DMA_IRQSTAT_IDX] |= (1u << ch);
        }
    }
};

static plugin_dma_t *
plugin_dma_parse(const void *, const sim_t *, reg_t *base,
                 const std::vector<std::string> &sargs)
{
    if (!sargs.empty()) *base = strtoull(sargs[0].c_str(), nullptr, 0);
    return new plugin_dma_t();
}

static std::string
plugin_dma_generate_dts(const sim_t *, const std::vector<std::string> &)
{ return ""; }

REGISTER_DEVICE(plugin_dma, plugin_dma_parse, plugin_dma_generate_dts)

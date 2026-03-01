// ============================================================================
// File: plugin_dma.cc
// Project: KV32 RISC-V Processor
// Description: Spike MMIO plugin for the KV32 DMA controller
//              with actual host-memory copy via simif_t::addr_to_mem().
//
// Register Map (relative to KV_DMA_BASE = 0x2003_0000, size 4 KB):
//
//   Per-channel registers (up to NUM_CHANNELS, each block 0x40 bytes):
//     ch*0x40 + 0x00  CTRL     - [0]=en, [1]=start, [2]=stop, [4:3]=mode, [5]=src_inc
//                                [6]=dst_inc, [7]=irq_en
//     ch*0x40 + 0x04  STAT     - [0]=busy(RO), [1]=done(W1C), [2]=err(W1C)
//     ch*0x40 + 0x08  SRC      - Source address (R/W)
//     ch*0x40 + 0x0C  DST      - Destination address (R/W)
//     ch*0x40 + 0x10  XFER     - Transfer size in bytes (R/W)
//     ch*0x40 + 0x14  SSTRIDE  - Source row stride (2D/3D)
//     ch*0x40 + 0x18  DSTRIDE  - Destination row stride (2D/3D)
//     ch*0x40 + 0x1C  ROWCNT   - Number of rows (2D/3D)
//     ch*0x40 + 0x20  SPSTRIDE - Source plane stride (3D)
//     ch*0x40 + 0x24  DPSTRIDE - Destination plane stride (3D)
//     ch*0x40 + 0x28  PLANECNT - Number of planes (3D)
//     ch*0x40 + 0x2C  SGADDR   - Scatter-gather descriptor base address
//     ch*0x40 + 0x30  SGCNT    - Number of SG descriptors
//
//   Global registers:
//     0xF00  IRQ_STAT  - Per-channel done/err flags (W1C)
//     0xF04  IRQ_EN    - Per-channel IRQ global enable (R/W)
//     0xF08  ID        - 0xD4A00100 (read-only)
//     0xF0C  CAP       - [7:0]=NUM_CHANNELS, [15:8]=MAX_BURST, [31:16]=VERSION
//     0xF10-0xF1C      - Performance counters (stub: return 0)
//
// Simulation behaviour:
//   On START: use simif_t::addr_to_mem() (public pure virtual) to resolve
//   src/dst to host pointers, then execute 1D/2D/3D/SG copy immediately.
//   If src is 0x0 (unmapped), set STAT_ERR instead of STAT_DONE.
//   PLIC source KV_PLIC_SRC_DMA is asserted while (IRQ_STAT & IRQ_EN) != 0.
// ============================================================================

#include <riscv/abstract_device.h>

#ifdef SPIKE_INCLUDE
#include <riscv/sim.h>
#include <riscv/simif.h>
#include <riscv/devices.h>
#endif

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
    explicit plugin_dma_t(sim_t *sim = nullptr) : sim_(sim)
    {
        memset(ch_regs_,  0, sizeof(ch_regs_));
        memset(glb_regs_, 0, sizeof(glb_regs_));
        glb_regs_[DMA_ID_IDX]  = DMA_ID_VAL;
        glb_regs_[DMA_CAP_IDX] = DMA_CAP_VAL;
    }

    bool load(reg_t addr, size_t len, uint8_t *bytes) override
    {
        if (addr > DMA_ADDR_MAX || (addr & 3u)) return false;
        // Hole between end of channel registers and global registers → SLVERR
        if (addr >= (reg_t)(DMA_NUM_CHANNELS * KV_DMA_CH_STRIDE) &&
            addr <  (reg_t)KV_DMA_IRQ_STAT_OFF) return false;
        uint32_t val = reg_read(addr);
        memset(bytes, 0, len);
        if (len >= 4) memcpy(bytes, &val, 4);
        else           memcpy(bytes, &val, len);
        return true;
    }

    bool store(reg_t addr, size_t len, const uint8_t *bytes) override
    {
        if (addr > DMA_ADDR_MAX || (addr & 3u)) return false;
        // Hole between end of channel registers and global registers → SLVERR
        if (addr >= (reg_t)(DMA_NUM_CHANNELS * KV_DMA_CH_STRIDE) &&
            addr <  (reg_t)KV_DMA_IRQ_STAT_OFF) return false;
        uint32_t val = 0;
        if (len >= 4) memcpy(&val, bytes, 4);
        else           memcpy(&val, bytes, len);
        reg_write(addr, val);
        return true;
    }

    reg_t size() override { return (reg_t)KV_DMA_SIZE; }

private:
    sim_t *sim_;

    // ── PLIC IRQ ─────────────────────────────────────────────────────────────

    void update_meip() const
    {
#ifdef SPIKE_INCLUDE
        if (!sim_) return;
        const bool pending =
            (glb_regs_[DMA_IRQSTAT_IDX] & glb_regs_[DMA_IRQEN_IDX]) != 0;
        sim_->get_intctrl()->set_interrupt_level(
            (uint32_t)KV_PLIC_SRC_DMA, pending ? 1 : 0);
#endif
    }

    // ── Host-memory access ───────────────────────────────────────────────────

    // Resolves a RISC-V physical address to a host pointer.
    // addr_to_mem() is PUBLIC pure virtual on simif_t (private on sim_t),
    // so we must cast through simif_t.
    uint8_t *to_host(uint32_t paddr) const
    {
#ifdef SPIKE_INCLUDE
        if (!sim_ || paddr == 0u) return nullptr;
        simif_t *sif = static_cast<simif_t *>(sim_);
        char *p = sif->addr_to_mem((reg_t)paddr);
        return reinterpret_cast<uint8_t *>(p);
#else
        (void)paddr;
        return nullptr;
#endif
    }

    bool do_1d_copy(uint32_t src, uint32_t dst, uint32_t bytes,
                    bool src_inc, bool dst_inc) const
    {
        uint8_t *s = to_host(src);
        uint8_t *d = to_host(dst);
        if (!s || !d) return false;
        if (src_inc && dst_inc) {
            memcpy(d, s, bytes);
        } else {
            for (uint32_t i = 0; i < bytes; i++)
                *(dst_inc ? d + i : d) = *(src_inc ? s + i : s);
        }
        return true;
    }

    // ── Register bank ────────────────────────────────────────────────────────

    // Channel register file: [channel][word_index]
    uint32_t ch_regs_[DMA_NUM_CHANNELS][CH_WORDS];

    // Global register file indexed by enum
    enum GlbIdx {
        DMA_IRQSTAT_IDX = 0, DMA_IRQEN_IDX, DMA_ID_IDX, DMA_CAP_IDX,
        DMA_PERFCTRL_IDX, DMA_PERFCYC_IDX, DMA_PERFRDBYTES_IDX,
        DMA_PERFWRBYTES_IDX, DMA_GLB_COUNT
    };
    uint32_t glb_regs_[DMA_GLB_COUNT];

    // Map global offset to glb_regs_ index
    static int glb_idx(reg_t off)
    {
        switch (off) {
        case KV_DMA_IRQ_STAT_OFF:      return DMA_IRQSTAT_IDX;
        case KV_DMA_IRQ_EN_OFF:        return DMA_IRQEN_IDX;
        case KV_DMA_ID_OFF:            return DMA_ID_IDX;
        case KV_DMA_CAP_OFF:           return DMA_CAP_IDX;
        case KV_DMA_PERF_CTRL_OFF:     return DMA_PERFCTRL_IDX;
        case KV_DMA_PERF_CYCLES_OFF:   return DMA_PERFCYC_IDX;
        case KV_DMA_PERF_RD_BYTES_OFF: return DMA_PERFRDBYTES_IDX;
        case KV_DMA_PERF_WR_BYTES_OFF: return DMA_PERFWRBYTES_IDX;
        default:                        return -1;
        }
    }

    // ── Register access ──────────────────────────────────────────────────────

    uint32_t reg_read(reg_t addr)
    {
        if (addr >= KV_DMA_IRQ_STAT_OFF) {
            int idx = glb_idx(addr);
            return (idx >= 0) ? glb_regs_[idx] : 0u;
        }
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
            if (idx == DMA_IRQSTAT_IDX) {
                glb_regs_[idx] &= ~val;   // W1C
                update_meip();
            } else if (idx == DMA_IRQEN_IDX) {
                glb_regs_[idx] = val;
                update_meip();
            } else if (idx == DMA_ID_IDX || idx == DMA_CAP_IDX) {
                // read-only
            } else if (idx == DMA_PERFCTRL_IDX) {
                // bit[1]=reset: clear all perf counters; bit[0]=enable
                if (val & 2u) {
                    glb_regs_[DMA_PERFCYC_IDX]      = 0;
                    glb_regs_[DMA_PERFRDBYTES_IDX]  = 0;
                    glb_regs_[DMA_PERFWRBYTES_IDX]  = 0;
                }
                glb_regs_[idx] = val & 1u; // store only enable bit
            } else {
                glb_regs_[idx] = val;
            }
            return;
        }

        uint32_t ch  = (uint32_t)(addr / KV_DMA_CH_STRIDE);
        uint32_t off = (uint32_t)(addr % KV_DMA_CH_STRIDE);
        if (ch >= DMA_NUM_CHANNELS || (off & 3u)) return;
        uint32_t word = off / 4;

        if (off == KV_DMA_CH_STAT_OFF) {
            // W1C for done/err
            ch_regs_[ch][word] &= ~(val & (KV_DMA_STAT_DONE | KV_DMA_STAT_ERR));
            if (val & (KV_DMA_STAT_DONE | KV_DMA_STAT_ERR)) {
                glb_regs_[DMA_IRQSTAT_IDX] &= ~(1u << ch);
                update_meip();
            }
            return;
        }

        ch_regs_[ch][word] = val;

        if (off == KV_DMA_CH_CTRL_OFF && (val & KV_DMA_CTRL_START)) {
            ch_regs_[ch][word] &= ~(uint32_t)KV_DMA_CTRL_START; // auto-clear

            uint32_t &stat    = ch_regs_[ch][KV_DMA_CH_STAT_OFF  / 4];
            uint32_t src_addr = ch_regs_[ch][KV_DMA_CH_SRC_OFF   / 4];
            uint32_t dst_addr = ch_regs_[ch][KV_DMA_CH_DST_OFF   / 4];
            uint32_t xfer_cnt = ch_regs_[ch][KV_DMA_CH_XFER_OFF  / 4];
            uint32_t mode     = (val >> 3) & 0x3u;
            bool src_inc      = (val & KV_DMA_CTRL_SRC_INC) != 0;
            bool dst_inc      = (val & KV_DMA_CTRL_DST_INC) != 0;

            stat &= ~(uint32_t)KV_DMA_STAT_BUSY;
            bool err = false;

            if (src_addr == 0u) {
                err = true;   // unmapped address → bus error
            } else {
                switch (mode) {
                case 0: // 1-D flat
                    err = !do_1d_copy(src_addr, dst_addr, xfer_cnt,
                                      src_inc, dst_inc);
                    break;
                case 1: { // 2-D strided
                    uint32_t ss = ch_regs_[ch][KV_DMA_CH_SSTRIDE_OFF / 4];
                    uint32_t ds = ch_regs_[ch][KV_DMA_CH_DSTRIDE_OFF / 4];
                    uint32_t nr = ch_regs_[ch][KV_DMA_CH_ROWCNT_OFF  / 4];
                    for (uint32_t r = 0; r < nr && !err; r++)
                        err = !do_1d_copy(src_addr + r * ss,
                                          dst_addr + r * ds,
                                          xfer_cnt, src_inc, dst_inc);
                    break;
                }
                case 2: { // 3-D planar
                    uint32_t ss = ch_regs_[ch][KV_DMA_CH_SSTRIDE_OFF  / 4];
                    uint32_t ds = ch_regs_[ch][KV_DMA_CH_DSTRIDE_OFF  / 4];
                    uint32_t nr = ch_regs_[ch][KV_DMA_CH_ROWCNT_OFF   / 4];
                    uint32_t sp = ch_regs_[ch][KV_DMA_CH_SPSTRIDE_OFF / 4];
                    uint32_t dp = ch_regs_[ch][KV_DMA_CH_DPSTRIDE_OFF / 4];
                    uint32_t np = ch_regs_[ch][KV_DMA_CH_PLANECNT_OFF / 4];
                    for (uint32_t p = 0; p < np && !err; p++)
                        for (uint32_t r = 0; r < nr && !err; r++)
                            err = !do_1d_copy(
                                src_addr + p * sp + r * ss,
                                dst_addr + p * dp + r * ds,
                                xfer_cnt, src_inc, dst_inc);
                    break;
                }
                case 3: { // Scatter-Gather
                    // SG descriptor (16 bytes each):
                    //   uint32 src_addr;
                    //   uint32 dst_addr;
                    //   uint32 xfer_cnt;
                    //   uint32 mode_ctrl;  [2]=src_inc, [3]=dst_inc
                    uint32_t sg_base  = ch_regs_[ch][KV_DMA_CH_SGADDR_OFF / 4];
                    uint32_t sg_count = ch_regs_[ch][KV_DMA_CH_SGCNT_OFF  / 4];
                    for (uint32_t i = 0; i < sg_count && !err; i++) {
                        const uint32_t *desc = reinterpret_cast<const uint32_t *>(
                            to_host(sg_base + i * 16u));
                        if (!desc) { err = true; break; }
                        bool si = (desc[3] & (1u << 2)) != 0;
                        bool di = (desc[3] & (1u << 3)) != 0;
                        err = !do_1d_copy(desc[0], desc[1], desc[2], si, di);
                    }
                    break;
                }
                default: break;
                }
            }

            stat |= err ? KV_DMA_STAT_ERR : KV_DMA_STAT_DONE;

            // Accumulate performance counters if enabled
            if (!err && (glb_regs_[DMA_PERFCTRL_IDX] & 1u)) {
                uint32_t bytes = xfer_cnt;
                // For 2D/3D modes, multiply by row/plane count
                uint32_t nr = ch_regs_[ch][KV_DMA_CH_ROWCNT_OFF  / 4];
                uint32_t np = ch_regs_[ch][KV_DMA_CH_PLANECNT_OFF / 4];
                if (mode == 1 && nr > 0)           bytes = xfer_cnt * nr;
                else if (mode == 2 && nr > 0 && np > 0) bytes = xfer_cnt * nr * np;
                // SG: approximate by individual xfer_cnt totals (already done)
                glb_regs_[DMA_PERFRDBYTES_IDX] += bytes;
                glb_regs_[DMA_PERFWRBYTES_IDX] += bytes;
            }

            if (val & KV_DMA_CTRL_IE)
                glb_regs_[DMA_IRQSTAT_IDX] |= (1u << ch);
            update_meip();
        }
    }
};

static plugin_dma_t *
plugin_dma_parse(const void *, const sim_t *sim, reg_t *base,
                 const std::vector<std::string> &sargs)
{
    if (!sargs.empty()) *base = strtoull(sargs[0].c_str(), nullptr, 0);
    return new plugin_dma_t(const_cast<sim_t *>(sim));
}

static std::string
plugin_dma_generate_dts(const sim_t *, const std::vector<std::string> &)
{ return ""; }

REGISTER_DEVICE(plugin_dma, plugin_dma_parse, plugin_dma_generate_dts)

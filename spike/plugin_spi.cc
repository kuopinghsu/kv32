/* ============================================================================
 * spike/plugin_spi.cc – Spike MMIO plugin for the KV32 SPI master
 *
 * Base address : KV_SPI_BASE  (0x2002_0000)
 * Window size  : KV_SPI_SIZE  (64 KB)
 *
 * Register offsets (from kv_platform.h):
 *   KV_SPI_CTRL_OFF    0x00  Control
 *   KV_SPI_DIV_OFF     0x04  Clock divider
 *   KV_SPI_TX_OFF      0x08  TX FIFO push  (write-only)
 *   KV_SPI_RX_OFF      0x0C  RX FIFO pop   (read-only)
 *   KV_SPI_STATUS_OFF  0x10  Status
 *   KV_SPI_IE_OFF      0x14  Interrupt Enable
 *   KV_SPI_IS_OFF      0x18  Interrupt Status (W1C)
 *
 * Behaviour:
 *   In loopback mode (KV_SPI_CTRL_LOOPBACK) every TX byte is immediately
 *   reflected into the RX FIFO, simulating a device that echoes back data.
 *   Without loopback the TX FIFO drains silently (no external slave).
 *   IRQ is raised via plic_notify(KV_PLIC_SRC_SPI, 1) when the RX FIFO
 *   becomes non-empty and KV_SPI_IE_RX_READY is set.
 * =========================================================================*/
#include "mmio_plugin_api.h"
#include <stdlib.h>

enum { SPI_FIFO_DEPTH = 16 };

struct spi_t {
    uint8_t  rx_fifo[SPI_FIFO_DEPTH];
    uint8_t  rd;
    uint8_t  wr;
    uint32_t ctrl;
    uint32_t div;
    uint32_t ie;
    uint32_t is;
    int      irq_state;
};

static inline bool spi_rx_empty(const spi_t* s) { return s->rd == s->wr; }
static inline bool spi_rx_full(const spi_t* s) {
    return (uint8_t)(s->wr - s->rd) == SPI_FIFO_DEPTH;
}
static inline void spi_rx_push(spi_t* s, uint8_t b) {
    if (!spi_rx_full(s)) { s->rx_fifo[s->wr & (SPI_FIFO_DEPTH-1)] = b; s->wr++; }
}
static inline uint8_t spi_rx_pop(spi_t* s) {
    uint8_t b = s->rx_fifo[s->rd & (SPI_FIFO_DEPTH-1)]; s->rd++; return b;
}

static void spi_update_irq(spi_t* s) {
    int pending = 0;
    if ((s->ie & (uint32_t)KV_SPI_IE_RX_READY) && !spi_rx_empty(s))
        pending = 1;
    if (pending != s->irq_state) {
        s->irq_state = pending;
        plic_notify(KV_PLIC_SRC_SPI, pending);
    }
}

static void* spi_alloc(const char* /*args*/) { return calloc(1, sizeof(spi_t)); }
static void  spi_dealloc(void* dev)          { free(dev); }

static bool spi_access(void* dev, reg_t addr,
                        size_t len, uint8_t* bytes, bool store)
{
    spi_t*   s   = (spi_t*)dev;
    uint32_t off = (uint32_t)addr;

    if (!store) {
        uint32_t val = 0;
        if (off == (uint32_t)KV_SPI_RX_OFF) {
            if (!spi_rx_empty(s)) val = spi_rx_pop(s);
            spi_update_irq(s);
        } else if (off == (uint32_t)KV_SPI_CTRL_OFF) {
            val = s->ctrl;
        } else if (off == (uint32_t)KV_SPI_DIV_OFF) {
            val = s->div;
        } else if (off == (uint32_t)KV_SPI_STATUS_OFF) {
            val  = (uint32_t)KV_SPI_ST_TX_READY;   /* TX always ready */
            val |= (uint32_t)KV_SPI_ST_TX_EMPTY;
            if (!spi_rx_empty(s)) val |= (uint32_t)KV_SPI_ST_RX_VALID;
            if (spi_rx_full(s))   val |= (uint32_t)KV_SPI_ST_RX_FULL;
        } else if (off == (uint32_t)KV_SPI_IE_OFF) {
            val = s->ie;
        } else if (off == (uint32_t)KV_SPI_IS_OFF) {
            val = s->is;
            if (!spi_rx_empty(s)) val |= (uint32_t)KV_SPI_IE_RX_READY;
            val |= (uint32_t)KV_SPI_IE_TX_EMPTY;   /* TX always empty */
        }
        fill_bytes(bytes, len, val);
    } else {
        uint32_t val = extract_val(bytes, len);
        if (off == (uint32_t)KV_SPI_TX_OFF) {
            if (s->ctrl & (uint32_t)KV_SPI_CTRL_LOOPBACK)
                spi_rx_push(s, (uint8_t)val);
            /* else: data is silently dropped (no external slave) */
            spi_update_irq(s);
        } else if (off == (uint32_t)KV_SPI_CTRL_OFF) {
            s->ctrl = val;
        } else if (off == (uint32_t)KV_SPI_DIV_OFF) {
            s->div = val;
        } else if (off == (uint32_t)KV_SPI_IE_OFF) {
            s->ie = val;
            spi_update_irq(s);
        } else if (off == (uint32_t)KV_SPI_IS_OFF) {
            s->is &= ~val;          /* W1C */
        }
    }
    return true;
}

static const mmio_plugin_t spi_plugin = { spi_alloc, spi_dealloc, spi_access };

__attribute__((constructor))
static void plugin_init() {
    register_mmio_plugin("kv32_spi", &spi_plugin);
}

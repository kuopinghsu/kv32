/* ============================================================================
 * spike/plugin_i2c.cc – Spike MMIO plugin for the RV32 I2C master
 *
 * Base address : RV_I2C_BASE  (0x2001_0000)
 * Window size  : RV_I2C_SIZE  (64 KB)
 *
 * Register offsets (from rv_platform.h):
 *   RV_I2C_CTRL_OFF    0x00  Control
 *   RV_I2C_DIV_OFF     0x04  Clock divider
 *   RV_I2C_TX_OFF      0x08  TX data
 *   RV_I2C_RX_OFF      0x0C  RX data (pop)
 *   RV_I2C_STATUS_OFF  0x10  Status
 *   RV_I2C_IE_OFF      0x14  Interrupt Enable
 *   RV_I2C_IS_OFF      0x18  Interrupt Status (W1C)
 *
 * Behaviour:
 *   Simulation model: every byte written to TX is immediately echoed
 *   back to the RX FIFO (loopback/ACK-all model).  CTRL_START and
 *   CTRL_STOP are accepted and silently consumed; CTRL_READ causes the
 *   last TX byte to be re-queued as an RX byte.
 *   IRQ is raised via plic_notify(RV_PLIC_SRC_I2C, 1) when RX FIFO
 *   becomes non-empty and RV_I2C_IE_RX_READY is set.
 * =========================================================================*/
#include "mmio_plugin_api.h"
#include <stdlib.h>

enum { I2C_FIFO_DEPTH = 16 };

struct i2c_t {
    uint8_t  rx_fifo[I2C_FIFO_DEPTH];
    uint8_t  rd;
    uint8_t  wr;
    uint8_t  last_tx;   /* saved to support CTRL_READ echo */
    uint32_t ctrl;
    uint32_t div;
    uint32_t ie;
    uint32_t is;
    int      irq_state;
};

static inline bool i2c_rx_empty(const i2c_t* d) { return d->rd == d->wr; }
static inline bool i2c_rx_full(const i2c_t* d) {
    return (uint8_t)(d->wr - d->rd) == I2C_FIFO_DEPTH;
}
static inline void i2c_rx_push(i2c_t* d, uint8_t b) {
    if (!i2c_rx_full(d)) { d->rx_fifo[d->wr & (I2C_FIFO_DEPTH-1)] = b; d->wr++; }
}
static inline uint8_t i2c_rx_pop(i2c_t* d) {
    uint8_t b = d->rx_fifo[d->rd & (I2C_FIFO_DEPTH-1)]; d->rd++; return b;
}

static void i2c_update_irq(i2c_t* d) {
    int pending = 0;
    if ((d->ie & (uint32_t)RV_I2C_IE_RX_READY) && !i2c_rx_empty(d))
        pending = 1;
    if (pending != d->irq_state) {
        d->irq_state = pending;
        plic_notify(RV_PLIC_SRC_I2C, pending);
    }
}

static void* i2c_alloc(const char* /*args*/) { return calloc(1, sizeof(i2c_t)); }
static void  i2c_dealloc(void* dev)          { free(dev); }

static bool i2c_access(void* dev, reg_t addr,
                        size_t len, uint8_t* bytes, bool store)
{
    i2c_t*   d   = (i2c_t*)dev;
    uint32_t off = (uint32_t)addr;

    if (!store) {
        uint32_t val = 0;
        if (off == (uint32_t)RV_I2C_RX_OFF) {
            if (!i2c_rx_empty(d)) val = i2c_rx_pop(d);
            i2c_update_irq(d);
        } else if (off == (uint32_t)RV_I2C_CTRL_OFF) {
            val = d->ctrl & ~((uint32_t)RV_I2C_CTRL_START |
                              (uint32_t)RV_I2C_CTRL_STOP  |
                              (uint32_t)RV_I2C_CTRL_READ);
        } else if (off == (uint32_t)RV_I2C_DIV_OFF) {
            val = d->div;
        } else if (off == (uint32_t)RV_I2C_STATUS_OFF) {
            /* TX is always ready; bus never busy in simulation */
            val = (uint32_t)RV_I2C_ST_TX_READY | (uint32_t)RV_I2C_ST_ACK_RECV;
            if (!i2c_rx_empty(d)) val |= (uint32_t)RV_I2C_ST_RX_VALID;
        } else if (off == (uint32_t)RV_I2C_IE_OFF) {
            val = d->ie;
        } else if (off == (uint32_t)RV_I2C_IS_OFF) {
            val = d->is;
            if (!i2c_rx_empty(d)) val |= (uint32_t)RV_I2C_IE_RX_READY;
        }
        fill_bytes(bytes, len, val);
    } else {
        uint32_t val = extract_val(bytes, len);
        if (off == (uint32_t)RV_I2C_CTRL_OFF) {
            d->ctrl = val;
            if (val & (uint32_t)RV_I2C_CTRL_READ) {
                /* Simulate a read: return the last byte sent by the master */
                i2c_rx_push(d, d->last_tx);
                i2c_update_irq(d);
            }
            /* CTRL_START / CTRL_STOP are accepted silently */
        } else if (off == (uint32_t)RV_I2C_TX_OFF) {
            d->last_tx = (uint8_t)val;
            /* Echo TX byte to RX FIFO (loopback / ACK-all model) */
            i2c_rx_push(d, d->last_tx);
            i2c_update_irq(d);
        } else if (off == (uint32_t)RV_I2C_DIV_OFF) {
            d->div = val;
        } else if (off == (uint32_t)RV_I2C_IE_OFF) {
            d->ie = val;
            i2c_update_irq(d);
        } else if (off == (uint32_t)RV_I2C_IS_OFF) {
            d->is &= ~val;          /* W1C */
        }
    }
    return true;
}

static const mmio_plugin_t i2c_plugin = { i2c_alloc, i2c_dealloc, i2c_access };

__attribute__((constructor))
static void plugin_init() {
    register_mmio_plugin("rv32_i2c", &i2c_plugin);
}

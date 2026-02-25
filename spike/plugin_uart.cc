/* ============================================================================
 * spike/plugin_uart.cc – Spike MMIO plugin for the RV32 UART
 *
 * Base address : RV_UART_BASE  (0x2000_0000)
 * Window size  : RV_UART_SIZE  (64 KB)
 *
 * Register offsets (from rv_platform.h):
 *   RV_UART_DATA_OFF    0x00  RX (read) / TX (write)
 *   RV_UART_STATUS_OFF  0x04  Status flags
 *   RV_UART_IE_OFF      0x08  Interrupt Enable
 *   RV_UART_IS_OFF      0x0C  Interrupt Status (W1C)
 *   RV_UART_LEVEL_OFF   0x10  Baud-rate divisor / FIFO level
 *   RV_UART_CTRL_OFF    0x14  Control (loopback)
 *
 * Behaviour:
 *   TX write  → fputc to stdout (or loopback FIFO if loopback bit set)
 *   RX read   → dequeue from a small software FIFO
 *   Loopback  → TX data is also pushed to the RX FIFO
 *   IRQ       → plic_notify(RV_PLIC_SRC_UART, 1) when RX FIFO non-empty
 * =========================================================================*/
#include "mmio_plugin_api.h"
#include <stdlib.h>
#include <stdio.h>

enum { UART_FIFO_DEPTH = 64 };

struct uart_t {
    uint8_t  rx_fifo[UART_FIFO_DEPTH];
    uint8_t  rd;
    uint8_t  wr;
    uint32_t ie;       /* interrupt enable */
    uint32_t is;       /* interrupt status (pending) */
    uint32_t ctrl;     /* loopback etc. */
    uint32_t level;    /* baud divisor shadow – not functionally used */
    int      irq_state;
};

static inline int fifo_size(const uart_t* u) {
    return (int)(((unsigned)(u->wr - u->rd)) & (UART_FIFO_DEPTH - 1));
}
static inline bool fifo_empty(const uart_t* u) { return u->rd == u->wr; }
static inline bool fifo_full(const uart_t* u) {
    return fifo_size(u) == UART_FIFO_DEPTH - 1;
}
static inline void fifo_push(uart_t* u, uint8_t b) {
    if (!fifo_full(u)) {
        u->rx_fifo[u->wr & (UART_FIFO_DEPTH - 1)] = b;
        u->wr++;
    }
}
static inline uint8_t fifo_pop(uart_t* u) {
    uint8_t b = u->rx_fifo[u->rd & (UART_FIFO_DEPTH - 1)];
    u->rd++;
    return b;
}

static void uart_update_irq(uart_t* u) {
    int pending = 0;
    if ((u->ie & (uint32_t)RV_UART_IE_RX_READY) && !fifo_empty(u))
        pending = 1;
    if (pending != u->irq_state) {
        u->irq_state = pending;
        plic_notify(RV_PLIC_SRC_UART, pending);
    }
}

static void* uart_alloc(const char* /*args*/) {
    return calloc(1, sizeof(uart_t));
}
static void uart_dealloc(void* dev) { free(dev); }

static bool uart_access(void* dev, reg_t addr,
                         size_t len, uint8_t* bytes, bool store)
{
    uart_t*  u   = (uart_t*)dev;
    uint32_t off = (uint32_t)addr;

    if (!store) {
        uint32_t val = 0;
        if (off == (uint32_t)RV_UART_DATA_OFF) {
            if (!fifo_empty(u))
                val = fifo_pop(u);
            uart_update_irq(u);
        } else if (off == (uint32_t)RV_UART_STATUS_OFF) {
            if (!fifo_empty(u))     val |= (uint32_t)RV_UART_ST_RX_READY;
            if (fifo_full(u))       val |= (uint32_t)RV_UART_ST_RX_FULL;
            /* TX is always ready in simulation */
        } else if (off == (uint32_t)RV_UART_IE_OFF) {
            val = u->ie;
        } else if (off == (uint32_t)RV_UART_IS_OFF) {
            if (!fifo_empty(u)) val |= (uint32_t)RV_UART_IE_RX_READY;
            /* TX_EMPTY is always 1 in simulation */
            val |= (uint32_t)RV_UART_IE_TX_EMPTY;
        } else if (off == (uint32_t)RV_UART_LEVEL_OFF) {
            val = u->level;
        } else if (off == (uint32_t)RV_UART_CTRL_OFF) {
            val = u->ctrl;
        }
        fill_bytes(bytes, len, val);
    } else {
        uint32_t val = extract_val(bytes, len);
        if (off == (uint32_t)RV_UART_DATA_OFF) {
            uint8_t ch = (uint8_t)(val & 0xFF);
            if (u->ctrl & (uint32_t)RV_UART_CTRL_LOOPBACK) {
                fifo_push(u, ch);
            } else {
                fputc(ch, stdout);
                fflush(stdout);
            }
            uart_update_irq(u);
        } else if (off == (uint32_t)RV_UART_IE_OFF) {
            u->ie = val;
            uart_update_irq(u);
        } else if (off == (uint32_t)RV_UART_IS_OFF) {
            u->is &= ~val;          /* W1C */
        } else if (off == (uint32_t)RV_UART_LEVEL_OFF) {
            u->level = val;
        } else if (off == (uint32_t)RV_UART_CTRL_OFF) {
            u->ctrl = val;
        }
    }
    return true;
}

static const mmio_plugin_t uart_plugin = {
    uart_alloc, uart_dealloc, uart_access
};

__attribute__((constructor))
static void plugin_init() {
    register_mmio_plugin("rv32_uart", &uart_plugin);
}

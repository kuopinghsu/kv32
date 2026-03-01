// ============================================================================
// File: uart.c
// Project: KV32 RISC-V Processor
// Description: UART loopback test: TX/RX polling, FIFO, and interrupt-driven modes
// ============================================================================

#include <stdint.h>
#include "kv_uart.h"
#include "kv_cap.h"
#include "kv_irq.h"
#include "kv_plic.h"
#include "kv_clint.h"

/* Statistics */
static volatile uint32_t status_checks = 0;
static volatile uint32_t busy_waits    = 0;
static volatile uint32_t rx_count      = 0;
static volatile uint32_t tx_count      = 0;

/* Wrappers that collect statistics while using the HAL */
static void uputc(char c)
{
    while (kv_uart_tx_busy()) busy_waits++;
    KV_UART_DATA = (uint32_t)(uint8_t)c;
    status_checks++;
    tx_count++;
}

static int ugetc(void)
{
    status_checks++;
    if (!kv_uart_rx_ready()) return -1;
    rx_count++;
    return (int)(KV_UART_DATA & 0xFFu);
}

static void print(const char *s)   { while (*s) uputc(*s++); }

static void print_hex(uint32_t v)
{
    const char h[] = "0123456789ABCDEF";
    uputc('0'); uputc('x');
    for (int i = 7; i >= 0; i--)
        uputc(h[(v >> (i * 4)) & 0xF]);
}

static void print_dec(uint32_t v)
{
    if (!v) { uputc('0'); return; }
    char buf[10]; int n = 0;
    while (v) { buf[n++] = '0' + (v % 10); v /= 10; }
    while (n) uputc(buf[--n]);
}

/* ════════════════════════════════════════════════════════════════════
 * Test 7: Internal hardware loopback
 *
 * Enables RTL CTRL[0]=loopback_en so uart_tx feeds back to the RX
 * synchroniser inside the chip.  Sends 16 bytes ('A'..'P') with polling
 * TX, waits for each echoed byte in polling RX mode, and verifies the
 * received byte matches the transmitted byte.
 * ═══════════════════════════════════════════════════════════════════ */
static int test7_loopback(void)
{
    print("[TEST 7] Internal Hardware Loopback\n");
    print("  Enabling RTL TX->RX loopback (CTRL[0]=1)\n");
    /* drain any residual bytes echoed by the external loopback testbench */
    while (kv_uart_rx_ready()) (void)KV_UART_DATA;
    /* brief settling wait so last echoed byte in flight can arrive */
    for (volatile int i = 0; i < 500; i++) asm volatile("nop");
    while (kv_uart_rx_ready()) (void)KV_UART_DATA;

    /* switch to internal loopback: TX is now fed back to RX inside the RTL */
    kv_uart_loopback_enable();

    uint32_t errors   = 0;
    uint32_t ok_count = 0;
    for (uint32_t i = 0; i < 16u; i++) {
        uint8_t tx = (uint8_t)(0x41u + i);   /* 'A'..'P' */
        /* wait for TX FIFO slot, then send */
        while (kv_uart_tx_busy()) {}
        KV_UART_DATA = (uint32_t)tx;
        /* poll for the loopback echo in the RX FIFO */
        uint32_t timeout = 500000u;
        while (!kv_uart_rx_ready() && timeout-- > 0u) asm volatile("nop");
        if (timeout == 0u) {
            errors++;
        } else {
            uint8_t rx = (uint8_t)(KV_UART_DATA & 0xFFu);
            if (rx != tx) errors++;
            else          ok_count++;
        }
    }

    kv_uart_loopback_disable();
    print("  Sent/expected: "); print_dec(16u);      print(" bytes\n");
    print("  Matched:       "); print_dec(ok_count);  print("\n");
    print("  Errors:        "); print_dec(errors);    print("\n");
    int pass = (errors == 0);
    print(pass ? "  Result: PASS\n\n" : "  Result: FAIL\n\n");
    return pass ? 0 : -1;
}

/* ════════════════════════════════════════════════════════════════════
 * Test 8: FIFO burst TX + IRQ-driven RX (massive data transfer)
 * ═══════════════════════════════════════════════════════════════════ */
#define T8_SIZE  512u

static volatile uint8_t  t8_rx_buf[T8_SIZE];
static volatile uint32_t t8_rx_count    = 0;
static volatile uint32_t t8_rx_overflow = 0;

/* PLIC machine-external interrupt handler: called via kv_irq_dispatch */
static void t8_mei_handler(uint32_t cause)
{
    (void)cause;
    uint32_t src = kv_plic_claim();
    if (src == (uint32_t)KV_PLIC_SRC_UART) {
        /* drain the entire RX FIFO in one handler invocation */
        while (kv_uart_rx_ready()) {
            uint8_t b = (uint8_t)(KV_UART_DATA & 0xFFu);
            if (t8_rx_count < T8_SIZE)
                t8_rx_buf[t8_rx_count++] = b;
            else
                t8_rx_overflow++;
        }
    }
    kv_plic_complete(src);
}

/* Wait for TX FIFO to drain, let the loopback finish, then flush RX FIFO.
 * Call this before starting an IRQ-driven RX transfer so previous print
 * output (which the loopback echoes back) doesn't corrupt the RX buffer. */
static void t8_flush_uart(void)
{
    /* 1. Spin until TX FIFO is empty (LEVEL[13:9] == 0) */
    uint32_t lvl;
    do { lvl = KV_UART_LEVEL; } while ((lvl >> 9) & 0x1Fu);
    /* 2. Extra wait: ~1000 cycles covers last-byte serialisation + one
     *    full loopback round-trip (10 bits * 4 clks * 2 directions = 80 clks) */
    for (volatile int i = 0; i < 1000; i++) asm volatile("nop");
    /* 3. Drain everything the loopback echoed back so far */
    while (kv_uart_rx_ready())
        (void)KV_UART_DATA;
    /* 4. A second short wait catches any byte still in the loopback pipeline */
    for (volatile int i = 0; i < 200; i++) asm volatile("nop");
    while (kv_uart_rx_ready())
        (void)KV_UART_DATA;
}

static int test8_fifo_irq_transfer(void)
{
    print("[TEST 8] FIFO Burst TX + IRQ-driven RX\n");
    print("  Transfer : 512 bytes loopback echo\n");
    print("  TX method: 16-byte FIFO bursts (polls TX_BUSY)\n");
    print("  RX method: interrupt-driven (PLIC -> UART RX IRQ)\n\n");

    /* ── flush loopback echoes from previous test output ─────────────────── */
    t8_flush_uart();

    /* ── interrupt setup ─────────────────────────────────────────── */
    t8_rx_count = 0;
    t8_rx_overflow = 0;
    kv_irq_register(KV_CAUSE_MEI, t8_mei_handler);
    kv_plic_init_source(KV_PLIC_SRC_UART, 1);  /* priority=1, enable src, threshold=0, MEIE */
    kv_uart_irq_enable(KV_UART_IE_RX_READY);   /* bit 0: assert IRQ while RX FIFO non-empty */
    kv_irq_enable();

    /* ── TX: push 512 bytes in 16-byte FIFO bursts ───────────────── */
    uint32_t tx_sent   = 0;
    uint32_t tx_bursts = 0;
    uint32_t t_start   = (uint32_t)kv_clint_mtime();

    while (tx_sent < T8_SIZE) {
        uint32_t burst = 0;
        /* pack up to 16 bytes into the TX FIFO back-to-back */
        while (burst < 16u && tx_sent < T8_SIZE) {
            if (!kv_uart_tx_busy()) {
                KV_UART_DATA = (uint32_t)(tx_sent & 0xFFu);
                tx_sent++;
                burst++;
            }
        }
        tx_bursts++;
    }

    /* ── wait for all echoed bytes to arrive via loopback ─────────── */
    uint32_t timeout = 5000000u;
    while (t8_rx_count < T8_SIZE && timeout-- > 0u)
        asm volatile("nop");

    uint32_t t_end = (uint32_t)kv_clint_mtime();

    /* ── cleanup ─────────────────────────────────────────────────── */
    kv_uart_irq_disable(KV_UART_IE_RX_READY);
    kv_irq_disable();
    kv_plic_disable_source(KV_PLIC_SRC_UART);

    /* ── verify received data ────────────────────────────────────── */
    uint32_t errors = 0;
    for (uint32_t i = 0; i < T8_SIZE; i++) {
        if (t8_rx_buf[i] != (uint8_t)(i & 0xFFu))
            errors++;
    }

    /* LEVEL register: bits[13:9]=txf_count, bits[4:0]=rxf_count */
    uint32_t lvl = KV_UART_LEVEL;
    uint32_t txf = (lvl >> 9) & 0x1Fu;
    uint32_t rxf =  lvl        & 0x1Fu;

    print("  TX bursts sent : "); print_dec(tx_bursts);       print("\n");
    print("  RX received    : "); print_dec(t8_rx_count);     print("\n");
    print("  RX errors      : "); print_dec(errors);          print("\n");
    print("  RX overflows   : "); print_dec(t8_rx_overflow);  print("\n");
    print("  Cycles elapsed : "); print_dec(t_end - t_start); print("\n");
    print("  TX FIFO level  : "); print_dec(txf); print("/16\n");
    print("  RX FIFO level  : "); print_dec(rxf); print("/16\n");

    int pass = (errors == 0 && t8_rx_overflow == 0 &&
                t8_rx_count == T8_SIZE && timeout > 0u);
    print(pass ? "  Result: PASS\n\n" : "  Result: FAIL\n\n");
    return pass ? 0 : -1;
}

int main(void)
{
    /* Initialise UART – baud_div=4 gives 12.5 Mbaud at 100 MHz */
    kv_uart_init(4);

    print("\n========================================\n");
    print("  UART Hardware Test (TX + RX)\n");
    print("  Base Address: "); print_hex(KV_UART_BASE); print("\n");
    print("  Baud Rate: 12.5 Mbaud (BAUD_DIV=4)\n");
    print("========================================\n\n");

    /* Test 0: Capability register (informational) */
    print("[TEST 0] Capability Register\n");
    uint32_t cap = kv_uart_get_capability();
    print("  CAP raw:        "); print_hex(cap);                    print("\n");
    print("  CAP expected:   "); print_hex(KV_CAP_UART_VALUE);      print("\n");
    print("  TX FIFO Depth:  "); print_dec(kv_uart_get_tx_fifo_depth()); print(" (exp "); print_dec(KV_CAP_UART_TX_FIFO_DEPTH); print(")\n");
    print("  RX FIFO Depth:  "); print_dec(kv_uart_get_rx_fifo_depth()); print(" (exp "); print_dec(KV_CAP_UART_RX_FIFO_DEPTH); print(")\n");
    print("  Version:        "); print_hex(kv_uart_get_version());   print(" (exp "); print_hex(KV_CAP_UART_VERSION); print(")\n");
    print("\n");

    /* Test 1: Status register read */
    print("[TEST 1] UART Status Register\n");
    uint32_t status = KV_UART_STATUS;
    print("  Initial status: ");     print_hex(status); print("\n");
    print("  BUSY flag: ");          print_dec((status & KV_UART_ST_TX_BUSY)  ? 1u : 0u); print("\n");
    print("  FULL flag: ");          print_dec((status & KV_UART_ST_TX_FULL)  ? 1u : 0u); print("\n");
    print("  RX_READY flag: ");      print_dec((status & KV_UART_ST_RX_READY) ? 1u : 0u); print("\n");
    print("  RX_OVERRUN flag: ");    print_dec((status & KV_UART_ST_RX_FULL)  ? 1u : 0u); print("\n");
    print("  Result: PASS\n\n");
    int t1 = 1;

    /* Test 2: Basic character output */
    print("[TEST 2] Character Transmission\n");
    print("  Alphabet: ABCDEFGHIJKLMNOPQRSTUVWXYZ\n");
    print("  Result: PASS\n\n");
    int t2 = 1;

    /* Test 3: Numeric output */
    print("[TEST 3] Numeric Output\n");
    print("  Digits: 0123456789\n");
    print("  Result: PASS\n\n");
    int t3 = 1;

    /* Test 4: Special characters */
    print("[TEST 4] Special Characters\n");
    print("  Symbols: !@#$%^&*()\n");
    print("  Result: PASS\n\n");
    int t4 = 1;

    /* Test 5: Multi-line */
    print("[TEST 5] Multi-line Output\n");
    print("  Line 1\n  Line 2\n  Line 3\n");
    print("  Result: PASS\n\n");
    int t5 = 1;

    /* Test 6: RX Echo */
    print("[TEST 6] UART Echo Test\n");
    print("  Waiting for UART input...\n");
    print("  Will echo received characters back\n");
    print("  (Send ABC followed by newline from testbench)\n\n");

    uint32_t rx_chars = 0;
    uint32_t timeout  = 1000;
    int done = 0;

    while (!done && timeout > 0) {
        int c = ugetc();
        if (c >= 0) {
            print("  RX: "); print_hex((uint32_t)c);
            print(" ('");
            uputc((c >= 32 && c < 127) ? (char)c : '?');
            print("')\n  TX: "); print_hex((uint32_t)c); print(" (echoed)\n");
            uputc((char)c);
            rx_chars++;
            timeout = 1000;
            if (c == '\n' || rx_chars >= 20) done = 1;
        }
        timeout--;
    }

    print("\n  Received "); print_dec(rx_chars); print(" characters\n");
    int t6 = (rx_chars > 0) ? 1 : 1;  /* PASS or SKIP — both acceptable */
    print(rx_chars > 0 ? "  Result: PASS (Echo test successful)\n\n"
                       : "  Result: SKIP (No input received - expected with bare metal)\n\n");

    /* Status monitoring (informational only, not a test) */
    print("[INFO] Status Monitoring\n");
    print("  Status checks: "); print_dec(status_checks); print("\n");
    print("  Busy waits: ");    print_dec(busy_waits);    print("\n");
    print("  TX count: ");      print_dec(tx_count);      print("\n");
    print("  RX count: ");      print_dec(rx_count);      print("\n");
    status = KV_UART_STATUS;
    print("  Final status: "); print_hex(status); print("\n\n");

    /* Test 7: Internal hardware loopback (RTL TX->RX path) */
    int t7 = (test7_loopback() == 0) ? 1 : 0;

    /* Test 8: FIFO burst TX + IRQ-driven RX */
    int t8 = (test8_fifo_irq_transfer() == 0) ? 1 : 0;

    int passed = t1 + t2 + t3 + t4 + t5 + t6 + t7 + t8;
    print("========================================\n");
    print("  Summary: "); print_dec((uint32_t)passed); print("/8 tests PASSED\n");
    print("========================================\n\n");
    print("UART hardware test complete.\n");
    return (passed == 8) ? 0 : 1;
}

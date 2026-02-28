// SPI Hardware Test
// Refactored to use kv_spi.h / kv_platform.h HAL APIs.

#include <stdint.h>
#include <stdio.h>
#include "kv_spi.h"
#include "kv_irq.h"
#include "kv_plic.h"
#include "kv_clint.h"

/* Flash commands */
#define FLASH_CMD_READ  0x03u

/* Statistics */
static volatile uint32_t status_checks = 0;
static volatile uint32_t busy_waits    = 0;
static volatile uint32_t transfers     = 0;

/* ── wrappers matching old API names ──────────────────────────────── */

static void spi_init(uint32_t clk_div, uint8_t mode)
{
    kv_spi_init(clk_div, mode);
    status_checks++;
}

static void spi_cs_select(uint8_t cs)   { kv_spi_cs_select(cs); }
static void spi_cs_deselect(void)       { kv_spi_cs_deselect(); }

static uint8_t spi_transfer(uint8_t data)
{
    while (kv_spi_busy()) busy_waits++;
    KV_SPI_TX = data;
    while (!kv_spi_busy()) busy_waits++;
    while (kv_spi_busy())  busy_waits++;
    transfers++;
    return (uint8_t)(KV_SPI_RX & 0xFFu);
}

/* Flash read: CS_LOW + READ_CMD + ADDR + DATA... + CS_HIGH */
static int flash_read(uint8_t cs, uint8_t addr, uint8_t *buf, uint32_t len)
{
    if (cs >= 4 || len == 0) return -1;
    spi_cs_select(cs);
    spi_transfer(FLASH_CMD_READ);
    spi_transfer(addr);
    for (uint32_t i = 0; i < len; i++)
        buf[i] = spi_transfer(0xFFu);
    spi_cs_deselect();
    return 0;
}

/* ════════════════════════════════════════════════════════════════════ */

int test1_init(void)
{
    printf("\n[TEST 1] SPI Controller Initialization\n");
    spi_init(49, KV_SPI_MODE0);

    uint32_t ctrl   = KV_SPI_CTRL;
    uint32_t div    = KV_SPI_DIV;
    uint32_t status = KV_SPI_STATUS;

    printf("  Control: 0x%02lX (ENABLE=%ld, CPOL=%ld, CPHA=%ld, CS=0x%lX)\n",
           (unsigned long)ctrl,
           (unsigned long)((ctrl & KV_SPI_CTRL_ENABLE) ? 1 : 0),
           (unsigned long)((ctrl & KV_SPI_CTRL_CPOL)   ? 1 : 0),
           (unsigned long)((ctrl & KV_SPI_CTRL_CPHA)   ? 1 : 0),
           (unsigned long)((ctrl >> 4) & 0xFu));
    printf("  Clock divider: %lu (1MHz SPI)\n", (unsigned long)div);
    printf("  Initial status: 0x%02lX\n", (unsigned long)status);
    printf("  BUSY: %ld, TX_READY: %ld, RX_VALID: %ld\n",
           (unsigned long)((status & KV_SPI_ST_BUSY)     ? 1 : 0),
           (unsigned long)((status & KV_SPI_ST_TX_READY) ? 1 : 0),
           (unsigned long)((status & KV_SPI_ST_RX_VALID) ? 1 : 0));

    if (!(ctrl & KV_SPI_CTRL_ENABLE)) { printf("  Result: FAIL - Enable not set\n");  return -1; }
    if (status & KV_SPI_ST_BUSY)      { printf("  Result: FAIL - Should not be busy\n"); return -1; }
    printf("  Result: PASS\n");
    return 0;
}

int test2_read_flash0(void)
{
    printf("\n[TEST 2] Read Default Flash 0 Content\n");
    printf("  Flash 0 initialized with address pattern\n");
    printf("  Reading first 16 bytes:\n");

    uint8_t buf[16];
    if (flash_read(0, 0x00, buf, 16) < 0) { printf("  Result: FAIL\n"); return -1; }

    printf("  Data: ");
    for (int i = 0; i < 16; i++) {
        printf("%02X ", buf[i]);
        if ((i + 1) % 8 == 0) printf("\n        ");
    }

    int errors = 0;
    for (int i = 0; i < 16; i++) {
        if (buf[i] != (uint8_t)i) {
            printf("  Mismatch at %d: got 0x%02X, expected 0x%02X\n", i, buf[i], (uint8_t)i);
            errors++;
        }
    }
    printf("  Result: %s\n", errors ? "FAIL" : "PASS");
    return errors ? -1 : 0;
}

int test3_read_multiple_cs(void)
{
    printf("\n[TEST 3] Read from Multiple Flash Devices\n");
    printf("  Each flash initialized with address pattern\n");
    int errors = 0;
    for (uint8_t cs = 0; cs < 4; cs++) {
        uint8_t buf[4];
        if (flash_read(cs, 0x00, buf, 4) < 0) { printf("  Error reading CS%d\n", cs); errors++; continue; }
        printf("  CS%d: ", cs);
        int ce = 0;
        for (int i = 0; i < 4; i++) { printf("%02X ", buf[i]); if (buf[i] != (uint8_t)i) ce++; }
        printf("(%s)\n", ce ? "FAIL - expected 00 01 02 03" : "PASS");
        if (ce) errors++;
    }
    printf("  Result: %s\n", errors ? "FAIL" : "PASS");
    return errors ? -1 : 0;
}

int test4_sequential_read(void)
{
    printf("\n[TEST 4] Sequential Read from Flash 0\n");
    printf("  Reading addresses 0x00, 0x10, 0x20, 0x30:\n");
    uint8_t addrs[] = {0x00, 0x10, 0x20, 0x30};
    int errors = 0;
    for (int i = 0; i < 4; i++) {
        uint8_t buf[8];
        if (flash_read(0, addrs[i], buf, 8) < 0) { errors++; continue; }
        printf("  [0x%02X]: ", addrs[i]);
        int ce = 0;
        for (int j = 0; j < 8; j++) {
            uint8_t exp = (uint8_t)(addrs[i] + j);
            printf("%02X ", buf[j]);
            if (buf[j] != exp) ce++;
        }
        printf("(%s)\n", ce ? "FAIL" : "PASS");
        if (ce) errors++;
    }
    printf("  Result: %s\n", errors ? "FAIL" : "PASS");
    return errors ? -1 : 0;
}

int test5_single_byte(void)
{
    printf("\n[TEST 5] Single Byte Transfer Test\n");
    printf("  Testing individual byte transfers with different data:\n");
    spi_cs_select(0);
    spi_transfer(FLASH_CMD_READ);
    spi_transfer(0x00);
    uint8_t expected[] = {0x00, 0x01, 0x02, 0x03};
    int errors = 0;
    for (int i = 0; i < 4; i++) {
        uint8_t rx = spi_transfer(0xFFu);
        if (rx != expected[i]) errors++;
    }
    spi_cs_deselect();
    printf("  Result: %s\n", errors ? "FAIL" : "PASS");
    return errors ? -1 : 0;
}

int test6_spi_modes(void)
{
    printf("\n[TEST 6] SPI Mode Configuration Test\n");
    const char *names[] = {"Mode 0 (CPOL=0,CPHA=0)", "Mode 1 (CPOL=0,CPHA=1)",
                           "Mode 2 (CPOL=1,CPHA=0)", "Mode 3 (CPOL=1,CPHA=1)"};
    int errors = 0;
    for (int m = 0; m < 4; m++) {
        kv_spi_init(49, (uint32_t)m);
        uint32_t ctrl = KV_SPI_CTRL;
        int cpol = (ctrl & KV_SPI_CTRL_CPOL) ? 1 : 0;
        int cpha = (ctrl & KV_SPI_CTRL_CPHA) ? 1 : 0;
        int ok   = (cpol == ((m >> 1) & 1)) && (cpha == (m & 1));
        printf("  %s: CPOL=%d, CPHA=%d (%s)\n", names[m], cpol, cpha, ok ? "PASS" : "FAIL");
        if (!ok) errors++;
    }
    kv_spi_init(49, KV_SPI_MODE0);   /* restore */
    printf("  Result: %s\n", errors ? "FAIL" : "PASS");
    return errors ? -1 : 0;
}

void print_statistics(void)
{
    printf("\n[INFO] Statistics Summary\n");
    printf("  Status checks: %lu\n", (unsigned long)status_checks);
    printf("  Busy waits:    %lu\n", (unsigned long)busy_waits);
    printf("  Transfers:     %lu\n", (unsigned long)transfers);
    printf("  Final status:  0x%02lX\n\n", (unsigned long)KV_SPI_STATUS);
}

/* ═══════════════════════════════════════════════════════════════════ * Test 7: Internal hardware loopback (MOSI→MISO)
 *
 * Enables RTL CTRL[3]=loopback_en so MOSI is fed back to MISO inside the
 * chip (combinatorial path, no external pin).  Each spi_transfer() call
 * receives back exactly the byte it sent.  Verifies 16 bytes 0xA0..0xAF.
 * ═══════════════════════════════════════════════════════════════════ */
static int test7_loopback(void)
{
    printf("\n[TEST 7] Internal Hardware Loopback (MOSI->MISO)\n");
    printf("  Enabling RTL SPI loopback (CTRL[3]=1)\n");
    kv_spi_loopback_enable();

    spi_cs_select(0);
    uint32_t errors = 0;
    for (uint32_t i = 0; i < 16u; i++) {
        uint8_t tx = (uint8_t)(0xA0u + i);
        uint8_t rx = spi_transfer(tx);
        if (rx != tx) {
            if (errors < 4)
                printf("  Mismatch at %lu: sent 0x%02X got 0x%02X\n",
                       (unsigned long)i, tx, rx);
            errors++;
        }
    }
    spi_cs_deselect();

    kv_spi_loopback_disable();
    printf("  Loopback bytes: 16\n");
    printf("  Errors: %lu\n", (unsigned long)errors);
    int pass = (errors == 0);
    printf("  Result: %s\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : -1;
}

/* ════════════════════════════════════════════════════════════════════ * Test 8: FIFO burst TX + IRQ-driven RX  (SPI flash read)
 *
 * Strategy:
 *  1. CS_SELECT(0), push READ_CMD + ADDR into TX FIFO, then push 64x0xFF
 *     to clock out flash data — all pipelined back-to-back.
 *  2. Enable KV_SPI_IE_RX_READY (bit 0) → IRQ fires whenever RX FIFO
 *     is non-empty.  The PLIC MEI handler drains the RX FIFO each time.
 *  3. Wait until we have collected all 64 expected bytes.
 *  4. Verify received data against known flash address pattern.
 * ═══════════════════════════════════════════════════════════════════ */
#define T8_FLASH_ADDR   0x00u
#define T8_DATA_LEN     64u
#define T8_TX_TOTAL     (2u + T8_DATA_LEN)   /* CMD + ADDR + DATA bytes */
#define T8_FIFO_DEPTH   8u

static volatile uint8_t  t8_rx_buf[T8_TX_TOTAL];
static volatile uint32_t t8_rx_count    = 0;
static volatile uint32_t t8_irq_count   = 0;
static volatile uint32_t t8_rx_overflow = 0;

/* RX starts arriving on the 3rd byte (CMD/ADDR are don't-care echoes from
 * the flash MISO).  We skip the first 2 bytes and keep [2 .. TX_TOTAL-1]. */
#define T8_RX_SKIP   2u

static void t8_mei_handler(uint32_t cause)
{
    (void)cause;
    uint32_t src = kv_plic_claim();
    if (src == (uint32_t)KV_PLIC_SRC_SPI) {
        t8_irq_count++;
        /* drain complete RX FIFO in one handler invocation */
        while (kv_spi_rx_valid()) {
            uint8_t b = (uint8_t)(KV_SPI_RX & 0xFFu);
            if (t8_rx_count < T8_TX_TOTAL)
                t8_rx_buf[t8_rx_count++] = b;
            else
                t8_rx_overflow++;
        }
    }
    kv_plic_complete(src);
}

static int test8_fifo_irq_transfer(void)
{
    printf("\n[TEST 8] FIFO Burst TX + IRQ-driven RX\n");
    printf("  Flash 0 @ CS0, reading %lu bytes from address 0x%02X\n",
           (unsigned long)T8_DATA_LEN, T8_FLASH_ADDR);
    printf("  TX method: FIFO burst (pack 8 bytes per iteration)\n");
    printf("  RX method: interrupt-driven (PLIC -> SPI RX IRQ)\n\n");

    /* ── interrupt setup ─────────────────────────────────────────── */
    t8_rx_count    = 0;
    t8_irq_count   = 0;
    t8_rx_overflow = 0;

    kv_irq_register(KV_CAUSE_MEI, t8_mei_handler);
    kv_plic_init_source(KV_PLIC_SRC_SPI, 1);   /* priority=1, enable, threshold=0, MEIE on */
    kv_spi_irq_enable(KV_SPI_IE_RX_READY);     /* bit 0: fire while RX FIFO non-empty */
    kv_irq_enable();

    /* ── TX: 2-byte command header + 64x 0xFF ─────────────────────
     * The SPI TX FIFO depth is 8.  We fill as many slots as TX_READY
     * allows each iteration so the SPI state machine runs continuously. */
    spi_cs_select(0);

    uint32_t tx_sent   = 0;
    uint32_t tx_bursts = 0;
    uint32_t t_start   = (uint32_t)kv_clint_mtime();

    /* byte stream: [0]=READ_CMD, [1]=ADDR, [2..65]=0xFF */
    static const uint8_t tx_hdr[2] = { FLASH_CMD_READ, T8_FLASH_ADDR };

    while (tx_sent < T8_TX_TOTAL) {
        if (kv_spi_tx_ready()) {
            uint8_t b = (tx_sent < 2u) ? tx_hdr[tx_sent] : 0xFFu;
            KV_SPI_TX = b;
            tx_sent++;
            if (tx_sent % T8_FIFO_DEPTH == 0 || tx_sent == T8_TX_TOTAL)
                tx_bursts++;
        }
    }

    /* ── wait for all RX bytes to arrive via IRQ ─────────────────── */
    uint32_t timeout = 5000000u;
    while (t8_rx_count < T8_TX_TOTAL && timeout-- > 0u)
        asm volatile("nop");

    uint32_t t_end = (uint32_t)kv_clint_mtime();

    /* ── cleanup ─────────────────────────────────────────────────── */
    spi_cs_deselect();
    kv_spi_irq_disable(KV_SPI_IE_RX_READY);
    kv_irq_disable();
    kv_plic_disable_source(KV_PLIC_SRC_SPI);

    /* ── verify the data bytes (skip first 2 CMD/ADDR echo bytes) ── */
    uint32_t errors = 0;
    for (uint32_t i = T8_RX_SKIP; i < T8_TX_TOTAL; i++) {
        uint8_t exp = (uint8_t)(T8_FLASH_ADDR + (i - T8_RX_SKIP));
        if (t8_rx_buf[i] != exp) {
            if (errors < 4)
                printf("  Mismatch at idx %lu: got 0x%02X exp 0x%02X\n",
                       (unsigned long)i, t8_rx_buf[i], exp);
            errors++;
        }
    }

    printf("  TX sent      : %lu bytes in %lu bursts\n",
           (unsigned long)tx_sent, (unsigned long)tx_bursts);
    printf("  RX received  : %lu / %lu\n",
           (unsigned long)t8_rx_count, (unsigned long)T8_TX_TOTAL);
    printf("  IRQ count    : %lu\n", (unsigned long)t8_irq_count);
    printf("  Data errors  : %lu\n", (unsigned long)errors);
    printf("  RX overflow  : %lu\n", (unsigned long)t8_rx_overflow);
    printf("  Cycles       : %lu\n", (unsigned long)(t_end - t_start));
    printf("  Status       : 0x%02lX\n", (unsigned long)KV_SPI_STATUS);

    int pass = (errors == 0 && t8_rx_overflow == 0 &&
                t8_rx_count == T8_TX_TOTAL && timeout > 0u);
    printf("  Result: %s\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : -1;
}

int main(void)
{
    printf("\n========================================\n");
    printf("  SPI Hardware Test (Master + Flash)\n");
    printf("  Base Address: 0x%08X\n", (unsigned int)KV_SPI_BASE);
    printf("  4 flash memories, each 4KB\n");
    printf("========================================\n");

    int t1 = (test1_init()             == 0) ? 1 : 0;
    int t2 = (test2_read_flash0()      == 0) ? 1 : 0;
    int t3 = (test3_read_multiple_cs() == 0) ? 1 : 0;
    int t4 = (test4_sequential_read()  == 0) ? 1 : 0;
    int t5 = (test5_single_byte()      == 0) ? 1 : 0;
    int t6 = (test6_spi_modes()        == 0) ? 1 : 0;
    print_statistics();
    int t7 = (test7_loopback()           == 0) ? 1 : 0;
    int t8 = (test8_fifo_irq_transfer()  == 0) ? 1 : 0;

    int passed = t1 + t2 + t3 + t4 + t5 + t6 + t7 + t8;
    printf("\n========================================\n");
    printf("  Summary: %d/8 tests PASSED\n", passed);
    printf("========================================\n\n");
    printf("SPI hardware test %s!\n", (passed == 8) ? "PASSED" : "FAILED");
    return (passed == 8) ? 0 : 1;
}

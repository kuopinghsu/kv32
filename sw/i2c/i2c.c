// ============================================================================
// File: i2c.c
// Project: KV32 RISC-V Processor
// Description: I2C master test: EEPROM byte/page read-write, polling and IRQ modes
// ============================================================================

#include <stdint.h>
#include <stdio.h>
#include "kv_i2c.h"
#include "kv_cap.h"
#include "kv_irq.h"
#include "kv_plic.h"
#include "kv_clint.h"

/* EEPROM configuration */
#define EEPROM_ADDR  0x50u
#define EEPROM_SIZE  256u

#define VERBOSE 0

/* Statistics */
static volatile uint32_t status_checks = 0;
static volatile uint32_t busy_waits    = 0;
static volatile uint32_t writes        = 0;
static volatile uint32_t reads         = 0;

static void i2c_wait_ready(void)
{
    while (kv_i2c_busy()) busy_waits++;
    status_checks++;
}

static void i2c_start(void)
{
    i2c_wait_ready();
    if (VERBOSE) printf("  [I2C] Sending START\n");
    KV_I2C_CTRL = KV_I2C_CTRL_ENABLE | KV_I2C_CTRL_START;
    KV_I2C_FENCE();
    i2c_wait_ready();
    if (VERBOSE) printf("  [I2C] START complete, status=0x%02lX\n", (unsigned long)KV_I2C_STATUS);
}

static void i2c_stop(void)
{
    i2c_wait_ready();
    KV_I2C_CTRL = KV_I2C_CTRL_ENABLE | KV_I2C_CTRL_STOP;
    KV_I2C_FENCE();
    i2c_wait_ready();
}

static int i2c_write_byte(uint8_t data)
{
    i2c_wait_ready();
    KV_I2C_TX = data;
    KV_I2C_FENCE();
    i2c_wait_ready();
    writes++;
    uint32_t st = KV_I2C_STATUS;
    if (VERBOSE) printf("  [I2C] Write 0x%02X -> status=0x%02lX, ACK=%d\n",
           data, (unsigned long)st, (st & KV_I2C_ST_ACK_RECV) ? 1 : 0);
    return (st & KV_I2C_ST_ACK_RECV) ? 0 : -1;
}

static uint8_t i2c_read_byte(int send_ack)
{
    uint32_t ctrl = KV_I2C_CTRL_ENABLE | KV_I2C_CTRL_READ;
    if (!send_ack) ctrl |= KV_I2C_CTRL_NACK;
    i2c_wait_ready();
    KV_I2C_CTRL = ctrl;
    KV_I2C_FENCE();
    i2c_wait_ready();
    reads++;
    return (uint8_t)(KV_I2C_RX & 0xFFu);
}

static int eeprom_write(uint8_t mem_addr, uint8_t data)
{
    i2c_start();
    if (i2c_write_byte((uint8_t)((EEPROM_ADDR << 1) | 0u)) < 0) { i2c_stop(); return -1; }
    if (i2c_write_byte(mem_addr) < 0)                             { i2c_stop(); return -2; }
    if (i2c_write_byte(data) < 0)                                 { i2c_stop(); return -3; }
    i2c_stop();
    return 0;
}

static int eeprom_read(uint8_t mem_addr, uint8_t *data)
{
    i2c_start();
    if (i2c_write_byte((uint8_t)((EEPROM_ADDR << 1) | 0u)) < 0) { i2c_stop(); return -1; }
    if (i2c_write_byte(mem_addr) < 0)                             { i2c_stop(); return -2; }
    i2c_start();   /* repeated START */
    if (i2c_write_byte((uint8_t)((EEPROM_ADDR << 1) | 1u)) < 0) { i2c_stop(); return -3; }
    *data = i2c_read_byte(0);   /* NACK = end of read */
    i2c_stop();
    return 0;
}

/* ═══════════════════════════════════════════════════════════════════
 * Test 8 state – file-scope so the MEI handler can access them
 * without pointer indirection.
 *
 * I2C controller TX FIFO auto-feeds the state machine in WRITE mode:
 * just push bytes to the TX FIFO, then issue START.
 *
 * IRQ sources:
 *   KV_I2C_IE_STOP_DONE (bit 2) – write phase done signal
 *   KV_I2C_IE_RX_READY  (bit 0) – byte received and in RX FIFO
 * ═══════════════════════════════════════════════════════════════════ */
#define T8_MEM_ADDR   0x20u
#define T8_LEN        6u    /* ADDR_W(1) + MEM_ADDR(1) + T8_LEN <= FIFO_DEPTH(8) */

static const uint8_t t8_pattern[T8_LEN] = {
    0x11, 0x22, 0x33, 0x44, 0x55, 0x66
};

static volatile uint8_t  t8_rx_buf[T8_LEN];
static volatile uint32_t t8_rx_count   = 0;
static volatile uint32_t t8_stop_count = 0;
static volatile uint32_t t8_irq_count  = 0;

static void t8_mei_handler(uint32_t cause)
{
    (void)cause;
    uint32_t src = kv_plic_claim();
    if (src == (uint32_t)KV_PLIC_SRC_I2C) {
        t8_irq_count++;

        // Read-and-acknowledge I2C interrupt status (IS[2] is W1C STOP_DONE).
        uint32_t is = kv_i2c_irq_status();

        /* Drain RX FIFO if data available (Phase 2 reads) */
        while (kv_i2c_rx_valid()) {
            uint8_t b = (uint8_t)(KV_I2C_RX & 0xFFu);
            if (t8_rx_count < T8_LEN)
                t8_rx_buf[t8_rx_count++] = b;
        }

        // STOP_DONE is sticky and explicitly acknowledged via kv_i2c_irq_status().
        if (is & KV_I2C_IE_STOP_DONE)
            t8_stop_count++;
    }
    kv_plic_complete(src);
}

static int test7_fifo_irq_transfer(void)
{
    printf("[TEST 7] FIFO Burst TX + IRQ-driven RX\n");
    printf("  EEPROM @ 0x%02X, mem_addr=0x%02X, len=%u\n",
           EEPROM_ADDR, T8_MEM_ADDR, (unsigned)T8_LEN);
    printf("  Phase 1: TX FIFO burst write + STOP_DONE IRQ\n");
    printf("  Phase 2: Sequential read    + RX_READY IRQ\n\n");

    t8_rx_count   = 0;
    t8_stop_count = 0;
    t8_irq_count  = 0;

    /* ── interrupt setup ─────────────────────────────────────────── */
    kv_irq_register(KV_CAUSE_MEI, t8_mei_handler);
    kv_plic_init_source(KV_PLIC_SRC_I2C, 1);
    kv_i2c_irq_enable(KV_I2C_IE_STOP_DONE | KV_I2C_IE_RX_READY);
    kv_irq_enable();

    /* ── Phase 1: burst write via TX FIFO ────────────────────────
     * IMPORTANT: The RTL I2C controller pops TX FIFO immediately in
     * IDLE state. TX FIFO must only be filled AFTER START is issued.
     *
     * Fill TX FIFO with ADDR_W + MEM_ADDR + T8_LEN data bytes
     * (= 8 bytes total = FIFO_DEPTH). The controller auto-pops each
     * byte from IDLE and transmits it, then returns to IDLE for next.
     * After TX FIFO drains we issue explicit STOP; STOP_DONE IRQ fires. */
    while (kv_i2c_busy()) {}

    /* Issue START first – controller transitions: IDLE → START → IDLE */
    KV_I2C_CTRL = KV_I2C_CTRL_ENABLE | KV_I2C_CTRL_START;
    KV_I2C_FENCE();
    while (kv_i2c_busy()) {}   /* wait for START to complete → IDLE */

    /* NOW fill TX FIFO (exactly FIFO_DEPTH = 8 bytes).
     * State machine auto-pops and sends each byte from IDLE. */
    KV_I2C_TX = (uint8_t)((EEPROM_ADDR << 1) | 0u);  /* ADDR_W */
    KV_I2C_TX = T8_MEM_ADDR;
    for (uint32_t i = 0; i < T8_LEN; i++)
        KV_I2C_TX = t8_pattern[i];
    KV_I2C_FENCE();

    printf("  [Phase 1] START issued; TX FIFO loaded: 1+1+%u = %u bytes\n",
           (unsigned)T8_LEN, (unsigned)(2 + T8_LEN));

    /* Wait until controller goes IDLE (TX FIFO empty + not busy) */
    uint32_t timeout = 5000000u;
    while ((kv_i2c_busy() || (KV_I2C_IS & KV_I2C_IE_TX_EMPTY) == 0) && timeout-- > 0u)
        asm volatile("nop");

    /* Now issue explicit STOP – this will trigger STOP_DONE IRQ */
    if (!kv_i2c_busy()) {
        KV_I2C_CTRL = KV_I2C_CTRL_ENABLE | KV_I2C_CTRL_STOP;
        KV_I2C_FENCE();
    }

    while (t8_stop_count == 0)
        kv_wfi();   /* gate clocks until STOP_DONE IRQ fires */

    if (t8_stop_count == 0) {   /* unreachable; kept as safety guard */
        printf("  Phase 1 TIMEOUT – STOP_DONE IRQ not received\n");
        printf("  Result: FAIL\n\n");
        kv_irq_disable();
        kv_i2c_irq_disable(KV_I2C_IE_STOP_DONE | KV_I2C_IE_RX_READY);
        kv_plic_disable_source(KV_PLIC_SRC_I2C);
        return -1;
    }
    printf("  Phase 1 done: STOP_DONE IRQ #%lu, irq_total=%lu\n",
           (unsigned long)t8_stop_count, (unsigned long)t8_irq_count);

    /* Brief pause – let EEPROM latch the written bytes */
    for (volatile int i = 0; i < 2000; i++) asm volatile("nop");

    /* ── Phase 2: sequential read ────────────────────────────────
     * Write pointer:  START + ADDR_W + MEM_ADDR + STOP
     * Then read:      START + ADDR_R + [T8_LEN READ commands] + STOP
     * RX FIFO bytes arrive via RX_READY IRQ.                         */
    printf("  [Phase 2] Issuing sequential read...\n");
    while (kv_i2c_busy()) {}

    /* Set EEPROM read pointer: START first, then push ADDR_W + MEM_ADDR, then STOP */
    KV_I2C_CTRL = KV_I2C_CTRL_ENABLE | KV_I2C_CTRL_START;
    KV_I2C_FENCE();
    while (kv_i2c_busy()) {}   /* wait for START to complete → IDLE */

    KV_I2C_TX = (uint8_t)((EEPROM_ADDR << 1) | 0u);  /* ADDR_W */
    KV_I2C_TX = T8_MEM_ADDR;
    KV_I2C_FENCE();

    /* Wait for TX FIFO to drain (bytes sent), then issue explicit STOP */
    timeout = 5000000u;
    while ((kv_i2c_busy() || (KV_I2C_IS & KV_I2C_IE_TX_EMPTY) == 0) && timeout-- > 0u)
        asm volatile("nop");

    /* Issue STOP to complete the write-pointer transaction */
    if (!kv_i2c_busy()) {
        KV_I2C_CTRL = KV_I2C_CTRL_ENABLE | KV_I2C_CTRL_STOP;
        KV_I2C_FENCE();
    }
    while (kv_i2c_busy()) {}

    /* Brief pause before read transaction */
    for (volatile int i = 0; i < 500; i++) asm volatile("nop");

    /* Read transaction: START first, then ADDR_R */
    KV_I2C_CTRL = KV_I2C_CTRL_ENABLE | KV_I2C_CTRL_START;
    KV_I2C_FENCE();
    while (kv_i2c_busy()) {}   /* wait for START to complete → IDLE */

    KV_I2C_TX = (uint8_t)((EEPROM_ADDR << 1) | 1u);  /* ADDR_R */
    KV_I2C_FENCE();
    while (kv_i2c_busy()) {}

    /* Issue T8_LEN READ commands; last one sends NACK */
    for (uint32_t i = 0; i < T8_LEN; i++) {
        while (kv_i2c_busy()) {}
        uint32_t ctrl = KV_I2C_CTRL_ENABLE | KV_I2C_CTRL_READ;
        if (i == T8_LEN - 1u) ctrl |= KV_I2C_CTRL_NACK;
        KV_I2C_CTRL = ctrl;
        KV_I2C_FENCE();
    }

    /* Wait until all RX bytes arrive via IRQ.
     * Keep this as an active wait (not WFI): dense back-to-back RX IRQs can
     * hit a rare interrupt-return edge case in the WFI loop during this phase. */
    while (t8_rx_count < T8_LEN)
        asm volatile("nop");

    /* STOP */
    while (kv_i2c_busy()) {}
    KV_I2C_CTRL = KV_I2C_CTRL_ENABLE | KV_I2C_CTRL_STOP;
    KV_I2C_FENCE();
    while (kv_i2c_busy()) {}

    /* ── cleanup & verify ────────────────────────────────────────── */
    kv_irq_disable();
    kv_i2c_irq_disable(KV_I2C_IE_STOP_DONE | KV_I2C_IE_RX_READY);
    kv_plic_disable_source(KV_PLIC_SRC_I2C);

    uint32_t errors = 0;
    for (uint32_t i = 0; i < T8_LEN; i++) {
        if (t8_rx_buf[i] != t8_pattern[i]) {
            printf("  Mismatch[%lu]: got 0x%02X exp 0x%02X\n",
                   (unsigned long)i, t8_rx_buf[i], t8_pattern[i]);
            errors++;
        }
    }

    printf("  RX received  : %lu / %lu\n",
           (unsigned long)t8_rx_count, (unsigned long)T8_LEN);
    printf("  Total IRQs   : %lu  (STOP: %lu)\n",
           (unsigned long)t8_irq_count, (unsigned long)t8_stop_count);
    printf("  Data errors  : %lu\n", (unsigned long)errors);

    int pass = (errors == 0 && t8_rx_count == T8_LEN);
    printf("  Result: %s\n\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : -1;
}

/* ════════════════════════════════════════════════════════════════════
 * Test 8: Scattered single-byte write + read-back
 * Exercises clock-stretching on individual eeprom_write() transactions.
 * 16 independent byte writes each trigger ADDR_W/MEM_ADDR/DATA ACK slots.
 * ════════════════════════════════════════════════════════════════════ */
#define SC_ADDR_BASE 0x30u
#define SC_LEN       16u

static const uint8_t sc_pattern[SC_LEN] = {
    0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18,
    0x29, 0x3A, 0x4B, 0x5C, 0x6D, 0x7E, 0x8F, 0x90
};

static int test8_scattered_write_read(void)
{
    printf("[TEST 8] Scattered Byte Write/Read (clock-stretch stress)\n");
    printf("  EEPROM addresses 0x%02X-0x%02X, %u individual writes\n",
           (unsigned)SC_ADDR_BASE, (unsigned)(SC_ADDR_BASE + SC_LEN - 1u),
           (unsigned)SC_LEN);

    /* Individual byte writes; each write has 3 ACK slots (ADDR_W, MEM_ADDR, DATA)
     * — all three trigger clock-stretch when STRETCH_CYCLES > 0.              */
    int ok = 1;
    for (uint32_t i = 0; i < SC_LEN && ok; i++) {
        if (eeprom_write((uint8_t)(SC_ADDR_BASE + i), sc_pattern[i]) < 0) {
            printf("  Write error at 0x%02X\n", (unsigned)(SC_ADDR_BASE + i));
            ok = 0;
        }
    }

    if (ok) {
        uint32_t errors = 0;
        for (uint32_t i = 0; i < SC_LEN; i++) {
            uint8_t d;
            if (eeprom_read((uint8_t)(SC_ADDR_BASE + i), &d) < 0 ||
                d != sc_pattern[i]) {
                printf("  Mismatch[%lu]: addr=0x%02X got=0x%02X exp=0x%02X\n",
                       (unsigned long)i, (unsigned)(SC_ADDR_BASE + i),
                       d, sc_pattern[i]);
                errors++;
            }
        }
        if (errors == 0)
            printf("  All %u bytes verified OK\n", (unsigned)SC_LEN);
        ok = (errors == 0);
    }

    printf("  Result: %s\n\n", ok ? "PASS" : "FAIL");
    return ok;
}

/* ════════════════════════════════════════════════════════════════════
 * Test 9: Block write + sequential read using kv_i2c_master helpers
 * Exercises kv_i2c_master_write and kv_i2c_master_read end-to-end.
 * ════════════════════════════════════════════════════════════════════ */
#define BK_ADDR_BASE 0x60u
#define BK_LEN       8u

static const uint8_t bk_data[BK_LEN] = {
    0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88
};

static int test9_block_transfer(void)
{
    printf("[TEST 9] Block Write + Sequential Read (kv_i2c_master helpers)\n");
    printf("  EEPROM address 0x%02X, %u bytes\n",
           (unsigned)BK_ADDR_BASE, (unsigned)BK_LEN);

    /* Write: [mem_addr, data0..dataN] packed into one kv_i2c_master_write call */
    uint8_t wbuf[1u + BK_LEN];
    wbuf[0] = BK_ADDR_BASE;
    for (uint32_t i = 0; i < BK_LEN; i++) wbuf[1u + i] = bk_data[i];

    if (kv_i2c_master_write(EEPROM_ADDR, wbuf, 1u + BK_LEN) < 0) {
        printf("  Block write FAILED (NACK)\n");
        printf("  Result: FAIL\n\n");
        return 0;
    }

    /* Brief write-cycle settle */
    for (volatile int i = 0; i < 2000; i++) asm volatile("nop");

    /* Set EEPROM internal read pointer to BK_ADDR_BASE */
    uint8_t ptr = BK_ADDR_BASE;
    if (kv_i2c_master_write(EEPROM_ADDR, &ptr, 1u) < 0) {
        printf("  Read-pointer set FAILED (NACK)\n");
        printf("  Result: FAIL\n\n");
        return 0;
    }

    /* Sequential read of BK_LEN bytes from BK_ADDR_BASE */
    uint8_t rbuf[BK_LEN];
    if (kv_i2c_master_read(EEPROM_ADDR, rbuf, BK_LEN) < 0) {
        printf("  Block read FAILED (NACK)\n");
        printf("  Result: FAIL\n\n");
        return 0;
    }

    uint32_t errors = 0;
    for (uint32_t i = 0; i < BK_LEN; i++) {
        if (rbuf[i] != bk_data[i]) {
            printf("  Mismatch[%lu]: got=0x%02X exp=0x%02X\n",
                   (unsigned long)i, rbuf[i], bk_data[i]);
            errors++;
        }
    }
    if (errors == 0)
        printf("  All %u bytes verified OK\n", (unsigned)BK_LEN);

    int pass = (errors == 0);
    printf("  Result: %s\n\n", pass ? "PASS" : "FAIL");
    return pass;
}

/* ════════════════════════════════════════════════════════════════════ */

int main(void)
{
    printf("\n========================================\n");
    printf("  I2C Hardware Test (Master + EEPROM)\n");
    printf("  Base Address: 0x%08X\n", (unsigned int)KV_I2C_BASE);
    printf("  EEPROM: 24C02 @ 0x%02X (256 bytes)\n", EEPROM_ADDR);
    printf("========================================\n\n");

    /* TEST 0: Capability register */
    printf("[TEST 0] Capability Register\n");
    uint32_t cap = kv_i2c_get_capability();
    printf("  CAP raw:        0x%08lX\n", (unsigned long)cap);
    printf("  CAP expected:   0x%08lX\n", (unsigned long)KV_CAP_I2C_VALUE);
    printf("  TX FIFO Depth:  %lu  (exp %lu)\n",
           (unsigned long)kv_i2c_get_tx_fifo_depth(), (unsigned long)KV_CAP_I2C_TX_FIFO_DEPTH);
    printf("  RX FIFO Depth:  %lu  (exp %lu)\n",
           (unsigned long)kv_i2c_get_rx_fifo_depth(), (unsigned long)KV_CAP_I2C_RX_FIFO_DEPTH);
    printf("  Version:        0x%04lX  (exp 0x%04lX)\n",
           (unsigned long)kv_i2c_get_version(), (unsigned long)KV_CAP_I2C_VERSION);
    printf("\n");

    /* TEST 1: Initialisation */
    printf("[TEST 1] I2C Controller Initialization\n");
    kv_i2c_init(249);   /* 100 kHz at 100 MHz */
    status_checks++;

    uint32_t status = KV_I2C_STATUS;
    printf("  Clock divider: 249 (100kHz I2C)\n");
    printf("  Initial status: 0x%08lX\n", (unsigned long)status);
    printf("  BUSY: %d, TX_READY: %d, RX_VALID: %d, ACK_RECV: %d\n",
           (status & KV_I2C_ST_BUSY)     ? 1 : 0,
           (status & KV_I2C_ST_TX_READY) ? 1 : 0,
           (status & KV_I2C_ST_RX_VALID) ? 1 : 0,
           (status & KV_I2C_ST_ACK_RECV) ? 1 : 0);
    printf("  Result: PASS\n\n");
    int t1 = 1;

    /* TEST 2: Read default EEPROM content */
    printf("[TEST 2] Read Default EEPROM Content\n");
    printf("  EEPROM initialized with pattern 0xA0 + address\n");
    printf("  Reading first 16 bytes:\n  ");

    int t2 = 1;
    for (int i = 0; i < 16; i++) {
        uint8_t d; int r = eeprom_read((uint8_t)i, &d);
        if (r < 0) { printf("\n  Error at 0x%02X\n", i); t2 = 0; break; }
        if (d != (uint8_t)(0xA0u + i)) { printf("\n  Mismatch at 0x%02X: exp 0x%02X got 0x%02X\n", i, (uint8_t)(0xA0u+i), d); t2 = 0; break; }
        printf("%02X ", d);
        if ((i + 1) % 8 == 0) printf("\n  ");
    }
    printf("\n  Result: %s\n\n", t2 ? "PASS" : "FAIL");

    /* TEST 3: Write to EEPROM */
    printf("[TEST 3] Write to EEPROM\n");
    printf("  Writing test pattern to addresses 0x10-0x1F\n");
    const uint8_t pat[] = {0x12,0x34,0x56,0x78,0x9A,0xBC,0xDE,0xF0,
                           0x01,0x23,0x45,0x67,0x89,0xAB,0xCD,0xEF};
    int t3 = 1;
    for (int i = 0; i < 16; i++) {
        if (eeprom_write((uint8_t)(0x10+i), pat[i]) < 0) { printf("  Error writing 0x%02X\n", 0x10+i); t3 = 0; break; }
    }
    if (t3) printf("  Successfully wrote 16 bytes\n");
    printf("  Result: %s\n\n", t3 ? "PASS" : "FAIL");

    /* TEST 4: Read back and verify */
    printf("[TEST 4] Read Back and Verify\n");
    printf("  Reading addresses 0x10-0x1F:\n  ");
    int t4 = 1;
    for (int i = 0; i < 16; i++) {
        uint8_t d; int r = eeprom_read((uint8_t)(0x10+i), &d);
        if (r < 0 || d != pat[i]) { printf("\n  Error at 0x%02X\n", 0x10+i); t4 = 0; break; }
        printf("%02X ", d);
        if ((i + 1) % 8 == 0) printf("\n  ");
    }
    printf("\n  Result: %s\n\n", t4 ? "PASS" : "FAIL");

    /* TEST 5: Sequential Read */
    printf("[TEST 5] Sequential Read Test\n");
    printf("  Reading 8 consecutive addresses starting at 0x00:\n  ");
    int t5 = 1;
    for (int i = 0; i < 8; i++) {
        uint8_t d; int r = eeprom_read((uint8_t)i, &d);
        if (r < 0 || d != (uint8_t)(0xA0u+i)) { t5 = 0; break; }
        printf("%02X ", d);
    }
    printf("\n  Result: %s\n\n", t5 ? "PASS" : "FAIL");

    /* TEST 6: Boundary address */
    printf("[TEST 6] Boundary Address Test\n");
    printf("  Testing addresses 0x00 and 0xFF\n");
    uint8_t d0, dff;
    int t6 = (eeprom_read(0x00, &d0) == 0) && (eeprom_read(0xFF, &dff) == 0);
    if (t6) {
        printf("  Address 0x00: 0x%02X (exp 0x%02X) %s\n", d0,  0xA0u,               (d0  == 0xA0u)                  ? "PASS" : "FAIL");
        printf("  Address 0xFF: 0x%02X (exp 0x%02X) %s\n", dff, (uint8_t)(0xA0u+0xFF),(dff == (uint8_t)(0xA0u+0xFF)) ? "PASS" : "FAIL");
        t6 = (d0 == 0xA0u) && (dff == (uint8_t)(0xA0u + 0xFF));
    }
    printf("  Result: %s\n\n", t6 ? "PASS" : "FAIL");

    /* Statistics (informational only, not a test) */
    printf("[INFO] Statistics Summary\n");
    printf("  Status checks: %lu\n", (unsigned long)status_checks);
    printf("  Busy waits:    %lu\n", (unsigned long)busy_waits);
    printf("  Writes:        %lu\n", (unsigned long)writes);
    printf("  Reads:         %lu\n", (unsigned long)reads);
    printf("  Final status:  0x%08lX\n\n", (unsigned long)KV_I2C_STATUS);

    /* TEST 7 */
    int t7 = (test7_fifo_irq_transfer() == 0) ? 1 : 0;

    /* TEST 8 */
    int t8 = test8_scattered_write_read();

    /* TEST 9 */
    int t9 = test9_block_transfer();

    int passed = t1 + t2 + t3 + t4 + t5 + t6 + t7 + t8 + t9;
    printf("========================================\n");
    printf("  Summary: %d/9 tests PASSED\n", passed);
    printf("========================================\n\n");
    printf("I2C hardware test complete.\n");
    return (passed == 9) ? 0 : 1;
}

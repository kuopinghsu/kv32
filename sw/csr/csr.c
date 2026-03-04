// ============================================================================
// File: csr.c
// Project: KV32 RISC-V Processor
// Description: CSR read-only exception test: illegal-instruction traps on RO CSR writes
//
// Verifies RISC-V Zicsr rule: a write is only attempted when
// rs1 != x0 (CSRRS/CSRRC) or uimm != 0 (CSRRSI/CSRRCI);
// otherwise it is a pure read and must not raise an exception.
// ============================================================================

#include <stdint.h>

extern void putc(char c);

// ---------------------------------------------------------------------------
// Minimal I/O
// ---------------------------------------------------------------------------

static void puts_raw(const char *s) {
    while (*s) putc(*s++);
}

static void print_hex(uint32_t v) {
    const char h[] = "0123456789abcdef";
    puts_raw("0x");
    for (int i = 7; i >= 0; i--)
        putc(h[(v >> (i * 4)) & 0xf]);
}

// ---------------------------------------------------------------------------
// Trap tracking (volatile so the compiler cannot eliminate the stores)
// ---------------------------------------------------------------------------

static volatile int      g_trapped;
static volatile uint32_t g_mcause;
static volatile uint32_t g_mepc;

// override the weak trap_handler from common/trap.c
void trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval) {
    (void)mtval;
    g_trapped = 1;
    g_mcause  = mcause;
    g_mepc    = mepc;
    // Advance mepc past the 4-byte faulting instruction so execution resumes
    // after the test instruction rather than retrying it forever.
    asm volatile("csrw mepc, %0" :: "r"(mepc + 4));
}

static void before_test(void) {
    g_trapped = 0;
    g_mcause  = 0;
    g_mepc    = 0;
}

// ---------------------------------------------------------------------------
// Pass/fail accounting
// ---------------------------------------------------------------------------

static int g_pass;
static int g_fail;

#define ILLOP_CAUSE 2u

// Expect an Illegal Instruction exception to have been raised.
static void check_trapped(const char *name) {
    if (g_trapped && (g_mcause == ILLOP_CAUSE)) {
        puts_raw("  PASS: ");
        puts_raw(name);
        puts_raw("\n");
        g_pass++;
    } else {
        puts_raw("  FAIL: ");
        puts_raw(name);
        puts_raw("  (trapped=");
        putc(g_trapped ? '1' : '0');
        puts_raw(", mcause=");
        print_hex(g_mcause);
        puts_raw(")\n");
        g_fail++;
    }
}

// Expect NO exception; print the value returned by the CSR read.
static void check_no_trap(const char *name, uint32_t rd_val) {
    if (!g_trapped) {
        puts_raw("  PASS: ");
        puts_raw(name);
        puts_raw("  (rd=");
        print_hex(rd_val);
        puts_raw(")\n");
        g_pass++;
    } else {
        puts_raw("  FAIL: ");
        puts_raw(name);
        puts_raw("  (unexpected trap, mcause=");
        print_hex(g_mcause);
        puts_raw(")\n");
        g_fail++;
    }
}

// ---------------------------------------------------------------------------
// Helpers that force a specific source register via GCC register variables.
// Using a named register variable prevents GCC from substituting x0 even
// when the value happens to be 0 (relevant for testcase 4 where x15=0 but
// the instruction has rs1=x15, not rs1=x0, so it must still trap).
// ---------------------------------------------------------------------------

// csrrs rd, csr_addr, <reg>  where <reg> is forced to a named GPR != x0
#define CSRRS_WITH_RS1(rd_out, csr_hex, rs1_reg, rs1_val) do {         \
    register uint32_t _rs1 asm(rs1_reg) = (rs1_val);                   \
    asm volatile("csrrs %0, " csr_hex ", %1"                           \
                 : "=r"(rd_out) : "r"(_rs1) : );                       \
} while (0)

// csrrc rd, csr_addr, <reg>
#define CSRRC_WITH_RS1(rd_out, csr_hex, rs1_reg, rs1_val) do {         \
    register uint32_t _rs1 asm(rs1_reg) = (rs1_val);                   \
    asm volatile("csrrc %0, " csr_hex ", %1"                           \
                 : "=r"(rd_out) : "r"(_rs1) : );                       \
} while (0)

// ---------------------------------------------------------------------------
// Main test
// ---------------------------------------------------------------------------

int main(void) {
    uint32_t rd = 0;

    puts_raw("CSR Read-Only Exception Test\n");
    puts_raw("============================\n\n");

    // -----------------------------------------------------------------------
    // Group 1: User-level counter CSRs  (cycle 0xC00, time 0xC01, instret 0xC02)
    //
    // These are read-only; any write attempt must raise Illegal Instruction.
    // A write is attempted when uimm≠0 (CSRRSI/CSRRCI) or rs1≠x0 (CSRRS/CSRRC).
    // -----------------------------------------------------------------------
    puts_raw("--- Group 1: User counter CSRs (cycle/time/instret) ---\n");

    // --- cycle (0xC00) ---

    // Testcase 1: csrrsi rd, cycle, 13  – uimm=13 ≠ 0 → write attempt → MUST trap
    // Encoding from the testcase: 0xc006be73 (rd=x23, uimm=13, csr=0xC00)
    before_test();
    asm volatile(".word 0xc006be73" ::: "x23");
    check_trapped("Testcase 1: csrrsi x23, cycle, 13  (uimm=13, must trap)");

    // csrrsi with uimm=0 on cycle → pure read → must NOT trap
    before_test();
    asm volatile("csrrsi %0, 0xC00, 0" : "=r"(rd));
    check_no_trap("csrrsi rd, cycle, 0  (uimm=0, pure read, no trap)", rd);

    // csrrs rd, cycle, x0 → pure read → must NOT trap
    before_test();
    asm volatile("csrrs %0, 0xC00, x0" : "=r"(rd));
    check_no_trap("csrrs  rd, cycle, x0  (rs1=x0, pure read, no trap)", rd);

    // csrrs rd, cycle, t0 (x5, any non-x0 register) → write attempt → MUST trap
    before_test();
    CSRRS_WITH_RS1(rd, "0xC00", "t0", 0x1);
    check_trapped("csrrs  rd, cycle, t0  (rs1=t0≠x0, must trap)");

    // csrrc rd, cycle, x0 → pure read → must NOT trap
    before_test();
    asm volatile("csrrc %0, 0xC00, x0" : "=r"(rd));
    check_no_trap("csrrc  rd, cycle, x0  (rs1=x0, pure read, no trap)", rd);

    // csrrc rd, cycle, t0 → write attempt → MUST trap
    before_test();
    CSRRC_WITH_RS1(rd, "0xC00", "t0", 0x1);
    check_trapped("csrrc  rd, cycle, t0  (rs1=t0≠x0, must trap)");

    // --- time (0xC01) ---

    // Testcase 3: csrrci x20, time, 0  – uimm=0 → pure read → must NOT trap
    // Encoding from the test case: 0xc0107a73 (rd=x20, uimm=0, csr=0xC01)
    before_test();
    asm volatile(".word 0xc0107a73" : "=r"(rd) :: "x20");
    asm volatile("mv %0, x20" : "=r"(rd));
    check_no_trap("Testcase 3: csrrci x20, time, 0  (uimm=0, pure read, no trap)", rd);

    // csrrsi rd, time, 1 → uimm=1 ≠ 0 → write attempt → MUST trap
    before_test();
    asm volatile("csrrsi %0, 0xC01, 1" : "=r"(rd));
    check_trapped("csrrsi rd, time, 1  (uimm=1, must trap)");

    // csrrc rd, time, t1 (x6) → write attempt → MUST trap
    before_test();
    CSRRC_WITH_RS1(rd, "0xC01", "t1", 0x1);
    check_trapped("csrrc  rd, time, t1  (rs1=t1≠x0, must trap)");

    // --- instret (0xC02) ---

    // Testcase 2: csrrc x18, instret, x19  – rs1=x19 ≠ x0 → write attempt → MUST trap
    before_test();
    CSRRC_WITH_RS1(rd, "0xC02", "s3", 0x1bc141a3u);   // s3 = x19
    check_trapped("Testcase 2: csrrc x18, instret, x19  (rs1=x19≠x0, must trap)");

    // csrrc rd, instret, x0 → pure read → must NOT trap
    before_test();
    asm volatile("csrrc %0, 0xC02, x0" : "=r"(rd));
    check_no_trap("csrrc  rd, instret, x0  (rs1=x0, pure read, no trap)", rd);

    // csrrsi rd, instret, 7 → uimm=7 ≠ 0 → write attempt → MUST trap
    before_test();
    asm volatile("csrrsi %0, 0xC02, 7" : "=r"(rd));
    check_trapped("csrrsi rd, instret, 7  (uimm=7, must trap)");

    // -----------------------------------------------------------------------
    // Group 2: Machine information CSRs (0xF11–0xF14)
    //   mvendorid (0xF11), marchid (0xF12), mimpid (0xF13), mhartid (0xF14)
    //
    // Address bits[11:10]=0b11 → read-only.  rs1≠x0 (even when the register
    // value is 0 at runtime) constitutes a write attempt and must trap.
    // -----------------------------------------------------------------------
    puts_raw("\n--- Group 2: Machine info CSRs (mvendorid/marchid/mimpid/mhartid) ---\n");

    // Testcase 4a: csrrs x20, mvendorid, x15  where x15=0 (not x0) → MUST trap
    before_test();
    CSRRS_WITH_RS1(rd, "0xF11", "a5", 0);       // a5 = x15; value 0 but register is not x0
    check_trapped("Testcase 4a: csrrs rd, mvendorid, a5 (a5=x15, value=0 but rs1≠x0, must trap)");

    // csrrs rd, mvendorid, x0  → pure read → must NOT trap
    before_test();
    asm volatile("csrrs %0, 0xF11, x0" : "=r"(rd));
    check_no_trap("csrrs  rd, mvendorid, x0  (rs1=x0, pure read, no trap)", rd);

    // csrr rd, mvendorid  (pseudo; assembles as csrrs rd, mvendorid, x0) → must NOT trap
    before_test();
    asm volatile("csrr %0, mvendorid" : "=r"(rd));
    check_no_trap("csrr   rd, mvendorid  (pure read, no trap)", rd);

    // Testcase 4b: csrrs rd, marchid, t0 (rs1=x5 ≠ x0) → MUST trap
    before_test();
    CSRRS_WITH_RS1(rd, "0xF12", "t0", 1);
    check_trapped("Testcase 4b: csrrs rd, marchid, t0  (rs1=t0≠x0, must trap)");

    // csrr rd, marchid → pure read → must NOT trap
    before_test();
    asm volatile("csrr %0, marchid" : "=r"(rd));
    check_no_trap("csrr   rd, marchid  (pure read, no trap)", rd);

    // Testcase 4c: csrrs rd, mimpid, t0 → MUST trap
    before_test();
    CSRRS_WITH_RS1(rd, "0xF13", "t0", 1);
    check_trapped("Testcase 4c: csrrs rd, mimpid, t0  (rs1=t0≠x0, must trap)");

    // csrr rd, mimpid → pure read → must NOT trap
    before_test();
    asm volatile("csrr %0, mimpid" : "=r"(rd));
    check_no_trap("csrr   rd, mimpid  (pure read, no trap)", rd);

    // Testcase 4d: csrrs rd, mhartid, t0 → MUST trap
    before_test();
    CSRRS_WITH_RS1(rd, "0xF14", "t0", 1);
    check_trapped("Testcase 4d: csrrs rd, mhartid, t0  (rs1=t0≠x0, must trap)");

    // csrr rd, mhartid → pure read → must NOT trap
    before_test();
    asm volatile("csrr %0, mhartid" : "=r"(rd));
    check_no_trap("csrr   rd, mhartid  (pure read, no trap)", rd);

    // Also verify csrrc with rs1≠x0 traps for all four machine info CSRs
    before_test();
    CSRRC_WITH_RS1(rd, "0xF11", "t0", 1);
    check_trapped("csrrc  rd, mvendorid, t0  (rs1≠x0, must trap)");

    before_test();
    CSRRC_WITH_RS1(rd, "0xF12", "t0", 1);
    check_trapped("csrrc  rd, marchid,  t0  (rs1≠x0, must trap)");

    before_test();
    CSRRC_WITH_RS1(rd, "0xF13", "t0", 1);
    check_trapped("csrrc  rd, mimpid,   t0  (rs1≠x0, must trap)");

    before_test();
    CSRRC_WITH_RS1(rd, "0xF14", "t0", 1);
    check_trapped("csrrc  rd, mhartid,  t0  (rs1≠x0, must trap)");

    // -----------------------------------------------------------------------
    // Group 3: CSRRW / CSRRWI to read-only CSRs
    //
    // CSRRW/CSRRWI always constitute a write regardless of rs1/uimm value.
    // Any such access to a read-only CSR (addr[11:10]=2'b11) must trap.
    // -----------------------------------------------------------------------
    puts_raw("\n--- Group 3: CSRRW/CSRRWI to read-only CSRs ---\n");

    // csrrw rd, cycle, t0  → always writes → MUST trap
    before_test();
    {
        register uint32_t _rs1 asm("t0") = 0x1234;
        asm volatile("csrrw %0, 0xC00, %1" : "=r"(rd) : "r"(_rs1));
    }
    check_trapped("csrrw  rd, cycle, t0   (always-write to RO, must trap)");

    // csrrwi rd, cycle, 0  → always writes even with uimm=0 → MUST trap
    before_test();
    asm volatile("csrrwi %0, 0xC00, 0" : "=r"(rd));
    check_trapped("csrrwi rd, cycle, 0    (CSRRWI always-write even uimm=0, must trap)");

    // csrrwi rd, cycle, 1  → always writes → MUST trap
    before_test();
    asm volatile("csrrwi %0, 0xC00, 1" : "=r"(rd));
    check_trapped("csrrwi rd, cycle, 1    (CSRRWI always-write, must trap)");

    // csrrw rd, instret, t0  → MUST trap
    before_test();
    {
        register uint32_t _rs1 asm("t0") = 0x1;
        asm volatile("csrrw %0, 0xC02, %1" : "=r"(rd) : "r"(_rs1));
    }
    check_trapped("csrrw  rd, instret, t0 (always-write to RO, must trap)");

    // csrrwi rd, mvendorid, 0  → MUST trap
    before_test();
    asm volatile("csrrwi %0, 0xF11, 0" : "=r"(rd));
    check_trapped("csrrwi rd, mvendorid, 0 (CSRRWI always-write to RO, must trap)");

    // csrrw rd, mhartid, t0  → MUST trap
    before_test();
    {
        register uint32_t _rs1 asm("t0") = 0x0;
        asm volatile("csrrw %0, 0xF14, %1" : "=r"(rd) : "r"(_rs1));
    }
    check_trapped("csrrw  rd, mhartid, t0 (rs1=t0,val=0, always-write, must trap)");

    // -----------------------------------------------------------------------
    // Group 4: Non-existent CSR addresses
    //
    // Accessing any CSR address not implemented raises Illegal Instruction
    // (RISC-V privileged spec section 2.1).
    // -----------------------------------------------------------------------
    puts_raw("\n--- Group 4: Non-existent CSR addresses ---\n");

    // Write to 0xABC  (addr[11:10]=2'b10 — not a read-only address, just unknown)
    before_test();
    {
        register uint32_t _rs1 asm("t0") = 0xDEAD;
        asm volatile("csrrw %0, 0xABC, %1" : "=r"(rd) : "r"(_rs1));
    }
    check_trapped("csrrw  rd, 0xABC, t0   (unknown CSR write, must trap)");

    // Write to 0x800 (addr[11:10]=2'b10, unknown machine-mode CSR)
    before_test();
    {
        register uint32_t _rs1 asm("t0") = 0x1;
        asm volatile("csrrw %0, 0x800, %1" : "=r"(rd) : "r"(_rs1));
    }
    check_trapped("csrrw  rd, 0x800, t0   (unknown CSR write, must trap)");

    // Read from 0xABC via csrrs rd, 0xABC, x0 (pure read of unknown CSR)
    before_test();
    asm volatile("csrrs %0, 0xABC, x0" : "=r"(rd));
    check_trapped("csrrs  rd, 0xABC, x0   (unknown CSR read, must trap)");

    // csrrsi rd, 0xABC, 0  (uimm=0 → pure read of unknown CSR)
    before_test();
    asm volatile("csrrsi %0, 0xABC, 0" : "=r"(rd));
    check_trapped("csrrsi rd, 0xABC, 0    (unknown CSR read uimm=0, must trap)");

    // -----------------------------------------------------------------------
    // Summary
    // -----------------------------------------------------------------------
    puts_raw("\n============================\n");
    puts_raw("Results: ");
    {
        char buf[12];
        int n = g_pass, i = 0;
        if (n == 0) { buf[i++] = '0'; }
        else { char tmp[12]; int j=0; while(n>0){tmp[j++]='0'+(n%10);n/=10;} while(j>0)buf[i++]=tmp[--j]; }
        buf[i] = '\0';
        puts_raw(buf);
    }
    puts_raw(" passed, ");
    {
        char buf[12];
        int n = g_fail, i = 0;
        if (n == 0) { buf[i++] = '0'; }
        else { char tmp[12]; int j=0; while(n>0){tmp[j++]='0'+(n%10);n/=10;} while(j>0)buf[i++]=tmp[--j]; }
        buf[i] = '\0';
        puts_raw(buf);
    }
    puts_raw(" failed\n");
    if (g_fail == 0)
        puts_raw("ALL TESTS PASSED\n");
    else
        puts_raw("SOME TESTS FAILED\n");

    return g_fail ? 1 : 0;
}

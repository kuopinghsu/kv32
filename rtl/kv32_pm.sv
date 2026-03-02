// ============================================================================
// File: kv32_pm.sv
// Project: KV32 RISC-V Processor
// Description: Power Manager — Clock Gating Controller for kv32_core
//
// When the processor executes a WFI instruction, kv32_core asserts
// core_sleep_o once all outstanding instruction-fetch and store-buffer
// traffic has drained.  kv32_pm then gates the clock to the core until
// any machine-mode interrupt source becomes active, at which point the
// clock enable is de-asserted and the global clock resumes on the next
// falling edge (ICG behaviour).
//
// Technology Mapping:
//   Synthesis (FPGA — Xilinx UltraScale+):
//     BUFGCE is instantiated directly.  The CE input is routed through a
//     transparent latch that is open during the low phase of clk_i so that
//     CE is captured glitch-free at the rising edge (standard ICG protocol).
//
//   Simulation / ASIC:
//     A behavioural ICG model (latch + AND gate) is used so that ISA-level
//     simulations and RTL-vs-software trace comparisons are unaffected by
//     the clock-gating logic.
//
// Clock Enable Logic:
//   clk_en = !sleep_req_i                   (core not in WFI)
//          | timer_irq_i                     (CLINT timer IRQ pending)
//          | external_irq_i                  (PLIC external IRQ pending)
//          | software_irq_i                  (CLINT software IRQ pending)
//
//   When sleep_req_i is asserted AND no interrupt is pending, clk_en=0 and
//   the gated clock is held low.  The interrupt signals are driven by the
//   SoC peripherals (CLINT, PLIC) which continue to run on the ungated
//   system clock, so wake-up latency is one clock period.
// ============================================================================

module kv32_pm (
    input  logic clk_i,           // System clock (ungated)
    input  logic rst_n,           // Active-low asynchronous reset

    // Sleep request from kv32_core (asserted during WFI idle)
    input  logic sleep_req_i,     // core_sleep_o from kv32_core

    // Interrupt sources (from CLINT / PLIC, run on ungated clock)
    input  logic timer_irq_i,     // CLINT machine-timer interrupt
    input  logic external_irq_i,  // PLIC external interrupt
    input  logic software_irq_i,  // CLINT software interrupt

    // Gated clock output to kv32_core
    output logic gated_clk_o      // Clock-gated version of clk_i
);

    // =========================================================================
    // Wake-interrupt Latch (ungated clock domain)
    // =========================================================================
    // Problem: interrupt sources may produce a single-cycle pulse on the
    // ungated system clock.  If the pulse arrives while the gated clock is
    // held low, the core never sees a rising edge, MIP is never updated, and
    // the core stays asleep forever.
    //
    // Solution: a flip-flop clocked on the UNGATED system clock captures any
    // interrupt pulse and holds clk_en=1 until the core has fully woken up
    // (sleep_req_i deasserts).  The latch clears itself one cycle after the
    // core de-asserts sleep_req_i, which guarantees the gated clock delivers
    // at least one edge to the core's interrupt-sampling logic.
    logic irq_wake_pending;

    always_ff @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            irq_wake_pending <= 1'b0;
        end else begin
            if (!sleep_req_i)
                irq_wake_pending <= 1'b0;          // Core is awake — clear the latch
            else if (timer_irq_i | external_irq_i | software_irq_i)
                irq_wake_pending <= 1'b1;          // Capture edge/level while sleeping
        end
    end

    // =========================================================================
    // Clock Enable Logic
    // =========================================================================
    // Clock is enabled when:
    //   1. Core is not requesting sleep (normal run / WFI not yet entered)
    //   2. Any interrupt source is currently asserted (level wake)
    //   3. A previous interrupt pulse was captured (irq_wake_pending)
    //
    // The enable signal is sampled on the falling edge of clk_i by the ICG
    // latch so that no glitches propagate to the gated clock output.
    logic clk_en;

    assign clk_en = !sleep_req_i
                  | timer_irq_i
                  | external_irq_i
                  | software_irq_i
                  | irq_wake_pending;

`ifdef SYNTHESIS
    // =========================================================================
    // Xilinx UltraScale+ BUFGCE Instantiation
    // =========================================================================
    // BUFGCE provides integrated clock-gating with a synchronous CE input.
    // The ICG latch is built into the primitive; Vivado correctly infers
    // the setup/hold constraints on CE with respect to the global clock.
    //
    // CE_TYPE="SYNC" means CE is sampled synchronously (on the rising edge of
    // the internal clock) which gives the same glitch-free behaviour as an
    // external ICG latch.  Use CE_TYPE="ASYNC" only when CE is guaranteed
    // to be stable before the rising edge.
    BUFGCE #(
        .CE_TYPE        ("SYNC"),        // Synchronous CE sampling
        .IS_CE_INVERTED (1'b0),          // CE active-high
        .IS_I_INVERTED  (1'b0)           // Clock not inverted
    ) u_bufgce (
        .O  (gated_clk_o),               // Gated clock output
        .CE (clk_en),                    // Clock enable
        .I  (clk_i)                      // Clock input
    );
`else
    // =========================================================================
    // Behavioural ICG Model (simulation / ASIC flow)
    // =========================================================================
    // Standard integrated-clock-gating cell:
    //   - A transparent latch captures clk_en on the LOW phase of clk_i.
    //   - The gated clock is the AND of clk_i and the latched enable.
    // This model is recognised by synthesis tools as an ICG cell pattern.
    //
    // In pure RTL simulation the latch ensures CE is glitch-free at the
    // rising edge, matching the BUFGCE timing model exactly.

    logic latch_en;

    /* verilator lint_off LATCH */
    always_latch begin
        if (!clk_i)
            latch_en = clk_en;
    end
    /* verilator lint_on LATCH */

    assign gated_clk_o = clk_i & latch_en;
`endif

endmodule

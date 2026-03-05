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
// Clock Enable Logic (registered on always-on clk_i):
//   clk_en is a flip-flop driven on the ungated system clock:
//     - Goes LOW on the rising edge of sleep_req_i  (core entering WFI)
//     - Goes HIGH as soon as any IRQ source is asserted  (wake-up condition)
//     - IRQ takes priority: if an IRQ arrives simultaneously with the sleep
//       request rising edge, the clock stays enabled.
//
// Wakeup Signal (handshake):
//   wakeup_o is a set-clear FF on the always-on clock:
//     - SET  when any IRQ is asserted while the core is sleeping
//     - CLEAR when sleep_req_i deasserts, confirming the pipeline has unstalled
//   This guarantees wakeup_o remains asserted across the 1-2 cycle latency
//   of the clock gate re-enabling, even if the IRQ is a single-cycle pulse.
// ============================================================================

`ifdef SYNTHESIS
    import kv32_pkg::*;
`endif

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
    output logic gated_clk_o,     // Clock-gated version of clk_i

    // Wakeup signal to kv32_core (unstall from WFI)
    output logic wakeup_o         // High while sleeping and any IRQ is pending
);
`ifndef SYNTHESIS
    import kv32_pkg::*;
`endif

    // =========================================================================
    // Clock Enable & Wakeup Logic (always-on clock domain)
    // =========================================================================
    // clk_en is a registered FF clocked by the ungated system clock:
    //   - Set   (1) when any IRQ is asserted  OR wakeup_o is still held high
    //     (wakeup_o keeps the clock alive until the core fully exits WFI)
    //   - Cleared (0) on the rising edge of sleep_req_i, only when wakeup_o=0
    //     (prevents re-gating while a wakeup is still in flight)
    //
    // wakeup_o is a set-clear handshake FF:
    //   - SET  when irq_any fires while the core is sleeping (sleep_req_i=1)
    //   - CLEAR on the first cycle sleep_req_i deasserts (core exited WFI)

    logic irq_any;
    assign irq_any = timer_irq_i | external_irq_i | software_irq_i;

    logic sleep_req_d;   // previous-cycle value for rising-edge detection
    logic clk_en;

    always_ff @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            sleep_req_d <= 1'b0;
            clk_en      <= 1'b1;   // clock running after reset
        end else begin
            sleep_req_d <= sleep_req_i;
            if (irq_any || wakeup_o)
                clk_en <= 1'b1;                       // IRQ pending or wakeup in flight: keep clock alive
            else if (sleep_req_i && !sleep_req_d)
                clk_en <= 1'b0;                       // rising edge of sleep_req (no wakeup pending) → gate clock
        end
    end

`ifdef DEBUG
    always_ff @(posedge clk_i or negedge rst_n) begin
        if (rst_n) begin
            // Report on rising edge of sleep_req_i
            if (sleep_req_i && !sleep_req_d)
                `DEBUG2(`DBG_GRP_WFI, ("[PM] sleep_req RISE → gating clock. irq_any=%b timer=%b ext=%b sw=%b",
                         irq_any, timer_irq_i, external_irq_i, software_irq_i));
            // Report when IRQ fires while sleeping
            if (sleep_req_i && irq_any && !wakeup_o)
                `DEBUG1(("[PM] IRQ while sleeping @ %0t: timer=%b ext=%b sw=%b clk_en=%b wakeup_o=%b",
                         $time, timer_irq_i, external_irq_i, software_irq_i, clk_en, wakeup_o));
            // Report when wakeup_o goes high
            if (sleep_req_i && irq_any && !wakeup_o)
                `DEBUG1(("[PM] wakeup_o SET @ %0t", $time));
            // Report when sleep_req_i falls (pipeline unstalled)
            if (!sleep_req_i && sleep_req_d)
                `DEBUG1(("[PM] sleep_req FALL → wakeup_o cleared, core resumed @ %0t", $time));
            // Periodic report while sleeping (every cycle)
            if (sleep_req_i)
                `DEBUG2(`DBG_GRP_WFI, ("[PM] sleeping: irq_any=%b timer=%b ext=%b sw=%b clk_en=%b wakeup_o=%b",
                         irq_any, timer_irq_i, external_irq_i, software_irq_i, clk_en, wakeup_o));
        end
    end
`endif

    always_ff @(posedge clk_i or negedge rst_n) begin
        if (!rst_n)
            wakeup_o <= 1'b0;
        else begin
            if (!sleep_req_i)
                wakeup_o <= 1'b0;           // pipeline left WFI — clear handshake
            else if (irq_any)
                wakeup_o <= 1'b1;           // IRQ fired while sleeping — assert and hold
        end
    end

`ifdef FPGA_SYNTHESIS
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
            latch_en <= clk_en;  // non-blocking in always_latch avoids scheduling hazard
    end
    /* verilator lint_on LATCH */

    assign gated_clk_o = clk_i & latch_en;
`endif

endmodule


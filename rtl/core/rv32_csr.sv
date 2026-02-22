// ============================================================================
// File: rv32_csr.sv
// Project: RV32 RISC-V Processor
// Description: RISC-V Control and Status Registers (CSR)
//
// Implements machine-mode CSRs for the RISC-V processor:
//   - Machine Information: mvendorid, marchid, mimpid, mhartid
//   - Machine Trap Setup: mstatus, misa, mie, mtvec
//   - Machine Trap Handling: mscratch, mepc, mcause, mtval, mip
//   - Machine Counters: mcycle, minstret
//
// Features:
//   - CSR read/write operations (CSRRW, CSRRS, CSRRC, immediate variants)
//   - Exception and interrupt handling
//   - Timer and external interrupt support
//   - Performance counters
// ============================================================================

module rv32_csr (
    input  logic        clk,
    input  logic        rst_n,

    // CSR access
    input  logic [11:0] csr_addr,
    input  logic [2:0]  csr_op,
    input  logic [31:0] csr_wdata,
    input  logic [4:0]  csr_zimm,
    output logic [31:0] csr_rdata,
    output logic        csr_illegal,

    // Exception/Interrupt
    input  logic        exception,
    input  logic [4:0]  exception_cause,
    input  logic [31:0] exception_pc,
    input  logic [31:0] exception_tval,

    input  logic        mret,
    output logic [31:0] mtvec,
    output logic [31:0] mepc_o,

    // Interrupt PC (PC+4 for async interrupts)
    input  logic [31:0] interrupt_pc,

    // Interrupts
    input  logic        timer_irq,
    input  logic        external_irq,
    input  logic        software_irq,

    output logic        irq_pending,
    output logic [31:0] irq_cause,

    // Cycle counter
    input  logic        retire_instr,

    // Trace-compare mode: substitute minstret for mcycle on cycle/time CSR reads
    // so that RTL cycle-counter reads are independent of pipeline stalls and produce
    // identical results to the software simulator (which increments mcycle and
    // minstret together, one-per-instruction).  Only asserted when +TRACE is active.
`ifndef SYNTHESIS
    input  logic        trace_mode
`endif
);

    import rv32_pkg::*;

    // CSR registers
    logic [31:0] mstatus;
    logic [31:0] misa;
    logic [31:0] mie;
    logic [31:0] mtvec_r;
    logic [31:0] mscratch;
    logic [31:0] mepc;
    logic [31:0] mcause;
    logic [31:0] mtval;
    logic [31:0] mip;
    logic [63:0] mcycle;
    logic [63:0] minstret;

    // cycle_csr_src: selects which counter is returned for cycle/time/mcycle reads.
    // In normal operation this is mcycle (actual wall-clock cycles).
    //
    // In trace-compare mode (trace_mode=1, set by testbench when +TRACE is active)
    // we must return a value that matches the software simulator exactly.
    //
    // Timing of the RTL CSR read:
    //   - The CSR read instruction is in the MEM stage when csr_rdata is computed.
    //   - minstret is a registered counter: it holds the count of instructions
    //     that retired in *previous* clock cycles only.
    //   - In steady-state pipeline, the instruction just before the CSR read
    //     instruction (N-1) is in the WB stage simultaneously, where retire_instr
    //     fires *this* clock edge — but the registered minstret has not yet
    //     captured that increment.
    //
    // Software simulator convention:
    //   - csr_minstret is incremented at the *start* of every instruction.
    //   - So when the Nth instruction (csrrs cycle) executes, csr_minstret == N.
    //
    // RTL correction formula (universally correct with or without WB bubble):
    //   minstret (registered, old)
    //   + retire_instr && !exception  -- WB instruction retiring this edge but not
    //                                    yet in minstret (0 if WB is a bubble)
    //   + 1                           -- the csrrs instruction itself (in MEM now)
    //   = N  (matches software simulator)
`ifndef SYNTHESIS
    logic [63:0] cycle_csr_src;
    assign cycle_csr_src = trace_mode
        ? (minstret + {63'd0, (retire_instr & ~exception)} + 64'd1)
        : mcycle;
    // instret_csr_src: same pipeline correction as cycle_csr_src but for
    // instret/minstret reads.  In normal operation returns minstret as-is
    // (retired instruction count).  In trace mode applies the same +2
    // adjustment so the returned value equals N for the Nth instruction,
    // matching the software simulator (which returns N for every csrrs instret).
    logic [63:0] instret_csr_src;
    assign instret_csr_src = trace_mode
        ? (minstret + {63'd0, (retire_instr & ~exception)} + 64'd1)
        : minstret;
`else
    logic [63:0] cycle_csr_src;
    assign cycle_csr_src = mcycle;  // In synthesis, always use real cycle count
    logic [63:0] instret_csr_src;
    assign instret_csr_src = minstret;  // In synthesis, always use real instret
`endif

    assign mtvec = mtvec_r;
    assign mepc_o = mepc;

    // MSTATUS fields
    logic mie_en;   // Machine Interrupt Enable
    logic mpie;     // Previous MIE

    assign mie_en = mstatus[3];
    assign mpie   = mstatus[7];

    // MIE/MIP fields
    logic mtie, msie, meie;  // Timer, Software, External interrupt enable
    logic mtip, msip, meip;  // Timer, Software, External interrupt pending

    assign mtie = mie[7];
    assign msie = mie[3];
    assign meie = mie[11];

    assign mtip = timer_irq;
    assign msip = software_irq;
    assign meip = external_irq;

    always_comb begin
        mip = 32'd0;
        mip[7]  = mtip;
        mip[3]  = msip;
        mip[11] = meip;
    end

    // Interrupt detection
    logic [31:0] pending_irqs;
    assign pending_irqs = mie & mip;

    `ifdef DEBUG
    logic prev_irq_pending;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_irq_pending <= 1'b0;
        end else begin
            prev_irq_pending <= irq_pending;
            if (irq_pending && !prev_irq_pending) begin
                `DBG2(("[CSR] irq_pending asserted: cause=0x%h mie=0x%h mip=0x%h mie_en=%b",
                       irq_cause, mie, mip, mie_en));
            end
        end
    end
    `endif

    always_comb begin
        irq_pending = mie_en && (|pending_irqs);

        // Priority: MEI > MSI > MTI
        if (pending_irqs[11]) begin
            irq_cause = 32'h8000000B;  // Machine external interrupt
        end else if (pending_irqs[3]) begin
            irq_cause = 32'h80000003;  // Machine software interrupt
        end else if (pending_irqs[7]) begin
            irq_cause = 32'h80000007;  // Machine timer interrupt
        end else begin
            irq_cause = 32'd0;
        end
    end

    // CSR read
    always_comb begin
        csr_illegal = 1'b0;
        case (csr_addr)
            CSR_MSTATUS:   csr_rdata = mstatus;
            CSR_MISA:      csr_rdata = misa;
            CSR_MIE:       csr_rdata = mie;
            CSR_MTVEC:     csr_rdata = mtvec_r;
            CSR_MSCRATCH:  csr_rdata = mscratch;
            CSR_MEPC:      csr_rdata = mepc;
            CSR_MCAUSE:    csr_rdata = mcause;
            CSR_MTVAL:     csr_rdata = mtval;
            CSR_MIP:       csr_rdata = mip;
            CSR_MCYCLE:    csr_rdata = cycle_csr_src[31:0];
            CSR_MCYCLEH:   csr_rdata = cycle_csr_src[63:32];
            CSR_MINSTRET:  csr_rdata = instret_csr_src[31:0];
            CSR_MINSTRETH: csr_rdata = instret_csr_src[63:32];
            // User-mode read-only shadows (alias to machine-mode counters)
            // In trace-compare mode (trace_mode=1) cycle/time/mcycle return minstret
            // so timer CSR reads are pipeline-stall-independent and match the software
            // simulator, which always increments mcycle and minstret together.
            CSR_CYCLE:     csr_rdata = cycle_csr_src[31:0];
            CSR_CYCLEH:    csr_rdata = cycle_csr_src[63:32];
            CSR_INSTRET:   csr_rdata = instret_csr_src[31:0];
            CSR_INSTRETH:  csr_rdata = instret_csr_src[63:32];
            CSR_TIME:      csr_rdata = cycle_csr_src[31:0];   // TIME aliases to CYCLE
            CSR_TIMEH:     csr_rdata = cycle_csr_src[63:32];
            default: begin
                csr_rdata   = 32'd0;
                csr_illegal = (csr_op != 3'b0);
            end
        endcase
    end

    // CSR write
    logic [31:0] csr_wdata_final;

    always_comb begin
        case (csr_op)
            3'b001: csr_wdata_final = csr_wdata;                        // CSRRW
            3'b010: csr_wdata_final = csr_rdata | csr_wdata;            // CSRRS
            3'b011: csr_wdata_final = csr_rdata & ~csr_wdata;           // CSRRC
            3'b101: csr_wdata_final = {27'd0, csr_zimm};                // CSRRWI
            3'b110: csr_wdata_final = csr_rdata | {27'd0, csr_zimm};    // CSRRSI
            3'b111: csr_wdata_final = csr_rdata & ~{27'd0, csr_zimm};   // CSRRCI
            default: csr_wdata_final = 32'd0;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mstatus   <= 32'h0000_0000;  // Match simulator reset state
            misa      <= 32'h4014_1101;  // RV32IMASU (A+I+M+S+U, matches rv32sim/spike)
            mie       <= 32'd0;
            mtvec_r   <= 32'd0;
            mscratch  <= 32'd0;
            mepc      <= 32'd0;
            mcause    <= 32'd0;
            mtval     <= 32'd0;
            mcycle    <= 64'd0;
            minstret  <= 64'd0;
        end else begin
            // Cycle counter
            mcycle <= mcycle + 64'd1;

            // Instruction retired counter
            if (retire_instr && !exception) begin
                minstret <= minstret + 64'd1;
            end

            // Exception handling (synchronous - save PC of faulting instruction)
            if (exception) begin
                mepc           <= exception_pc;
                mcause         <= {27'd0, exception_cause};
                mtval          <= exception_tval;
                mstatus[7]     <= mstatus[3];   // MPIE <= MIE
                mstatus[3]     <= 1'b0;         // MIE  <= 0
                mstatus[12:11] <= 2'b11;        // MPP  <= M-mode (machine-mode only)
                `DBG2(("[CSR] Exception: mcause=0x%h mepc=0x%h mstatus.MIE: %b->0", {27'd0, exception_cause}, exception_pc, mstatus[3]));
            // Interrupt handling (asynchronous - save PC+4 of next instruction)
            end else if (irq_pending) begin
                mepc          <= interrupt_pc;  // PC+4 for interrupts
                mcause        <= irq_cause;
                `DBG2(("[CSR] Interrupt: mcause=0x%h mepc=0x%h mstatus.MIE: %b->0", irq_cause, interrupt_pc, mstatus[3]));
                mtval         <= 32'd0;
                mstatus[7]    <= mstatus[3];
                mstatus[3]    <= 1'b0;
                mstatus[12:11] <= 2'b11;        // MPP  <= M-mode (machine-mode only)
            end else if (mret) begin
                mstatus[3]    <= mstatus[7];    // MIE  <= MPIE
                mstatus[7]    <= 1'b1;          // MPIE <= 1
                mstatus[12:11] <= 2'b00;        // MPP  <= U-mode (spec: reset to least-privileged mode)
            end else if (csr_op != 3'b0 && !csr_illegal) begin
                case (csr_addr)
                    CSR_MSTATUS: begin
                        mstatus  <= csr_wdata_final & 32'h0000_1888;
                        `DBG2(("[CSR] Writing MSTATUS: 0x%h -> 0x%h", mstatus, csr_wdata_final & 32'h0000_1888));
                    end
                    CSR_MIE: begin
                        mie <= csr_wdata_final & 32'h0000_0888;
                        `DBG2(("[CSR] Writing MIE: 0x%h -> 0x%h", mie, csr_wdata_final & 32'h0000_0888));
                    end
                    CSR_MTVEC:     mtvec_r  <= {csr_wdata_final[31:2], 2'b00};
                    CSR_MSCRATCH:  mscratch <= csr_wdata_final;
                    CSR_MEPC:      mepc     <= {csr_wdata_final[31:2], 2'b00};
                    CSR_MCAUSE:    mcause   <= csr_wdata_final;
                    CSR_MTVAL:     mtval    <= csr_wdata_final;
                    CSR_MCYCLE:    mcycle[31:0]  <= csr_wdata_final;
                    CSR_MCYCLEH:   mcycle[63:32] <= csr_wdata_final;
                    CSR_MINSTRET:  minstret[31:0]  <= csr_wdata_final;
                    CSR_MINSTRETH: minstret[63:32] <= csr_wdata_final;
                    default: ;
                endcase
            end
        end
    end

endmodule

// ============================================================================
// File: rv32_core.sv
// Project: RV32 RISC-V Processor
// Description: RV32IMA Processor Core with 5-Stage Pipeline
//
// Implements the RISC-V RV32IMA instruction set architecture:
//   - RV32I: Base integer instruction set
//   - M extension: Integer multiplication and division
//   - A extension: Atomic instructions
//   - Machine mode CSRs and exception handling
//   - Precise exceptions
//
// Pipeline Stages:
//   IF (Instruction Fetch)  - Fetch instruction from memory
//   ID (Instruction Decode) - Decode instruction and read registers
//   EX (Execute)            - Execute ALU operation, compute branch target
//   MEM (Memory Access)     - Access data memory for loads/stores
//   WB (Write Back)         - Write results back to register file
//
// Features:
//   - Instruction buffer (configurable depth) to track outstanding instruction fetches
//   - Store buffer (configurable depth) to allow stores to complete asynchronously
//   - Data forwarding to resolve RAW hazards
//   - Pipeline stalls for load-use hazards and memory backpressure
//   - Branch prediction: always not-taken (flush on misprediction)
//   - Exception handling with precise exception support
//   - Performance counters for cycle, instruction, and stall counts
//
// Parameters:
//   - IB_DEPTH: Instruction buffer depth (default=2), higher allows more outstanding fetches
//   - SB_DEPTH: Store buffer depth (default=4), higher allows more buffered stores
//   - FAST_DIV: Division mode (default=1)
//     - 1: Combinatorial divide (single cycle, larger area)
//     - 0: Serial divider (33 cycles, smaller area)
// ============================================================================

module rv32_core #(
    parameter int IB_DEPTH = 4,  // Instruction buffer depth (outstanding fetches); must be power-of-2 and >= effective_latency+1
    parameter int SB_DEPTH = 4,  // Store buffer depth (buffered stores)
    parameter int FAST_DIV = 1   // Division mode: 1=combinatorial, 0=serial
)(
    input  logic        clk,
    input  logic        rst_n,

    // Instruction memory interface
    output logic        imem_req_valid,
    output logic [31:0] imem_req_addr,
    input  logic        imem_req_ready,

    input  logic        imem_resp_valid,
    input  logic [31:0] imem_resp_data,
    input  logic        imem_resp_error,
    output logic        imem_resp_ready,

    // Data memory interface
    output logic        dmem_req_valid,
    output logic [31:0] dmem_req_addr,
    output logic [3:0]  dmem_req_we,
    output logic [31:0] dmem_req_wdata,
    input  logic        dmem_req_ready,

    input  logic        dmem_resp_valid,
    input  logic [31:0] dmem_resp_data,
    input  logic        dmem_resp_error,
    input  logic        dmem_resp_is_write, // 1=B response (store complete), 0=R response (load data)
    output logic        dmem_resp_ready,

    // Interrupts
    input  logic        timer_irq,
    input  logic        external_irq,
    input  logic        software_irq,

    // Performance counters
    output logic [63:0] cycle_count,
    output logic [63:0] instret_count,
    output logic [63:0] stall_count,
    output logic [63:0] first_retire_cycle,
    output logic [63:0] last_retire_cycle,

`ifndef SYNTHESIS
    // Timeout detection (simulation only)
    output logic        timeout_error,
    // Expose retire pulse so axi_clint can advance mtime per instruction
    // in trace mode, keeping mtime identical to the software simulator.
    output logic        retire_instr_out,
    // Expose WB-stage store signals so the CLINT can immediately update its
    // registers (specifically MSIP) when a store to those addresses retires,
    // matching the single-cycle store latency the software simulator assumes.
    output logic        wb_store_out,       // retiring store (retire_instr & mem_write_wb)
    output logic [31:0] wb_store_addr_out,  // store address (alu_result_wb)
    output logic [31:0] wb_store_data_out,  // store data word (store_data_wb pre-encoded)
    output logic [3:0]  wb_store_strb_out,  // store byte enables
    // Trace-compare mode: when asserted, cycle/time CSR reads return minstret
    // instead of mcycle, making them pipeline-stall-independent and identical
    // to what the software simulator returns (see rv32_csr.sv for details).
    input  logic        trace_mode
`endif
);

    import rv32_pkg::*;

    // Timeout for detecting pipeline deadlocks (simulation only)
    localparam int STALL_TIMEOUT = 200;  // Cycles before timeout assertion

    // ====== Performance Counters ======
    logic [63:0] cycle_counter;
    logic [63:0] instret_counter;
    logic [63:0] stall_counter;
    logic [63:0] first_retire_cycle_reg;  // Cycle when first instruction retires
    logic [63:0] last_retire_cycle_reg;   // Cycle when last instruction retires
    logic        started_retiring;         // Set when first instruction retires
    logic [31:0] last_retired_pc;          // Track last retired PC to avoid duplicates
    logic [31:0] last_retired_instr;       // Track last retired instruction
    logic        last_wb_valid;            // Track if WB was valid last cycle

    assign cycle_count = cycle_counter;
    assign instret_count = instret_counter;
    assign stall_count = stall_counter;
    assign first_retire_cycle = first_retire_cycle_reg;
    assign last_retire_cycle = last_retire_cycle_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_counter <= 64'd0;
            instret_counter <= 64'd0;
            stall_counter <= 64'd0;
            first_retire_cycle_reg <= 64'd0;
            last_retire_cycle_reg <= 64'd0;
            started_retiring <= 1'b0;
            last_retired_pc <= 32'd0;
            last_retired_instr <= 32'd0;
            last_wb_valid <= 1'b0;
        end else begin
            cycle_counter <= cycle_counter + 64'd1;
            // Increment instruction counter on retirement
            if (retire_instr) begin
                instret_counter <= instret_counter + 64'd1;
                last_retire_cycle_reg <= cycle_counter;  // Latch current cycle
                if (!started_retiring) begin
                    first_retire_cycle_reg <= cycle_counter;
                    started_retiring <= 1'b1;
                end
                // Update last retired instruction when it actually retires
                last_retired_pc <= pc_wb;
                last_retired_instr <= instr_wb;
            end
            last_wb_valid <= wb_valid;
            if (id_ex_stall) begin
                stall_counter <= stall_counter + 64'd1;
            end
        end
    end

`ifndef SYNTHESIS
    // Timeout detection - flag if no instructions retire for STALL_TIMEOUT cycles
    logic [31:0] cycles_since_retire;
    logic        timeout_error_reg;

    assign timeout_error = timeout_error_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycles_since_retire <= 32'd0;
            timeout_error_reg <= 1'b0;
        end else begin
            if (retire_instr || (wb_valid && !mem_wb_stall)) begin
                // Reset counter when instruction retires OR WB advances to new instruction
                cycles_since_retire <= 32'd0;
            end else if (started_retiring && !timeout_error_reg) begin
                // Only count after first instruction and before timeout
                cycles_since_retire <= cycles_since_retire + 32'd1;
                if (cycles_since_retire >= STALL_TIMEOUT) begin
                    timeout_error_reg <= 1'b1;
                    // Do not handle the timeout here; delegate it to the testbench.
                    //$error("TIMEOUT: No instructions retired for %0d cycles", STALL_TIMEOUT);
                    `DBG1(("TIMEOUT ERROR: PC=0x%h, outstanding_reqs=%0d, if_valid=%b",
                           pc_if, ib_outstanding, if_valid));
                    `DBG1(("  FETCH STATE: imem_req_valid=%b imem_req_ready=%b imem_resp_valid=%b",
                           imem_req_valid, imem_req_ready, imem_resp_valid));
                    `DBG1(("  DEDUP STATE: last_issued_valid=%b last_issued_pc=0x%h ib_resp_discard=%b",
                           last_issued_valid, last_issued_fetch_pc, ib_resp_discard));
                    `DBG1(("  PIPELINE: if_id_stall=%b non_branch_flush=%b if_flush=%b",
                           if_id_stall, non_branch_flush, if_flush));
                    `DBG1(("  IMEM: req_addr=0x%h resp_pc=0x%h fetch_issued_for_effective_pc=%b",
                           imem_req_addr, ib_resp_pc, fetch_issued_for_effective_pc));
                end
            end
        end
    end
`endif

    // ====== Fetch Stage (IF) ======
    // The fetch stage reads instructions from memory using the program counter.
    // It handles instruction buffer management and PC updates.
    logic [31:0] pc_if;          // Program counter in fetch stage
    logic [31:0] pc_next;        // Next sequential PC (pc_if + 4)
    logic [31:0] instr_if;       // Instruction fetched from memory
    logic        if_valid;       // Valid instruction available
    logic        if_id_stall;    // Stall IF/ID pipeline register
    logic        if_flush;       // Flush IF stage (on branch/exception)

    // ====== Decode Stage (ID) ======
    // The decode stage decodes the instruction, generates control signals,
    // reads source registers from the register file, and detects hazards.
    logic [31:0] pc_id;                  // Program counter in decode stage
    logic [31:0] instr_id;               // Instruction being decoded
    logic        id_valid;               // Valid instruction in decode stage
    logic        instr_access_fault_id;  // Instruction fetch error from IF stage
    logic [4:0]  rs1_addr, rs2_addr, rd_addr_id;
    logic [31:0] rs1_data, rs2_data;
    logic [31:0] imm_id;
    alu_op_e     alu_op_id;
    logic        alu_src_id;
    logic        reg_we_id;
    logic        mem_read_id, mem_write_id;
    mem_op_e     mem_op_id;
    logic        branch_id, jal_id, jalr_id;
    branch_op_e  branch_op_id;
    logic        lui_id, auipc_id;
    logic        system_id, illegal_id;
    logic [2:0]  csr_op_id;
    logic [11:0] csr_addr_id;
    logic        is_mret_id, is_ecall_id, is_ebreak_id;
    logic        is_amo_id;
    amo_op_e     amo_op_id;
    logic        is_fence_id;
    logic        id_ex_stall;
    logic        id_flush;

    // ====== Execute Stage (EX) ======
    // The execute stage performs ALU operations, computes branch targets,
    // evaluates branch conditions, and handles data forwarding.
    logic [31:0] pc_ex;                  // Program counter in execute stage
    logic [31:0] instr_ex;               // Instruction being executed
    logic        instr_access_fault_ex;  // Instruction fetch error propagated from ID
    logic [31:0] rs1_data_ex, rs2_data_ex;
    logic [31:0] imm_ex;
    logic [4:0]  rd_addr_ex;
    logic [4:0]  rs1_addr_ex, rs2_addr_ex;
    alu_op_e     alu_op_ex;
    logic        alu_src_ex;
    logic        reg_we_ex;
    logic        mem_read_ex, mem_write_ex;
    mem_op_e     mem_op_ex;
    logic        branch_ex, jal_ex, jalr_ex;
    branch_op_e  branch_op_ex;
    logic        lui_ex, auipc_ex;
    logic        system_ex, illegal_ex;
    logic [2:0]  csr_op_ex;
    logic [11:0] csr_addr_ex;
    logic        is_mret_ex, is_ecall_ex, is_ebreak_ex;
    logic        is_amo_ex;
    amo_op_e     amo_op_ex;
    logic        is_fence_ex;
    logic [31:0] alu_result_ex;
    logic        alu_ready;
    logic        branch_taken;
    logic [31:0] branch_target;
    logic        ex_valid;
    logic        ex_mem_stall;
    logic        ex_flush;

    // ====== Memory Stage (MEM) ======
    // The memory stage handles load and store operations, interfaces with
    // the data memory system, and manages the store buffer.
    logic [31:0] pc_mem;                 // Program counter in memory stage
    logic [31:0] instr_mem;              // Instruction in memory stage
    logic [31:0] alu_result_mem;         // ALU result (address for loads/stores)
    logic [31:0] rs1_data_mem;
    logic [31:0] rs2_data_mem;
    logic [4:0]  rs1_addr_mem;
    logic [4:0]  rd_addr_mem;
    logic        reg_we_mem;
    logic        mem_read_mem;
    logic        mem_write_mem;
    mem_op_e     mem_op_mem;
    logic        system_mem;
    logic [2:0]  csr_op_mem;
    logic [11:0] csr_addr_mem;
    logic        is_amo_mem;
    amo_op_e     amo_op_mem;
    logic        is_fence_mem;
    logic        mem_valid;
    logic        mem_wb_stall;
    logic        mem_flush;
    logic        data_access_fault_mem;  // Load/store access error

    // ====== Atomic Memory Operation (AMO) State ======
    // AMO operations require read-modify-write sequence:
    //   1. Read current value from memory (returned to rd)
    //   2. Compute new value using AMO operation
    //   3. Write new value back to memory
    typedef enum logic [1:0] {
        AMO_IDLE,      // No AMO operation in progress
        AMO_READ,      // Waiting for read response
        AMO_WRITE      // Waiting for write response
    } amo_state_e;
    amo_state_e  amo_state;
    logic        amo_started;            // Flag: AMO operation started for current instruction
    logic        sc_success;             // SC operation succeeded (reservation was valid)
    logic [31:0] amo_addr;               // AMO operation address
    logic [31:0] amo_read_data;          // Data read from memory
    logic [31:0] amo_write_data;         // Data to write back
    logic [31:0] amo_result;             // Final result for rd register

    // LR/SC (Load-Reserved/Store-Conditional) reservation tracking
    logic        lr_valid;               // Reservation is valid
    logic [31:0] lr_addr;                // Reserved address

    // ====== Writeback Stage (WB) ======
    // The writeback stage writes results back to the register file and
    // handles late-arriving exceptions (e.g., from memory responses).
    logic [31:0] pc_wb;                  // Program counter in writeback stage
    logic [31:0] instr_wb;               // Instruction in writeback stage
    logic [31:0] alu_result_wb;          // ALU result to write back
    logic [31:0] mem_data_wb;
    logic [4:0]  rd_addr_wb;
    logic        reg_we_wb;
    logic        mem_read_wb;
    logic        mem_write_wb;
    logic [31:0] store_data_wb;
    logic [31:0] csr_wdata_wb;
    logic [4:0]  csr_zimm_wb;
    logic [2:0]  csr_op_wb;
    logic [11:0] csr_addr_wb;
    logic [31:0] csr_rdata_wb;
    logic        is_amo_wb;
    amo_op_e     amo_op_wb;
    logic        wb_valid;
    logic        data_access_fault_wb;  // Load/store access error in WB
    logic [31:0] wb_write_data;         // Final WB data (mem/alu/csr)

    // ====== Control and Status Registers (CSRs) ======
    // Machine-mode CSRs for exception handling and system control
    logic [31:0] csr_rdata;              // CSR read data
    logic        csr_illegal;            // Illegal CSR access detected
    logic [31:0] mtvec, mepc;            // Machine trap vector and exception PC
    logic        exception;
    logic [4:0]  exception_cause;
    logic [31:0] exception_pc;
    logic [31:0] exception_tval;
    logic [31:0] interrupt_pc;           // PC+4 for async interrupts
    logic        wb_exception;         // Exception from WB stage
    logic [4:0]  wb_exception_cause;
    logic [31:0] wb_exception_pc;
    logic [31:0] wb_exception_tval;
    logic        irq_pending;
    logic [31:0] irq_cause;
    logic        retire_instr;

`ifndef SYNTHESIS
    assign retire_instr_out    = retire_instr;
    // Expose retiring store signals for trace-mode CLINT bypass.
    // Fires on the same cycle as retire_instr when a store instruction retires.
    assign wb_store_out        = retire_instr && mem_write_wb;
    assign wb_store_addr_out   = alu_result_wb;
    assign wb_store_data_out   = store_data_wb;
    assign wb_store_strb_out   = 4'b1111; // Stores are always full-word writes for MMIO
`endif

    // ====== Hazard Detection and Data Forwarding ======
    // Resolve Read-After-Write (RAW) hazards by forwarding data from later
    // pipeline stages back to the execute stage.
    logic [1:0]  forward_a, forward_b;   // Forwarding control: 00=ID, 01=WB, 10=MEM
    logic [31:0] rs1_forwarded, rs2_forwarded; // Forwarded register values

    // ====== Fetch Stage Implementation ======

    // Instruction Buffer Signals
    // The instruction buffer (IB) tracks program counters for outstanding
    // instruction fetch requests. This allows the core to have multiple
    // instruction fetches in flight, improving throughput.
    logic [31:0] ib_resp_pc;             // PC associated with current response
    logic [$clog2(IB_DEPTH+1)-1:0]  ib_outstanding;  // Number of outstanding fetch requests
    logic        ib_can_accept;          // Buffer can accept new fetch request
    logic        ib_resp_discard;        // Response should be discarded (stale)

    // -------------------------------------------------------------------------
    // Fetch dedup and early-branch-target optimization
    // -------------------------------------------------------------------------
    // last_issued_fetch_pc / last_issued_valid: track the exact PC we last
    // issued a fetch for.  Suppress a new fetch only when the effective PC
    // matches what was already in-flight.  This replaces the older
    // fetch_issued_for_current_pc + pc_if_prev approach, which could not
    // handle the early-branch case cleanly.
    logic [31:0] last_issued_fetch_pc;
    logic        last_issued_valid;

    // IF stage outputs
    assign if_valid = imem_resp_valid && !if_flush && !ib_resp_discard;
    assign instr_if = if_valid ? imem_resp_data : 32'h00000013; // NOP on invalid
    // Consume responses when pipeline not stalled OR when discarding flushed requests
    assign imem_resp_ready = !if_id_stall || ib_resp_discard;

    // Early-branch-target fetch:
    //   On the same cycle branch_taken=1, override imem_req_addr with
    //   branch_target and allow the fetch to proceed (bypassing !if_flush).
    //   The memory AR channel is combinational (mem_axi_ro bypass), so the
    //   response arrives one cycle later, reducing branch penalty from 3→2.
    //
    //   For non-branch flushes (exception / irq / mret) the old PC is not
    //   yet valid, so we still block.
    logic        non_branch_flush;        // exception / irq / mret flush (not branch)
    logic        fetch_issued_for_effective_pc;
    logic [31:0] imem_req_addr_comb;      // combinational fetch address
    logic        imem_req_valid_comb;     // combinational fetch valid (before gating)

    assign non_branch_flush = exception || irq_pending || is_mret_ex;

    // dedup_consuming: the current pc_if is already in-flight and its
    // response is arriving this cycle.  In this case pc_if will advance to
    // pc_next at the end of this cycle, so we should issue for pc_next
    // immediately rather than waiting for the flip-flop update.
    //
    // IMPORTANT: gate on imem_req_ready.  If the memory system cannot
    // accept a new request right now, asserting imem_req_valid for pc_next
    // and then dropping it next cycle (when dedup_consuming=0) violates the
    // handshake rule "valid must stay high until ready".  When the memory is
    // busy, fall back to the one-cycle-stall path (Consumed-no-issue + normal
    // sequential issue next cycle) which is always correct.
    logic dedup_consuming;
    assign dedup_consuming = last_issued_valid &&
                             (pc_if == last_issued_fetch_pc) &&
                             imem_resp_valid && imem_resp_ready && !ib_resp_discard &&
                             !if_flush &&
                             imem_req_ready;  // only look-ahead when mem can take it now

    // imem_req_addr / imem_req_valid:
    //   Combinational address and valid.
    //   - branch cycle: use branch_target for early fetch
    //   - dedup-consume: use pc_next (pc_if is about to advance this cycle)
    //   - otherwise: use current pc_if
    assign imem_req_addr_comb = (branch_taken && !branch_flushed) ? branch_target :
                                dedup_consuming                   ? pc_next :
                                                                   pc_if;

    // Dedup: suppress if we already issued for this exact address.
    assign fetch_issued_for_effective_pc = last_issued_valid &&
                                           (imem_req_addr == last_issued_fetch_pc);

    // Gate: always allow on branch cycle (early target fetch); block only on
    // exception/irq/mret flushes, dedup, and when the memory bus is not ready.
    //
    // AXI handshake compliance (rule A3.2.1): valid must not be deasserted before
    // ready.  Gating valid on imem_req_ready ensures we only assert valid during
    // the exact cycle the channel is ready to accept, so valid is never held in
    // a blocked state.  This is zero-cost performance-wise because the handshake
    // completes in the same cycle regardless.
    assign imem_req_valid_comb = ib_can_accept && !non_branch_flush &&
                                 !fetch_issued_for_effective_pc &&
                                 imem_req_ready;

    assign imem_req_valid = imem_req_valid_comb;
    assign imem_req_addr  = imem_req_addr_comb;

    // ====== Fetch Request Lifecycle Debug Tracing ======
    `ifdef DEBUG
    always_ff @(posedge clk) begin
        if (rst_n) begin
            // Track fetch request issuance
            if (imem_req_valid && imem_req_ready) begin
                `DBG2(("[FETCH_REQ] Issued: pc=0x%h, outstanding=%0d->%0d, can_accept=%b",
                       imem_req_addr, ib_outstanding, ib_outstanding + 1'b1, ib_can_accept));
            end else if (imem_req_valid && !imem_req_ready) begin
                `DBG2(("[FETCH_REQ] Blocked: pc=0x%h, outstanding=%0d, can_accept=%b, imem_req_ready=%b",
                       imem_req_addr, ib_outstanding, ib_can_accept, imem_req_ready));
            end else if (!imem_req_valid && ib_can_accept && !non_branch_flush) begin
                `DBG2(("[FETCH_REQ] Suppressed: pc=0x%h already fetched (last=0x%h valid=%b)",
                       imem_req_addr, last_issued_fetch_pc, last_issued_valid));
            end else if (!imem_req_valid && !ib_can_accept) begin
                `DBG2(("[FETCH_REQ] IB Full: pc=0x%h, outstanding=%0d, can_accept=%b",
                       imem_req_addr, ib_outstanding, ib_can_accept));
            end else if (!imem_req_valid && non_branch_flush) begin
                `DBG2(("[FETCH_REQ] Flushed(exc/irq): pc=0x%h, non_branch_flush=%b", pc_if, non_branch_flush));
            end

            // Track fetch response arrival
            if (imem_resp_valid) begin
                if (ib_resp_discard) begin
                    `DBG2(("[FETCH_RESP] Arrived (DISCARD): pc=0x%h, data=0x%h, error=%b, outstanding=%0d",
                           ib_resp_pc, imem_resp_data, imem_resp_error, ib_outstanding));
                end else begin
                    `DBG2(("[FETCH_RESP] Arrived (VALID): pc=0x%h, data=0x%h, error=%b, outstanding=%0d",
                           ib_resp_pc, imem_resp_data, imem_resp_error, ib_outstanding));
                end
            end

            // Track fetch response consumption
            if (imem_resp_valid && imem_resp_ready) begin
                if (ib_resp_discard) begin
                    `DBG2(("[FETCH_CONSUME] Discarded: pc=0x%h, if_flush=%b, ib_resp_discard=%b",
                           ib_resp_pc, if_flush, ib_resp_discard));
                end else if (!if_id_stall) begin
                    `DBG2(("[FETCH_CONSUME] Consumed: pc=0x%h, instr=0x%h, advancing to ID",
                           ib_resp_pc, imem_resp_data));
                end else begin
                    `DBG2(("[FETCH_CONSUME] Stalled: pc=0x%h, if_id_stall=%b",
                           ib_resp_pc, if_id_stall));
                end
            end else if (imem_resp_valid && !imem_resp_ready) begin
                `DBG2(("[FETCH_CONSUME] Held: pc=0x%h, if_id_stall=%b, resp_ready=%b",
                       ib_resp_pc, if_id_stall, imem_resp_ready));
            end

            // Track IF stage state
            if (if_valid && !if_id_stall) begin
                `DBG2(("[FETCH_IF] Valid instruction ready: pc=0x%h, instr=0x%h, outstanding=%0d",
                       ib_resp_pc, instr_if, ib_outstanding));
            end
        end
    end
    `endif

    // Fetch dedup tracking register.
    // Priority: if a fetch is issued this cycle, record it even if a flush is
    // happening simultaneously (the branch-target early-fetch case).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_issued_fetch_pc <= 32'hFFFF_FFFF;
            last_issued_valid    <= 1'b0;
        end else if (imem_req_valid && imem_req_ready) begin
            // Fetch accepted this cycle - record which PC was issued.
            // This takes priority over the flush clear so that the early
            // branch-target fetch (cycle N) properly suppresses a duplicate
            // on cycle N+1 when pc_if settles to branch_target.
            last_issued_fetch_pc <= imem_req_addr;
            last_issued_valid    <= 1'b1;
            `DBG2(("[FETCH_PC] Issued for pc=0x%h (branch_early=%b)",
                   imem_req_addr, branch_taken && !branch_flushed));
        end else if (if_flush || (ib_outstanding == '0 && !imem_resp_valid)) begin
            // Flush without a simultaneous new issue: allow re-fetch.
            // Also clear when IB is empty and no response is arriving — nothing
            // is in-flight, so last_issued_valid would permanently block fetches.
            last_issued_valid <= 1'b0;
            `DBG2(("[FETCH_PC] Flush/empty: clearing issue-tracking, pc=0x%h flush=%b out=%0d",
                   pc_if, if_flush, ib_outstanding));
        end
        // No change otherwise: stall or sequential with pending response.
    end

    // Instruction Buffer Instance
    // Configurable depth allows multiple outstanding instruction fetch requests
    rv32_ib #(
        .DEPTH(IB_DEPTH),
        .ADDR_WIDTH(32)
    ) instruction_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .req_valid(imem_req_valid),
        .req_addr(imem_req_addr),   // may be branch_target on early-branch cycle
        .req_ready(imem_req_ready),
        .can_accept(ib_can_accept),
        .resp_valid(imem_resp_valid),
        .resp_addr(ib_resp_pc),
        .resp_discard(ib_resp_discard),
        .resp_consume(imem_resp_valid && imem_resp_ready),
        .flush(if_flush),
        .outstanding_count(ib_outstanding)
    );

    // Program Counter (PC) Update Logic
    // Priority (highest to lowest):
    //   1. Exception/Interrupt -> mtvec
    //   2. MRET instruction -> mepc
    //   3. Branch taken -> branch_target
    //   4. Sequential -> pc_if + 4
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_if <= 32'h8000_0000;  // Reset vector (RISC-V standard)
        end else begin
            if (wb_exception || exception || irq_pending) begin
                // Exception or interrupt: jump to trap handler
                pc_if <= mtvec;
                `DBG2(("[FETCH_PC] EXCEPTION/IRQ: pc=0x%h -> mtvec=0x%h (exc=%b wb_exc=%b irq=%b), outstanding=%0d",
                       pc_if, mtvec, exception, wb_exception, irq_pending, ib_outstanding));
            end else if (is_mret_ex) begin
                // Return from trap: jump to saved exception PC
                pc_if <= mepc;
                `DBG2(("[FETCH_PC] MRET: pc=0x%h -> mepc=0x%h, outstanding=%0d", pc_if, mepc, ib_outstanding));
            end else if (branch_taken && !branch_flushed) begin
                // Branch/jump taken: update to target address.
                // Guard with !branch_flushed to avoid re-redirecting on stall cycles
                // (branch_flushed prevents duplicate flushes when branch stays in EX).
                pc_if <= branch_target;
                `DBG2(("[FETCH_PC] BRANCH: pc=0x%h -> target=0x%h, outstanding=%0d",
                       pc_if, branch_target, ib_outstanding));
            end else begin
                if (imem_req_ready && imem_req_valid) begin
                    // Fetch accepted: advance to the PC after what was issued.
                    // Normally imem_req_addr==pc_if so we advance by 4.
                    // In the dedup_consuming case imem_req_addr==pc_next (pc_if+4),
                    // so we advance by 8 (next after the issued address).
                    pc_if <= imem_req_addr + 32'd4;
                    `DBG2(("[FETCH_PC] Sequential: pc=0x%h -> 0x%h (issued=0x%h), outstanding=%0d",
                           pc_if, imem_req_addr + 32'd4, imem_req_addr, ib_outstanding));
                end else if (!imem_req_valid && dedup_consuming) begin
                    // Dedup suppression with no new fetch issued.
                    // dedup_consuming=1: the response arriving this cycle IS for pc_if,
                    // so it is safe to advance pc_if to pc_next.
                    // (IB full or some other block prevented issuing for pc_next)
                    // dedup_consuming already checks imem_req_ready, imem_resp_valid,
                    // imem_resp_ready, !ib_resp_discard, !if_flush.
                    // IMPORTANT: do NOT advance pc_if when a response arrives for an
                    // earlier in-flight PC while pc_if itself has not yet been fetched.
                    pc_if <= pc_next;
                    `DBG2(("[FETCH_PC] Consumed(no-issue): pc=0x%h -> 0x%h, outstanding=%0d",
                           pc_if, pc_next, ib_outstanding));
                end else if (imem_req_valid && !imem_req_ready) begin
                    // PC update blocked by memory system backpressure
                    `DBG2(("[FETCH_PC] BLOCKED: pc=0x%h (imem ready=0), outstanding=%0d",
                           pc_if, ib_outstanding));
                end
            end
        end
    end

    assign pc_next = pc_if + 32'd4;  // Next sequential address (not branch_target based)

    // ============================================================================
    // IF/ID Pipeline Register
    // ============================================================================
    // Latches instruction and PC from fetch stage to decode stage.
    // Can be flushed on branch misprediction or exception.
    // IF/ID Pipeline Register
    // ============================================================================
    // Latches instruction and PC from fetch stage to decode stage.
    // Can be flushed on branch misprediction or exception.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_id     <= 32'd0;
            instr_id  <= 32'h00000013;
            id_valid  <= 1'b0;
            instr_access_fault_id <= 1'b0;
        end else if (if_flush || id_flush) begin
            instr_id  <= 32'h00000013;
            id_valid  <= 1'b0;
            instr_access_fault_id <= 1'b0;
            if (if_flush || id_flush) begin
                `DBG2(("[FETCH_PIPE] IF/ID flush - if_flush=%b id_flush=%b", if_flush, id_flush));
            end
        end else if (!if_id_stall && if_valid) begin
            // Only update when pipeline advances AND we have a valid instruction
            pc_id     <= ib_resp_pc;  // Use PC from instruction buffer
            instr_id  <= instr_if;
            id_valid  <= 1'b1;
            instr_access_fault_id <= imem_resp_valid && imem_resp_error;
            `DBG2(("[FETCH_PIPE] IF->ID: pc=0x%h instr=0x%h error=%b outstanding=%0d",
                   ib_resp_pc, instr_if, imem_resp_error, ib_outstanding));
        end else if (!if_id_stall && !if_valid) begin
            // Pipeline advances but no valid instruction, insert bubble
            id_valid <= 1'b0;
            `DBG2(("[FETCH_PIPE] IF->ID: BUBBLE (no valid instruction), outstanding=%0d", ib_outstanding));
        end else if (if_id_stall && if_valid) begin
            // Valid instruction but pipeline stalled
            `DBG2(("[FETCH_PIPE] IF/ID STALL: pc=0x%h instr=0x%h, outstanding=%0d",
                   ib_resp_pc, instr_if, ib_outstanding));
        end
    end

    // ============================================================================
    // Decode Stage Implementation
    // ============================================================================

    // Instruction Decoder
    // Decodes 32-bit RISC-V instruction into control signals and immediate values
    rv32_decoder decoder (
        .instr(instr_id),
        .valid(id_valid),
        .rs1_addr(rs1_addr),
        .rs2_addr(rs2_addr),
        .rd_addr(rd_addr_id),
        .imm(imm_id),
        .alu_op(alu_op_id),
        .alu_src(alu_src_id),
        .reg_we(reg_we_id),
        .mem_read(mem_read_id),
        .mem_write(mem_write_id),
        .mem_op(mem_op_id),
        .branch(branch_id),
        .branch_op(branch_op_id),
        .jal(jal_id),
        .jalr(jalr_id),
        .lui(lui_id),
        .auipc(auipc_id),
        .system(system_id),
        .illegal(illegal_id),
        .csr_op(csr_op_id),
        .csr_addr(csr_addr_id),
        .is_mret(is_mret_id),
        .is_ecall(is_ecall_id),
        .is_ebreak(is_ebreak_id),
        .is_amo(is_amo_id),
        .amo_op(amo_op_id),
        .is_fence(is_fence_id)
    );

    // Register File (32 x 32-bit registers)
    // x0 is hardwired to zero, x1-x31 are general purpose registers
    // Supports 2 read ports (rs1, rs2) and 1 write port (rd)
    // Register writes only happen when instruction retires (retire_instr)
    // to prevent duplicate writes when instruction stalls in WB stage
    always_comb begin
        if (is_amo_wb) begin
            // AMO: Write the original value (before modification)
            wb_write_data = mem_data_wb;  // AMO result captured from amo_result
        end else if (mem_read_wb) begin
            wb_write_data = mem_data_wb;
        end else if (csr_op_wb != 3'd0) begin
            wb_write_data = csr_rdata_wb;
        end else begin
            wb_write_data = alu_result_wb;
        end
    end

    rv32_regfile regfile (
        .clk(clk),
        .rst_n(rst_n),
        .rs1_addr(rs1_addr),
        .rs1_data(rs1_data),
        .rs2_addr(rs2_addr),
        .rs2_data(rs2_data),
        .we(reg_we_wb && retire_instr),
        .rd_addr(rd_addr_wb),
        .rd_data(wb_write_data)
    );

    `ifdef DEBUG
    always_ff @(posedge clk) begin
        if (rst_n && reg_we_wb && retire_instr && (rd_addr_wb != 5'd0)) begin
            `DBG2(("[REG_WRITE] PC=0x%h instr=0x%h rd=x%0d we=%b retire=%b data=0x%h (from %s)",
                   pc_wb, instr_wb, rd_addr_wb, reg_we_wb, retire_instr,
                   wb_write_data,
                   mem_read_wb ? "mem" : (csr_op_wb != 3'd0 ? "csr" : "alu")));
        end
        if (rst_n && wb_valid && reg_we_wb && !retire_instr && (rd_addr_wb != 5'd0)) begin
            `DBG2(("[REG_WRITE_BLOCKED] PC=0x%h instr=0x%h rd=x%0d: we=%b but retire=%b (reg not written)",
                   pc_wb, instr_wb, rd_addr_wb, reg_we_wb, retire_instr));
            `DBG2(("[REG_WRITE_BLOCKED]   retire_base=%b wb_valid=%b wb_except=%b pc_match=%b instr_match=%b",
                   wb_valid && !wb_exception, wb_valid, wb_exception,
                   pc_wb == last_retired_pc, instr_wb == last_retired_instr));
            `DBG2(("[REG_WRITE_BLOCKED]   Value would be 0x%h (from %s), but available for forwarding",
                     wb_write_data,
                     mem_read_wb ? "mem" : (csr_op_wb != 3'd0 ? "csr" : "alu")));
        end
        if (rst_n && wb_valid && (rd_addr_wb != 5'd0) && !reg_we_wb) begin
            `DBG2(("[REG_NO_WRITE] PC=0x%h instr=0x%h rd=x%0d we=%b valid=%b mem_read=%b fault=%b",
                   pc_wb, instr_wb, rd_addr_wb, reg_we_wb, wb_valid, mem_read_wb, data_access_fault_wb));
        end
    end
    `endif

    // ============================================================================
    // Clock-cycle MEM/EX->ID Forwarding (for back-to-back dependency)
    // ============================================================================
    // When an instruction in MEM or EX writes to a register on the same cycle that
    // an instruction in ID reads it, the register file's internal forwarding
    // doesn't work because it uses registered WB signals. We need explicit
    // forwarding here.
    //
    // Critical Fix: Forward data even when pipeline is stalled (mem_wb_stall).
    // The data in MEM/EX stages remains valid during stalls, and must be
    // forwarded to prevent reading stale values from the register file.
    //
    // Forwarding Priority (highest to lowest):
    //   1. MEM stage (most recent write)
    //   2. EX stage (write in progress)
    //   3. Register file (baseline)
    logic [31:0] rs1_data_id, rs2_data_id;
    logic [31:0] wb_write_data_next;  // Data that will be in WB next cycle

    // Calculate what will be written to WB on next cycle from current MEM stage
    always_comb begin
        if (is_amo_mem) begin
            wb_write_data_next = mem_data_wb_next;  // AMO result
        end else if (mem_read_mem) begin
            wb_write_data_next=mem_data_wb_next;  // Load data
        end else if (csr_op_mem != 3'd0) begin
            wb_write_data_next = csr_rdata;  // CSR read data
        end else begin
            wb_write_data_next = alu_result_mem;  // ALU result (default)
        end
    end

    // ============================================================================
    // Stall Type Detection for Forwarding Logic
    // ============================================================================
    // Distinguish between different stall types to make correct forwarding decisions:
    //   - load_stall: Load waiting for memory response (data not valid, NO forwarding)
    //   - store_stall: Store waiting for store buffer space (data valid, YES forwarding)
    //   - amo_stall: AMO operation in progress (data not valid until complete)

    logic load_stall, store_stall, fence_stall;
    // dmem_resp_valid qualified: B-responses (dmem_resp_is_write=1) are for the store buffer,
    // not for loads. Only count R-responses as satisfying the load.
    logic load_resp_valid;
    assign load_resp_valid = dmem_resp_valid && !dmem_resp_is_write;
    assign load_stall = mem_read_mem && !is_amo_mem && (!load_req_issued || !(load_resp_valid || dmem_resp_valid_buf));
    assign store_stall = mem_write_mem && !is_amo_mem && !sb_cpu_ready;

    // ============================================================================
    // Register Forwarding: MEM->ID and WB->ID
    // ============================================================================
    // Forward register values from later pipeline stages to ID stage when:
    //   1. MEM stage has valid instruction (not a pending load)
    //   2. WB stage has unretired instruction (blocked by duplicate detection)
    //
    // Priority: MEM > WB > Register File
    //   - MEM has HIGHER priority because it holds the most recently issued write
    //     in program order. When both MEM and WB target the same register (e.g.
    //     lui a3 in WB followed by addi a3 in MEM), MEM's result is what the
    //     current instruction should see.
    //   - If WB were given higher priority, rs_data_id would be latched with the
    //     stale WB value. Then once the instruction stalls in EX (e.g. behind a
    //     slow load), the EX-stage forwarding may become unavailable (the WB
    //     instruction retires and reg_we_wb is cleared), leaving rs_data_ex with
    //     the wrong value.
    //
    // Design improvements over original:
    //   1. Correct MEM > WB priority (previous WB > MEM was wrong)
    //   2. Separate load_stall vs store_stall detection for correct forwarding decisions
    //   3. WB->ID forwarding path for instructions blocked by duplicate retirement
    //   4. Clear reg_we_wb after retirement to prevent stale forwarding
    //   5. Forward during store buffer stalls (data is valid in MEM/WB)
    //
    // Forwarding Priority: MEM > WB > RegFile.
    // MEM stage holds the most recently issued write (in program order), so it
    // must take priority over WB when both stages target the same destination
    // register (e.g. lui→addi back-to-back: lui is in WB, addi is in MEM).
    // Using WB-first priority would incorrectly latch the stale lui result into
    // rs_data_ex, causing wrong ALU input once the instruction stalls in EX.
    assign rs1_data_id = (reg_we_mem && mem_valid && !load_stall && (rd_addr_mem != 5'd0) && (rs1_addr == rd_addr_mem)) ? wb_write_data_next :
                         (reg_we_wb && (rd_addr_wb != 5'd0) && (rs1_addr == rd_addr_wb)) ? wb_write_data :
                         rs1_data;
    assign rs2_data_id = (reg_we_mem && mem_valid && !load_stall && (rd_addr_mem != 5'd0) && (rs2_addr == rd_addr_mem)) ? wb_write_data_next :
                         (reg_we_wb && (rd_addr_wb != 5'd0) && (rs2_addr == rd_addr_wb)) ? wb_write_data :
                         rs2_data;

    `ifdef DEBUG
    // Debug: log ID-stage forwarding from MEM or WB (MEM has higher priority)
    always_ff @(posedge clk) begin
        if (rst_n && id_valid && !id_ex_stall && !id_flush) begin
            // MEM->ID forwarding fired for rs1
            if (reg_we_mem && mem_valid && !load_stall && (rd_addr_mem != 5'd0) && (rs1_addr == rd_addr_mem)) begin
                `DBG2(("[ID_FWD_MEM->rs1] PC=0x%h rs1=x%0d rd_mem=x%0d wb_write_data_next=0x%h csr_op_mem=%0d mem_read_mem=%b alu_result_mem=0x%h",
                       pc_id, rs1_addr, rd_addr_mem, wb_write_data_next, csr_op_mem, mem_read_mem, alu_result_mem));
            end
            // WB->ID forwarding fired for rs1 (only when MEM doesn't match)
            if (reg_we_wb && (rd_addr_wb != 5'd0) && (rs1_addr == rd_addr_wb) &&
                !(reg_we_mem && mem_valid && !load_stall && (rd_addr_mem != 5'd0) && (rs1_addr == rd_addr_mem))) begin
                `DBG2(("[ID_FWD_WB->rs1] PC=0x%h rs1=x%0d rd_wb=x%0d wb_write_data=0x%h",
                       pc_id, rs1_addr, rd_addr_wb, wb_write_data));
            end
            // MEM->ID forwarding fired for rs2
            if (reg_we_mem && mem_valid && !load_stall && (rd_addr_mem != 5'd0) && (rs2_addr == rd_addr_mem)) begin
                `DBG2(("[ID_FWD_MEM->rs2] PC=0x%h rs2=x%0d rd_mem=x%0d wb_write_data_next=0x%h csr_op_mem=%0d mem_read_mem=%b alu_result_mem=0x%h",
                       pc_id, rs2_addr, rd_addr_mem, wb_write_data_next, csr_op_mem, mem_read_mem, alu_result_mem));
            end
            // WB->ID forwarding fired for rs2 (only when MEM doesn't match)
            if (reg_we_wb && (rd_addr_wb != 5'd0) && (rs2_addr == rd_addr_wb) &&
                !(reg_we_mem && mem_valid && !load_stall && (rd_addr_mem != 5'd0) && (rs2_addr == rd_addr_mem))) begin
                `DBG2(("[ID_FWD_WB->rs2] PC=0x%h rs2=x%0d rd_wb=x%0d wb_write_data=0x%h",
                       pc_id, rs2_addr, rd_addr_wb, wb_write_data));
            end
        end
    end
    `endif

    // ============================================================================
    // Hazard Detection: Load-Use Stalls
    // ============================================================================
    // A load-use hazard occurs when an instruction tries to use the result of
    // a load before it's available. Since loads complete in MEM stage, we must
    // stall if the current instruction reads a register being loaded by the
    // previous instruction.
    //
    // Stall conditions:
    //   1. Load-use hazard: EX stage has load and ID uses its result
    //   2. When a downstream stall occurs, we must stall upstream stages to prevent
    //      instructions from advancing past stalled stages
    //
    // Note: When mem_wb_stall occurs, instructions in MEM can't advance. We must stall
    // upstream stages, but we should NOT inject a bubble into EX for downstream stalls.
    // Only when IF/ID stalls (load-use or other reasons) AND EX can advance should we
    // inject a bubble into EX.
    logic load_use_hazard;
    logic downstream_stall;

    assign load_use_hazard = (mem_read_ex && ex_valid && (rd_addr_ex != 5'd0) &&
                              ((rd_addr_ex == rs1_addr) || (rd_addr_ex == rs2_addr)));
    assign downstream_stall = id_ex_stall || ex_mem_stall || mem_wb_stall;

    assign if_id_stall = load_use_hazard || downstream_stall;

    // Debug stall signals
    always @(posedge clk) begin
        if (if_id_stall || id_ex_stall || ex_mem_stall || mem_wb_stall) begin
            `DBG2(("STALL: if_id=%b id_ex=%b ex_mem=%b mem_wb=%b | load_use=%b alu_ready=%b ex_valid=%b",
                   if_id_stall, id_ex_stall, ex_mem_stall, mem_wb_stall, load_use_hazard, alu_ready, ex_valid));
        end
    end

    // ============================================================================
    // ID/EX Pipeline Register
    // ============================================================================
    // Latches decoded instruction and control signals from decode to execute stage.
    // Can inject bubbles (NOPs) on stalls or be flushed on branch misprediction.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_ex         <= 32'd0;
            instr_ex      <= 32'h00000013;
            instr_access_fault_ex <= 1'b0;
            rs1_data_ex   <= 32'd0;
            rs2_data_ex   <= 32'd0;
            imm_ex        <= 32'd0;
            rd_addr_ex    <= 5'd0;
            rs1_addr_ex   <= 5'd0;
            rs2_addr_ex   <= 5'd0;
            alu_op_ex     <= ALU_ADD;
            alu_src_ex    <= 1'b0;
            reg_we_ex     <= 1'b0;
            mem_read_ex   <= 1'b0;
            mem_write_ex  <= 1'b0;
            mem_op_ex     <= MEM_WORD;
            branch_ex     <= 1'b0;
            branch_op_ex  <= BRANCH_EQ;
            jal_ex        <= 1'b0;
            jalr_ex       <= 1'b0;
            lui_ex        <= 1'b0;
            auipc_ex      <= 1'b0;
            system_ex     <= 1'b0;
            illegal_ex    <= 1'b0;
            csr_op_ex     <= 3'd0;
            csr_addr_ex   <= 12'd0;
            is_mret_ex    <= 1'b0;
            is_ecall_ex   <= 1'b0;
            is_ebreak_ex  <= 1'b0;
            is_amo_ex     <= 1'b0;
            amo_op_ex     <= AMO_ADD;
            is_fence_ex   <= 1'b0;
            ex_valid      <= 1'b0;
        end else if (ex_flush) begin
            // Branch misprediction or exception: flush pipeline stage
            pc_ex         <= 32'd0;
            instr_ex      <= 32'h00000013;  // NOP
            instr_access_fault_ex <= 1'b0;
            reg_we_ex    <= 1'b0;  // Disable writes
            mem_read_ex  <= 1'b0;  // Disable memory ops
            mem_write_ex <= 1'b0;
            branch_ex    <= 1'b0;  // Disable control flow
            jal_ex       <= 1'b0;
            jalr_ex      <= 1'b0;
            system_ex    <= 1'b0;
            ex_valid     <= 1'b0;  // Mark as invalid
            `DBG2(("Cycle %0t: ID/EX flush - ex_flush=%b, blocking PC=0x%h instr=0x%h", $time, ex_flush, pc_id, instr_id));
        end else if (if_id_stall && !downstream_stall) begin
            // IF/ID stalled (e.g., load-use hazard) but EX can advance: inject bubble
            // ID is not advancing, but EX will move to MEM, so we need a NOP in EX
            reg_we_ex    <= 1'b0;
            mem_read_ex  <= 1'b0;
            mem_write_ex <= 1'b0;
            branch_ex    <= 1'b0;
            jal_ex       <= 1'b0;
            jalr_ex      <= 1'b0;
            system_ex    <= 1'b0;
            ex_valid     <= 1'b0;
        end else if (downstream_stall) begin
            // Downstream stall: hold current EX contents
            // No assignments needed; retain previous state
        end else if (id_flush) begin
            pc_ex         <= 32'd0;
            instr_ex      <= 32'h00000013;
            instr_access_fault_ex <= 1'b0;
            rs1_data_ex   <= 32'd0;
            rs2_data_ex   <= 32'd0;
            imm_ex        <= 32'd0;
            rd_addr_ex    <= 5'd0;
            rs1_addr_ex   <= 5'd0;
            rs2_addr_ex   <= 5'd0;
            alu_op_ex     <= ALU_ADD;
            alu_src_ex    <= 1'b0;
            reg_we_ex     <= 1'b0;
            mem_read_ex   <= 1'b0;
            mem_write_ex  <= 1'b0;
            mem_op_ex     <= MEM_WORD;
            branch_ex     <= 1'b0;
            branch_op_ex  <= BRANCH_EQ;
            jal_ex        <= 1'b0;
            jalr_ex       <= 1'b0;
            lui_ex        <= 1'b0;
            auipc_ex      <= 1'b0;
            system_ex     <= 1'b0;
            illegal_ex    <= 1'b0;
            csr_op_ex     <= 3'd0;
            csr_addr_ex   <= 12'd0;
            is_mret_ex    <= 1'b0;
            is_ecall_ex   <= 1'b0;
            is_ebreak_ex  <= 1'b0;
            is_amo_ex     <= 1'b0;
            amo_op_ex     <= AMO_ADD;
            is_fence_ex   <= 1'b0;
            ex_valid      <= 1'b0;
        end else if (!id_ex_stall) begin
            pc_ex         <= pc_id;
            instr_ex      <= instr_id;
            instr_access_fault_ex <= instr_access_fault_id;
            rs1_data_ex   <= rs1_data_id;  // Use forwarded data if WB->ID hazard
            rs2_data_ex   <= rs2_data_id;  // Use forwarded data if WB->ID hazard
            imm_ex        <= imm_id;
            rd_addr_ex    <= rd_addr_id;
            rs1_addr_ex   <= rs1_addr;
            rs2_addr_ex   <= rs2_addr;
            alu_op_ex     <= alu_op_id;
            alu_src_ex    <= alu_src_id;
            reg_we_ex     <= reg_we_id;
            mem_read_ex   <= mem_read_id;
            mem_write_ex  <= mem_write_id;
            mem_op_ex     <= mem_op_id;
            branch_ex     <= branch_id;
            branch_op_ex  <= branch_op_id;
            jal_ex        <= jal_id;
            jalr_ex       <= jalr_id;
            lui_ex        <= lui_id;
            auipc_ex      <= auipc_id;
            system_ex     <= system_id;
            illegal_ex    <= illegal_id;
            csr_op_ex     <= csr_op_id;
            csr_addr_ex   <= csr_addr_id;
            is_mret_ex    <= is_mret_id;
            is_ecall_ex   <= is_ecall_id;
            is_ebreak_ex  <= is_ebreak_id;
            is_amo_ex     <= is_amo_id;
            amo_op_ex     <= amo_op_id;
            is_fence_ex   <= is_fence_id;
            ex_valid      <= id_valid;
            if (id_valid) begin
                `DBG2(("Cycle %0t: ID->EX pc=0x%h instr=0x%h rd=%0d mem_w=%b mem_r=%b id_valid=%b ex_valid_next=%b",
                       $time, pc_id, instr_id, rd_addr_id, mem_write_id, mem_read_id, id_valid, id_valid));
            end
        end
    end

    // ============================================================================
    // Execute Stage Implementation
    // ============================================================================

    // Data Forwarding Logic
    // Resolves Read-After-Write (RAW) hazards by forwarding data from later
    // pipeline stages (MEM or WB) back to the execute stage.
    //
    // Forwarding priority for rs1:
    //   1. Forward from MEM stage if MEM will write to rs1
    //   2. Forward from WB stage if WB will write to rs1
    //   3. Use value from register file (no forwarding)
    //
    // Note: Forward from WB when the register will be written (retire_instr=1)
    // or when it's a load/CSR (data arrives later). After the register is written,
    // the value is available from the regfile, so forwarding is not needed.
    //
    // forward_a/forward_b encoding:
    //   00: No forwarding (use register file value)
    //   01: Forward from WB stage
    //   10: Forward from MEM stage
    always_comb begin
        forward_a = 2'b00;  // Default: no forwarding for rs1
        forward_b = 2'b00;  // Default: no forwarding for rs2

        // Forward rs1 if there's a RAW hazard
        if (reg_we_mem && (rd_addr_mem != 5'd0) && (rd_addr_mem == rs1_addr_ex)) begin
            forward_a = 2'b10;  // Forward from MEM (higher priority)
        end else if (reg_we_wb && wb_valid && !wb_exception && (rd_addr_wb != 5'd0) && (rd_addr_wb == rs1_addr_ex)) begin
            forward_a = 2'b01;  // Forward from WB (data ready and valid)
        end

        // Forward rs2 if there's a RAW hazard
        if (reg_we_mem && (rd_addr_mem != 5'd0) && (rd_addr_mem == rs2_addr_ex)) begin
            forward_b = 2'b10;  // Forward from MEM (higher priority)
        end else if (reg_we_wb && wb_valid && !wb_exception && (rd_addr_wb != 5'd0) && (rd_addr_wb == rs2_addr_ex)) begin
            forward_b = 2'b01;  // Forward from WB (data ready and valid)
        end
    end

    // Select forwarded value based on forwarding control signals
    // MEM→EX forwarding (2'b10): use csr_rdata for CSR instructions (not alu_result_mem),
    // since CSR writes csr_rdata (old CSR value) to rd, not the ALU result.
    // For all other instruction types (ALU, AMO, etc.) forward alu_result_mem as before.
    // NOTE: Loads never reach MEM→EX forwarding because load_use_hazard inserts a stall.
    logic [31:0] mem_fwd_data;
    assign mem_fwd_data = (csr_op_mem != 3'd0) ? csr_rdata : alu_result_mem;

    always_comb begin
        case (forward_a)
            2'b01:   rs1_forwarded = wb_write_data;
            2'b10:   rs1_forwarded = mem_fwd_data;
            default: rs1_forwarded = rs1_data_ex;
        endcase

        case (forward_b)
            2'b01:   rs2_forwarded = wb_write_data;
            2'b10:   rs2_forwarded = mem_fwd_data;
            default: rs2_forwarded = rs2_data_ex;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst_n && ex_valid && (forward_a != 2'd0) && (rs1_addr_ex != 5'd0)) begin
            `DBG2(("[REG_FORWARD] PC=0x%h rs1=%0d forward_a=%0d rs1_data_ex=0x%h alu_result_mem=0x%h alu_result_wb=0x%h",
                 pc_ex, rs1_addr_ex, forward_a, rs1_data_ex, alu_result_mem, alu_result_wb));
            `DBG2(("[REG_FORWARD] MEM: pc=0x%h rd=%0d we=%b | WB: pc=0x%h rd=%0d we=%b retire=%b",
                 pc_mem, rd_addr_mem, reg_we_mem, pc_wb, rd_addr_wb, reg_we_wb, retire_instr));
        end
        // Debug: log operand values when no forwarding fires (forward_a=0), filtered for rs1=x15
        if (rst_n && ex_valid && (forward_a == 2'd0) && (rs1_addr_ex == 5'd15)) begin
            `DBG2(("[EX_NOFWD] PC=0x%h rs1=x15 rs1_data_ex=0x%h rs2_addr=%0d rs2_data_ex=0x%h | MEM: pc=0x%h rd=%0d | WB: pc=0x%h rd=%0d",
                 pc_ex, rs1_data_ex, rs2_addr_ex, rs2_data_ex, pc_mem, rd_addr_mem, pc_wb, rd_addr_wb));
        end
    end

    // ALU Operand Selection
    // Operand A sources:
    //   - AUIPC: PC (for PC-relative address calculation)
    //   - Others: rs1 (with forwarding)
    //
    // Operand B sources:
    //   - Immediate instructions: immediate value
    //   - Register instructions: rs2 (with forwarding)
    logic [31:0] alu_operand_a, alu_operand_b;

    always_comb begin
        if (auipc_ex) begin
            alu_operand_a = pc_ex;  // AUIPC uses PC as base
        end else begin
            alu_operand_a = rs1_forwarded;  // Most instructions use rs1
        end

        if (alu_src_ex) begin
            alu_operand_b = imm_ex;  // Immediate operand
        end else begin
            alu_operand_b = rs2_forwarded;  // Register operand
        end
    end

    // ALU Instance
    // Handles arithmetic, logical, shift, and comparison operations
    // Multi-cycle operations (divide with FAST_DIV=0) report ready=0 while executing

    always_ff @(posedge clk) begin
        if (rst_n && ex_valid && (rd_addr_ex != 5'd0)) begin
            `DBG2(("[ALU_OPERANDS] PC=0x%h instr=0x%h rd=%0d alu_op=%0d operand_a=0x%h operand_b=0x%h rs1_fwd=0x%h imm=0x%h ready=%b",
                   pc_ex, instr_ex, rd_addr_ex, alu_op_ex, alu_operand_a, alu_operand_b, rs1_forwarded, imm_ex, alu_ready));
        end
    end

    rv32_alu #(
        .FAST_DIV(FAST_DIV)
    ) alu (
        .clk(clk),
        .rst_n(rst_n),
        .alu_op(alu_op_ex),
        .operand_a(alu_operand_a),
        .operand_b(alu_operand_b),
        .result(alu_result_ex),
        .ready(alu_ready)
    );

    // ============================================================================
    // Branch Evaluation Logic
    // ============================================================================
    // Evaluates branch condition using forwarded register values.
    // Supports all 6 RISC-V branch conditions:
    //   BEQ, BNE (equality)
    //   BLT, BGE (signed comparison)
    //   BLTU, BGEU (unsigned comparison)
    logic branch_cond;

    always_comb begin
        case (branch_op_ex)
            BRANCH_EQ:  branch_cond = (rs1_forwarded == rs2_forwarded);
            BRANCH_NE:  branch_cond = (rs1_forwarded != rs2_forwarded);
            BRANCH_LT:  branch_cond = ($signed(rs1_forwarded) < $signed(rs2_forwarded));
            BRANCH_GE:  branch_cond = ($signed(rs1_forwarded) >= $signed(rs2_forwarded));
            BRANCH_LTU: branch_cond = (rs1_forwarded < rs2_forwarded);
            BRANCH_GEU: branch_cond = (rs1_forwarded >= rs2_forwarded);
            default:    branch_cond = 1'b0;
        endcase
    end

    // Debug: Log branch decisions
    always @(posedge clk) begin
        if (branch_ex && ex_valid) begin
            `DBG2(("Branch @ PC=0x%h: rs1=0x%h rs2=0x%h op=%0d cond=%b taken=%b fwd_a=%0d fwd_b=%0d",
                   pc_ex, rs1_forwarded, rs2_forwarded, branch_op_ex, branch_cond, branch_taken, forward_a, forward_b));
        end
    end

    // Branch Decision
    // Branches are predicted not-taken; flush pipeline if prediction was wrong
    // Suppress branches during flush or when MRET is executing to prevent PC misdirection
    assign branch_taken = ((branch_ex && branch_cond) || jal_ex || jalr_ex) && ex_valid && !ex_flush && !is_mret_ex;

    `ifdef DEBUG
    logic branch_taken_prev;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            branch_taken_prev <= 1'b0;
        end else begin
            branch_taken_prev <= branch_taken;
            if (branch_taken && !branch_taken_prev) begin
                `DBG2(("[BRANCH] Branch taken: pc_ex=0x%h instr_ex=0x%h target=0x%h (br=%b cond=%b jal=%b jalr=%b) ex_valid=%b",
                       pc_ex, instr_ex, branch_target, branch_ex, branch_cond, jal_ex, jalr_ex, ex_valid));
            end
            if (!branch_taken && branch_taken_prev) begin
                `DBG2(("[BRANCH] Branch cleared: pc_ex=0x%h instr_ex=0x%h ex_valid=%b branch_flushed=%b",
                       pc_ex, instr_ex, ex_valid, branch_flushed));
            end
        end
    end
    `endif

    // Track if we've already flushed for the current branch in EX
    // Without this, during stalls, if_flush stays high and discards the target instruction
    logic branch_flushed;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            branch_flushed <= 1'b0;
        end else if (branch_taken && !branch_flushed) begin
            // Priority 1: SET on first branch cycle.
            // This must come BEFORE the pipeline-advancing reset so that
            // branch_flushed=1 is actually committed on the same cycle
            // the branch fires (not clobbered by the else-if reset).
            branch_flushed <= 1'b1;
            `DBG2(("[BRANCH_FLUSH] Setting branch_flushed for pc_ex=0x%h target=0x%h",
                   pc_ex, branch_target));
        end else if (!id_ex_stall && !downstream_stall && !load_use_hazard) begin
            // Priority 2: RESET when a new instruction enters EX.
            branch_flushed <= 1'b0;
            if (branch_flushed) begin
                `DBG2(("[BRANCH_FLUSH] Resetting branch_flushed (new instr entering EX)"));
            end
        end
    end

    // Branch Target Calculation
    // JALR: (rs1 + imm) & ~1  (clear LSB per RISC-V spec)
    // JAL/Branch: PC + offset
    always_comb begin
        if (jalr_ex) begin
            branch_target = (rs1_forwarded + imm_ex) & ~32'd1;  // Clear LSB
        end else if (jal_ex || branch_ex) begin
            branch_target = pc_ex + imm_ex;  // PC-relative offset
        end else begin
            branch_target = pc_next;  // Sequential
        end
    end

    // LUI and JAL/JALR Result Selection
    // LUI bypasses ALU and directly uses immediate value
    // JAL/JALR store return address (PC+4) instead of ALU result
    logic [31:0] alu_result_final;
    assign alu_result_final = lui_ex ? imm_ex :
                              (jal_ex || jalr_ex) ? (pc_ex + 32'd4) :
                              alu_result_ex;

    // Stall EX stage if ALU is busy (e.g., serial divider when FAST_DIV=0)
    assign id_ex_stall = !alu_ready && ex_valid;

    // ============================================================================
    // Pipeline Flush Control
    // ============================================================================
    // Flush signals clear invalid instructions from pipeline stages:
    //
    // IF/ID flush: On branch taken or exception
    //   - Wrong-path instructions after branch/jump
    //   - Instructions fetched before exception handler
    //   - Only pulses for ONE cycle per branch to avoid discarding target instruction
    //
    // EX flush: Only on WB-stage exceptions and interrupts
    //   - Don't flush on branch (branch is evaluated IN EX)
    //   - Don't flush on EX exceptions (exception detected IN EX)
    //   - Don't flush on MRET (MRET is evaluated IN EX)
    //
    // MEM flush: On all exceptions, interrupts, and MRET
    //   - But not on branches (need PC+4 for JAL/JALR link register)
    assign if_flush = (branch_taken && !branch_flushed) || exception || irq_pending || is_mret_ex;
    assign id_flush = (branch_taken && !branch_flushed) || exception || irq_pending || is_mret_ex;
    assign ex_flush = irq_pending || wb_exception;
    // Note: is_mret_ex is intentionally NOT included here. When mret is in EX stage,
    // the instruction currently in MEM is a valid trap-handler epilogue instruction and
    // should be allowed to retire.  mret itself passes through MEM/WB with no side effects
    // (reg_we=0, mem_op=none, csr_op=0) so it retires cleanly and appears in the trace.
    assign mem_flush = exception || irq_pending || wb_exception;

    // ====== Flush Event Debug Tracing ======
    `ifdef DEBUG
    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (if_flush) begin
                if (branch_taken && !branch_flushed) begin
                    `DBG2(("[FETCH_FLUSH] Branch mispredict: pc_ex=0x%h target=0x%h, outstanding=%0d",
                           pc_ex, branch_target, ib_outstanding));
                end else if (exception) begin
                    `DBG2(("[FETCH_FLUSH] Exception: pc_ex=0x%h cause=%0d, outstanding=%0d",
                           pc_ex, exception_cause, ib_outstanding));
                end
            end
            if (wb_exception) begin
                `DBG2(("[FETCH_FLUSH] WB Exception: pc_wb=0x%h cause=%0d, outstanding=%0d",
                       pc_wb, wb_exception_cause, ib_outstanding));
            end
            if (irq_pending) begin
                `DBG1(("[FETCH_FLUSH] Interrupt: cause=0x%h mem_valid=%b pc_mem=0x%h ex_valid=%b pc_ex=0x%h id_valid=%b pc_id=0x%h pc_if=0x%h interrupt_pc=0x%h outstanding=%0d wb_valid=%b pc_wb=0x%h retire_instr=%b mtime=%0d",
                       irq_cause, mem_valid, pc_mem, ex_valid, pc_ex, id_valid, pc_id, pc_if, interrupt_pc, ib_outstanding, wb_valid, pc_wb, retire_instr, $time));
            end
        end
    end
    `endif

    // ============================================================================
    // Exception Detection (EX Stage)
    // ============================================================================
    // Detects synchronous exceptions in execute stage:
    //   - Instruction access faults (from IF stage)
    //   - Illegal instructions (from decoder)
    //   - ECALL (environment call)
    //   - EBREAK (breakpoint)
    //
    // Priority (highest to lowest):
    //   1. Instruction access fault
    //   2. Illegal instruction
    //   3. ECALL
    //   4. EBREAK
    always_comb begin
        exception = 1'b0;
        exception_cause = 5'd0;
        exception_pc = pc_ex;      // For sync exceptions: PC of faulting instruction
        // For async interrupts: save the PC of the oldest non-committed instruction.
        // The interrupt flushes MEM, EX, ID, and IF stages.  The instruction in the
        // MEM stage (if valid) is the oldest one that hasn't written back yet and needs
        // to be re-executed after mret.  Walk the pipeline from oldest to newest.
        if (mem_valid) begin
            interrupt_pc = pc_mem;   // MEM stage is oldest un-committed
        end else if (ex_valid) begin
            interrupt_pc = pc_ex;    // EX stage (no valid instruction in MEM)
        end else if (id_valid) begin
            interrupt_pc = pc_id;    // ID stage
        end else begin
            interrupt_pc = pc_if;    // Pipeline is empty; resume from IF target
        end
        exception_tval = 32'd0;

        if (ex_valid) begin
            if (instr_access_fault_ex) begin
                // Instruction access fault has highest priority
                exception = 1'b1;
                exception_cause = EXC_INSTR_ACCESS_FAULT;
                exception_tval = pc_ex;  // Faulting address
                `DBG1(("EXCEPTION: Instr access fault @ PC=0x%h", pc_ex));
            end else if (illegal_ex) begin
                exception = 1'b1;
                exception_cause = EXC_ILLEGAL_INSTR;
                exception_tval = instr_ex;  // Illegal instruction word (for mtval)
                `DBG1(("EXCEPTION: Illegal instruction @ PC=0x%h instr=0x%h", pc_ex, instr_ex));
            end else if (is_ecall_ex) begin
                exception = 1'b1;
                exception_cause = EXC_ECALL_MMODE;
                `DBG1(("EXCEPTION: ECALL @ PC=0x%h", pc_ex));
            end else if (is_ebreak_ex) begin
                exception = 1'b1;
                exception_cause = EXC_BREAKPOINT;
                exception_tval  = pc_ex;  // RISC-V spec: mtval = PC of ebreak instruction
                `DBG1(("EXCEPTION: EBREAK @ PC=0x%h", pc_ex));
            end else if (mem_read_ex && (
                ((mem_op_ex == MEM_HALF || mem_op_ex == MEM_HALF_U) && alu_result_final[0]) ||
                (mem_op_ex == MEM_WORD && alu_result_final[1:0] != 2'b00)
            )) begin
                exception       = 1'b1;
                exception_cause = EXC_LOAD_ADDR_MISALIGNED;
                exception_tval  = alu_result_final;
                `DBG1(("EXCEPTION: Load addr misaligned @ PC=0x%h addr=0x%h", pc_ex, alu_result_final));
            end else if (mem_write_ex && (
                ((mem_op_ex == MEM_HALF) && alu_result_final[0]) ||
                (mem_op_ex == MEM_WORD && alu_result_final[1:0] != 2'b00)
            )) begin
                exception       = 1'b1;
                exception_cause = EXC_STORE_ADDR_MISALIGNED;
                exception_tval  = alu_result_final;
                `DBG1(("EXCEPTION: Store addr misaligned @ PC=0x%h addr=0x%h", pc_ex, alu_result_final));
            end else if (branch_taken && (branch_target[1:0] != 2'b00)) begin
                // Instruction-address-misaligned: branch/jump target is not
                // 4-byte aligned (RISC-V spec section 2.5).
                // The fetch is suppressed via non_branch_flush = exception.
                exception       = 1'b1;
                exception_cause = EXC_INSTR_ADDR_MISALIGNED;
                exception_tval  = branch_target;  // faulting target address
                `DBG1(("EXCEPTION: Instr addr misaligned @ PC=0x%h target=0x%h", pc_ex, branch_target));
            end
        end
    end

    // ============================================================================
    // EX/MEM Pipeline Register
    // ============================================================================
    // Latches ALU results and control signals from execute to memory stage.
    // Special handling for JAL/JALR: stores return address (PC+4) in alu_result
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_mem        <= 32'd0;
            instr_mem     <= 32'h00000013;
            alu_result_mem <= 32'd0;
            rs1_data_mem  <= 32'd0;
            rs2_data_mem  <= 32'd0;
            rs1_addr_mem  <= 5'd0;
            rd_addr_mem   <= 5'd0;
            reg_we_mem    <= 1'b0;
            mem_read_mem  <= 1'b0;
            mem_write_mem <= 1'b0;
            mem_op_mem    <= MEM_WORD;
            system_mem    <= 1'b0;
            csr_op_mem    <= 3'd0;
            csr_addr_mem  <= 12'd0;
            is_amo_mem    <= 1'b0;
            amo_op_mem    <= AMO_ADD;
            is_fence_mem  <= 1'b0;
            mem_valid     <= 1'b0;
            data_access_fault_mem <= 1'b0;
        end else if (mem_flush) begin
            // Exception/interrupt: flush memory stage
            reg_we_mem    <= 1'b0;
            mem_read_mem  <= 1'b0;
            mem_write_mem <= 1'b0;
            system_mem    <= 1'b0;
            mem_valid     <= 1'b0;
            is_fence_mem  <= 1'b0;
            data_access_fault_mem <= 1'b0;
        end else if (!ex_mem_stall) begin
            pc_mem        <= pc_ex;
            instr_mem     <= instr_ex;
            // alu_result_final already contains PC+4 for JAL/JALR
            alu_result_mem <= alu_result_final;
            if ((jal_ex || jalr_ex) && ex_valid) begin
                `DBG2(("JAL/JALR @ PC=0x%h, return_addr=0x%h, rd=%0d",
                       pc_ex, pc_ex + 32'd4, rd_addr_ex));
            end
            rs1_data_mem  <= rs1_forwarded;
            rs2_data_mem  <= rs2_forwarded;
            rs1_addr_mem  <= rs1_addr_ex;
            rd_addr_mem   <= rd_addr_ex;
            reg_we_mem    <= reg_we_ex;
            mem_read_mem  <= mem_read_ex;
            mem_write_mem <= mem_write_ex;
            mem_op_mem    <= mem_op_ex;
            system_mem    <= system_ex;
            csr_op_mem    <= csr_op_ex;
            csr_addr_mem  <= csr_addr_ex;
            is_amo_mem    <= is_amo_ex;
            amo_op_mem    <= amo_op_ex;
            is_fence_mem  <= is_fence_ex;
            mem_valid     <= ex_valid && !exception && !irq_pending && !wb_exception;
            if (ex_valid) begin
                `DBG2(("Cycle %0t: EX->MEM pc=0x%h instr=0x%h ex_valid=%b mem_valid_next=%b",
                       $time, pc_ex, instr_ex, ex_valid, ex_valid && !exception && !irq_pending && !wb_exception));
            end
            // Capture data access error from buffered response for memory operations only
            // Set fault only if the instruction entering MEM is a mem op to prevent
            // non-memory instructions from incorrectly triggering exceptions
            if (dmem_resp_valid_buf && dmem_resp_error_buf && (mem_read_ex || mem_write_ex)) begin
                data_access_fault_mem <= 1'b1;
            end else if (!ex_mem_stall) begin
                // Clear fault when pipeline advances (new instruction enters MEM)
                data_access_fault_mem <= 1'b0;
            end
        end
    end

    // ============================================================================
    // Memory Stage Implementation
    // ============================================================================
    // Handles load and store operations with data memory.
    // Key features:
    //   - Store buffer (depth=2) for asynchronous store completion
    //   - RAW hazard prevention: loads stall when stores are pending
    //   - Byte/halfword access with proper alignment and sign extension

    // Store Buffer Signals
    // The store buffer allows stores to complete without blocking the pipeline.
    // It maintains a FIFO of pending stores and issues them to memory when ready.
    logic        sb_cpu_valid;           // CPU has store to buffer
    logic        sb_cpu_ready;           // Store buffer can accept store
    logic [31:0] sb_mem_addr;            // Address for buffered store
    logic [31:0] sb_mem_data;            // Data for buffered store
    logic [3:0]  sb_mem_strb;            // Byte enables for buffered store
    logic        sb_mem_valid;           // Store buffer has memory request
    logic        sb_mem_ready;           // Memory accepts buffered store
    logic        sb_store_pending;       // Stores are pending in buffer
    logic        sb_addr_hit;             // A buffered store's lower 10 bits match incoming load
    logic [1:0]  sb_buffered_count;      // Number of stores in buffer

    // Store Response Tracking
    // Track whether a pending memory response belongs to the store buffer or a load.
    // This is needed because memory responses don't carry transaction IDs.
    logic        sb_mem_inflight;        // Store buffer has transaction in flight

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sb_mem_inflight <= 1'b0;
        end else begin
            // Set when store buffer initiates memory transaction
            if (sb_mem_valid && dmem_req_ready) begin
                sb_mem_inflight <= 1'b1;
            // Clear when B-response arrives (store buffer transaction complete)
            end else if (dmem_resp_valid && dmem_resp_is_write) begin
                sb_mem_inflight <= 1'b0;
            end
        end
    end

    // ============================================================================
    // Memory Request Routing
    // ============================================================================
    // Loads go directly to memory, stores go through the store buffer.
    // This allows stores to complete asynchronously without blocking the pipeline.
    //
    // RAW (Read-After-Write) Hazard Prevention:
    //   Loads must wait only when a buffered store's lower 10 address bits match
    //   the incoming load address, avoiding unnecessary stalls on non-conflicting
    //   stores. The stall persists until ALL matching entries have drained (flush-out).
    logic        load_req_valid;
    logic        store_req_valid;
    logic        load_req_issued;   // Tracks if load request has been issued

    // Track whether load request has been issued to prevent duplicate requests
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_req_issued <= 1'b0;
        end else if (mem_flush || !mem_valid) begin
            // Clear when instruction leaves MEM stage
            load_req_issued <= 1'b0;
        end else if (load_req_valid && !sb_mem_valid && !amo_mem_req && dmem_req_ready) begin
            // Set only when the load itself wins the bus (store buffer and AMO have priority)
            load_req_issued <= 1'b1;
        end else if (dmem_resp_valid && !dmem_resp_is_write) begin
            // Clear only on load R-response (B-responses belong to store buffer)
            load_req_issued <= 1'b0;
        end
    end

    // Note: store_req_issued tracking removed - stores now stall in EX until buffer ready,
    // ensuring they're only sent to buffer once when they enter MEM stage

    // Load request: stall only when a buffered store's lower 10 address bits match
    // the load address (potential RAW hazard). Non-conflicting loads can issue while
    // stores are draining; B-responses are filtered at the response consumers below.
    // Wait until all address-matched entries have drained (lookup_hit=0).
    assign load_req_valid = mem_read_mem && mem_valid && !sb_addr_hit && !load_req_issued && !is_amo_mem;

    // Store request: send to buffer when store is in MEM stage (not for AMO)
    assign store_req_valid = mem_write_mem && mem_valid && !is_amo_mem;

    // Store buffer accepts stores from CPU
    assign sb_cpu_valid = store_req_valid;

    // Debug: Track store/load requests and store buffer state
    always_ff @(posedge clk) begin
        if (mem_write_mem && mem_valid) begin
            `DBG2(("[SB_DEBUG] STORE in MEM: pc=0x%h valid=%b ready=%b accepted=%b pending=%b",
                   pc_mem, store_req_valid, sb_cpu_ready, store_req_valid && sb_cpu_ready, sb_store_pending));
        end
        if (mem_read_mem && mem_valid) begin
            `DBG2(("[SB_DEBUG] LOAD in MEM: pc=0x%h addr=0x%h addr_hit=%b load_req_valid=%b load_req_issued=%b",
                   pc_mem, alu_result_mem, sb_addr_hit, load_req_valid, load_req_issued));
        end
    end

    // Memory interface arbitration
    // Priority: AMO > Buffered stores > Loads
    assign dmem_req_valid = amo_mem_req || sb_mem_valid || load_req_valid;
    assign dmem_req_addr = amo_mem_req ? amo_req_addr :
                           (sb_mem_valid ? sb_mem_addr : alu_result_mem);
    assign dmem_resp_ready = 1'b1;  // Always ready (no backpressure on responses)

    // Memory ready signal back to store buffer
    assign sb_mem_ready = sb_mem_valid && !amo_mem_req ? dmem_req_ready : 1'b0;

    // ============================================================================
    // Store Data Encoding
    // ============================================================================
    // Convert store data and operation into memory-ready format.
    // Handles byte/halfword stores by:
    //   1. Replicating data to all byte positions
    //   2. Generating byte enables based on address alignment
    //
    // Memory Interface Format:
    //   - wdata: 32-bit word with data replicated to target bytes
    //   - we (write enable): 4-bit byte enables (1 = write that byte)
    //
    // Write data and byte enable generation
    always_comb begin
        dmem_req_wdata = 32'd0;
        dmem_req_we = 4'b0000;

        if (amo_mem_req) begin
            // AMO operation: use AMO write data and byte enables
            dmem_req_wdata = amo_req_wdata;
            dmem_req_we = amo_req_we;
        end else if (sb_mem_valid) begin
            // Store from buffer: data already encoded
            dmem_req_wdata = sb_mem_data;
            dmem_req_we = sb_mem_strb;
        end else if (mem_write_mem) begin
            // Direct write: encode based on operation and address
            case (mem_op_mem)
                MEM_BYTE: begin
                    // Replicate byte to all positions
                    dmem_req_wdata = {4{rs2_data_mem[7:0]}};
                    // Select byte lane based on address[1:0]
                    case (alu_result_mem[1:0])
                        2'b00: dmem_req_we = 4'b0001;  // Byte 0
                        2'b01: dmem_req_we = 4'b0010;  // Byte 1
                        2'b10: dmem_req_we = 4'b0100;  // Byte 2
                        2'b11: dmem_req_we = 4'b1000;  // Byte 3
                    endcase
                end
                MEM_HALF: begin
                    // Replicate halfword to both positions
                    dmem_req_wdata = {2{rs2_data_mem[15:0]}};
                    // Select halfword based on address[1]
                    dmem_req_we = alu_result_mem[1] ? 4'b1100 : 4'b0011;
                end
                MEM_WORD: begin
                    // Full word write
                    dmem_req_wdata = rs2_data_mem;
                    dmem_req_we = 4'b1111;
                end
                default: begin
                    dmem_req_wdata = 32'd0;
                    dmem_req_we = 4'b0000;
                end
            endcase
        end
    end

    // Store Data Encoding for Store Buffer
    // Pre-encode store data for the store buffer (same format as above)
    logic [31:0] store_data_encoded;
    logic [3:0]  store_strb_encoded;

    always_comb begin
        store_data_encoded = 32'd0;
        store_strb_encoded = 4'b0000;

        if (mem_write_mem) begin
            case (mem_op_mem)
                MEM_BYTE: begin
                    store_data_encoded = {4{rs2_data_mem[7:0]}};
                    case (alu_result_mem[1:0])
                        2'b00: store_strb_encoded = 4'b0001;
                        2'b01: store_strb_encoded = 4'b0010;
                        2'b10: store_strb_encoded = 4'b0100;
                        2'b11: store_strb_encoded = 4'b1000;
                    endcase
                end
                MEM_HALF: begin
                    store_data_encoded = {2{rs2_data_mem[15:0]}};
                    store_strb_encoded = alu_result_mem[1] ? 4'b1100 : 4'b0011;
                end
                MEM_WORD: begin
                    store_data_encoded = rs2_data_mem;
                    store_strb_encoded = 4'b1111;
                end
                default: begin
                    store_data_encoded = 32'd0;
                    store_strb_encoded = 4'b0000;
                end
            endcase
        end
    end

    // ============================================================================
    // Store Buffer Instance
    // ============================================================================
    // Configurable depth allows multiple stores to be buffered while awaiting completion.
    // Stores are issued to memory in FIFO order.
    // Buffer is flushed on branches/exceptions to maintain precise exceptions.
    rv32_sb #(
        .DEPTH(SB_DEPTH),
        .ADDR_WIDTH(32),
        .DATA_WIDTH(32)
    ) store_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .cpu_valid(sb_cpu_valid),
        .cpu_addr(alu_result_mem),
        .cpu_data(store_data_encoded),
        .cpu_strb(store_strb_encoded),
        .cpu_ready(sb_cpu_ready),
        .mem_valid(sb_mem_valid),
        .mem_addr(sb_mem_addr),
        .mem_data(sb_mem_data),
        .mem_strb(sb_mem_strb),
        .mem_ready(sb_mem_ready),
        .resp_valid(dmem_resp_valid && dmem_resp_is_write),
        .resp_error(dmem_resp_error),
        /* verilator lint_off PINCONNECTEMPTY */
        .resp_ready(),  // Not used
        /* verilator lint_on PINCONNECTEMPTY */
        // Never flush committed stores: all SB entries are from retired
        // instructions (past EX stage). EX-stage exceptions and interrupts
        // must not cancel pre-committed writes (RISC-V precise-exception model).
        .flush(1'b0),
        .lookup_addr(alu_result_mem[9:0]),
        .lookup_hit(sb_addr_hit),
        .buffered_count(sb_buffered_count),
        .store_pending(sb_store_pending)
    );

    // ============================================================================
    // Atomic Memory Operations (AMO) Implementation
    // ============================================================================
    // AMO instructions perform read-modify-write operations atomically:
    //   1. Read current value from memory
    //   2. Perform operation (swap, add, xor, and, or, min, max)
    //   3. Write result back to memory
    //   4. Return original value to destination register
    //
    // LR (Load Reserved) and SC (Store Conditional):
    //   - LR: Load word and set reservation on address
    //   - SC: Store word if reservation still valid, return 0=success, 1=fail
    //
    // State Machine:
    //   - IDLE: No AMO in progress
    //   - READ: Issued read, waiting for response
    //   - WRITE: Issued write, waiting for response
    //
    // Memory interface:
    //   - AMO operations bypass the store buffer (direct memory access)
    //   - AMO read uses dmem_req with we=0
    //   - AMO write uses dmem_req with we!=0

    // LR/SC Reservation Tracking
    // Reservation is set by LR and cleared by SC, context switch, or memory access to reserved address
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lr_valid <= 1'b0;
            lr_addr  <= 32'd0;
        end else if (mem_flush) begin
            // Clear reservation on exception/interrupt
            lr_valid <= 1'b0;
        end else if (is_amo_mem && mem_valid && (amo_op_mem == AMO_LR)) begin
            // LR: Set reservation on the address
            `DBG2(("[LR/SC] Setting reservation: addr=0x%h PC=0x%h", alu_result_mem, pc_mem));
            lr_valid <= 1'b1;
            lr_addr  <= alu_result_mem;
        end else if (is_amo_mem && mem_valid && (amo_op_mem == AMO_SC)) begin
            // SC: Clear reservation after attempt
            `DBG2(("[LR/SC] SC clearing reservation: lr_valid=%b lr_addr=0x%h sc_addr=0x%h PC=0x%h", lr_valid, lr_addr, alu_result_mem, pc_mem));
            lr_valid <= 1'b0;
        end else if (mem_write_mem && mem_valid && !is_amo_mem && lr_valid) begin
            // Normal store to reserved address (or overlapping word) clears reservation
            // RISC-V spec: reservation granularity is implementation-defined, typically a cache line
            // We use word-level granularity: clear if store overlaps the reserved word
            if (alu_result_mem[31:2] == lr_addr[31:2]) begin  // Same word
                `DBG2(("[LR/SC] Store to reserved address clearing reservation: store_addr=0x%h lr_addr=0x%h PC=0x%h", alu_result_mem, lr_addr, pc_mem));
                lr_valid <= 1'b0;
            end
        end
    end

    // AMO State Machine
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            amo_state <= AMO_IDLE;
            amo_started <= 1'b0;
            sc_success <= 1'b0;
            amo_addr  <= 32'd0;
            amo_read_data <= 32'd0;
        end else begin
            // Clear amo_started when instruction leaves MEM stage
            if (!mem_wb_stall && is_amo_mem) begin
                amo_started <= 1'b0;
            end

            case (amo_state)
                AMO_IDLE: begin
                    // Start AMO when AMO instruction first enters MEM stage
                    // Only start if we haven't already started for this instruction
                    if (is_amo_mem && mem_valid && !amo_started) begin
                        // AMO instruction entering MEM stage
                        amo_started <= 1'b1;  // Mark that we've started this AMO
                        `DBG2(("[AMO] Starting AMO op=%0d PC=0x%h addr=0x%h", amo_op_mem, pc_mem, alu_result_mem));
                        if (amo_op_mem == AMO_LR) begin
                            // LR: Just read, no write phase
                            amo_state <= AMO_READ;
                            amo_addr  <= alu_result_mem;
                        end else if (amo_op_mem == AMO_SC) begin
                            // SC: Check reservation before proceeding
                            `DBG2(("[LR/SC] SC checking: lr_valid=%b lr_addr=0x%h sc_addr=0x%h match=%b PC=0x%h",
                                   lr_valid, lr_addr, alu_result_mem, (lr_valid && (lr_addr == alu_result_mem)), pc_mem));
                            if (lr_valid && (lr_addr == alu_result_mem)) begin
                                // Reservation valid: proceed with write
                                `DBG2(("[LR/SC] SC proceeding with write"));
                                sc_success <= 1'b1;  // Save success status
                                amo_state <= AMO_WRITE;
                                amo_addr  <= alu_result_mem;
                                amo_read_data <= 32'd0;  // SC doesn't need read data
                            end else begin
                                // Reservation invalid: fail immediately (no memory access)
                                `DBG2(("[LR/SC] SC FAILED - reservation invalid"));
                                sc_success <= 1'b0;  // Save failure status
                                amo_state <= AMO_IDLE;
                                amo_read_data <= 32'd1;  // Return 1 = failure
                            end
                        end else begin
                            // Other AMO: Start with read phase
                            amo_state <= AMO_READ;
                            amo_addr  <= alu_result_mem;
                        end
                    end
                end

                AMO_READ: begin
                    // Waiting for read response.
                    // Require amo_req_issued to avoid mistakenly capturing a
                    // lingering write B-channel response (data=0) from the
                    // store buffer draining before our actual read completes.
                    if (dmem_resp_valid && !dmem_resp_is_write && amo_req_issued) begin
                        amo_read_data <= dmem_resp_data;
                        `DBG2(("[AMO] READ complete addr=0x%h data=0x%h", amo_addr, dmem_resp_data));
                        `DBG2(("[AMO] Result will be: amo_result_comb=0x%h (from amo_read_data_next)", dmem_resp_data));
                        if (amo_op_mem == AMO_LR) begin
                            // LR: Complete (no write phase)
                            amo_state <= AMO_IDLE;
                        end else begin
                            // Other AMO: Proceed to write phase
                            amo_state <= AMO_WRITE;
                        end
                    end
                end

                AMO_WRITE: begin
                    // Waiting for write response
                    if (dmem_resp_valid && dmem_resp_is_write) begin
                        `DBG2(("[AMO] WRITE complete addr=0x%h, amo_read_data still=0x%h", amo_addr, amo_read_data));
                        `DBG2(("[AMO] Completing: amo_result=0x%h will be written to rd", amo_read_data));
                        amo_state <= AMO_IDLE;
                    end
                end

                default: amo_state <= AMO_IDLE;
            endcase

            // Clear state on flush
            if (mem_flush) begin
                amo_state <= AMO_IDLE;
            end
        end
    end

    // AMO Operation Computation
    // Compute the value to write back based on AMO operation
    always_comb begin
        amo_write_data = amo_read_data;  // Default: no change
        amo_result = amo_read_data;      // Default: return read value

        case (amo_op_mem)
            AMO_LR: begin
                amo_result = amo_read_data;
                amo_write_data = amo_read_data;  // No write
            end

            AMO_SC: begin
                if (sc_success) begin
                    amo_result = 32'd0;  // Success
                    amo_write_data = rs2_data_mem;
                end else begin
                    amo_result = 32'd1;  // Failure
                    amo_write_data = 32'd0;  // No write
                end
            end

            AMO_SWAP: begin
                amo_result = amo_read_data;
                amo_write_data = rs2_data_mem;
            end

            AMO_ADD: begin
                amo_result = amo_read_data;
                amo_write_data = amo_read_data + rs2_data_mem;
            end

            AMO_XOR: begin
                amo_result = amo_read_data;
                amo_write_data = amo_read_data ^ rs2_data_mem;
            end

            AMO_AND: begin
                amo_result = amo_read_data;
                amo_write_data = amo_read_data & rs2_data_mem;
            end

            AMO_OR: begin
                amo_result = amo_read_data;
                amo_write_data = amo_read_data | rs2_data_mem;
            end

            AMO_MIN: begin
                // Signed comparison
                amo_result = amo_read_data;
                amo_write_data = ($signed(amo_read_data) < $signed(rs2_data_mem)) ?
                                  amo_read_data : rs2_data_mem;
            end

            AMO_MAX: begin
                // Signed comparison
                amo_result = amo_read_data;
                amo_write_data = ($signed(amo_read_data) > $signed(rs2_data_mem)) ?
                                  amo_read_data : rs2_data_mem;
            end

            AMO_MINU: begin
                // Unsigned comparison
                amo_result = amo_read_data;
                amo_write_data = (amo_read_data < rs2_data_mem) ?
                                  amo_read_data : rs2_data_mem;
            end

            AMO_MAXU: begin
                // Unsigned comparison
                amo_result = amo_read_data;
                amo_write_data = (amo_read_data > rs2_data_mem) ?
                                  amo_read_data : rs2_data_mem;
            end

            default: begin
                amo_result = amo_read_data;
                amo_write_data = amo_read_data;
            end
        endcase
    end

    // AMO Memory Request Logic
    // Generate memory requests for AMO operations
    logic amo_mem_req;
    logic [31:0] amo_req_addr;
    logic [3:0] amo_req_we;
    logic [31:0] amo_req_wdata;
    logic amo_req_issued;  // Track if request has been issued and accepted

    // Track when AMO request has been issued and accepted
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            amo_req_issued <= 1'b0;
        end else if (mem_flush || (amo_state == AMO_IDLE)) begin
            amo_req_issued <= 1'b0;
        end else if (amo_mem_req && dmem_req_ready) begin
            amo_req_issued <= 1'b1;
        end else if (dmem_resp_valid && !dmem_resp_is_write) begin
            // Clear when R-response arrives (AMO read complete)
            amo_req_issued <= 1'b0;
        end
    end

    always_comb begin
        amo_mem_req = 1'b0;
        amo_req_addr = amo_addr;
        amo_req_we = 4'b0000;
        amo_req_wdata = amo_write_data;

        case (amo_state)
            AMO_IDLE: begin
                // Check if AMO instruction is entering MEM stage
                if (is_amo_mem && mem_valid && !mem_wb_stall) begin
                    if (amo_op_mem == AMO_SC && (!lr_valid || (lr_addr != alu_result_mem))) begin
                        // SC with invalid reservation: no memory access
                        amo_mem_req = 1'b0;
                    end else begin
                        // Start read phase - defer until store buffer drains to avoid
                        // reading stale data when a sw immediately precedes the AMO.
                        // AMO_READ state will re-issue once sb_store_pending clears.
                        amo_mem_req = !sb_store_pending;
                        amo_req_addr = alu_result_mem;
                        amo_req_we = 4'b0000;  // Read
                    end
                end
            end

            AMO_READ: begin
                // Keep request valid until accepted.
                // Wait for pending stores to drain first to maintain store-before-load
                // ordering (e.g., LR.W after a store to the same address must see
                // the stored value, but the store buffer issues writes asynchronously).
                if (!amo_req_issued && !sb_store_pending) begin
                    amo_mem_req = 1'b1;
                    amo_req_we = 4'b0000;  // Read
                end
            end

            AMO_WRITE: begin
                // Keep write request valid until accepted
                if (!amo_req_issued) begin
                    amo_mem_req = 1'b1;
                    amo_req_addr = amo_addr;
                    amo_req_we = 4'b1111;  // Write all bytes
                    amo_req_wdata = amo_write_data;
                end
            end

            default: amo_mem_req = 1'b0;
        endcase
    end

    // ============================================================================
    // Pipeline Stall Logic (MEM stage)
    // ============================================================================
    // MEM stage stalls when:
    //   1. Load request but memory not ready (backpressure)
    //   2. Store request but store buffer full
    //   3. Waiting for memory response
    //
    // For loads, stall until:
    //   - Request issues: (!sb_addr_hit; issues alongside draining stores), AND
    //   - Response received: (load_resp_valid || dmem_resp_valid_buf)
    // For stores, wait until store buffer accepts (cpu_ready handshake)
    // For AMO, stall while AMO instruction is being processed
    //   Need combinational logic to catch the first cycle when AMO enters MEM
    logic amo_in_progress;
    assign amo_in_progress = (amo_state != AMO_IDLE) ||  // Currently processing
                              (is_amo_mem && mem_valid && !amo_started);  // Just entering, not started yet

    assign ex_mem_stall = mem_wb_stall || (load_req_valid && !dmem_req_ready) || (amo_mem_req && !dmem_req_ready);
    // Combine all MEM->WB stall conditions (load_stall and store_stall defined above for forwarding)
    // fence_stall: stall until store buffer drains (fence ordering guarantee)
    assign fence_stall  = is_fence_mem && mem_valid && sb_store_pending;
    assign mem_wb_stall = load_stall || store_stall || (is_amo_mem && amo_in_progress) || fence_stall;

    // Debug mem/wb stall reasons
    always @(posedge clk) begin
        if (mem_wb_stall) begin
            `DBG2(("MEM_WB_STALL: mem_read=%b mem_write=%b | load_issued=%b dmem_resp=%b sb_ready=%b mem_valid=%b",
                   mem_read_mem, mem_write_mem, load_req_issued, dmem_resp_valid, sb_cpu_ready, mem_valid));
        end
    end

    // ============================================================================
    // WRITEBACK (WB) STAGE
    // ============================================================================
    // The WB stage is the final pipeline stage where:
    //   1. Load data is extracted and aligned from memory response
    //   2. Final result (ALU or memory data) is selected for register writeback
    //   3. Instruction retirement occurs (performance counter increment)
    //   4. Data access fault exceptions are detected and reported
    //
    // WB stage processes:
    //   - Load data extraction: Extracts bytes/halfwords from 32-bit memory word
    //   - Sign extension: Applies sign/zero extension based on load type
    //   - Exception detection: Detects load/store access faults from memory
    //   - Register writeback: Writes result to destination register
    //
    // Pipeline control:
    //   - mem_wb_stall: Stalls WB stage when waiting for memory response
    //   - wb_valid: Indicates valid instruction in WB stage ready to retire
    //   - retire_instr: Final retirement signal (wb_valid && !exception)
    // ============================================================================

    // ----------------------------------------------------------------------------
    // Memory Response Buffering
    // ----------------------------------------------------------------------------
    // Buffer memory response to avoid losing data during pipeline stalls.
    // When dmem_resp_valid arrives, capture the data immediately and hold
    // until the pipeline can consume it. This decouples memory response timing
    // from pipeline advancement.
    //
    // Response buffering signals:
    logic [31:0] mem_data_aligned;       // Load data after extraction/alignment
    logic [31:0] mem_data_wb_next;       // Load data to propagate to WB stage
    logic [4:0]  rd_addr_mem_reg;        // Saved destination register address
    logic        reg_we_mem_reg;         // Saved register write enable
    logic        mem_read_mem_reg;       // Saved memory read indicator
    logic        mem_valid_reg;          // Saved valid flag for MEM stage
    logic [31:0] dmem_resp_data_buf;     // Buffered memory response data
    logic        dmem_resp_valid_buf;    // Valid flag for buffered response
    logic        dmem_resp_error_buf;    // Error flag for buffered response

    // Memory Response Buffer Register
    // Captures dmem_resp_data when dmem_resp_valid asserts, holds it until
    // pipeline advances. This prevents data loss when MEM->WB transition
    // is stalled for other reasons.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dmem_resp_data_buf <= 32'd0;
            dmem_resp_valid_buf <= 1'b0;
            dmem_resp_error_buf <= 1'b0;
        end else if (load_req_valid && !sb_mem_valid && !amo_mem_req && dmem_req_ready) begin
            // Clear buffer when the load itself wins the bus
            dmem_resp_data_buf <= 32'd0;
            dmem_resp_valid_buf <= 1'b0;
            dmem_resp_error_buf <= 1'b0;
        end else if (dmem_resp_valid && !dmem_resp_is_write) begin
            // Capture load R-response only; ignore store B-responses
            dmem_resp_data_buf <= dmem_resp_data;
            dmem_resp_valid_buf <= 1'b1;
            dmem_resp_error_buf <= dmem_resp_error;
        end else if (!mem_wb_stall) begin
            // Clear buffer when pipeline advances (data consumed)
            dmem_resp_data_buf <= 32'd0;  // Clear data to prevent stale value reuse
            dmem_resp_valid_buf <= 1'b0;
            dmem_resp_error_buf <= 1'b0;
        end
    end

    // Store MEM stage metadata for alignment logic
    // Since memory response may arrive after multiple cycles, save the
    // load operation type and register info from EX stage so we can
    // correctly extract/align the data when response arrives.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_addr_mem_reg  <= 5'd0;
            reg_we_mem_reg   <= 1'b0;
            mem_read_mem_reg <= 1'b0;
            mem_valid_reg    <= 1'b0;
        end else if (!ex_mem_stall) begin
            rd_addr_mem_reg  <= rd_addr_ex;
            reg_we_mem_reg   <= reg_we_ex;
            mem_read_mem_reg <= mem_read_ex;
            mem_valid_reg    <= ex_valid && !exception && !irq_pending;
        end
    end

    // ----------------------------------------------------------------------------
    // Load Data Extraction and Alignment
    // ----------------------------------------------------------------------------
    // Extract requested data size (byte/halfword/word) from 32-bit memory word
    // and apply sign/zero extension based on load type:
    //   - LB  (MEM_BYTE):   Extract byte, sign-extend to 32 bits
    //   - LBU (MEM_BYTE_U): Extract byte, zero-extend to 32 bits
    //   - LH  (MEM_HALF):   Extract halfword, sign-extend to 32 bits
    //   - LHU (MEM_HALF_U): Extract halfword, zero-extend to 32 bits
    //   - LW  (MEM_WORD):   Use full 32-bit word
    //
    // Byte extraction uses alu_result_mem[1:0] (memory address low bits) to
    // select which byte/halfword from the 32-bit word. Memory system always
    // returns aligned 32-bit words; we extract the requested portion here.
    //
    // Use fresh data (dmem_resp_data) when available, otherwise use buffered data.
    // This avoids race conditions where we try to use dmem_resp_data_buf before
    // it's been updated in the same clock cycle.
    logic [31:0] load_data_source;
    // Use fresh load R-response when available (guard against B-responses)
    assign load_data_source = load_resp_valid ? dmem_resp_data : dmem_resp_data_buf;

    always_comb begin
        case (mem_op_mem)
            MEM_BYTE: begin  // LB - Load Byte (sign-extended)
                case (alu_result_mem[1:0])
                    2'b00: mem_data_aligned = {{24{load_data_source[7]}}, load_data_source[7:0]};
                    2'b01: mem_data_aligned = {{24{load_data_source[15]}}, load_data_source[15:8]};
                    2'b10: mem_data_aligned = {{24{load_data_source[23]}}, load_data_source[23:16]};
                    2'b11: mem_data_aligned = {{24{load_data_source[31]}}, load_data_source[31:24]};
                endcase
            end
            MEM_BYTE_U: begin  // LBU - Load Byte Unsigned (zero-extended)
                case (alu_result_mem[1:0])
                    2'b00: mem_data_aligned = {24'd0, load_data_source[7:0]};
                    2'b01: mem_data_aligned = {24'd0, load_data_source[15:8]};
                    2'b10: mem_data_aligned = {24'd0, load_data_source[23:16]};
                    2'b11: mem_data_aligned = {24'd0, load_data_source[31:24]};
                endcase
            end
            MEM_HALF: begin  // LH - Load Halfword (sign-extended)
                mem_data_aligned = alu_result_mem[1] ?
                    {{16{load_data_source[31]}}, load_data_source[31:16]} :
                    {{16{load_data_source[15]}}, load_data_source[15:0]};
            end
            MEM_HALF_U: begin  // LHU - Load Halfword Unsigned (zero-extended)
                mem_data_aligned = alu_result_mem[1] ?
                    {16'd0, load_data_source[31:16]} :
                    {16'd0, load_data_source[15:0]};
            end
            MEM_WORD: begin  // LW - Load Word (no extraction needed)
                mem_data_aligned = load_data_source;
            end
            default: mem_data_aligned = load_data_source;
        endcase
    end

    // Select load data or AMO result for writeback
    assign mem_data_wb_next = is_amo_mem ? amo_result : mem_data_aligned;

    always_ff @(posedge clk) begin
        if (mem_valid && is_amo_mem) begin
            `DBG2(("[AMO_WB] PC=0x%h is_amo_mem=%b amo_result=0x%h mem_data_wb_next=0x%h amo_state=%0d",
                   pc_mem, is_amo_mem, amo_result, mem_data_wb_next, amo_state));
            // Show when AMO completes and data will be latched
            if (amo_state == AMO_IDLE || (amo_state == AMO_WRITE && dmem_resp_valid)) begin
                `DBG2(("[AMO_FINAL] PC=0x%h amo_complete: amo_read_data=0x%h amo_result=0x%h mem_data_wb_next=0x%h",
                       pc_mem, amo_read_data, amo_result, mem_data_wb_next));
            end
        end
    end

    // ----------------------------------------------------------------------------
    // MEM/WB Pipeline Register
    // ----------------------------------------------------------------------------
    // Propagates instruction from MEM stage to WB stage. Stalls when:
    //   - mem_wb_stall=1: Waiting for memory response or store buffer ready
    //
    // Carries forward:
    //   - pc_wb: Program counter for exception reporting and retirement trace
    //   - instr_wb: Instruction word for debug/trace
    //   - alu_result_wb: ALU result (used as address for exception reporting)
    //   - mem_data_wb: Aligned load data to write to register file
    //   - rd_addr_wb: Destination register address
    //   - reg_we_wb: Register write enable
    //   - mem_read_wb: Memory read indicator (for exception type determination)
    //   - wb_valid: Valid instruction indicator
    //   - data_access_fault_wb: Data access fault flag from memory
    //
    // Flush behavior: Not directly flushed; relies on wb_valid propagating
    // through from upstream stages that were flushed.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_wb         <= 32'd0;
            instr_wb      <= 32'h00000013;  // NOP instruction
            alu_result_wb <= 32'd0;
            mem_data_wb   <= 32'd0;
            rd_addr_wb    <= 5'd0;
            reg_we_wb     <= 1'b0;
            mem_read_wb   <= 1'b0;
            mem_write_wb  <= 1'b0;
            store_data_wb <= 32'd0;
            csr_wdata_wb  <= 32'd0;
            csr_zimm_wb   <= 5'd0;
            csr_op_wb     <= 3'd0;
            csr_addr_wb   <= 12'd0;
            csr_rdata_wb  <= 32'd0;
            is_amo_wb     <= 1'b0;
            amo_op_wb     <= AMO_ADD;
            wb_valid      <= 1'b0;
            data_access_fault_wb <= 1'b0;
        end else if (!mem_wb_stall) begin
            pc_wb         <= pc_mem;
            instr_wb      <= instr_mem;
            alu_result_wb <= alu_result_mem;
            mem_data_wb   <= mem_data_wb_next;  // Aligned load data
            rd_addr_wb    <= rd_addr_mem;
            // Clear reg_we for loads with data access faults, or when flushing
            // the WB stage due to an interrupt or WB-stage exception.
            reg_we_wb     <= reg_we_mem && !(mem_read_mem && data_access_fault_mem)
                                        && !irq_pending && !wb_exception;
            if (reg_we_mem && (mem_read_mem && data_access_fault_mem)) begin
                `DBG2(("[WB_REG_WE_CLEAR] PC=0x%h instr=0x%h rd=%0d: Clearing reg_we due to faulting load",
                       pc_mem, instr_mem, rd_addr_mem));
            end
            if (reg_we_mem && !mem_read_mem && !mem_write_mem && data_access_fault_mem) begin
                `DBG2(("[WB_DEBUG] Non-memory instr with fault flag: PC=0x%h instr=0x%h rd=%0d rd_data=0x%h fault=%b",
                       pc_mem, instr_mem, rd_addr_mem, alu_result_mem, data_access_fault_mem));
            end
            mem_read_wb   <= mem_read_mem;
            mem_write_wb  <= mem_write_mem;
            store_data_wb <= rs2_data_mem;
            csr_wdata_wb  <= rs1_data_mem;
            csr_zimm_wb   <= rs1_addr_mem;
            csr_op_wb     <= csr_op_mem;
            csr_addr_wb   <= csr_addr_mem;
            csr_rdata_wb  <= csr_rdata;
            is_amo_wb     <= is_amo_mem;
            amo_op_wb     <= amo_op_mem;
            wb_valid      <= mem_valid && !irq_pending && !wb_exception;
            data_access_fault_wb <= data_access_fault_mem;
            if (mem_valid) begin
                `DBG2(("Cycle %0t: MEM->WB pc=0x%h instr=0x%h mem_valid=%b wb_valid_next=%b",
                       $time, pc_mem, instr_mem, mem_valid, mem_valid));
                if (mem_read_mem) begin
                    `DBG2(("[LOAD_DATA] pc=0x%h addr=0x%h mem_data_wb_next=0x%h dmem_resp_valid=%b dmem_resp_data=0x%h dmem_resp_valid_buf=%b dmem_resp_data_buf=0x%h",
                           pc_mem, alu_result_mem, mem_data_wb_next, dmem_resp_valid, dmem_resp_data, dmem_resp_valid_buf, dmem_resp_data_buf));
                end
            end
        end else if (mem_valid) begin
            `DBG2(("Cycle %0t: MEM->WB STALLED pc=0x%h mem_wb_stall=%b mem_read=%b mem_write=%b dmem_resp_valid_buf=%b dmem_req_ready=%b",
                   $time, pc_mem, mem_wb_stall, mem_read_mem, mem_write_mem, dmem_resp_valid_buf, dmem_req_ready));
            // Clear reg_we after instruction retires to prevent stale forwarding
            if (retire_instr && reg_we_wb) begin
                reg_we_wb <= 1'b0;
                `DBG2(("[REG_WE_CLEAR] PC=0x%h instr=0x%h rd=x%0d: Cleared reg_we after retirement (pipeline stalled)",
                       pc_wb, instr_wb, rd_addr_wb));
            end
        end
    end

    // ----------------------------------------------------------------------------
    // Instruction Retirement
    // ----------------------------------------------------------------------------
    // An instruction retires when it reaches WB stage with valid data and
    // no exception. Retired instructions update performance counters and
    // represent architecturally committed work.
    //
    // retire_instr: High for one cycle when instruction successfully completes
    // Only trigger for NEW instructions (not duplicates when WB stalls)
    logic retire_instr_base;
    assign retire_instr_base = wb_valid && !wb_exception;
    // Only retire if instruction is new:
    // - PC changed (different instruction location), OR
    // - Instruction encoding changed (different instruction)
    // Do NOT use !last_wb_valid because that causes duplicate retirements when
    // the same instruction stays in WB and wb_valid has a bubble (0->1 transition)
    assign retire_instr = retire_instr_base && (pc_wb != last_retired_pc || instr_wb != last_retired_instr);

    // Retirement and exception debug traces (simulation only)
    `ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (retire_instr) begin
            `DBG1(("RETIRE: PC=0x%h instr=0x%h cycle=%0d", pc_wb, instr_wb, cycle_counter));
            if (reg_we_wb && (rd_addr_wb != 5'd0)) begin
                `DBG2(("RETIRE:   Writing rd=x%0d with 0x%h", rd_addr_wb,
                       wb_write_data));
            end
        end else if (wb_valid && wb_exception) begin
            `DBG2(("WB_EXCEPTION: PC=0x%h cause=%0d cycle=%0d", pc_wb, wb_exception_cause, cycle_counter));
        end else if (wb_valid && !retire_instr && reg_we_wb && (rd_addr_wb != 5'd0)) begin
            // WB stage valid but not retiring (duplicate)
            `DBG2(("[RETIRE_SKIP] PC=0x%h instr=0x%h rd=x%0d: Not retiring (duplicate detection)",
                   pc_wb, instr_wb, rd_addr_wb));
            `DBG2(("[RETIRE_SKIP]   retire_base=%b last_pc=0x%h last_instr=0x%h",
                   retire_instr_base, last_retired_pc, last_retired_instr));
        end
    end
    `endif

    // ----------------------------------------------------------------------------
    // WB Stage Exception Detection
    // ----------------------------------------------------------------------------
    // Detects data access faults that were flagged by the memory system.
    // These exceptions are detected in WB stage because memory responses
    // may arrive multiple cycles after the load/store request.
    //
    // Exception types:
    //   - EXC_LOAD_ACCESS_FAULT:  Load from invalid/protected address
    //   - EXC_STORE_ACCESS_FAULT: Store to invalid/protected address
    //
    // Exception information:
    //   - wb_exception_cause: Exception code (5 or 7)
    //   - wb_exception_pc: PC of faulting instruction
    //   - wb_exception_tval: Memory address that caused fault
    //
    // Priority: WB exceptions are reported to CSR along with earlier-stage
    // exceptions. CSR logic handles exception prioritization.
    always_comb begin
        wb_exception = 1'b0;
        wb_exception_cause = 5'd0;
        wb_exception_pc = pc_wb;
        wb_exception_tval = alu_result_wb;  // Faulting memory address

        if (wb_valid && data_access_fault_wb) begin
            wb_exception = 1'b1;
            if (mem_read_wb) begin
                wb_exception_cause = EXC_LOAD_ACCESS_FAULT;  // Exception code 5
                `DBG1(("EXCEPTION: Load access fault @ PC=0x%h addr=0x%h", pc_wb, alu_result_wb));
            end else begin
                wb_exception_cause = EXC_STORE_ACCESS_FAULT;  // Exception code 7
                `DBG1(("EXCEPTION: Store access fault @ PC=0x%h addr=0x%h", pc_wb, alu_result_wb));
            end
        end
    end

    // ============================================================================
    // Control and Status Register (CSR) Unit
    // ============================================================================
    // The CSR unit implements RISC-V machine-mode control and status registers
    // including exception handling, interrupt management, and performance counters.
    //
    // CSR operations (CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI):
    //   - csr_addr: CSR address (12-bit) from instruction
    //   - csr_op: Operation type (read/write/set/clear, immediate or register)
    //   - csr_wdata: Write data from ALU result (rs1 data)
    //   - csr_zimm: Immediate value (zero-extended from rs1_addr field)
    //   - csr_rdata: Read data returned to pipeline (forwarded to EX stage)
    //   - csr_illegal: Indicates illegal CSR access
    //
    // Exception handling:
    //   - Combines exceptions from all pipeline stages (WB has priority)
    //   - exception: Exception occurred (any stage)
    //   - exception_cause: Exception code (interrupt/exception type)
    //   - exception_pc: PC of faulting instruction
    //   - exception_tval: Additional exception info (bad address, instruction)
    //   - mtvec: Trap vector address (where to jump on exception/interrupt)
    //   - mepc: Exception program counter (return address after trap)
    //   - mret: Machine return instruction (returns from trap handler)
    //
    // Interrupt handling:
    //   - timer_irq, external_irq, software_irq: Interrupt request inputs
    //   - irq_pending: Interrupt is pending and should be taken
    //   - irq_cause: Interrupt cause code
    //
    // Performance monitoring:
    //   - retire_instr: Increments minstret CSR (instructions retired)
    //
    // CSR registers implemented (machine mode):
    //   - mstatus, mie, mtvec, mscratch, mepc, mcause, mtval
    //   - minstret, mcycle (performance counters)
    //   - mvendorid, marchid, mimpid, mhartid (read-only identification)
    rv32_csr csr (
        .clk(clk),
        .rst_n(rst_n),

        // CSR access interface (from MEM stage)
        .csr_addr(csr_addr_mem),
        .csr_op(csr_op_mem),
        .csr_wdata(rs1_data_mem),
        .csr_zimm(rs1_addr_mem),
        .csr_rdata(csr_rdata),
        .csr_illegal(csr_illegal),

        // Exception handling (prioritize WB stage exceptions)
        .exception(wb_exception || exception),
        .exception_cause(wb_exception ? wb_exception_cause : exception_cause),
        .exception_pc(wb_exception ? wb_exception_pc : exception_pc),
        .exception_tval(wb_exception ? wb_exception_tval : exception_tval),
        .interrupt_pc(wb_exception ? (wb_exception_pc + 4) : interrupt_pc),  // PC+4 for interrupts
        .mret(is_mret_ex),
        .mtvec(mtvec),
        .mepc_o(mepc),

        // Interrupt handling
        .timer_irq(timer_irq),
        .external_irq(external_irq),
        .software_irq(software_irq),
        .irq_pending(irq_pending),
        .irq_cause(irq_cause),

        // Performance monitoring
        .retire_instr(retire_instr)

`ifndef SYNTHESIS
        ,.trace_mode(trace_mode)
`endif
    );

    // ========================================================================
    // Assertions for Pipeline Integrity and Protocol Checking
    // ========================================================================
    // Define ASSERTION by default (can be disabled with +define+NO_ASSERTION)
`ifndef NO_ASSERTION
`ifndef ASSERTION
`define ASSERTION
`endif
`endif // NO_ASSERTION

`ifdef ASSERTION

    // ========================================================================
    // PC Management and Alignment
    // ========================================================================

    property p_pc_alignment;
        @(posedge clk) disable iff (!rst_n)
        (pc_if[1:0] == 2'b00) && (pc_id[1:0] == 2'b00) &&
        (pc_ex[1:0] == 2'b00) && (pc_mem[1:0] == 2'b00) && (pc_wb[1:0] == 2'b00);
    endproperty
    assert property (p_pc_alignment)
        else $error("[CORE] PC misalignment detected: IF=0x%h ID=0x%h EX=0x%h MEM=0x%h WB=0x%h",
                    pc_if, pc_id, pc_ex, pc_mem, pc_wb);

    property p_branch_target_alignment;
        @(posedge clk) disable iff (!rst_n || instr_access_fault_ex || exception)
        branch_taken |-> (branch_target[1:0] == 2'b00);
    endproperty
    assert property (p_branch_target_alignment)
        else $error("[CORE] Branch target misaligned: PC=0x%h target=0x%h", pc_ex, branch_target);

    property p_pc_sequential_increment;
        @(posedge clk) disable iff (!rst_n)
        (imem_req_valid && imem_req_ready && !if_id_stall && !branch_taken &&
         !exception && !wb_exception && !irq_pending && !is_mret_ex) |=>
        (pc_if == ($past(imem_req_addr) + 32'd4));
    endproperty
    assert property (p_pc_sequential_increment)
        else $error("[CORE] PC did not increment sequentially: prev=0x%h curr=0x%h (issued=0x%h)",
                    $past(pc_if), pc_if, $past(imem_req_addr));

    // ========================================================================
    // Register File Protection
    // ========================================================================

    // Note: Writes to x0 are allowed in RISC-V but ignored by the register file.
    // This is expected behavior (e.g., from ADDI x0, x0, 0 or similar instructions).
    // The register file itself enforces that x0 always reads as zero.
    // property p_no_write_x0;
    //     @(posedge clk) disable iff (!rst_n)
    //     (reg_we_wb && wb_valid) |-> (rd_addr_wb != 5'd0);
    // endproperty
    // assert property (p_no_write_x0)
    //     else $error("[CORE] Write to x0 (ignored by regfile), PC=0x%h", pc_wb);

    property p_rd_addr_bounds;
        @(posedge clk) disable iff (!rst_n)
        (rd_addr_id < 32) && (rd_addr_ex < 32) && (rd_addr_mem < 32) && (rd_addr_wb < 32);
    endproperty
    assert property (p_rd_addr_bounds)
        else $error("[CORE] Destination register out of bounds");

    property p_rs_addr_bounds;
        @(posedge clk) disable iff (!rst_n)
        (rs1_addr < 32) && (rs2_addr < 32) &&
        (rs1_addr_ex < 32) && (rs2_addr_ex < 32);
    endproperty
    assert property (p_rs_addr_bounds)
        else $error("[CORE] Source register out of bounds");

    // ========================================================================
    // Pipeline Stage Validity Consistency
    // ========================================================================

    property p_no_write_when_invalid;
        @(posedge clk) disable iff (!rst_n)
        !wb_valid |-> !reg_we_wb;
    endproperty
    assert property (p_no_write_when_invalid)
        else $error("[CORE] Register write enabled when WB stage invalid");

    property p_no_branch_when_invalid;
        @(posedge clk) disable iff (!rst_n)
        !ex_valid |-> !branch_taken;
    endproperty
    assert property (p_no_branch_when_invalid)
        else $error("[CORE] Branch taken from invalid EX stage, PC=0x%h", pc_ex);

    property p_no_memory_when_invalid;
        @(posedge clk) disable iff (!rst_n)
        !mem_valid |-> !(mem_read_mem || mem_write_mem);
    endproperty
    assert property (p_no_memory_when_invalid)
        else $error("[CORE] Memory operation from invalid MEM stage");

    property p_valid_propagation_id_ex;
        @(posedge clk) disable iff (!rst_n)
        (id_valid && !if_id_stall && !ex_flush && !id_flush) |=> ex_valid;
    endproperty
    assert property (p_valid_propagation_id_ex)
        else $error("[CORE] Valid bit did not propagate ID->EX");

    // ========================================================================
    // Data Forwarding Consistency
    // ========================================================================

    property p_forward_only_when_writing;
        @(posedge clk) disable iff (!rst_n)
        (forward_a == 2'b10) |-> (reg_we_mem && (rd_addr_mem != 5'd0));
    endproperty
    assert property (p_forward_only_when_writing)
        else $error("[CORE] Forwarding from MEM but MEM not writing");

    property p_forward_only_when_writing_wb;
        @(posedge clk) disable iff (!rst_n)
        (forward_a == 2'b01) |-> (reg_we_wb && wb_valid && !wb_exception && (rd_addr_wb != 5'd0));
    endproperty
    assert property (p_forward_only_when_writing_wb)
        else $error("[CORE] Forwarding from WB but WB not valid (reg_we_wb=%b wb_valid=%b wb_except=%b rd=%0d)",
                    reg_we_wb, wb_valid, wb_exception, rd_addr_wb);

    property p_forward_only_when_writing_wb_b;
        @(posedge clk) disable iff (!rst_n)
        (forward_b == 2'b01) |-> (reg_we_wb && wb_valid && !wb_exception && (rd_addr_wb != 5'd0));
    endproperty
    assert property (p_forward_only_when_writing_wb_b)
        else $error("[CORE] Forwarding rs2 from WB but WB not valid (reg_we_wb=%b wb_valid=%b wb_except=%b rd=%0d)",
                    reg_we_wb, wb_valid, wb_exception, rd_addr_wb);

    property p_forward_correct_register_a;
        @(posedge clk) disable iff (!rst_n)
        (forward_a == 2'b10) |-> (rd_addr_mem == rs1_addr_ex);
    endproperty
    assert property (p_forward_correct_register_a)
        else $error("[CORE] MEM forwarding address mismatch for rs1");

    property p_forward_correct_register_a_wb;
        @(posedge clk) disable iff (!rst_n)
        (forward_a == 2'b01) |-> (rd_addr_wb == rs1_addr_ex);
    endproperty
    assert property (p_forward_correct_register_a_wb)
        else $error("[CORE] WB forwarding address mismatch for rs1");

    property p_forward_correct_register_b;
        @(posedge clk) disable iff (!rst_n)
        (forward_b == 2'b10) |-> (rd_addr_mem == rs2_addr_ex);
    endproperty
    assert property (p_forward_correct_register_b)
        else $error("[CORE] MEM forwarding address mismatch for rs2");

    property p_forward_correct_register_b_wb;
        @(posedge clk) disable iff (!rst_n)
        (forward_b == 2'b01) |-> (rd_addr_wb == rs2_addr_ex);
    endproperty
    assert property (p_forward_correct_register_b_wb)
        else $error("[CORE] WB forwarding address mismatch for rs2");

    // ========================================================================
    // Hazard Detection
    // ========================================================================

    property p_load_use_stall;
        @(posedge clk) disable iff (!rst_n)
        (mem_read_ex && ex_valid && id_valid &&
         ((rd_addr_ex == rs1_addr) || (rd_addr_ex == rs2_addr)) &&
         (rd_addr_ex != 5'd0)) |-> if_id_stall;
    endproperty
    assert property (p_load_use_stall)
        else $error("[CORE] Load-use hazard not stalled: rd=%0d rs1=%0d rs2=%0d",
                    rd_addr_ex, rs1_addr, rs2_addr);

    // Pipeline stall integrity: EX stage should hold instruction during downstream stalls
    property p_ex_holds_during_downstream_stall;
        @(posedge clk) disable iff (!rst_n)
        (ex_valid && !load_use_hazard && downstream_stall && !ex_flush) |=>
        ((pc_ex == $past(pc_ex)) && (instr_ex == $past(instr_ex)) && ex_valid);
    endproperty
    assert property (p_ex_holds_during_downstream_stall)
        else $error("[CORE] EX stage instruction lost during downstream stall: was PC=0x%h instr=0x%h, now PC=0x%h instr=0x%h valid=%b (stall was: downstream=%b ex_mem=%b mem_wb=%b)",
                    $past(pc_ex), $past(instr_ex), pc_ex, instr_ex, ex_valid,
                    $past(downstream_stall), $past(ex_mem_stall), $past(mem_wb_stall));

    // EX stage should not accept new instructions when stalled
    property p_ex_no_new_instr_during_stall;
        @(posedge clk) disable iff (!rst_n)
        (ex_valid && ex_mem_stall && !ex_flush && !load_use_hazard) |=>
        (ex_valid && (pc_ex == $past(pc_ex)));
    endproperty
    assert property (p_ex_no_new_instr_during_stall)
        else $error("[CORE] EX accepted new instruction during ex_mem_stall: prev PC=0x%h, new PC=0x%h (ex_mem_stall=%b mem_wb_stall=%b)",
                    $past(pc_ex), pc_ex, $past(ex_mem_stall), $past(mem_wb_stall));

    // ========================================================================
    // Instruction Fetch Integrity
    // ========================================================================

    property p_imem_req_addr_aligned;
        @(posedge clk) disable iff (!rst_n)
        imem_req_valid |-> (imem_req_addr[1:0] == 2'b00);
    endproperty
    assert property (p_imem_req_addr_aligned)
        else $error("[CORE] Instruction fetch address misaligned: 0x%h", imem_req_addr);

    // Dedup assertion using new last_issued_fetch_pc tracker:
    // When last_issued_valid and effective addr matches last issued, no new fetch should fire.
    property p_no_duplicate_fetch;
        @(posedge clk) disable iff (!rst_n)
        fetch_issued_for_effective_pc |-> !imem_req_valid;
    endproperty
    assert property (p_no_duplicate_fetch)
        else $error("[CORE] Duplicate instruction fetch for PC=0x%h", imem_req_addr);

    property p_ib_outstanding_bounded;
        @(posedge clk) disable iff (!rst_n)
        ib_outstanding <= IB_DEPTH;
    endproperty
    assert property (p_ib_outstanding_bounded)
        else $error("[CORE] IB outstanding count exceeded: %0d > %0d",
                    ib_outstanding, IB_DEPTH);

    // ========================================================================
    // Memory Interface Protocol
    // ========================================================================

    property p_dmem_req_we_valid;
        @(posedge clk) disable iff (!rst_n)
        dmem_req_valid |-> (dmem_req_we inside {4'b0000, 4'b0001, 4'b0010, 4'b0011,
                                                 4'b0100, 4'b1000, 4'b1100, 4'b1111});
    endproperty
    assert property (p_dmem_req_we_valid)
        else $error("[CORE] Invalid dmem write enable pattern: 0x%h", dmem_req_we);

    property p_load_no_write_enable;
        @(posedge clk) disable iff (!rst_n)
        // Only check when load is the active bus driver (AMO and store buffer have priority)
        (load_req_valid && !sb_mem_valid && !amo_mem_req) |-> (dmem_req_we == 4'b0000);
    endproperty
    assert property (p_load_no_write_enable)
        else $error("[CORE] Load request has write enables set: we=0x%h", dmem_req_we);

    property p_mem_alignment_byte;
        @(posedge clk) disable iff (!rst_n)
        (mem_write_mem && mem_valid && (mem_op_mem == MEM_BYTE)) |->
        (store_strb_encoded inside {4'b0001, 4'b0010, 4'b0100, 4'b1000});
    endproperty
    assert property (p_mem_alignment_byte)
        else $error("[CORE] Byte store has invalid strobe: 0x%h", store_strb_encoded);

    property p_mem_alignment_half;
        @(posedge clk) disable iff (!rst_n)
        (mem_write_mem && mem_valid && (mem_op_mem == MEM_HALF)) |->
        (store_strb_encoded inside {4'b0011, 4'b1100});
    endproperty
    assert property (p_mem_alignment_half)
        else $error("[CORE] Halfword store has invalid strobe: 0x%h", store_strb_encoded);

    property p_mem_alignment_word;
        @(posedge clk) disable iff (!rst_n)
        (mem_write_mem && mem_valid && (mem_op_mem == MEM_WORD)) |->
        (store_strb_encoded == 4'b1111);
    endproperty
    assert property (p_mem_alignment_word)
        else $error("[CORE] Word store has invalid strobe: 0x%h", store_strb_encoded);

    property p_sb_count_bounded;
        @(posedge clk) disable iff (!rst_n)
        sb_buffered_count <= SB_DEPTH;
    endproperty
    assert property (p_sb_count_bounded)
        else $error("[CORE] Store buffer count exceeded: %0d > %0d",
                    sb_buffered_count, SB_DEPTH);

    // ========================================================================
    // Branch and Jump Target Validation
    // ========================================================================

    property p_jalr_clears_lsb;
        @(posedge clk) disable iff (!rst_n)
        (jalr_ex && ex_valid) |-> (branch_target[0] == 1'b0);
    endproperty
    assert property (p_jalr_clears_lsb)
        else $error("[CORE] JALR target LSB not cleared: target=0x%h", branch_target);

    // ========================================================================
    // Exception Handling
    // ========================================================================

    property p_exception_flushes_pipeline;
        @(posedge clk) disable iff (!rst_n)
        (exception || wb_exception || irq_pending) |-> (if_flush || mem_flush);
    endproperty
    // Use OR instead of AND since store buffer stalling can delay mem_flush
    assert property (p_exception_flushes_pipeline)
        else $error("[CORE] Exception did not flush pipeline stages");

    property p_exception_updates_pc_to_mtvec;
        @(posedge clk) disable iff (!rst_n)
        (exception || wb_exception || irq_pending) |=> (pc_if == $past(mtvec));
    endproperty
    assert property (p_exception_updates_pc_to_mtvec)
        else $error("[CORE] Exception did not update PC to mtvec");

    property p_mret_updates_pc_to_mepc;
        @(posedge clk) disable iff (!rst_n)
        is_mret_ex |=> (pc_if == $past(mepc));
    endproperty
    assert property (p_mret_updates_pc_to_mepc)
        else $error("[CORE] MRET did not update PC to mepc");

    property p_no_writeback_on_exception;
        @(posedge clk) disable iff (!rst_n)
        (wb_exception && wb_valid) |-> !(reg_we_wb && (rd_addr_wb != 5'd0));
    endproperty
    // reg_we_wb should already be cleared for faulting loads
    assert property (p_no_writeback_on_exception)
        else $error("[CORE] Writeback occurred during exception: PC=0x%h instr=0x%h rd=%0d reg_we=%b mem_read=%b mem_write=%b cause=%0d",
                    pc_wb, instr_wb, rd_addr_wb, reg_we_wb, mem_read_wb, mem_write_wb, wb_exception_cause);

    // ========================================================================
    // Performance Counter Consistency
    // ========================================================================

    property p_cycle_counter_increments;
        @(posedge clk) disable iff (!rst_n)
        1'b1 |=> (cycle_counter == ($past(cycle_counter) + 64'd1));
    endproperty
    assert property (p_cycle_counter_increments)
        else $error("[CORE] Cycle counter did not increment");

    property p_instret_on_retire;
        @(posedge clk) disable iff (!rst_n)
        retire_instr |=> (instret_counter == ($past(instret_counter) + 64'd1));
    endproperty
    assert property (p_instret_on_retire)
        else $error("[CORE] Instruction counter did not increment on retire");

    property p_retire_only_when_valid;
        @(posedge clk) disable iff (!rst_n)
        retire_instr |-> wb_valid;
    endproperty
    assert property (p_retire_only_when_valid)
        else $error("[CORE] Instruction retired when WB stage invalid");

    property p_retire_not_on_exception;
        @(posedge clk) disable iff (!rst_n)
        retire_instr |-> !wb_exception;
    endproperty
    assert property (p_retire_not_on_exception)
        else $error("[CORE] Instruction retired during exception");

    // ========================================================================
    // Flush Signal Consistency
    // ========================================================================

    property p_branch_flushes_if_id;
        @(posedge clk) disable iff (!rst_n)
        (branch_taken && !branch_flushed) |-> (if_flush && id_flush);
    endproperty
    assert property (p_branch_flushes_if_id)
        else $error("[CORE] Branch did not flush IF/ID stages");

    property p_flush_clears_valid_id;
        @(posedge clk) disable iff (!rst_n)
        (if_flush || id_flush) |=> !id_valid;
    endproperty
    assert property (p_flush_clears_valid_id)
        else $error("[CORE] ID valid not cleared after flush");

    property p_flush_clears_valid_ex;
        @(posedge clk) disable iff (!rst_n)
        ex_flush |=> !ex_valid;
    endproperty
    assert property (p_flush_clears_valid_ex)
        else $error("[CORE] EX valid not cleared after flush");

    property p_flush_disables_writes_id_ex;
        @(posedge clk) disable iff (!rst_n)
        (ex_flush) |=> (!reg_we_ex && !mem_read_ex && !mem_write_ex);
    endproperty
    assert property (p_flush_disables_writes_id_ex)
        else $error("[CORE] EX stage not properly bubbled after flush");

    // ========================================================================
    // X/Z Detection on Critical Control Signals
    // ========================================================================

    property p_no_x_imem_req_valid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(imem_req_valid);
    endproperty
    assert property (p_no_x_imem_req_valid)
        else $error("[CORE] X/Z on imem_req_valid");

    property p_no_x_dmem_req_valid;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(dmem_req_valid);
    endproperty
    assert property (p_no_x_dmem_req_valid)
        else $error("[CORE] X/Z on dmem_req_valid");

    property p_no_x_reg_we;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(reg_we_wb);
    endproperty
    assert property (p_no_x_reg_we)
        else $error("[CORE] X/Z on reg_we_wb");

    property p_no_x_branch_taken;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(branch_taken);
    endproperty
    assert property (p_no_x_branch_taken)
        else $error("[CORE] X/Z on branch_taken");

    property p_no_x_exception;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(exception);
    endproperty
    assert property (p_no_x_exception)
        else $error("[CORE] X/Z on exception");

    property p_no_x_valid_flags;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(id_valid) && !$isunknown(ex_valid) &&
        !$isunknown(mem_valid) && !$isunknown(wb_valid);
    endproperty
    assert property (p_no_x_valid_flags)
        else $error("[CORE] X/Z on pipeline valid flags");

    property p_no_x_stall_flags;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(if_id_stall) && !$isunknown(id_ex_stall) &&
        !$isunknown(ex_mem_stall) && !$isunknown(mem_wb_stall);
    endproperty
    assert property (p_no_x_stall_flags)
        else $error("[CORE] X/Z on pipeline stall flags");

    property p_no_x_flush_flags;
        @(posedge clk) disable iff (!rst_n)
        !$isunknown(if_flush) && !$isunknown(id_flush) &&
        !$isunknown(ex_flush) && !$isunknown(mem_flush);
    endproperty
    assert property (p_no_x_flush_flags)
        else $error("[CORE] X/Z on pipeline flush flags");

    // ========================================================================
    // Memory Response Buffering
    // ========================================================================

    property p_mem_resp_buffer_cleared;
        @(posedge clk) disable iff (!rst_n)
        (dmem_resp_valid_buf && !mem_wb_stall) |=> !dmem_resp_valid_buf;
    endproperty
    assert property (p_mem_resp_buffer_cleared)
        else $error("[CORE] Memory response buffer not cleared after consumption");

    property p_load_waits_for_response;
        @(posedge clk) disable iff (!rst_n)
        (mem_read_mem && mem_valid && load_req_issued) |->
        (dmem_resp_valid || dmem_resp_valid_buf || mem_wb_stall);
    endproperty
    assert property (p_load_waits_for_response)
        else $error("[CORE] Load completed without waiting for response");

    // ========================================================================
    // Retirement Logic
    // ========================================================================

    // Check that retire_instr correctly prevents duplicate retirements
    // Exception: Allow while(1) loops (unconditional jump to same PC)
    logic is_while1_loop;
    assign is_while1_loop = (instr_wb[6:0] == 7'b1101111) && (instr_wb[11:7] == 5'd0); // JAL x0 (infinite loop pattern)

    property p_no_duplicate_retirement;
        @(posedge clk) disable iff (!rst_n)
        (retire_instr && !is_while1_loop) |->
        ((pc_wb != last_retired_pc) || (instr_wb != last_retired_instr));
    endproperty
    assert property (p_no_duplicate_retirement)
        else $error("[CORE] Instruction retired multiple times: PC=0x%h instr=0x%h (last: PC=0x%h instr=0x%h)",
                    pc_wb, instr_wb, last_retired_pc, last_retired_instr);

`endif // ASSERTION

endmodule

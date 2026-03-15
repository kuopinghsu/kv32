## Plan: KV32 Performance Roadmap

Create a concrete implementation plan for a staged KV32 performance roadmap that improves measurement visibility, simulator fidelity, branch prediction quality, AXI read-level parallelism, D-cache miss tolerance, and store-path throughput.

The plan must be implementation-oriented, reference the actual KV32 codebase structure, and be organized into phases with clear dependencies, verification gates, and scope boundaries.

### Objectives

The roadmap must cover these major areas:

1. Software-visible performance counters
- Expose counters for at least:
- branch mispredicts
- branch predictions
- I-cache misses
- D-cache misses
- total stall cycles
- optional stall breakdowns such as IF stall, memory stall, store-buffer stall, CMO stall, AXI AR stall, AXI R wait

2. Simulator improvements
- Add a dual-mode simulator architecture for kv32sim:
- fast functional mode when no memory model is enabled
- modeled-timing mode enabled by --mem_model=default.cfg
- In modeled-timing mode, add timing/state models for:
- BTB
- BHT
- RAS
- I-cache
- D-cache
- main memory
- Provide two memory backend models:
- SRAM with simple configurable read/write latency
- DDR4 with latency derived from DDR4 timing parameters and translated between memory clock and core clock
- The simulator timing mode should aim to correlate with RTL simulation results as closely as practical
- Add an extension interface for future timing/statistics models
- When timing mode is disabled, preserve current fast functional behavior and speed
- After simulation completes, report statistics similar to RTL simulation, including:
- instructions
- simulated cycles
- CPI
- predictor/cache/memory statistics
- wall-clock simulation time
- simulator speed such as instructions per second

3. Branch predictor quality improvements
- Keep the current prediction point compatible with the existing KV32 pipeline
- Improve BTB, BHT, and RAS quality with low-risk architectural upgrades
- Keep fallback or feature-gating knobs so legacy behavior remains available for debug and bisecting

4. Increase memory-level parallelism on AXI read path
- Improve outstanding read capability across the current bridges and arbiter
- Reduce avoidable request bottlenecks while preserving ordering guarantees

5. Non-blocking D-cache
- Plan a first implementation of hit-under-miss with a small MSHR count
- Keep first version conservative and correctness-focused

6. Store-buffer optimization
- Improve effective throughput through depth, merging/coalescing, and drain policy refinement

### Simulator Config Profiles

The plan must include a recommended sim/cfgs layout and explain intended use for each file:

- sim/cfgs/default.cfg
- sim/cfgs/functional-fast.cfg
- sim/cfgs/sram-default.cfg
- sim/cfgs/sram-lowlat.cfg
- sim/cfgs/sram-stress.cfg
- sim/cfgs/ddr4-1600.cfg
- sim/cfgs/ddr4-1866.cfg
- sim/cfgs/ddr4-3200.cfg
- sim/cfgs/includes/core-defaults.cfg
- sim/cfgs/includes/ddr4-common.cfg
- sim/cfgs/includes/stats-defaults.cfg
- sim/cfgs/examples/ext-null.cfg

The plan should explain how default.cfg composes shared defaults with a selected backend profile.

### Required Planning Output

The implementation plan should include:

1. A phased roadmap with explicit ordering and dependencies
2. A simulator-specific phase that is fully integrated into the broader roadmap, not treated as a side note
3. Exact file targets in the current repository
4. Verification steps for each phase
5. Decisions and scope boundaries
6. Recommended acceptance criteria for RTL correlation and functional stability
7. Suggested statistics and reporting format alignment between simulator and RTL

### Codebase Anchors

Use the existing KV32 codebase structure when writing the plan. Relevant files likely include:

- [sim/kv32sim.cpp](sim/kv32sim.cpp)
- [sim/kv32sim.h](sim/kv32sim.h)
- [sim/device.h](sim/device.h)
- [sim/device.cpp](sim/device.cpp)
- [sim/README.md](sim/README.md)
- [rtl/core/kv32_core.sv](rtl/core/kv32_core.sv)
- [rtl/core/kv32_csr.sv](rtl/core/kv32_csr.sv)
- [rtl/core/kv32_pkg.sv](rtl/core/kv32_pkg.sv)
- [rtl/core/kv32_btb.sv](rtl/core/kv32_btb.sv)
- [rtl/core/kv32_bht.sv](rtl/core/kv32_bht.sv)
- [rtl/core/kv32_ras.sv](rtl/core/kv32_ras.sv)
- [rtl/kv32_dcache.sv](rtl/kv32_dcache.sv)
- [rtl/core/kv32_sb.sv](rtl/core/kv32_sb.sv)
- [rtl/mem_axi_ro.sv](rtl/mem_axi_ro.sv)
- [rtl/mem_axi.sv](rtl/mem_axi.sv)
- [rtl/axi_arbiter.sv](rtl/axi_arbiter.sv)
- [rtl/kv32_soc.sv](rtl/kv32_soc.sv)
- [docs/pipeline_architecture.md](docs/pipeline_architecture.md)
- [docs/cache_architecture.md](docs/cache_architecture.md)
- [docs/kv32_soc_datasheet.adoc](docs/kv32_soc_datasheet.adoc)
- [docs/sdk_api_reference.adoc](docs/sdk_api_reference.adoc)
- [sim/README.md](sim/README.md)
- [Makefile](Makefile)
- [TODO.md](TODO.md)

### Verification Expectations

The plan must include verification using representative workloads such as:

- simple
- cachebench
- coremark
- rtos
- cache_diag

It should cover both SRAM and DDR4-oriented scenarios and distinguish:

- functional stability checks
- modeled simulator versus RTL correlation checks
- performance regression checks
- end-of-run statistics validation

### Constraints

- Keep fast functional simulation as the default path
- Make modeled timing opt-in via --mem_model=default.cfg
- Target close RTL cycle correlation, not signal-level electrical accuracy
- Keep the simulator timing framework extensible
- Keep statistics names as close to RTL output as practical
- Prefer low-risk, staged implementation over large architectural jumps

### Deliverable Style

Produce a clear implementation plan with:

- a short summary
- numbered phases
- relevant files
- verification
- decisions
- further considerations if needed

If you want, I can also compress this into a shorter agent-facing prompt variant optimized for a planning subagent rather than a human-readable prompt file.

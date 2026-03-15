# ThreadX Port (KV32)

This directory contains a bring-up port of ThreadX for KV32.

Current status:
- CLINT MTI-driven preemptive tick is enabled in the KV32 port.
- Timer ISR updates the ThreadX system clock/time-slice and re-arms CLINT each tick.
- Trap-level preemption redirection into `_tx_thread_system_return` is enabled when preemption is safe.
- Full asynchronous context save/restore is implemented in `tx_port_asm.S` for interrupt preemption.

Tick configuration:
- Default CLINT interval is controlled by `TX_KV32_CLINT_CYCLES_PER_TICK` in `ports/kv32/tx_port.h`.
- Default value is `100000ULL` (cycles per tick).
- Override it in `tx_user.h` for a different tick period.

Build and run:
- `make sim-threadx-simple`
- `make rtl-threadx-simple`

Expected sample result:
- `=== ThreadX KV32 simple 4-thread test ===`
- `[PASS] ThreadX switch/semaphore/mutex/event tests`

Framework-local build:
- `make -C rtos/threadx list-tests`
- `make -C rtos/threadx build TEST=simple`

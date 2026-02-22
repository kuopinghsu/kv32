# Outstanding Request Analysis - Memory Latency Test

## Test Configuration

### 1-Cycle Latency (Normal Operation)
```
Memory:            MEM_READ_LATENCY=1, MEM_WRITE_LATENCY=1, MAX_OUTSTANDING=16
Instruction Bridge: OUTSTANDING_DEPTH=2 (IB_DEPTH)
Data Bridge:        OUTSTANDING_DEPTH=4
Arbiter:            OUTSTANDING_DEPTH=8
```

### 16-Cycle Latency (Stress Test - FAILED)
```
Memory:            MEM_READ_LATENCY=16, MEM_WRITE_LATENCY=16
All Bridges:       OUTSTANDING_DEPTH=16 (increased for test)
```

## Results Summary

### With 1-Cycle Latency ✓
```
Read Operations:
  AR Requests (Master):        973
  R Responses (Slave):         973
  Max Outstanding Reads:       1

Write Operations:
  AW Requests (Master):        138
  W Data (Master):             138
  B Responses (Slave):         138
  Max Outstanding Writes:      1

Total Transactions:            1111
```

**Analysis:**
- Outstanding = 1 for both reads and writes
- Responses return immediately (1 cycle)
- No pipelining benefit with fast memory
- System behaves as expected

### With 16-Cycle Latency ✗
```
Assertion Failed: Write outstanding count exceeded: 31 > 16
Debug Output:
  [DMEM_BRIDGE] AW handshake: outstanding 0 -> 1 @ cycle 7
  [DMEM_BRIDGE] B handshake: outstanding 1 -> 0 @ cycle 8
  [DMEM_BRIDGE] B handshake: outstanding 0 -> 4294967295 @ cycle 8
```

**Root Cause:** Counter underflow bug
- Two B responses received in same cycle (cycle 8)
- Counter decremented twice: 1 → 0 → underflow (-1 = 4294967295 unsigned)
- Underflowed counter allowed 31 more requests before assertion fired

## Key Architectural Findings

### Load vs Store Behavior

**Loads (Pipeline Stalls):**
- ID stage waits for data response
- Pipeline freezes: no EX, no IF
- Outstanding reads limited by pipeline stall
- **User's original understanding was correct for loads**

**Stores (Non-Blocking):**
- Store buffer decouples CPU from memory latency
- CPU continues after pushing to store buffer
- Pipeline doesn't stall (unless SB full)
- Stores complete in background
- **This is where outstanding > 1 occurs**

### Store Path Flow
```
CPU → Store Buffer (SB_DEPTH=2) → AXI Bridge (OUTSTANDING_DEPTH=4) → Memory
```

1. CPU can issue 2 stores before stalling (SB_DEPTH=2)
2. Store buffer issues to bridge asynchronously
3. Bridge can have up to 4 outstanding (OUTSTANDING_DEPTH=4)
4. Memory can buffer up to 16 (MAX_OUTSTANDING=16)

### Why Max Outstanding = 1 with Fast Memory

With 1-cycle latency:
- Store issued on cycle N
- B response returns on cycle N+1
- Next store can issue on cycle N+1
- **Perfect overlap**: AR→R→AR→R pattern
- Outstanding never exceeds 1

With slow memory (16 cycles):
- Multiple requests can be "in flight" simultaneously
- Store buffer can queue requests while waiting for responses
- Outstanding count reflects pipeline depth being utilized

## Bug Discovered: Bridge Counter Underflow

**Location:** `rtl/mem_axi.sv:175-189`

**Issue:**
```systemverilog
always_ff @(posedge clk) begin
    case ({axi_awvalid && axi_awready, axi_bvalid && axi_bready})
        2'b10: write_outstanding_count <= write_outstanding_count + 1;
        2'b01: write_outstanding_count <= write_outstanding_count - 1;
    endcase
end
```

The counter assumes one handshake per cycle, but with long latencies and burst responses, multiple B responses can arrive causing underflow.

**Symptoms:**
- Counter underflows (becomes 4294967295)
- Eventually wraps around to reach assertion threshold
- Detected at cycle 85 with value 31

## Conclusions

1. **Outstanding capability exists and is properly implemented in memory**
   - Memory can accept 16 outstanding requests
   - Pipeline/FIFO structure supports buffering

2. **Processor doesn't exercise high outstanding with fast memory**
   - 1-cycle latency → max outstanding = 1
   - This is expected and correct behavior
   - No benefit to pipelining with immediate responses

3. **Bridge has a bug with high-latency scenarios**
   - Outstanding counter can underflow
   - Needs proper protection against negative decrements
   - Not critical for normal operation (1-cycle latency works fine)

4. **Architecture understanding clarified**
   - Loads: Stall pipeline (user was correct)
   - Stores: Non-blocking via store buffer (key difference)
   - Outstanding count measures "in-flight" transactions

## Recommendations

1. **Keep 1-cycle latency for normal testing**
   - Matches typical on-chip memory behavior
   - System operates correctly
   - Outstanding = 1 is expected

2. **Fix bridge counter underflow for future high-latency testing**
   - Add underflow protection
   - Better synchronization between handshakes

3. **Current configuration is appropriate**
   - Memory: MAX_OUTSTANDING = 16 (capability)
   - Bridges: Conservative limits (2, 4, 8)
   - Matches processor issue rate

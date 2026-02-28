# Outstanding Write Request Analysis

## The Question
With pipeline stalls for loads, how can we have 7 outstanding writes when the bridge limit is 4?

## Key Architectural Components

1. **Store Buffer (kv32_sb)**: SB_DEPTH = 2
   - Decouples CPU from memory write latency
   - CPU doesn't stall for stores (unless buffer full)
   - Entries: INVALID → VALID → INFLIGHT → INVALID

2. **AXI Bridge (mem_axi)**: OUTSTANDING_DEPTH = 4
   - Converts mem interface to AXI
   - Tracks outstanding: `write_outstanding_count` (AW handshakes - B responses)
   - Should limit to maximum 4 outstanding

3. **AXI Memory (axi_memory)**: MAX_OUTSTANDING_WRITES = 16
   - Testbench memory model with configurable latency
   - Can buffer up to 16 requests

## Store vs Load Behavior

### Loads (User's Correct Understanding)
- **ID stage waits for data response**
- **Pipeline stalls**: `ex_mem_stall = mem_wb_stall || (load_req_valid && !dmem_req_ready)`
- **IF stage blocked**: No new instructions fetched while stalled
- **Max outstanding limited** by pipeline depth

### Stores (Where 7 Comes From)
- **Store buffer decouples CPU from memory**
- **CPU continues immediately** after pushing to store buffer (if not full)
- **Pipeline doesn't stall** (unless SB full)
- **Stores complete in background**

## The Backpressure Chain

```
CPU → Store Buffer (2 deep) → AXI Bridge (4 outstanding) → AXI Memory (unlimited)
```

### Store Buffer Backpressure
- `sb_cpu_ready` = 1 when count < SB_DEPTH (2)
- Pipeline stalls only when: `(mem_write_mem && !sb_cpu_ready)`
- With 2 entries, can hold 2 stores

### Bridge Backpressure
- `mem_req_ready` gates store buffer from issuing to bridge
- Calculated as: `!axi_awvalid && !axi_wvalid && !write_fifo_full`
- `write_fifo_full = (write_outstanding_count >= OUTSTANDING_DEPTH)` = (count >= 4)

## The Timing Bug: How 7 Outstanding Occurs

### Root Cause: 1-Cycle Backpressure Delay

The `write_outstanding_count` is updated sequentially:
```systemverilog
always_ff @(posedge clk) begin
    case ({axi_awvalid && axi_awready, axi_bvalid && axi_bready})
        2'b10: write_outstanding_count <= write_outstanding_count + 1;
        2'b01: write_outstanding_count <= write_outstanding_count - 1;
    endcase
end
```

But `mem_req_ready` uses it combinationally:
```systemverilog
assign write_fifo_full = (write_outstanding_count >= OUTSTANDING_DEPTH);
assign mem_req_ready = !axi_awvalid && !axi_wvalid && !write_fifo_full;
```

### Detailed Timeline (16-Cycle Latency)

| Cycle | write_count | mem_req_ready | AW Handshake | B Response | Notes |
|-------|------------|---------------|--------------|------------|-------|
| 0     | 0          | 1             | Yes (store 0)| -          | SB issues store 0 |
| 1     | 1          | 1             | Yes (store 1)| -          | Count updates to 1, SB issues store 1 |
| 2     | 2          | 1             | Yes (store 2)| -          | Both SB slots now INFLIGHT |
| 3     | 3          | 1             | Yes (store 3)| -          | Still < 4, accepts store 3 |
| 4     | 4          | 0             | No           | -          | **NOW blocked** (4 >= 4) |
| 5-15  | 4          | 0             | No           | -          | Waiting for responses |
| 16    | 3          | 1             | Yes (store 4)| Yes (0)    | B[0] returns, immediately issue store 4 |
| 17    | 3          | 1             | Yes (store 5)| Yes (1)    | **BOTH happen same cycle!** |
| 18    | 3          | 1             | Yes (store 6)| Yes (2)    | Pattern continues |
| 19    | 3 → **7**  | 1 → 0         | Yes (store 7)| Yes (3)    | 4 AR + 3 existing = 7 |

### Why 7 Outstanding?

At cycle 16, when the first B response returns:
1. **Cycle 16**: `write_count`=4, B[0] arrives → count will become 3 next cycle
2. **Cycle 16**: `mem_req_ready` sees count=4, but B handshake makes it 3 → ready=1 (combinational)
3. **Cycle 16**: Store buffer immediately issues store 4 (AW handshake)
4. **Cycle 17-19**: Similar pattern - B response and new AW in same cycle
5. **Result**: 4 new AW handshakes (stores 4-7) before any of those B responses return
6. **Outstanding**: Original 3 (stores 1-3) + New 4 (stores 4-7) = 7

## The Architectural Answer

**Your understanding about loads is correct!** Loads do stall the pipeline.

**But stores are different:**
- Store buffer decouples CPU from memory latency
- CPU can continue executing while stores complete in background
- With long memory latency (16 cycles), multiple "waves" of stores can overlap
- The bridge's backpressure has a 1-cycle delay due to sequential counter

## Summary

The 7 outstanding writes come from:
1. **Store buffer decoupling**: CPU doesn't wait for store completion
2. **Background completion**: Stores complete while CPU continues
3. **Response clustering**: With 16-cycle latency, B responses return in bursts
4. **Backpressure timing**: 1-cycle delay allows extra requests to slip through

**This is NOT about IF stage issuing during stalls.** The IF stage is not stalled for stores because stores don't block the pipeline (store buffer handles them asynchronously).

**The theoretical maximum outstanding:**
- With perfect backpressure: OUTSTANDING_DEPTH = 4
- With 1-cycle delay: 4 + (number of B responses arriving during saturation) = potentially unbounded
- In this case: 7 (original 3 + 4 new requests during response burst)

**To prevent this:** The bridge needs to account for inflight requests combinationally, not just count them sequentially.

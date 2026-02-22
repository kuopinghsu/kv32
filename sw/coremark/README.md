# CoreMark Benchmark for RISC-V

CoreMark is an industry-standard benchmark developed by EEMBC (Embedded Microprocessor Benchmark Consortium) that measures the performance of embedded processors.

## About CoreMark

**Official Repository**: https://github.com/eembc/coremark

CoreMark consists of four major algorithms:
- **List processing** (find and sort)
- **Matrix manipulation** (common matrix operations)
- **State machine** (determine if an input stream contains valid numbers)
- **CRC** (cyclic redundancy check)

## Implementation Notes

This is a simplified baremetal adaptation for the RISC-V core:

**Baremetal Adaptations**:
- No `malloc()` - all data structures statically allocated
- Custom I/O using magic console address (0xFFFFFFF4)
- Timing via CSR cycle counters (`mcycle`)
- Reduced iterations for faster simulation
- Simplified validation (no full CoreMark score calculation)

**Limitations**:
- Not official CoreMark compliant (requires full validation)
- Reduced data set for simulation speed
- Single-threaded only
- No floating-point operations

## Building and Running

```bash
# Build CoreMark
make sw-coremark

# Run CoreMark benchmark
make rtl-coremark MAX_CYCLES=0

# View results
cat build/rtl_output.log | grep -A 20 "CoreMark"
```

## Expected Results

The benchmark will report:
- Total cycles
- Iterations completed
- CoreMark score estimate
- Performance metrics

**Note**: This is a demonstration/test version. For official CoreMark scores, use the full EEMBC CoreMark suite with proper validation.

## Source

This implementation is inspired by the official CoreMark but simplified for baremetal embedded systems without dynamic memory allocation.

## References

- CoreMark Official: https://www.eembc.org/coremark/
- CoreMark GitHub: https://github.com/eembc/coremark
- CoreMark Documentation: https://github.com/eembc/coremark/blob/main/README.md

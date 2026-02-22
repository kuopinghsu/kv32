# Whetstone Benchmark

Whetstone is one of the oldest synthetic benchmarks, originally developed in 1972 to measure floating-point performance.

## About Whetstone

**History**: Developed at the UK National Physical Laboratory

Whetstone measures:
- Floating-point operations
- Array operations
- Mathematical functions (sine, cosine, exponential, etc.)
- Conditional branches
- Integer operations

## Implementation Notes

This is an **integer-only** baremetal adaptation since the RISC-V core does not have FPU:

**Adaptations**:
- Fixed-point arithmetic instead of floating-point
- Scaling factor: 1000 for decimal precision
- Integer trigonometric approximations
- No dynamic memory allocation
- Custom I/O using magic console address
- Timing via CSR cycle counters
- Reduced iterations for simulation

**Limitations**:
- Not representative of true floating-point performance
- Integer approximations reduce accuracy
- Simplified mathematical functions
- Cannot produce official MWIPS score

**Note**: For true floating-point benchmarking, a processor with F/D extensions is required.

## Building and Running

```bash
# Build Whetstone
make sw-whetstone

# Run Whetstone benchmark
make rtl-whetstone MAX_CYCLES=0

# View results
cat build/rtl_output.log | grep -A 10 "Whetstone"
```

## Expected Results

The benchmark will report:
- Total cycles
- Iterations completed
- Approximate performance metrics

## References

- Whetstone History: https://en.wikipedia.org/wiki/Whetstone_(benchmark)
- Original Paper: "The Whetstone Benchmark" by Brian Wichmann (1976)

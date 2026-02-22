# Embench IoT Benchmark Suite

Embench is a modern embedded benchmark suite designed to replace Dhrystone and CoreMark with more realistic embedded workloads.

## About Embench

**Official Repository**: https://github.com/embench/embench-iot

Embench IoT consists of 19 small embedded benchmarks representing real embedded applications:
- **aha-mont64**: Montgomery multiplication (cryptography)
- **crc32**: CRC-32 calculation
- **cubic**: Cubic equation solver
- **edn**: Event detection
- **huffbench**: Huffman compression
- **matmult-int**: Integer matrix multiplication
- **minver**: Matrix inversion
- **nbody**: N-body simulation
- **nettle-aes**: AES encryption
- **nettle-sha256**: SHA-256 hashing
- **nsichneu**: Neural network
- **picojpeg**: JPEG decoder
- **qrduino**: QR code generation
- **sglib-combined**: Generic data structures
- **slre**: Regular expression matching
- **st**: Statistical functions
- **statemate**: State machine
- **ud**: UD benchmark
- **wikisort**: Sorting algorithm

## Implementation Notes

This is a simplified baremetal adaptation featuring a subset of Embench tests:

**Included Tests**:
- `crc32` - CRC-32 calculation
- `cubic` - Cubic equation solver
- `matmult` - Integer matrix multiplication
- `minver` - Matrix inversion
- `nsichneu` - Neural network

**Baremetal Adaptations**:
- No dynamic memory allocation
- Custom I/O using magic console address
- Timing via CSR cycle counters
- Reduced data sets for simulation speed
- Simplified framework (no Python harness)

## Building and Running

```bash
# Build Embench
make sw-embench

# Run Embench suite
make rtl-embench MAX_CYCLES=0

# View results
cat build/rtl_output.log | grep -A 5 "Embench"
```

## Expected Results

Each benchmark will report:
- Execution cycles
- Test pass/fail status
- Performance relative to baseline

## References

- Embench Website: https://www.embench.org/
- Embench GitHub: https://github.com/embench/embench-iot
- Embench Paper: https://arxiv.org/abs/2007.00794

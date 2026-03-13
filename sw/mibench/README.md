# MiBench Benchmark Suite

MiBench is a commercially representative embedded benchmark suite from the University of Michigan.

## About MiBench

**Official Website**: http://vhosts.eecs.umich.edu/mibench/

MiBench contains benchmarks from six categories:
- **Automotive**: Basic control, Susan (image recognition)
- **Consumer**: JPEG, LAME (MP3), Mad (MP3 decoder), Tiff
- **Office**: Ghostscript, Ispell, Rsynth, Stringsearch
- **Network**: Dijkstra, Patricia
- **Security**: Blowfish, Rijndael (AES), SHA, PGP
- **Telecom**: ADPCM, CRC, FFT, GSM

## Implementation Notes

This is a simplified baremetal adaptation featuring a subset of MiBench:

**Included Benchmarks**:
- **qsort**: Quicksort algorithm (automotive)
- **dijkstra**: Shortest path algorithm — 16-node graph (network)
- **blowfish**: Blowfish block cipher encryption (security)
- **fft**: Integer butterfly FFT (telecomm)
- **sha1**: SHA-1 cryptographic hash — verified against golden digest (security)
- **bitcount**: Bit population count — 3 methods: shift, Wegner, parallel (automotive)
- **adpcm**: IMA-ADPCM audio codec — encode + decode roundtrip (telecomm)
- **stringsearch**: Knuth-Morris-Pratt exact pattern match — 7 patterns (office)

**Baremetal Adaptations**:
- No file I/O - data embedded in code
- No dynamic memory allocation
- Custom I/O using magic console address
- Timing via CSR cycle counters
- Reduced data sets for simulation

## Building and Running

```bash
# Build MiBench
make sw-mibench

# Run MiBench suite
make rtl-mibench MAX_CYCLES=0

# View results
cat build/rtl_output.log | grep -A 5 "MiBench"
```

## Expected Results

Each benchmark will report:
- Execution cycles
- Test validation (checksum/result)
- Performance metrics

## References

- MiBench Website: http://vhosts.eecs.umich.edu/mibench/
- MiBench Paper: "MiBench: A free, commercially representative embedded benchmark suite"
- GitHub Mirror: https://github.com/embecosm/mibench

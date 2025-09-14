# zig-crypto-bench

[![CI](https://github.com/jadnohra/zig-crypto-bench/workflows/CI/badge.svg)](https://github.com/jadnohra/zig-crypto-bench/actions)

Crypto benchmarks: Zig vs Rust performance comparison.

## Overview

Cryptographic performance benchmarks across Zig stdlib and Rust implementations with hardware acceleration.


## Results

Run benchmarks to generate timestamped results in `results/` directory:

```bash
zig build bench -- --save-results
```


## Installation

### Prerequisites

- Zig 0.14.1 or later
- Rust toolchain (for building the comparison library)

### Build Instructions

```bash
git clone https://github.com/yourusername/zig-crypto-bench
cd zig-crypto-bench
zig build bench
```


## Usage

```bash
# Run all benchmarks with default settings (500 iterations, 50 warmup)
zig build bench

# Save timestamped results to results/ directory for contribution
zig build bench -- --save-results

# Run with custom iteration counts
zig build bench -- --iterations 2000 --warmup 200

# Generate JSON output for analysis
zig build bench -- --json > results.json

# Filter specific tests by size
zig build bench -- --filter 1MB

# Combined: save results with custom settings
zig build bench -- --save-results --iterations 1000 --warmup 100
```

## Features

- Configuration transparency
- Nanosecond-precision timing
- Statistical analysis
- Build optimization tracking
- Correctness verification



## Methodology

The benchmarking framework employs rigorous measurement protocols:

- Platform-specific nanosecond timers (mach_absolute_time, clock_gettime, etc.)
- Adaptive iteration counts with auto-scaling for large inputs
- Warmup phase to stabilize CPU performance
- Auto-batching for accurate timing of fast operations
- Correctness verification via bitwise output comparison
- Transparent build configuration and optimization flags

## Contributing

Contributions welcome for additional algorithms, implementations, or measurement improvements.

**Hardware Results**: Help expand hardware coverage by contributing benchmark results from your system. Run with `--save-results` and submit the generated markdown files from the `results/` directory.

## License

MIT License - see LICENSE file for details.

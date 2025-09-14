# zig-crypto-bench

[![CI](https://github.com/jadnohra/zig-crypto-bench/workflows/CI/badge.svg)](https://github.com/jadnohra/zig-crypto-bench/actions)

Crypto benchmarks: Zig vs Rust performance comparison.

## Overview

Cryptographic performance benchmarks across Zig stdlib and Rust implementations with hardware acceleration.

**Supported platforms**: Linux and macOS (x86_64, aarch64)


## Results

Run benchmarks to generate timestamped results in [**`results/`**](results/) directory:

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

- Adaptive iteration counts with auto-scaling for large inputs
- Warmup phase to stabilize CPU performance
- Auto-batching for accurate timing of fast operations
- Correctness verification via bitwise output comparison
- Transparent build configuration and optimization flags
- Statistical analysis
- CPU frequency governor detection and throttling warnings
- Framework versioning with git commit tracking in results

## Contributing

### Contributing Results

**Hardware Results**: Help expand hardware coverage by contributing benchmark results from your system. Run with --save-results and submit the generated markdown files from the [results/](results/) directory.

**Open Issues**: Check the [issues](https://github.com/jadnohra/zig-crypto-bench/issues) for tasks ranging from small improvements to major features.

**Development Conventions**:
- Test functions must print their title at the start using `std.debug.print("\n✓ Running: Test Name\n", .{});`
  (This is idiomatic in Zig as the test runner lacks built-in verbose output)

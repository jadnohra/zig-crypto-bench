# Cloud Benchmark Platform

Automated system for running benchmarks on dedicated cloud hardware.

## Features

- Multiple cloud provider support (Oracle, AWS, Scaleway, etc.)
- Automatic instance provisioning and teardown
- Cost estimation and safety controls
- Results submission as GitHub PRs
- Zero-cost option via Oracle Cloud free tier

## Quick Start

```bash
# Setup a provider (interactive wizard)
python cloud/setup.py

# Run benchmark on cheapest available provider
python cloud/bench.py run

# Run on specific provider
python cloud/bench.py run --provider oracle

# Emergency cleanup
python cloud/bench.py cleanup --all
```

## Directory Structure

```
cloud/
├── providers/       # Cloud provider implementations
│   ├── base.py     # Abstract base class
│   ├── oracle.py   # Oracle Cloud
│   ├── scaleway.py # Scaleway
│   └── aws.py      # AWS
├── core/           # Core functionality
│   ├── safety.py   # Safety and termination
│   ├── executor.py # Remote execution
│   └── costs.py    # Cost tracking
├── configs/        # Default configurations
│   └── defaults.yaml
├── bench.py        # Main CLI entry point
└── setup.py        # Provider setup wizard
```

## Provider Support

| Provider | Status | Free Tier | Dedicated CPU | Hourly Billing |
|----------|--------|-----------|---------------|----------------|
| Oracle   | ✅     | Yes (4 CPU, 24GB) | Yes | No (free) |
| Scaleway | 🚧     | No | Yes (bare metal) | Yes |
| Hetzner  | 🚧     | No | Yes | No (monthly) |
| AWS      | 🚧     | Limited | Yes (metal) | Yes |

## Safety Features

1. **Multiple termination safeguards**
2. **Cost estimation before creation**
3. **Automatic cleanup on exit**
4. **Hard cost limits**
5. **Orphaned instance detection**

## Configuration

Provider credentials are stored in `~/.config/cloud-bench/` or environment variables.
Never store credentials in this repository.
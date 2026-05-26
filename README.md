# ⏱️ Tau-Profiler

Cross-platform memory subsystem latency probe.
Supports Linux / macOS / Windows, x86_64 / AArch64.

## Benchmarks

- Cache Latency: pointer chase 4KB->64MB (L1/L2/L3/DRAM)
- TLB Reach: cross-page pointer chains (L1/L2 TLB)
- Page Fault: first-touch vs second-touch timing
- Context Switch: inter-thread signaling (estimates)

## Quick Start

```bash
git clone https://github.com/vamfish/tau-profiler.git
cd tau-profiler
zig build -Doptimize=ReleaseFast
./zig-out/bin/tau_profiler
```

Requires Zig >= 0.17.0-dev. Python 3 optional for tau_client.py.

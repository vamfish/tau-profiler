# ⏱️ Tau-Profiler

[//]: # (ASCII art header)
```
  ████████╗ █████╗ ██╗   ██╗    ██████╗ ██████╗  ██████╗ ███████╗██╗██╗     ███████╗██████╗
  ╚══██╔══╝██╔══██╗██║   ██║    ██╔══██╗██╔══██╗██╔═══██╗██╔════╝██║██║     ██╔════╝██╔══██╗
     ██║   ███████║██║   ██║    ██████╔╝██████╔╝██║   ██║█████╗  ██║██║     █████╗  ██████╔╝
     ██║   ██╔══██║██║   ██║    ██╔═══╝ ██╔══██╗██║   ██║██╔══╝  ██║██║     ██╔══╝  ██╔══██╗
     ██║   ██║  ██║╚██████╔╝    ██║     ██║  ██║╚██████╔╝██║     ██║███████╗███████╗██║  ██║
     ╚═╝   ╚═╝  ╚═╝ ╚═════╝     ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═╝     ╚═╝╚══════╝╚══════╝╚═╝  ╚═╝
```

Cross-platform memory subsystem latency probe.
Supports **Linux / macOS / Windows**, **x86_64 / AArch64**.

## Benchmarks

| Benchmark | What it measures |
|-----------|------------------|
| **Cache Latency** | Pointer chase 4KB → 64MB (L1/L2/L3/DRAM hierarchy) |
| **TLB Reach** | Cross-page pointer chains (L1/L2 TLB size & miss latency) |
| **Page Fault** | First-touch vs second-touch timing (minor fault overhead) |
| **Context Switch** | Inter-thread futex/yield ping-pong (scheduler latency) |

## Quick Start

### 🚀 Pre-built binary (recommended)
The repo includes a pre-compiled static binary — no Zig installation needed:

```bash
git clone https://github.com/vamfish/tau-profiler.git
cd tau-profiler

# CLI mode (no dependencies)
./zig-out/bin/tau_profiler

# GUI mode (requires Python + PyQt6)
uv sync
uv run python tau_gui.py
# If you do not use uv
# pip install -r requirements.txt
# python tau_gui.py
```

### 🔧 Build from source
If you want to modify the engine, you'll need **Zig ≥ 0.17.0-dev**:

```bash
# Fast native build (optimized for YOUR CPU)
zig build -Doptimize=ReleaseFast

# Portable build (works on most CPUs, no AVX-512)
zig build -Dtarget=x86_64-windows -Dcpu=x86_64_v3 -Doptimize=ReleaseFast

# Maximum compatibility (slow, works on ANY x86-64 CPU since 2003)
zig build -Dtarget=x86_64-windows -Dcpu=baseline -Doptimize=ReleaseFast

# Cross-compile for Linux/macOS (from Windows)
zig build -Dtarget=x86_64-linux-gnu -Dcpu=x86_64_v3 -Doptimize=ReleaseFast
zig build -Dtarget=x86_64-macos -Dcpu=x86_64_v3 -Doptimize=ReleaseFast

# Build all portable binaries
pwsh scripts/build-portable.ps1
```

> **CPU compatibility levels:**
> | Level | Feature set | Works on | Performance |
> |-------|------------|----------|-------------|
> | `native` | All features of your CPU | Build machine only | Fastest |
> | `x86_64_v3` | AVX2, BMI, FMA | Intel Haswell+ (2013), AMD Excavator+ (2015) | Good |
> | `x86_64_v2` | SSE4.2, POPCNT | Intel Nehalem+ (2008), AMD Barcelona+ (2007) | OK |
> | `baseline` | Basic x86-64 | Any x86-64 CPU | Slowest |

> ⚠️ **Why 0.17.0-dev?** The engine uses the new `std.Io` API introduced in Zig 0.17.
> This version is **not** available via `winget` / `apt` / `brew` yet.
> Install from [ziglang.org/download](https://ziglang.org/download/) → choose the latest **master** build.
> Or use [zigup](https://github.com/marler8997/zigup) / [zvm](https://github.com/tristanisham/zvm) to manage Zig versions.

##  Screenshot

```
⫸  TAU  PROFILER  ⫷
┌──────────────────────────────────────────────────────────────┐
│  🖥  DASHBOARD  │  📊  CACHE  │  📖  TLB  │  📄  PAGE FAULT  │  🔄  CTX  │  📋  REPORT  │
├──────────────────────────────────────────────────────────────┤
│  Platform: AMD Ryzen 5 3550H │ 8 logical cores │ WSL2      │
│  τ_L1: 1.43ns  τ_L2: 3.34ns  τ_L3: 9.06ns  τ_DRAM: 141ns  │
│  TSC: 2096.31 MHz                                           │
│  [Interactive cache/TLB/pagefault/ctx-switch charts]        │
└──────────────────────────────────────────────────────────────┘
```

## Features

- **🖥 Dashboard** — system info, timer calibration, τ constants
- **📊 Cache Chart** — bar/line/scatter for memory hierarchy latencies
- **📖 TLB Chart** — page count vs latency, hierarchical breakdown
- **📄 Page Fault Analysis** — minor fault & TLB shootdown overhead
- **🔄 Context Switch** — futex vs yield ping-pong comparison
- **📋 Report Export** — PDF (ReportLab) & HTML (dark hacker style)
- **💾 Save Charts** — export interactive charts as PNG
- **🎨 Hacker Theme** — green-on-black terminal aesthetic

## Output

```
Tau_cycle: 477.03 ps
┌──────────────────┬──────────┬───────────┬────────┐
│ Cache Level      │ Size     │ Latency   │ Cycles │
├──────────────────┼──────────┼───────────┼────────┤
│ L1 Data Cache    │    32 KB │ 1.43 ns   │   3.26 │
│ L2 Cache         │   256 KB │ 3.34 ns   │   7.62 │
│ L3/LLC           │     4 MB │ 53.43 ns  │ 112.78 │
│ DRAM Main Memory │    64 MB │ 141.20 ns │ 296.06 │
└──────────────────┴──────────┴───────────┴────────┘
```

## Requirements

- **Zig** ≥ 0.17.0-dev (build the engine)
- **Python** ≥ 3.10 (GUI client)
- **PyQt6** + **pyqtgraph** + **reportlab** (see `requirements.txt`)

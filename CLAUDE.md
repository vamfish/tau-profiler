# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run Commands

```bash
# Build Zig engine (requires Zig >= 0.17.0-dev)
zig build -Doptimize=ReleaseFast

# Run engine directly (binary mode, outputs JSON to stdout)
./zig-out/bin/tau_profiler

# Run engine + quick CLI report (Python client)
uv run python tau_client.py
# or: pip install -r requirements.txt && python tau_client.py

# Run GUI (PyQt6 interactive charts + PDF/HTML export)
uv run python tau_gui.py

# Headless JSON dump (no display needed)
TAU_HEADLESS=1 python tau_gui.py

# Run Zig engine tests
zig build test
```

Requirements: Zig >= 0.17.0-dev (uses new `std.Io` API), Python >= 3.10, PyQt6 + pyqtgraph + reportlab (see `pyproject.toml`).

## Architecture

**Two-layer design: Zig engine + Python frontend.**

### Zig engine (`src/`)

The engine is a native binary that performs low-level hardware benchmarking and writes JSON to stdout. Progress/log messages go to stderr.

| Module | Role |
|--------|------|
| `src/main.zig` | Entry point: orchestrates platform detection → timer calibration → core pinning → all 4 benchmarks → JSON output |
| `src/root.zig` | Library root, re-exports all modules, defines test entry |
| `src/platform.zig` | CPU/platform detection via CPUID (x86_64), sysfs/proc (Linux), sysctl (macOS), Win32 API. Handles core affinity binding. |
| `src/timer.zig` | TSC calibration (x86_64 RDTSCP), CNTVCT (AArch64), fallback to OS monotonic clock. Measures timer overhead. |
| `src/cache.zig` | Cache latency pointer-chase sweep from 4KB to 64MB |
| `src/tlb.zig` | TLB reach probe via cross-page pointer chains |
| `src/pagefault.zig` | Minor page fault overhead (first-touch vs second-touch) and TLB shootdown |
| `src/ctxswitch.zig` | Context switch latency via futex/yield thread ping-pong |
| `src/stats.zig` | Statistical filtering (confidence scoring) |

`build.zig` defines a library module (`tau_profiler`) and an executable (`tau_profiler`), both using Zig 0.17's `std.Io` API. The executable goes to `zig-out/bin/`.

### Python clients

- **`tau_client.py`** — CLI client. Calls the Zig engine via `subprocess`, parses stdout JSON, renders formatted tables to terminal.
- **`tau_gui.py`** — Full GUI with PyQt6 + pyqtgraph. Tabs: Dashboard, Cache, TLB, Page Fault, Context Switch, Report. Exports PDF (ReportLab) and HTML reports. The `run_engine()` wrapper normalizes v1→v2 JSON format and `size_bytes`→`size` backward compat. Supports headless mode via `TAU_HEADLESS` env var.

### Data flow

```
zig-out/bin/tau_profiler (stderr: progress, stdout: JSON)
    → tau_client.py  (terminal tables)
    → tau_gui.py     (interactive charts, export)
```

JSON structure (v2): `{ version, timestamp, status, calibration, platform, cache[], tlb[], pagefault[], ctxswitch[], warnings[] }`

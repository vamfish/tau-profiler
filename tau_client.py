#!/usr/bin/env python3
"""
Tau-Profiler Client — Phase 1 Prototype
Calls the Zig engine, parses JSON output, displays results.
"""

import subprocess
import json
import sys
import os


def find_engine() -> str:
    """Locate the compiled Zig engine binary."""
    candidates = [
        "./zig-out/bin/tau_profiler",
        "./tau_profiler",
        os.path.join(os.path.dirname(__file__), "zig-out", "bin", "tau_profiler"),
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    raise FileNotFoundError(
        "Tau engine binary not found. Build it first: zig build"
    )


def run_engine(engine_path: str) -> dict:
    """
    Run the Zig engine, capture JSON output from stdout,
    while stderr is shown in real-time.
    """
    print("🚀 Launching Tau-Profiler engine...")
    print()

    process = subprocess.Popen(
        [engine_path],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    # Read stderr line-by-line and display
    stderr_lines = []
    stdout_lines = []

    # We need to read both streams. Use a selective approach.
    # Read all stderr first (it's small enough)
    stderr_text = process.stderr.read()
    stdout_text = process.stdout.read()

    process.wait()

    # Print stderr (debug output)
    for line in stderr_text.split("\n"):
        if line.strip():
            print(f"  {line}")

    if process.returncode != 0:
        print(f"\n❌ Engine exited with code {process.returncode}")
        sys.exit(1)

    # Parse JSON from stdout
    try:
        data = json.loads(stdout_text)
        return data
    except json.JSONDecodeError as e:
        print(f"\n❌ Failed to parse JSON output: {e}")
        print(f"Raw stdout:\n{stdout_text[:500]}")
        sys.exit(1)


def render_results(data: dict):
    """Display results in a formatted terminal output."""
    plat = data.get("platform", {})
    cal = data.get("calibration", {})
    results = data.get("results", [])
    warnings = data.get("warnings", [])

    print()
    print("=" * 60)
    print("  🖥️  系统平台信息")
    print("=" * 60)
    print(f"  OS:        {plat.get('os', '?')}")
    print(f"  Arch:      {plat.get('arch', '?')}")
    print(f"  CPU:       {plat.get('cpu_brand', '?')}")
    print(f"  Vendor:    {plat.get('cpu_vendor', '?')}")
    print(f"  Cores:     {plat.get('physical_cores', '?')}P / {plat.get('logical_cores', '?')}L")
    print(f"  Page:      {plat.get('page_size', '?')} bytes")
    print(f"  VM:        {plat.get('is_virtualized', '?')} ({plat.get('virtualized_under', '?')})")

    print()
    print("=" * 60)
    print("  ⏱️  计时器校准")
    print("=" * 60)
    if cal.get("calibrated"):
        print(f"  TSC 频率:   {cal['tsc_hz'] / 1_000_000:.2f} MHz")
        cpu_ps = (1.0 / cal["tsc_hz"]) * 1e12
        print(f"  τ_cycle:    {cpu_ps:.2f} ps  (CPU 核心节拍)")
    else:
        print("  ⚠️  TSC 校准失败，使用系统时钟")

    print()
    print("=" * 60)
    print("  📊 内存层级延迟测试结果")
    print("=" * 60)
    print(f"  {'层级':<18} {'大小':>8} {'延迟(ns)':>10} {'周期':>8} {'置信度':>6}")
    print(f"  {'-'*18} {'-'*8} {'-'*10} {'-'*8} {'-'*6}")
    for r in results:
        size = r.get("size_bytes", 0)
        if size >= 1024 * 1024:
            size_str = f"{size // (1024*1024)}MB"
        elif size >= 1024:
            size_str = f"{size // 1024}KB"
        else:
            size_str = f"{size}B"
        print(f"  {r['label']:<18} {size_str:>8} {r['latency_ns']:>10.2f} {r['latency_cycles']:>8.1f} {r['confidence']:>5.0%}")

    # Find key transition points
    print()
    print("=" * 60)
    print("  📈 关键时间常数 (Tau)")
    print("=" * 60)

    # Find DRAM latency (largest size that's > 32MB)
    dram = [r for r in results if r.get("size_bytes", 0) >= 32 * 1024 * 1024]
    l3 = [r for r in results if 512 * 1024 <= r.get("size_bytes", 0) <= 4 * 1024 * 1024]
    l2 = [r for r in results if 64 * 1024 <= r.get("size_bytes", 0) <= 256 * 1024]
    l1 = [r for r in results if r.get("size_bytes", 0) <= 32 * 1024]

    def avg_lat(items):
        if not items:
            return 0
        return sum(r["latency_ns"] for r in items) / len(items)

    tau_cpu_cycle = cpu_ps if cal.get("calibrated") else 0
    tau_l1 = avg_lat(l1) if l1 else 0
    tau_l2 = avg_lat(l2) if l2 else 0
    tau_l3 = avg_lat(l3) if l3 else 0
    tau_dram = avg_lat(dram) if dram else 0

    print(f"  τ_cycle    (CPU 周期):    {tau_cpu_cycle:>8.2f} ps")
    print(f"  τ_L1       (L1 缓存):     {tau_l1:>8.2f} ns  ({tau_l1 * 1000:>8.0f} ps)")
    print(f"  τ_L2       (L2 缓存):     {tau_l2:>8.2f} ns")
    print(f"  τ_L3       (L3/LLC):      {tau_l3:>8.2f} ns")
    print(f"  τ_DRAM     (主存):        {tau_dram:>8.2f} ns")

    if tau_cpu_cycle > 0 and tau_dram > 0:
        ratio = (tau_dram * 1000) / tau_cpu_cycle
        print(f"\n  🔬 从 CPU 周期到 DRAM 延迟跨度: ~{ratio:.0f}x")

    if warnings:
        print()
        print("=" * 60)
        print("  ⚠️  警告")
        print("=" * 60)
        for w in warnings:
            print(f"  • {w}")

    print()
    print("=" * 60)
    print("  ✅ 测试完成")
    print("=" * 60)


def main():
    engine = find_engine()
    data = run_engine(engine)
    render_results(data)


if __name__ == "__main__":
    main()

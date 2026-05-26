#!/usr/bin/env python3
"""
Tau-Profiler Client — Phase 2
Calls the Zig engine, parses JSON output, displays results.
Supports cache, TLB, page fault, and context switch benchmarks.
"""

import subprocess
import json
import sys
import os
import math


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
    """Run the Zig engine, capture JSON output from stdout."""
    print("🚀 Launching Tau-Profiler engine...")
    print()

    process = subprocess.Popen(
        [engine_path],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    stderr_text = process.stderr.read()
    stdout_text = process.stdout.read()
    process.wait()

    for line in stderr_text.split("\n"):
        if line.strip():
            print(f"  {line}")

    if process.returncode != 0:
        print(f"\n❌ Engine exited with code {process.returncode}")
        sys.exit(1)

    try:
        data = json.loads(stdout_text)
        return data
    except json.JSONDecodeError as e:
        print(f"\n❌ Failed to parse JSON output: {e}")
        print(f"Raw stdout:\n{stdout_text[:500]}")
        sys.exit(1)


def fmt_ns(ns: float) -> str:
    """Format nanoseconds nicely."""
    if ns < 0.001:
        return f"{ns * 1000:.2f} ps"
    if ns < 1:
        return f"{ns * 1000:.1f} ps"
    if ns < 1000:
        return f"{ns:.2f} ns"
    return f"{ns / 1000:.3f} µs"


def fmt_size(b: int) -> str:
    """Format bytes nicely."""
    if b >= 1024 * 1024 * 1024:
        return f"{b / (1024*1024*1024):.1f}GB"
    if b >= 1024 * 1024:
        return f"{b // (1024*1024)}MB"
    if b >= 1024:
        return f"{b // 1024}KB"
    return f"{b}B"


def render_platform(data: dict):
    plat = data.get("platform", {})
    cal = data.get("calibration", {})

    print()
    print("=" * 60)
    print("  🖥️  系统平台信息")
    print("=" * 60)
    print(f"  OS:        {plat.get('os', '?')}")
    print(f"  Arch:      {plat.get('arch', '?')}")
    print(f"  CPU:       {plat.get('cpu_brand', '?')}")
    print(f"  Vendor:    {plat.get('cpu_vendor', '?')}")
    print(f"  Cores:     {plat.get('physical_cores', '?')}P / {plat.get('logical_cores', '?')}L")
    print(f"  Page:      {fmt_size(plat.get('page_size', 4096))}")
    print(f"  VM:        {plat.get('is_virtualized', '?')} ({plat.get('virtualized_under', '?')})")

    print()
    print("=" * 60)
    print("  ⏱️  计时器校准")
    print("=" * 60)
    if cal.get("calibrated"):
        hz = cal["tsc_hz"]
        print(f"  频率:        {hz / 1_000_000:.2f} MHz")
        cpu_ps = (1.0 / hz) * 1e12
        print(f"  τ_cycle:     {cpu_ps:.2f} ps")
    else:
        print("  ⚠️  校准失败")


def render_table(title: str, headers: list, rows: list, col_widths: list | None = None):
    """Render a simple aligned table."""
    print()
    print("=" * 60)
    print(f"  {title}")
    print("=" * 60)

    if not rows:
        print("  (no data)")
        return

    widths = col_widths or [max(len(str(h)), max(len(str(r[i])) for r in rows)) for i, h in enumerate(headers)]
    # Ensure minimum
    widths = [max(w, 6) for w in widths]

    header_line = "  " + " ".join(h.ljust(w) for h, w in zip(headers, widths))
    sep_line = "  " + " ".join("-" * w for w in widths)
    print(header_line)
    print(sep_line)

    for row in rows:
        parts = []
        for val, w in zip(row, widths):
            s = str(val)
            if isinstance(val, float):
                s = f"{val:.2f}"
            parts.append(s.ljust(w))
        print("  " + " ".join(parts))


def render_cache(data: dict):
    results = data.get("cache", [])
    if not results:
        return

    rows = []
    for r in results:
        size = r.get("size_bytes", 0)
        rows.append([
            r["label"],
            fmt_size(size),
            f"{r['latency_ns']:.2f}",
            f"{r['latency_cycles']:.1f}",
        ])

    render_table("📊 内存层级延迟 (Cache)", ["层级", "大小", "延迟(ns)", "周期"], rows)

    # Tau constants
    tau_l1 = avg_lat([r for r in results if r.get("size_bytes", 0) <= 32 * 1024])
    tau_l2 = avg_lat([r for r in results if 64 * 1024 <= r.get("size_bytes", 0) <= 256 * 1024])
    tau_l3 = avg_lat([r for r in results if 512 * 1024 <= r.get("size_bytes", 0) <= 4 * 1024 * 1024])
    tau_dram = avg_lat([r for r in results if r.get("size_bytes", 0) >= 32 * 1024 * 1024])

    print()
    print("─" * 60)
    print("  📈 关键时间常数 (Tau)")
    print("─" * 60)
    for name, val in [("τ_L1 (L1)", tau_l1), ("τ_L2 (L2)", tau_l2),
                     ("τ_L3 (LLC)", tau_l3), ("τ_DRAM", tau_dram)]:
        if val:
            print(f"  {name:<15}  {fmt_ns(val)}")
        else:
            print(f"  {name:<15}  —")


def avg_lat(items):
    if not items:
        return 0
    return sum(r["latency_ns"] for r in items) / len(items)


def render_tlb(data: dict):
    results = data.get("tlb", [])
    if not results:
        return

    rows = []
    for r in results:
        rows.append([
            r["label"],
            f"{r['pages']}",
            fmt_ns(r['latency_ns']),
            f"{r['latency_cycles']:.1f}",
            f"{r['confidence']:.0%}",
        ])

    render_table("📖 TLB 层级探测", ["层级", "页数", "延迟", "周期", "置信度"], rows)


def render_pagefault(data: dict):
    results = data.get("pagefault", [])
    if not results:
        return

    # Split into minor fault and TLB shootdown
    minor = [r for r in results if "Minor" in r["label"]]
    shootdown = [r for r in results if "Shootdown" in r["label"] or "Ping-Pong" in r["label"]]

    if minor:
        rows = []
        for r in minor:
            rows.append([
                fmt_size(r['total_bytes']),
                f"{r['pages']}",
                fmt_ns(r['first_touch_ns']),
                fmt_ns(r['second_touch_ns']),
                fmt_ns(r['fault_overhead_ns']),
            ])
        render_table("📄 缺页中断 (Minor Page Fault)", ["大小", "页数", "首次访问", "二次访问", "缺页开销"], rows)

    if shootdown:
        rows = []
        for r in shootdown:
            rows.append([
                fmt_size(r['total_bytes']),
                f"{r['pages']}",
                fmt_ns(r['first_touch_ns']),
                fmt_ns(r['second_touch_ns']),
                fmt_ns(r['fault_overhead_ns']),
            ])
        render_table("🔄 TLB 抖动开销", ["大小", "页数", "乒乓访问", "顺序访问", "开销"], rows)


def render_ctxswitch(data: dict):
    results = data.get("ctxswitch", [])
    if not results:
        return

    print()
    print("=" * 60)
    print("  🔄 上下文切换延迟")
    print("=" * 60)
    for r in results:
        if r['latency_ns'] > 0:
            print(f"  {r['label']:<30}  {fmt_ns(r['latency_ns'])}  (conf: {r['confidence']:.0%})")
        else:
            print(f"  {r['label']:<30}  (待实现)")


def render_warnings(data: dict):
    warnings = data.get("warnings", [])
    if warnings:
        print()
        print("=" * 60)
        print("  ⚠️  警告")
        print("=" * 60)
        for w in warnings:
            print(f"  • {w}")


def main():
    engine = find_engine()
    data = run_engine(engine)
    render_platform(data)
    render_cache(data)
    render_tlb(data)
    render_pagefault(data)
    render_ctxswitch(data)
    render_warnings(data)
    print()
    print("=" * 60)
    print("  ✅ 测试完成")
    print("=" * 60)


if __name__ == "__main__":
    main()

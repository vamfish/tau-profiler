#!/usr/bin/env python3
"""
Tau CPU Information Report
──────────────────────────
Produces a CPU-Z-style report using the tau_profiler engine's JSON output.
Usage:
    python tau_info.py          # Call engine and display report
    python tau_info.py cpu.json # Read from existing JSON file
"""

import json
import subprocess
import os
import sys
from pathlib import Path


def find_engine() -> str:
    candidates = [
        "./zig-out/bin/tau_profiler",
        "./tau_profiler",
        str(Path(__file__).parent / "zig-out" / "bin" / "tau_profiler"),
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
        if os.path.exists(c + ".exe"):
            return c + ".exe"
    raise FileNotFoundError("Tau engine binary not found. Build it first: zig build")


def run_engine(engine_path: str) -> dict:
    proc = subprocess.Popen(
        [engine_path],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    stdout_text, stderr_text = proc.communicate()
    if proc.returncode != 0:
        print(f"Engine error (code {proc.returncode}):", file=sys.stderr)
        print(stderr_text[:500], file=sys.stderr)
        sys.exit(1)
    return json.loads(stdout_text)


def fmt_size_kb(kb: int) -> str:
    if kb >= 1024 * 1024:
        return f"{kb / (1024*1024):.2f} GB"
    if kb >= 1024:
        return f"{kb / 1024:.1f} MB"
    return f"{kb} KB"


def fmt_cache_line(cd: dict) -> str:
    """Format a cache entry from cpuid_info.cache_details."""
    level = cd["level"]
    units = cd["instances"]
    size = cd["size_kb"]
    assoc = cd["associativity"]
    line = cd["line_size"]
    ctype = cd["type"]
    if level == 4:
        return ""
    total = size * units
    return f"{units} x {fmt_size_kb(size)} ({assoc}-way, {line}-byte line)"


def render(plat: dict, cpuid: dict | None, cal: dict):
    ts = plat.get("os", "?")

    print("=" * 74)
    print("  TAU PROFILER — CPU-Z STYLE REPORT")
    print("=" * 74)

    # ── Processor Identification ──
    print()
    print("── Processors Information ──".ljust(74, "─"))
    print(f"  Socket 1                     ID = 0")
    print(f"  Number of cores              {plat.get('physical_cores', '?')} (max ?)")
    print(f"  Number of threads            {plat.get('logical_cores', '?')} (max ?)")
    print(f"  Manufacturer                 {plat.get('cpu_vendor', '?').title()}")
    print(f"  Name                         {_cpu_name(plat)}")
    if cpuid:
        print(f"  Codename                     {cpuid.get('codename', '?')}")
        if cpuid.get('technology_nm', 0) > 0:
            print(f"  Technology                   {cpuid['technology_nm']} nm")
        print(f"  Socket                       {cpuid.get('socket', '?')}")
        print(f"  Specification                {plat.get('cpu_brand', '?')}")
        print(f"  CPUID                        {cpuid['family']:X}.{cpuid['model']:X}.{cpuid['stepping']:X}")
        print(f"  Max CPUID level              0x{cpuid['cpuid_level']}")
        if cpuid['cpuid_ext_level']:
            print(f"  Max CPUID ext. level         0x{cpuid['cpuid_ext_level']}")
        if cpuid.get("features"):
            print(f"  Instructions sets            {', '.join(cpuid['features'])}")
    print(f"  Virtualization               {plat.get('is_virtualized', '?')} ({plat.get('virtualized_under', '?')})")

    # ── Cache ──
    if cpuid and cpuid.get("cache_details"):
        print()
        l1d_entries = [c for c in cpuid["cache_details"] if c["level"] == 1 and c["type"] == "Data"]
        l1i_entries = [c for c in cpuid["cache_details"] if c["level"] == 1 and c["type"] == "Instruction"]
        l2_entries = [c for c in cpuid["cache_details"] if c["level"] == 2]
        l3_entries = [c for c in cpuid["cache_details"] if c["level"] == 3]

        if l1d_entries:
            print(f"  L1 Data cache               {fmt_cache_line(l1d_entries[0])}")
        if l1i_entries:
            print(f"  L1 Instruction cache        {fmt_cache_line(l1i_entries[0])}")
        if l2_entries:
            print(f"  L2 cache                    {fmt_cache_line(l2_entries[0])}")
        if l3_entries:
            e = l3_entries[0]
            print(f"  L3 cache                    {fmt_size_kb(e['size_kb'])} ({e['associativity']}-way, {e['line_size']}-byte line)")

    # ── Frequency ──
    print()
    print("── Frequency ──".ljust(74, "─"))
    base_ghz = plat.get("cpu_base_ghz", 0)
    max_ghz = plat.get("cpu_max_ghz", 0)
    bus = cpuid.get("bus_freq_mhz", 0) if cpuid else 0
    if base_ghz > 0:
        print(f"  Base frequency              {base_ghz:.2f} GHz ({int(base_ghz*1000)} MHz)")
    if max_ghz > 0:
        print(f"  Max turbo frequency         {max_ghz:.2f} GHz ({int(max_ghz*1000)} MHz)")
    if bus > 0:
        ratio = int(base_ghz * 1000 / bus) if base_ghz > 0 else 0
        print(f"  Bus speed (BCLK)            {bus:.1f} MHz")
        if ratio > 0:
            print(f"  Multiplier (max non-turbo)  {ratio}x")

    if cal.get("calibrated"):
        hz = cal["tsc_hz"]
        print(f"  TSC frequency               {hz/1_000_000:.2f} MHz")
        print(f"  τ_cycle                     {(1.0/hz)*1e12:.2f} ps")

    # ── Turbo Ratios ──
    if cpuid and cpuid.get("turbo_ratios") and len(cpuid["turbo_ratios"]) > 0:
        print()
        print("── Turbo Ratios ──".ljust(74, "─"))
        print(f"  Turbo Mode                  supported, enabled")
        if cpuid.get("max_non_turbo_ratio", 0) > 0:
            print(f"  Max non-turbo ratio         {cpuid['max_non_turbo_ratio']}x")
        for i, r in enumerate(cpuid["turbo_ratios"][:10]):
            if r > 0:
                print(f"  Core {i} max ratio             {r / 10:.1f}" if r > 9 else f"  Core {i} max ratio             {r}.0")

    # ── Platform ──
    print()
    print("── Platform ──".ljust(74, "─"))
    print(f"  OS                          {plat.get('os', '?')}")
    print(f"  Architecture                {plat.get('arch', '?')}")
    print(f"  Page size                   {plat.get('page_size', '?')} bytes")
    tsc_info = plat.get("has_invariant_tsc", False)
    print(f"  Invariant TSC               {'Yes' if tsc_info else 'No'}")

    # ── Benchmarks Summary ──
    cache_data = plat  # cache data is in platform or root
    print()
    print("=" * 74)
    print("  END OF REPORT")
    print("=" * 74)


def _cpu_name(plat: dict) -> str:
    brand = plat.get("cpu_brand", "Unknown")
    # Strip common prefixes for display
    for prefix in ["Intel(R) ", "AMD "]:
        if brand.startswith(prefix):
            brand = brand[len(prefix):]
    return brand


def main():
    if len(sys.argv) > 1:
        # Read from JSON file
        with open(sys.argv[1], "r") as f:
            data = json.load(f)
    else:
        engine = find_engine()
        data = run_engine(engine)

    plat = data.get("platform", {})
    cpuid = data.get("cpuid_info")
    cal = data.get("calibration", {})
    render(plat, cpuid, cal)


if __name__ == "__main__":
    main()

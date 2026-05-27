const std = @import("std");
const builtin = @import("builtin");

const platform = @import("platform.zig");
const timer_mod = @import("timer.zig");
const cache = @import("cache.zig");
const tlb = @import("tlb.zig");
const pagefault = @import("pagefault.zig");
const ctxswitch = @import("ctxswitch.zig");

const Timer = timer_mod.Timer;

// ═══════════════════════════════════════════════════════════════
//  JSON output
// ═══════════════════════════════════════════════════════════════

fn writeJson(
    io: std.Io,
    info: platform.PlatformInfo,
    timer: *const Timer,
    cache_results: []const cache.CacheResult,
    tlb_results: []const tlb.TlbResult,
    pf_results: []const pagefault.PageFaultResult,
    ctx_results: []const ctxswitch.CtxSwitchResult,
    warnings: []const []const u8,
) void {
    const out_file = std.Io.File.stdout();
    var buf: [131072]u8 = undefined;
    var writer = out_file.writer(io, &buf);
    const w = &writer.interface;

    w.print("{{\n", .{}) catch return;
    w.print("  \"version\": 2,\n", .{}) catch return;
    const ts = std.Io.Timestamp.now(io, .real);
    w.print("  \"timestamp\": {d},\n", .{@divFloor(ts.nanoseconds, 1_000_000_000)}) catch return;
    w.print("  \"status\": \"success\",\n", .{}) catch return;

    // ── Calibration ──
    w.print("  \"calibration\": {{\n", .{}) catch return;
    w.print("    \"tsc_hz\": {d:.0},\n", .{timer.tsc_hz}) catch return;
    w.print("    \"calibrated\": {}\n", .{timer.calibrated}) catch return;
    w.print("  }},\n", .{}) catch return;

    // ── Platform ──
    w.print("  \"platform\": {{\n", .{}) catch return;
    w.print("    \"os\": \"{s}\",\n", .{info.os}) catch return;
    w.print("    \"arch\": \"{s}\",\n", .{info.arch}) catch return;
    w.print("    \"cpu_vendor\": \"{s}\",\n", .{info.cpu_vendor}) catch return;
    w.print("    \"cpu_brand\": \"{s}\",\n", .{info.cpu_brand}) catch return;
    w.print("    \"physical_cores\": {},\n", .{info.physical_cores}) catch return;
    w.print("    \"logical_cores\": {},\n", .{info.logical_cores}) catch return;
    w.print("    \"page_size\": {},\n", .{info.page_size}) catch return;
    w.print("    \"has_invariant_tsc\": {},\n", .{info.has_invariant_tsc}) catch return;
    w.print("    \"is_virtualized\": {},\n", .{info.is_virtualized}) catch return;
    w.print("    \"virtualized_under\": \"{s}\"\n", .{info.virtualized_under}) catch return;
    w.print("  }},\n", .{}) catch return;

    // ── Cache results ──
    w.print("  \"cache\": [\n", .{}) catch return;
    for (cache_results, 0..) |r, i| {
        const comma: []const u8 = if (i + 1 < cache_results.len) "," else "";
        w.writeAll("    {\"label\":\"") catch return;
        w.print("{s}", .{r.label}) catch return;
        w.writeAll("\",\"size_bytes\":") catch return;
        w.print("{}", .{r.size}) catch return;
        w.writeAll(",\"latency_ns\":") catch return;
        w.print("{d:.4}", .{r.latency_ns}) catch return;
        w.writeAll(",\"latency_cycles\":") catch return;
        w.print("{d:.4}", .{r.latency_cycles}) catch return;
        w.writeAll(",\"confidence\":") catch return;
        w.print("{d:.2}", .{r.confidence}) catch return;
        w.print("}}{s}\n", .{comma}) catch return;
    }
    w.print("  ],\n", .{}) catch return;

    // ── TLB results ──
    w.print("  \"tlb\": [\n", .{}) catch return;
    for (tlb_results, 0..) |r, i| {
        const comma: []const u8 = if (i + 1 < tlb_results.len) "," else "";
        w.writeAll("    {\"label\":\"") catch return;
        w.print("{s}", .{r.label}) catch return;
        w.writeAll("\",\"pages\":") catch return;
        w.print("{}", .{r.pages}) catch return;
        w.writeAll(",\"latency_ns\":") catch return;
        w.print("{d:.4}", .{r.latency_ns}) catch return;
        w.writeAll(",\"latency_cycles\":") catch return;
        w.print("{d:.4}", .{r.latency_cycles}) catch return;
        w.writeAll(",\"confidence\":") catch return;
        w.print("{d:.2}", .{r.confidence}) catch return;
        w.print("}}{s}\n", .{comma}) catch return;
    }
    w.print("  ],\n", .{}) catch return;

    // ── Page fault results ──
    w.print("  \"pagefault\": [\n", .{}) catch return;
    for (pf_results, 0..) |r, i| {
        const comma: []const u8 = if (i + 1 < pf_results.len) "," else "";
        w.writeAll("    {\"label\":\"") catch return;
        w.print("{s}", .{r.label}) catch return;
        w.writeAll("\",\"pages\":") catch return;
        w.print("{}", .{r.pages}) catch return;
        w.writeAll(",\"total_bytes\":") catch return;
        w.print("{}", .{r.total_bytes}) catch return;
        w.writeAll(",\"first_touch_ns\":") catch return;
        w.print("{d:.4}", .{r.first_touch_ns}) catch return;
        w.writeAll(",\"second_touch_ns\":") catch return;
        w.print("{d:.4}", .{r.second_touch_ns}) catch return;
        w.writeAll(",\"fault_overhead_ns\":") catch return;
        w.print("{d:.4}", .{r.fault_overhead_ns}) catch return;
        w.print("}}{s}\n", .{comma}) catch return;
    }
    w.print("  ],\n", .{}) catch return;

    // ── Context switch results ──
    w.print("  \"ctxswitch\": [\n", .{}) catch return;
    for (ctx_results, 0..) |r, i| {
        const comma: []const u8 = if (i + 1 < ctx_results.len) "," else "";
        w.writeAll("    {\"label\":\"") catch return;
        w.print("{s}", .{r.label}) catch return;
        w.writeAll("\",\"method\":\"") catch return;
        w.print("{s}", .{r.method}) catch return;
        w.writeAll("\",\"latency_ns\":") catch return;
        w.print("{d:.4}", .{r.latency_ns}) catch return;
        w.writeAll(",\"latency_cycles\":") catch return;
        w.print("{d:.4}", .{r.latency_cycles}) catch return;
        w.writeAll(",\"confidence\":") catch return;
        w.print("{d:.2}", .{r.confidence}) catch return;
        w.print("}}{s}\n", .{comma}) catch return;
    }
    w.print("  ]", .{}) catch return;

    // ── Warnings ──
    if (warnings.len > 0) {
        w.print(",\n  \"warnings\": [\n", .{}) catch return;
        for (warnings, 0..) |warn, i| {
            const comma: []const u8 = if (i + 1 < warnings.len) "," else "";
            w.print("    \"{s}\"{s}\n", .{ warn, comma }) catch return;
        }
        w.print("  ]\n", .{}) catch return;
    } else {
        w.print("\n", .{}) catch return;
    }
    w.print("}}\n", .{}) catch return;
    w.flush() catch {};
}

// ═══════════════════════════════════════════════════════════════
//  Entry point
// ═══════════════════════════════════════════════════════════════

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.debug.print("=== Tau-Profiler Engine v0.3.0 ===\n", .{});
    std.debug.print("[1/5] Detecting platform...\n", .{});

    // ── Platform info ──
    var brand_buf: [48]u8 = undefined;
    const brand = platform.getCpuBrand(&brand_buf);
    const hv = platform.getVirtualization();
    var info = platform.PlatformInfo{
        .os = platform.getOS(),
        .arch = platform.getArch(),
        .cpu_vendor = platform.getCpuVendor(),
        .cpu_brand = brand,
        .physical_cores = 0,
        .logical_cores = 0,
        .page_size = @intCast(std.heap.pageSize()),
        .has_invariant_tsc = platform.getInvariantTsc(),
        .is_virtualized = hv.is_vm,
        .virtualized_under = hv.hv,
    };
    info.physical_cores = platform.getPhysicalCores();
    info.logical_cores = platform.getLogicalCores();

    std.debug.print("  OS: {s}, Arch: {s}\n", .{ info.os, info.arch });
    std.debug.print("  CPU: {s}\n", .{info.cpu_brand});
    std.debug.print("  Cores: {}/{} (phys/logical)\n", .{ info.physical_cores, info.logical_cores });

    var warnings: std.ArrayList([]const u8) = .empty;
    if (info.is_virtualized) {
        try warnings.append(allocator, "Running inside a VM -- results may have extra jitter");
    }

    // ── Timer calibration ──
    std.debug.print("[2/5] Calibrating timer...\n", .{});
    var timer = Timer.init(io);
    if (timer.calibrated) {
        switch (timer.timer_source) {
            .rdtscp => std.debug.print("  Source: RDTSCP\n", .{}),
            .cntvct => std.debug.print("  Source: CNTVCT_EL0 (ARM generic timer)\n", .{}),
            .fallback => std.debug.print("  Source: OS monotonic clock\n", .{}),
        }
        std.debug.print("  Freq:   {d:.2} MHz\n", .{timer.tsc_hz / 1_000_000.0});
    } else {
        std.debug.print("  WARNING: Timer calibration failed\n", .{});
        try warnings.append(allocator, "Timer calibration failed -- using OS clock");
    }

    const overhead = Timer.measureOverhead();
    std.debug.print("  Timer overhead: {d:.0} ticks\n", .{overhead});

    // ── Core pinning ──
    std.debug.print("[3/5] Pinning to core 0...\n", .{});
    const bound = platform.bindToCore(0);
    if (!bound) {
        std.debug.print("  WARNING: Could not pin to core 0\n", .{});
        try warnings.append(allocator, "Not bound to a single core");
    } else {
        std.debug.print("  OK\n", .{});
    }

    // ── Cache latency sweep ──
    std.debug.print("[4/5] Cache latency sweep (4KB -> 64MB)...\n", .{});
    const cache_results = cache.runSweep(allocator, &timer) catch |err| {
        std.debug.print("  ERROR: {}\n", .{err});
        std.process.exit(1);
    };
    std.debug.print("  Completed {d} cache points\n", .{cache_results.len});

    // ── Extended benchmarks ──
    std.debug.print("[5/5] Extended benchmarks...\n", .{});

    // TLB
    std.debug.print("  TLB probe...\n", .{});
    const tlb_results = tlb.runTlbSweep(allocator, &timer) catch |err| blk: {
        std.debug.print("  [WARN] TLB sweep failed: {}\n", .{err});
        try warnings.append(allocator, "TLB sweep failed");
        break :blk try allocator.alloc(tlb.TlbResult, 0);
    };
    std.debug.print("    {d} TLB points\n", .{tlb_results.len});

    // Page fault
    std.debug.print("  Page fault probe...\n", .{});
    const pf_results = pagefault.runPageFaultSweep(allocator, &timer) catch |err| blk: {
        std.debug.print("  [WARN] Page fault sweep failed: {}\n", .{err});
        try warnings.append(allocator, "Page fault sweep failed");
        break :blk try allocator.alloc(pagefault.PageFaultResult, 0);
    };
    std.debug.print("    {d} page fault points\n", .{pf_results.len});

    // Context switch
    std.debug.print("  Context switch probe...\n", .{});
    const ctx_results = ctxswitch.runCtxSwitch(allocator, &timer) catch |err| blk: {
        std.debug.print("  [WARN] Context switch probe failed: {}\n", .{err});
        try warnings.append(allocator, "Context switch probe failed");
        break :blk try allocator.alloc(ctxswitch.CtxSwitchResult, 0);
    };
    std.debug.print("    {d} ctx switch points\n", .{ctx_results.len});

    // ── Tau constants ──
    if (timer.tsc_hz > 0) {
        const cpu_ps = (1.0 / timer.tsc_hz) * 1.0e12;
        std.debug.print("\n  Tau_cycle: {d:.2} ps\n", .{cpu_ps});
    }

    writeJson(io, info, &timer, cache_results, tlb_results, pf_results, ctx_results, warnings.items);
}

const std = @import("std");
const builtin = @import("builtin");

const platform = @import("platform.zig");
const timer_mod = @import("timer.zig");
const cache = @import("cache.zig");

const Timer = timer_mod.Timer;

// ═══════════════════════════════════════════════════════════════
//  JSON output
// ═══════════════════════════════════════════════════════════════

fn writeJson(io: std.Io, info: platform.PlatformInfo, timer: *const Timer, results: []const cache.CacheResult, warnings: []const []const u8) void {
    const out_file = std.Io.File.stdout();
    var buf: [65536]u8 = undefined;
    var writer = out_file.writer(io, &buf);
    const w = &writer.interface;

    w.print("{{\n", .{}) catch return;
    w.print("  \"version\": 1,\n", .{}) catch return;
    const ts = std.Io.Timestamp.now(io, .real);
    w.print("  \"timestamp\": {d},\n", .{@divFloor(ts.nanoseconds, 1_000_000_000)}) catch return;
    w.print("  \"status\": \"success\",\n", .{}) catch return;
    w.print("  \"calibration\": {{\n", .{}) catch return;
    w.print("    \"tsc_hz\": {d:.0},\n", .{timer.tsc_hz}) catch return;
    w.print("    \"calibrated\": {}\n", .{timer.calibrated}) catch return;
    w.print("  }},\n", .{}) catch return;
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
    w.print("  \"results\": [\n", .{}) catch return;
    for (results, 0..) |r, i| {
        const comma: []const u8 = if (i + 1 < results.len) "," else "";
        w.print("    {{\"label\":\"{s}\",\"size_bytes\":{},\"latency_ns\":{d:.4},\"latency_cycles\":{d:.4},\"confidence\":{d:.2}}}{s}\n",
            .{ r.label, r.size, r.latency_ns, r.latency_cycles, r.confidence, comma }) catch return;
    }
    w.print("  ]", .{}) catch return;
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

    std.debug.print("=== Tau-Profiler Engine v0.2.0 ===\n", .{});
    std.debug.print("[1/4] Detecting platform...\n", .{});

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
    std.debug.print("[2/4] Calibrating timer...\n", .{});
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
    std.debug.print("[3/4] Pinning to core 0...\n", .{});
    const bound = platform.bindToCore(0);
    if (!bound) {
        // On platforms without affinity support this is non-fatal
        std.debug.print("  WARNING: Could not pin to core 0\n", .{});
        try warnings.append(allocator, "Not bound to a single core");
    } else {
        std.debug.print("  OK\n", .{});
    }

    // ── Sweep ──
    std.debug.print("[4/4] Running latency sweep (4KB -> 64MB)...\n", .{});
    const results = cache.runSweep(allocator, &timer) catch |err| {
        std.debug.print("  ERROR: {}\n", .{err});
        std.process.exit(1);
    };
    std.debug.print("  Completed {d} measurements\n", .{results.len});

    if (timer.tsc_hz > 0) {
        const cpu_ps = (1.0 / timer.tsc_hz) * 1.0e12;
        std.debug.print("\n  Tau_cycle: {d:.2} ps\n", .{cpu_ps});
    }

    writeJson(io, info, &timer, results, warnings.items);
}

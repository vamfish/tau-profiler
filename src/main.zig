const std = @import("std");
const builtin = @import("builtin");

const platform = @import("platform.zig");
const timer_mod = @import("timer.zig");
const cache = @import("cache.zig");
const tlb = @import("tlb.zig");
const pagefault = @import("pagefault.zig");
const ctxswitch = @import("ctxswitch.zig");
const cpuid_info = @import("cpuid_info.zig");

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
    cpuid_data: ?cpuid_info.CpuidInfo,
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
    w.print("    \"virtualized_under\": \"{s}\",\n", .{info.virtualized_under}) catch return;
    w.print("    \"l1_data_kb\": {},\n", .{info.l1_data_kb}) catch return;
    w.print("    \"l1_inst_kb\": {},\n", .{info.l1_inst_kb}) catch return;
    w.print("    \"l2_cache_kb\": {},\n", .{info.l2_cache_kb}) catch return;
    w.print("    \"l3_cache_kb\": {},\n", .{info.l3_cache_kb}) catch return;
    w.print("    \"cpu_base_ghz\": {d:.2},\n", .{info.cpu_base_ghz}) catch return;
    w.print("    \"cpu_max_ghz\": {d:.2}\n", .{info.cpu_max_ghz}) catch return;
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

    // ── CPUID info ──
    if (cpuid_data) |cd| {
        w.print(",\n  \"cpuid_info\": {{\n", .{}) catch return;
        w.print("    \"codename\": \"{s}\",\n", .{cd.codename}) catch return;
        w.print("    \"technology_nm\": {},\n", .{cd.technology_nm}) catch return;
        w.print("    \"socket\": \"{s}\",\n", .{cd.socket}) catch return;
        w.print("    \"family\": {},\n", .{cd.family}) catch return;
        w.print("    \"model\": {},\n", .{cd.model}) catch return;
        w.print("    \"stepping\": {},\n", .{cd.stepping}) catch return;
        w.print("    \"cpuid_level\": \"0x{x}\",\n", .{cd.cpuid_level}) catch return;
        w.print("    \"cpuid_ext_level\": \"0x{x}\",\n", .{cd.cpuid_ext_level}) catch return;
        w.print("    \"smt_supported\": {},\n", .{cd.smt_supported}) catch return;
        w.print("    \"base_freq_mhz\": {},\n", .{cd.base_freq_mhz}) catch return;
        w.print("    \"max_freq_mhz\": {},\n", .{cd.max_freq_mhz}) catch return;
        w.print("    \"bus_freq_mhz\": {},\n", .{cd.bus_freq_mhz}) catch return;
        w.print("    \"turbo_supported\": {},\n", .{cd.turbo_supported}) catch return;
        w.print("    \"max_non_turbo_ratio\": {},\n", .{cd.max_non_turbo_ratio}) catch return;
        w.writeAll("    \"features\": [") catch return;
        for (cd.features[0..cd.features_count], 0..) |f, j| {
            if (j > 0) w.writeAll(", ") catch return;
            w.writeAll("\"") catch return;
            w.writeAll(f) catch return;
            w.writeAll("\"") catch return;
        }
        w.print("],\n", .{}) catch return;
        w.writeAll("    \"turbo_ratios\": [") catch return;
        for (cd.turbo_ratios[0..cd.turbo_ratio_count], 0..) |r, j| {
            if (j > 0) w.writeAll(", ") catch return;
            w.print("{}", .{r}) catch return;
        }
        w.print("],\n", .{}) catch return;
        w.writeAll("    \"cache_details\": [\n") catch return;
        for (cd.cache[0..cd.cache_count], 0..) |ce, j| {
            const comma = if (j + 1 < cd.cache_count) "," else "";
            const ct: []const u8 = switch (ce.cache_type) { 1 => "Data", 2 => "Instruction", 3 => "Unified", else => "Unknown" };
            w.writeAll("      {\"level\":") catch return;
            w.print("{}", .{ce.level}) catch return;
            w.writeAll(",\"type\":\"") catch return;
            w.writeAll(ct) catch return;
            w.writeAll("\",\"size_kb\":") catch return;
            w.print("{}", .{ce.size_kb}) catch return;
            w.writeAll(",\"associativity\":") catch return;
            w.print("{}", .{ce.associativity}) catch return;
            w.writeAll(",\"line_size\":") catch return;
            w.print("{}", .{ce.line_size}) catch return;
            w.writeAll(",\"instances\":") catch return;
            w.print("{}", .{ce.instances}) catch return;
            w.writeAll(",\"shared_by\":") catch return;
            w.print("{}", .{ce.shared_by}) catch return;
            w.writeAll("}") catch return;
            w.print("{s}\n", .{comma}) catch return;
        }
        w.writeAll("    ]\n") catch return;
        w.writeAll("  }") catch return;
    }

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
    const debug = init.environ_map.get("TAU_DEBUG") != null;

    std.debug.print("=== Tau-Profiler Engine v0.3.0 ===\n", .{});
    if (debug) std.debug.print("[DEBUG] Build: {s}\n", .{@tagName(builtin.mode)});
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
        .l1_data_kb = 0,
        .l1_inst_kb = 0,
        .l2_cache_kb = 0,
        .l3_cache_kb = 0,
        .cpu_max_ghz = 0,
        .cpu_base_ghz = 0,
    };
    info.physical_cores = platform.getPhysicalCores();
    info.logical_cores = platform.getLogicalCores();

    // ── Cache topology ──
    const cache_info = platform.getCacheInfo();
    // L1/L2 are per-physical-core; multiply to get totals. L3 is shared.
    const phys = if (info.physical_cores > 0) info.physical_cores else @max(info.logical_cores, 1);
    info.l1_data_kb = cache_info.l1_data_kb * phys;
    info.l1_inst_kb = cache_info.l1_inst_kb * phys;
    info.l2_cache_kb = cache_info.l2_cache_kb * phys;
    info.l3_cache_kb = cache_info.l3_cache_kb;

    // ── Comprehensive CPUID info ──
    var cpuid_data: ?cpuid_info.CpuidInfo = null;
    if (builtin.cpu.arch == .x86_64) {
        cpuid_data = cpuid_info.collect(info.cpu_vendor, info.cpu_brand, info.physical_cores, info.logical_cores, 0) catch null;
    }

    std.debug.print("  OS: {s}, Arch: {s}\n", .{ info.os, info.arch });
    std.debug.print("  CPU: {s}\n", .{info.cpu_brand});
    std.debug.print("  Cores: {}/{} (phys/logical)\n", .{ info.physical_cores, info.logical_cores });
    std.debug.print("  L1: {}KB (d) / {}KB (i), L2: {}KB, L3: {}KB\n", .{ info.l1_data_kb, info.l1_inst_kb, info.l2_cache_kb, info.l3_cache_kb });

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

    // ── CPU frequency info ──
    var max_ghz: f32 = 0;
    var base_ghz: f32 = 0;
    if (builtin.cpu.arch == .x86_64) {
        const freq = platform.getCpuFreqX86();
        base_ghz = freq.base_ghz;
        max_ghz = freq.max_ghz;
    }
    // Fallback: use TSC calibration for base frequency
    if (base_ghz <= 0 and timer.tsc_hz > 0) {
        base_ghz = @as(f32, @floatCast(timer.tsc_hz / 1_000_000_000.0));
    }
    // Clamp turbo: if unavailable or below base, use base as minimum
    if (max_ghz < base_ghz) {
        max_ghz = base_ghz;
    }
    std.debug.print("\n  CPU Base:  {d:.2} GHz\n", .{base_ghz});
    if (max_ghz > base_ghz) {
        std.debug.print("  CPU Turbo: {d:.2} GHz\n", .{max_ghz});
    }
    info.cpu_base_ghz = base_ghz;
    info.cpu_max_ghz = max_ghz;

    // ── Tau constants ──
    if (timer.tsc_hz > 0) {
        const cpu_ps = (1.0 / timer.tsc_hz) * 1.0e12;
        std.debug.print("  Tau_cycle: {d:.2} ps\n", .{cpu_ps});
    }

    if (cpuid_data) |*cd| {
        cd.tsc_hz = @as(u64, @intFromFloat(timer.tsc_hz));
    }
    writeJson(io, info, &timer, cache_results, tlb_results, pf_results, ctx_results, warnings.items, cpuid_data);
}

test "platform detection smoke test" {
    const os = platform.getOS();
    const arch = platform.getArch();
    const vendor = platform.getCpuVendor();
    try std.testing.expect(os.len > 0);
    try std.testing.expect(arch.len > 0);
    try std.testing.expect(vendor.len > 0);
    _ = platform.getPhysicalCores();
    _ = platform.getLogicalCores();
    _ = platform.getVirtualization();
    _ = platform.getCacheInfo();
}

test "core count is reasonable" {
    const phys = platform.getPhysicalCores();
    const logi = platform.getLogicalCores();
    // Sanity: at least 1 core, at most 512
    try std.testing.expect(phys >= 1);
    try std.testing.expect(phys <= 512);
    try std.testing.expect(logi >= 1);
    try std.testing.expect(logi <= 1024);
    if (logi > 0 and phys > 0) {
        // Logical cores should be >= physical cores (HT/SMT)
        try std.testing.expect(logi >= phys);
    }
}

test "cache info is reasonable" {
    const info = platform.getCacheInfo();
    // Each cache level should either be 0 (unknown) or a reasonable size
    try std.testing.expect(info.l1_data_kb == 0 or (info.l1_data_kb >= 8 and info.l1_data_kb <= 128));
    try std.testing.expect(info.l1_inst_kb == 0 or (info.l1_inst_kb >= 8 and info.l1_inst_kb <= 128));
    try std.testing.expect(info.l2_cache_kb == 0 or (info.l2_cache_kb >= 128 and info.l2_cache_kb <= 4096));
    try std.testing.expect(info.l3_cache_kb == 0 or (info.l3_cache_kb >= 512 and info.l3_cache_kb <= 131072));
}

test "VM detection does not crash" {
    const vm = platform.getVirtualization();
    _ = vm.is_vm;
    _ = vm.hv;
    // On bare metal with Hyper-V platform, should not report as VM
    // (This test just ensures the function runs without crashing)
    if (vm.is_vm) {
        try std.testing.expect(vm.hv.len > 0);
    }
}

test "timer source detection is valid" {
    // Just verify the static functions don't crash
    const t0 = Timer.now();
    const t1 = Timer.now();
    try std.testing.expect(t1 >= t0);
    const overhead = Timer.measureOverhead();
    try std.testing.expect(overhead >= 0);
}

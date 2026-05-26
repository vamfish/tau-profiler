const std = @import("std");
const Timer = @import("timer.zig").Timer;

pub const CacheResult = struct {
    label: []const u8,
    size: usize,
    latency_ns: f64,
    latency_cycles: f64,
    confidence: f64,
};

fn getSizeLabel(size: usize) []const u8 {
    if (size <= 8 * 1024) return "L1 Data Cache";
    if (size <= 32 * 1024) return "L1/L2 Transition";
    if (size <= 256 * 1024) return "L2 Cache";
    if (size <= 4 * 1024 * 1024) return "L3/LLC";
    if (size <= 32 * 1024 * 1024) return "Large LLC";
    return "DRAM Main Memory";
}

pub fn measureLatency(allocator: std.mem.Allocator, size: usize, timer: *const Timer, iterations: usize) !CacheResult {
    const ptr_size = @sizeOf(usize);
    const n = @min(size / ptr_size, 1_000_000);
    if (n < 4) return error.BufferTooSmall;

    const buffer = try allocator.alloc(usize, n);
    defer allocator.free(buffer);

    const chain = try allocator.alloc(usize, n);
    defer allocator.free(chain);

    for (chain, 0..) |_, i| chain[i] = i;
    var rng = std.Random.DefaultPrng.init(42);
    const rand = rng.random();
    var ci = chain.len;
    while (ci > 1) {
        ci -= 1;
        const j = rand.intRangeAtMost(usize, 0, ci);
        std.mem.swap(usize, &chain[ci], &chain[j]);
    }

    for (chain, 0..) |idx, i| {
        const next = if (i + 1 < chain.len) chain[i + 1] else chain[0];
        buffer[idx] = @intFromPtr(&buffer[next]);
    }

    // Warm up
    var p: usize = buffer[0];
    for (0..n) |_| {
        p = @as(*usize, @ptrFromInt(p)).*;
    }

    // Measure
    const start = Timer.now();
    p = buffer[chain[0]];
    const total_accesses = n * iterations;
    for (0..iterations) |_| {
        for (0..n) |_| {
            p = @as(*usize, @ptrFromInt(p)).*;
        }
    }
    const end = Timer.now();
    std.mem.doNotOptimizeAway(p);

    const avg_ticks = @as(f64, @floatFromInt(end - start)) / @as(f64, @floatFromInt(total_accesses));
    const avg_ns = Timer.ticksToNs(@as(u64, @intFromFloat(avg_ticks)), timer.tsc_hz);

    return CacheResult{
        .label = getSizeLabel(size),
        .size = size,
        .latency_ns = avg_ns,
        .latency_cycles = if (timer.tsc_hz > 0) avg_ticks else 0,
        .confidence = if (total_accesses > 1000) 0.9 else 0.5,
    };
}

pub fn runSweep(allocator: std.mem.Allocator, timer: *const Timer) ![]CacheResult {
    const sizes = [_]usize{
        4 * 1024, 8 * 1024, 16 * 1024, 32 * 1024,
        64 * 1024, 128 * 1024, 256 * 1024, 512 * 1024,
        1 * 1024 * 1024, 2 * 1024 * 1024, 4 * 1024 * 1024,
        8 * 1024 * 1024, 16 * 1024 * 1024, 32 * 1024 * 1024,
        64 * 1024 * 1024,
    };

    var results_buf: [sizes.len]CacheResult = undefined;
    var count: usize = 0;

    for (sizes) |size| {
        const iters: usize = if (size <= 256 * 1024) 50 else 10;
        const result = measureLatency(allocator, size, timer, iters) catch |err| {
            std.debug.print("  [WARN] {} KB failed: {}\n", .{ size / 1024, err });
            continue;
        };
        results_buf[count] = result;
        count += 1;
    }

    const results = try allocator.alloc(CacheResult, count);
    @memcpy(results, results_buf[0..count]);
    return results;
}

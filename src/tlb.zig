const std = @import("std");
const Timer = @import("timer.zig").Timer;
const stats = @import("stats.zig");

pub const TlbResult = struct {
    label: []const u8,
    pages: usize,
    stride_pages: usize,
    latency_cycles: f64,
    latency_ns: f64,
    confidence: f64,
};

/// Probe TLB reach and miss latency.
///
/// Methodology:
///   Allocate `num_pages` pages and build a pointer chain that jumps
///   to a different page on every access. This defeats the page table
///   walker cache (L1/L2 TLB) because each access hits a different
///   page mapping.  By sweeping the page count we detect:
///     - L1 TLB size  (abrupt latency increase)
///     - L2 TLB size  (second latency step)
///     - Full page walk latency (beyond L2 TLB)
///
/// `stride_pages` controls how many pages apart each pointer land —
/// a stride of 1 touches consecutive pages; higher strides stress
/// the TLB's associative coverage.
pub fn measureTlbLatency(allocator: std.mem.Allocator, num_pages: usize, stride_pages: usize, timer: *const Timer, rounds: usize) !TlbResult {
    const page_size: usize = 4096;
    const alloc_size = num_pages * page_size;

    // Allocate an aligned region
    const buf = try allocator.alignedAlloc(u8, @enumFromInt(std.math.log2(page_size)), alloc_size);
    defer allocator.free(buf);

    // Zero it so the pages are faulted in
    @memset(buf, 0);

    // Build a cross-page pointer chain.
    // We place one `usize` pointer per page at offset 0.
    // Page i points to page (i + stride_pages) % num_pages.
    const ptr_size = @sizeOf(usize);
    const ptrs = std.mem.bytesAsSlice(usize, buf);

    // Create a permutation that jumps by stride_pages each time
    var visited: usize = 0;
    var current: usize = 0;
    while (visited < num_pages) {
        const next = (current + stride_pages) % num_pages;
        ptrs[(current * page_size) / ptr_size] = @intFromPtr(&buf[(next * page_size)]);
        current = next;
        visited += 1;
        if (visited >= num_pages) break;
        // Break cycles: if we've looped, advance by 1
        if (current == 0 and visited < num_pages) {
            current = 1;
        }
    }

    // Warm up: walk the chain once
    var p: usize = ptrs[0];
    for (0..num_pages) |_| {
        p = @as(*usize, @ptrFromInt(p)).*;
    }
    std.mem.doNotOptimizeAway(p);

    // Measure multiple rounds
    var raw_cycles = try allocator.alloc(f64, rounds);
    defer allocator.free(raw_cycles);

    for (0..rounds) |r| {
        p = ptrs[0];
        const start = Timer.now();
        for (0..num_pages) |_| {
            p = @as(*usize, @ptrFromInt(p)).*;
        }
        const end = Timer.now();
        std.mem.doNotOptimizeAway(p);

        const total_ticks = end - start;
        const per_access = @as(f64, @floatFromInt(total_ticks)) / @as(f64, @floatFromInt(num_pages));
        raw_cycles[r] = per_access;
    }

    // Filter outliers
    const filtered = try stats.filterMAD(allocator, raw_cycles, 3.0);
    defer allocator.free(filtered.filtered);

    const sm = stats.meanStddev(filtered.filtered);
    const avg_cycles = sm.mean;
    const avg_ns = Timer.ticksToNs(@as(u64, @intFromFloat(avg_cycles)), timer.tsc_hz);

    return TlbResult{
        .label = if (num_pages <= 8) "L1 TLB" else if (num_pages <= 64) "L2 TLB" else "Page Walk",
        .pages = num_pages,
        .stride_pages = stride_pages,
        .latency_cycles = avg_cycles,
        .latency_ns = avg_ns,
        .confidence = @min(0.99, @as(f64, @floatFromInt(filtered.filtered.len)) / @as(f64, @floatFromInt(rounds))),
    };
}

pub fn runTlbSweep(allocator: std.mem.Allocator, timer: *const Timer) ![]TlbResult {
    // Sweep page counts to detect TLB hierarchy
    const page_counts = [_]usize{ 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048 };
    const stride: usize = 1; // sequential pages
    const rounds: usize = 5;

    var results_buf: [page_counts.len]TlbResult = undefined;
    var count: usize = 0;

    for (page_counts) |np| {
        const result = measureTlbLatency(allocator, np, stride, timer, rounds) catch |err| {
            std.debug.print("  [WARN] TLB {} pages failed: {}\n", .{ np, err });
            continue;
        };
        results_buf[count] = result;
        count += 1;
    }

    const results = try allocator.alloc(TlbResult, count);
    @memcpy(results, results_buf[0..count]);
    return results;
}

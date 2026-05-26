const std = @import("std");
const Timer = @import("timer.zig").Timer;
const stats = @import("stats.zig");

pub const PageFaultResult = struct {
    label: []const u8,
    pages: usize,
    total_bytes: usize,
    first_touch_ns: f64,
    second_touch_ns: f64,
    fault_overhead_ns: f64,
};

/// Measure the cost of minor page faults (zero-fill on demand).
///
/// Methodology:
///   1. Allocate a large anonymous region (already committed).
///   2. Touch every page sequentially while timing the access.
///      On first touch, the kernel must zero-fill the page (minor fault).
///   3. Touch the same region again — these hits should be in TLB/cache.
///   4. The delta (first_touch - second_touch) is the page fault overhead.
///
/// Returns the average per-page first-touch and second-touch latency.
pub fn measureMinorFaultLatency(allocator: std.mem.Allocator, num_pages: usize, timer: *const Timer) !PageFaultResult {
    const page_size: usize = 4096;
    const total = num_pages * page_size;

    // Allocate (pages are virtual but not physically backed yet)
    const buf = try allocator.alignedAlloc(u8, page_size, total);
    defer allocator.free(buf);

    // First touch: trigger page faults
    const start1 = Timer.now();
    for (0..num_pages) |i| {
        // Touch the first byte of each page
        buf[i * page_size] = @as(u8, @intCast(i & 0xFF));
    }
    const end1 = Timer.now();

    // Second touch: should be in TLB + cache
    // First, flush cache by touching a large unrelated buffer
    var flush = try allocator.alloc(u8, 4 * 1024 * 1024);
    defer allocator.free(flush);
    @memset(flush, 0);

    const start2 = Timer.now();
    var sum: u8 = 0;
    for (0..num_pages) |i| {
        sum +|= buf[i * page_size];
    }
    const end2 = Timer.now();
    std.mem.doNotOptimizeAway(sum);

    const avg_first = Timer.ticksToNs(end1 - start1, timer.tsc_hz) / @as(f64, @floatFromInt(num_pages));
    const avg_second = Timer.ticksToNs(end2 - start2, timer.tsc_hz) / @as(f64, @floatFromInt(num_pages));

    return PageFaultResult{
        .label = "Minor Page Fault",
        .pages = num_pages,
        .total_bytes = total,
        .first_touch_ns = avg_first,
        .second_touch_ns = avg_second,
        .fault_overhead_ns = if (avg_first > avg_second) avg_first - avg_second else 0,
    };
}

/// Measure TLB shootdown cost by touching pages from a different core
/// (or, as approximation, by alternating between two large buffers).
pub fn measureTlbShootdown(allocator: std.mem.Allocator, num_pages: usize, timer: *const Timer) !PageFaultResult {
    const page_size: usize = 4096;
    const total = num_pages * page_size;

    // Allocate two large buffers
    const buf_a = try allocator.alignedAlloc(u8, page_size, total);
    defer allocator.free(buf_a);
    const buf_b = try allocator.alignedAlloc(u8, page_size, total);
    defer allocator.free(buf_b);

    // Fill both (fault in all pages)
    @memset(buf_a, 0xAA);
    @memset(buf_b, 0xBB);

    // Measure ping-pong between buffers — this stresses TLB
    const start = Timer.now();
    for (0..num_pages) |i| {
        // Interleave access: A[i], B[i], A[i], B[i]
        const va1: usize = @intFromPtr(&buf_a[i * page_size]);
        const vb1: usize = @intFromPtr(&buf_b[i * page_size]);
        const pa = @as(*u8, @ptrFromInt(va1));
        const pb = @as(*u8, @ptrFromInt(vb1));
        pa.* +|= pb.*;
        pb.* +|= pa.*;
    }
    const end = Timer.now();

    // Reference: sequential access to single buffer
    const start_ref = Timer.now();
    for (0..num_pages) |i| {
        buf_a[i * page_size] +|= buf_b[i * page_size];
    }
    const end_ref = Timer.now();

    const pingpong_ns = Timer.ticksToNs(end - start, timer.tsc_hz) / @as(f64, @floatFromInt(num_pages));
    const sequential_ns = Timer.ticksToNs(end_ref - start_ref, timer.tsc_hz) / @as(f64, @floatFromInt(num_pages));

    return PageFaultResult{
        .label = "TLB Shootdown / Ping-Pong",
        .pages = num_pages,
        .total_bytes = total * 2,
        .first_touch_ns = pingpong_ns,
        .second_touch_ns = sequential_ns,
        .fault_overhead_ns = if (pingpong_ns > sequential_ns) pingpong_ns - sequential_ns else 0,
    };
}

pub fn runPageFaultSweep(allocator: std.mem.Allocator, timer: *const Timer) ![]PageFaultResult {
    const page_counts = [_]usize{ 64, 256, 1024, 4096 };

    var results_buf: [page_counts.len * 2]PageFaultResult = undefined;
    var count: usize = 0;

    // Minor fault test
    for (page_counts) |np| {
        const result = measureMinorFaultLatency(allocator, np, timer) catch |err| {
            std.debug.print("  [WARN] PageFault {} pages failed: {}\n", .{ np, err });
            continue;
        };
        results_buf[count] = result;
        count += 1;
    }

    // TLB shootdown approximation
    for (page_counts) |np| {
        if (np > 2048) break; // skip very large for memory sanity
        const result = measureTlbShootdown(allocator, np, timer) catch |err| {
            std.debug.print("  [WARN] TLB shootdown {} pages failed: {}\n", .{ np, err });
            continue;
        };
        results_buf[count] = result;
        count += 1;
    }

    const results = try allocator.alloc(PageFaultResult, count);
    @memcpy(results, results_buf[0..count]);
    return results;
}

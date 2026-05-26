const std = @import("std");

/// Statistical utilities for outlier rejection and confidence estimation.
///
/// Uses Median + MAD (Median Absolute Deviation) for robust filtering.
/// The median is resistant to outliers, unlike the mean.

/// raw_samples must be a mutable slice; it will be sorted in-place.
/// Returns: { mean, stddev, n_filtered, filtered_outliers }.
pub const FilteredStats = struct {
    mean: f64,
    stddev: f64,
    min: f64,
    max: f64,
    median: f64,
    n_raw: usize,
    n_filtered: usize,
};

/// Sort a mutable slice of f64 in-place (insertion sort, fine for benchmark data).
pub fn sort(values: []f64) void {
    if (values.len <= 1) return;
    for (1..values.len) |i| {
        const key = values[i];
        var j = i;
        while (j > 0 and values[j - 1] > key) : (j -= 1) {
            values[j] = values[j - 1];
        }
        values[j] = key;
    }
}

/// Compute the median of a sorted slice.
pub fn medianSorted(sorted: []const f64) f64 {
    if (sorted.len == 0) return 0;
    if (sorted.len % 2 == 1) {
        return sorted[sorted.len / 2];
    }
    return (sorted[sorted.len / 2 - 1] + sorted[sorted.len / 2]) / 2.0;
}

/// Compute median without modifying the original data (copies internally).
pub fn median(values: []const f64) f64 {
    if (values.len == 0) return 0;
    var copy = std.heap.page_allocator.alloc(f64, values.len) catch return values[0];
    defer std.heap.page_allocator.free(copy);
    @memcpy(copy, values);
    sort(copy);
    return medianSorted(copy);
}

/// Filter outliers using Median + k * MAD.
/// `k` is the threshold multiplier (typ. 3.0 for aggressive, 5.0 for conservative).
/// The returned slice is allocated from allocator and contains only the inlier values.
pub fn filterMAD(allocator: std.mem.Allocator, values: []const f64, k: f64) !struct { filtered: []f64, outliers: usize } {
    if (values.len <= 2) return .{ .filtered = try allocator.dupe(f64, values), .outliers = 0 };

    var copy = try allocator.alloc(f64, values.len);
    defer allocator.free(copy);
    @memcpy(copy, values);
    sort(copy);

    const med = medianSorted(copy);
    // Compute MAD
    var mad_sum: f64 = 0;
    for (copy) |v| {
        mad_sum += @abs(v - med);
    }
    const mad = mad_sum / @as(f64, @floatFromInt(copy.len));

    if (mad == 0) {
        // All values identical — nothing to filter
        return .{ .filtered = try allocator.dupe(f64, values), .outliers = 0 };
    }

    const threshold = k * mad;
    var count: usize = 0;
    for (values) |v| {
        if (@abs(v - med) <= threshold) count += 1;
    }

    var filtered = try allocator.alloc(f64, count);
    var idx: usize = 0;
    var outliers: usize = 0;
    for (values) |v| {
        if (@abs(v - med) <= threshold) {
            filtered[idx] = v;
            idx += 1;
        } else {
            outliers += 1;
        }
    }
    return .{ .filtered = filtered, .outliers = outliers };
}

/// Compute mean and sample standard deviation.
pub fn meanStddev(values: []const f64) struct { mean: f64, stddev: f64, min: f64, max: f64 } {
    if (values.len == 0) return .{ .mean = 0, .stddev = 0, .min = 0, .max = 0 };

    var sum: f64 = 0;
    var min: f64 = values[0];
    var max: f64 = values[0];
    for (values) |v| {
        sum += v;
        if (v < min) min = v;
        if (v > max) max = v;
    }
    const mean = sum / @as(f64, @floatFromInt(values.len));

    var sq_sum: f64 = 0;
    for (values) |v| {
        const d = v - mean;
        sq_sum += d * d;
    }
    const variance = sq_sum / @as(f64, @floatFromInt(values.len));
    const stddev = @sqrt(variance);

    return .{ .mean = mean, .stddev = stddev, .min = min, .max = max };
}

/// Run N measurement rounds, filter outliers, return aggregate stats.
/// `rounds` — number of times to call `measure_fn`.
/// `measure_fn` returns latency in ticks.
pub fn runRounds(allocator: std.mem.Allocator, rounds: usize, measure_fn: *const fn () u64) !FilteredStats {
    var raw = try allocator.alloc(f64, rounds);
    defer allocator.free(raw);

    // Pre-heat
    for (0..3) |_| _ = measure_fn();

    for (0..rounds) |i| {
        raw[i] = @floatFromInt(measure_fn());
    }

    const filtered = try filterMAD(allocator, raw, 3.0);
    defer allocator.free(filtered.filtered);

    const sm = meanStddev(filtered.filtered);
    const med = median(filtered.filtered);

    return .{
        .mean = sm.mean,
        .stddev = sm.stddev,
        .min = sm.min,
        .max = sm.max,
        .median = med,
        .n_raw = rounds,
        .n_filtered = filtered.filtered.len,
    };
}

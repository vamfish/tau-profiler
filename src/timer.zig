const std = @import("std");
const builtin = @import("builtin");

/// Cross-platform high-precision timer.
///
/// Supported timer sources per platform:
///   - x86_64 (any OS):   RDTSCP  (cycle-accurate)
///   - AArch64 (any OS):  CNTVCT_EL0  (ARM generic timer)
///   - macOS (any arch):  mach_absolute_time via `std.time.nanoTimestamp`
///   - Fallback:           OS monotonic clock via `std.time.nanoTimestamp`
pub const Timer = struct {
    tsc_hz: f64 = 0,
    calibrated: bool = false,
    timer_source: TimerSource = .fallback,

    pub const TimerSource = enum {
        rdtscp,
        cntvct,
        fallback,
    };

    pub fn init(io: std.Io) Timer {
        var t = Timer{};
        t.timer_source = detectSource();
        t.tsc_hz = t.calibrate(io) catch 0;
        t.calibrated = t.tsc_hz > 0;
        return t;
    }

    /// Read the current cycle counter / timestamp.
    pub fn now() u64 {
        return switch (builtin.cpu.arch) {
            .x86_64 => readRdtscp(),
            .aarch64 => readCntvct(),
            else => @intCast(std.time.nanoTimestamp()),
        };
    }

    /// Convert a tick count (raw timer units) to nanoseconds.
    pub fn ticksToNs(ticks: u64, tsc_hz: f64) f64 {
        if (tsc_hz > 0) return @as(f64, @floatFromInt(ticks)) / tsc_hz * 1.0e9;
        // Fallback: assume timer is already nanoseconds
        return @floatFromInt(ticks);
    }

    /// Convert a tick count to picoseconds.
    pub fn ticksToPs(ticks: u64, tsc_hz: f64) f64 {
        if (tsc_hz > 0) return @as(f64, @floatFromInt(ticks)) / tsc_hz * 1.0e12;
        return @as(f64, @floatFromInt(ticks)) * 1000.0;
    }

    /// Measure the overhead of calling `now()` (in ticks).
    pub fn measureOverhead() f64 {
        const start = now();
        const end = now();
        return @floatFromInt(end - start);
    }

    // ── Private ──

    fn detectSource() TimerSource {
        return switch (builtin.cpu.arch) {
            .x86_64 => .rdtscp,
            .aarch64 => .cntvct,
            else => .fallback,
        };
    }

    fn calibrate(self: *Timer, io: std.Io) !f64 {
        return switch (self.timer_source) {
            .rdtscp => calibrateViaSleep(io),
            .cntvct => calibrateCntvct(io),
            .fallback => calibrateFallback(io),
        };
    }

    /// Generic calibration: sleep for 1 second, measure delta of raw counter.
    fn calibrateViaSleep(io: std.Io) !f64 {
        const start = readRdtscp();
        std.Io.sleep(io, .{ .nanoseconds = 1_000_000_000 }, .awake) catch return error.CalibrationFailed;
        const end = readRdtscp();
        const delta = end - start;
        if (delta == 0) return error.CalibrationFailed;
        return @as(f64, @floatFromInt(delta));
    }

    /// Calibrate CNTVCT.
    /// On aarch64 Linux we can read CNTFRQ_EL0 for the frequency directly;
    /// otherwise fall back to sleep-and-measure.
    fn calibrateCntvct(io: std.Io) !f64 {
        // Try reading the architected timer frequency register
        const freq = readCntfrq();
        if (freq > 0) {
            // Cross-check via sleep to detect dynamic frequency scaling
            const start = readCntvct();
            std.Io.sleep(io, .{ .nanoseconds = 1_000_000_000 }, .awake) catch return error.CalibrationFailed;
            const end = readCntvct();
            const delta = end - start;
            if (delta == 0) return error.CalibrationFailed;
            // If measured frequency matches CNTFRQ within 1%, trust CNTFRQ
            const measured = @as(f64, @floatFromInt(delta));
            const nominal = @as(f64, @floatFromInt(freq));
            const ratio = measured / nominal;
            if (ratio > 0.99 and ratio < 1.01) return measured;
            // Otherwise use measured (accounts for VM accuracy issues)
            return measured;
        }

        // Fall back to sleep-and-measure
        const start = readCntvct();
        std.Io.sleep(io, .{ .nanoseconds = 1_000_000_000 }, .awake) catch return error.CalibrationFailed;
        const end = readCntvct();
        const delta = end - start;
        if (delta == 0) return error.CalibrationFailed;
        return @as(f64, @floatFromInt(delta));
    }

    /// Fallback calibration: use OS monotonic clock.
    fn calibrateFallback(io: std.Io) !f64 {
        // For OS-clock-based timers, we return the OS clock rate (1 GHz in ns)
        // and just use nanosecond timestamps directly.
        const start = std.time.nanoTimestamp();
        std.Io.sleep(io, .{ .nanoseconds = 1_000_000_000 }, .awake) catch return error.CalibrationFailed;
        const end = std.time.nanoTimestamp();
        const delta = end - start;
        if (delta == 0) return error.CalibrationFailed;
        // Timestamps are in nanoseconds, so the "frequency" is 1e9
        return 1_000_000_000.0;
    }
};

// ── Architecture-specific counter reads ──

fn readRdtscp() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    var aux: u32 = undefined;
    asm volatile ("rdtscp"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
          [aux] "={ecx}" (aux)
    );
    std.mem.doNotOptimizeAway(aux);
    return (@as(u64, hi) << 32) | lo;
}

fn readCntvct() u64 {
    var val: u64 = undefined;
    asm volatile ("mrs %[val], cntvct_el0"
        : [val] "=r" (val)
    );
    return val;
}

/// Read the ARM generic timer frequency register.
/// Returns 0 if not readable (e.g., in some VM configurations).
fn readCntfrq() u64 {
    var val: u64 = undefined;
    asm volatile ("mrs %[val], cntfrq_el0"
        : [val] "=r" (val)
    );
    return val;
}

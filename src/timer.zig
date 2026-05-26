const std = @import("std");
const builtin = @import("builtin");

pub const Timer = struct {
    tsc_hz: f64 = 0,
    calibrated: bool = false,

    pub fn init(io: std.Io) Timer {
        var t = Timer{};
        if (builtin.cpu.arch == .x86_64) {
            t.tsc_hz = calibrateTsc(io) catch 0;
            t.calibrated = t.tsc_hz > 0;
        }
        return t;
    }

    pub fn now() u64 {
        if (builtin.cpu.arch == .x86_64) return readRdtscp();
        return @intCast(std.time.nanoTimestamp());
    }

    pub fn ticksToNs(ticks: u64, tsc_hz: f64) f64 {
        if (tsc_hz > 0) return @as(f64, @floatFromInt(ticks)) / tsc_hz * 1.0e9;
        return @floatFromInt(ticks);
    }

    pub fn ticksToPs(ticks: u64, tsc_hz: f64) f64 {
        if (tsc_hz > 0) return @as(f64, @floatFromInt(ticks)) / tsc_hz * 1.0e12;
        return @as(f64, @floatFromInt(ticks)) * 1000.0;
    }

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

    fn calibrateTsc(io: std.Io) !f64 {
        const start = readRdtscp();
        // Use Io to sleep 1 second
        std.Io.sleep(io, .{ .nanoseconds = 1_000_000_000 }, .awake) catch return error.CalibrationFailed;
        const end = readRdtscp();
        const delta = end - start;
        if (delta == 0) return error.CalibrationFailed;
        return @as(f64, @floatFromInt(delta));
    }

    pub fn measureOverhead() f64 {
        const start = now();
        const end = now();
        return @floatFromInt(end - start);
    }
};

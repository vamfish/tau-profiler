const std = @import("std");
const builtin = @import("builtin");
const Timer = @import("timer.zig").Timer;
const platform = @import("platform.zig");

pub const CtxSwitchResult = struct {
    label: []const u8,
    method: []const u8,
    latency_ns: f64,
    latency_cycles: f64,
    confidence: f64,
    iterations: usize,
};

// ═══════════════════════════════════════════════════════════════
//  Linux  futex-based  context switch
// ═══════════════════════════════════════════════════════════════

/// Futex ping-pong state. Two threads exchange a token through
/// shared memory using Linux futex syscalls, forcing a true
/// scheduler-mediated context switch on every hand-off.
const FutexState = struct {
    turn_a: u32 = 0, // 0 = A's turn, 1 = A is done, waiting for B
    turn_b: u32 = 0, // 0 = B's turn, 1 = B is done, waiting for A
    ready: u32 = 0,  // 0 = not ready, 1 = both threads ready
};

fn futexWait(ptr: *u32, expected: u32) void {
    if (builtin.os.tag != .linux) return;
    const SYS = std.os.linux.SYS;
    _ = std.os.linux.syscall6(
        SYS.futex,
        @intFromPtr(ptr),
        @as(u32, 0), // FUTEX_WAIT
        expected,
        @as(usize, 0), // no timeout
        @as(usize, 0),
        @as(usize, 0),
    );
}

fn futexWake(ptr: *u32, count: u32) void {
    if (builtin.os.tag != .linux) return;
    const SYS = std.os.linux.SYS;
    _ = std.os.linux.syscall6(
        SYS.futex,
        @intFromPtr(ptr),
        @as(u32, 1), // FUTEX_WAKE
        count,
        @as(usize, 0),
        @as(usize, 0),
        @as(usize, 0),
    );
}

fn ctxSwitchFutex(iterations: usize, timer: *const Timer) struct { one_way_ns: f64, one_way_cycles: f64 } {
    var state = FutexState{};
    const pinned = platform.bindToCore(0);

    // Spawn thread B
    const thread_b = std.Thread.spawn(.{}, struct {
        fn run(s: *FutexState, iters: usize) void {
            // Pin to same core if possible
            if (pinned) _ = platform.bindToCore(0);

            // Signal ready
            @atomicStore(u32, &s.ready, 1, .release);

            for (0..iters) |_| {
                // Wait for A to signal
                futexWait(&s.turn_a, 1);
                @atomicStore(u32, &s.turn_a, 0, .release);

                // Signal A that we've processed
                @atomicStore(u32, &s.turn_b, 1, .release);
                futexWake(&s.turn_b, 1);
            }
        }
    }.run, .{ &state, iterations }) catch {
        return .{ .one_way_ns = 0, .one_way_cycles = 0 };
    };

    // Wait for B to be ready
    while (@atomicLoad(u32, &state.ready, .acquire) == 0) {
        std.Thread.yield() catch {};
    }

    // First signal: A wakes B
    @atomicStore(u32, &state.turn_a, 1, .release);
    futexWake(&state.turn_a, 1);

    // Measure round-trips
    const start = Timer.now();
    for (0..iterations) |_| {
        // Wait for B to respond
        futexWait(&state.turn_b, 1);
        @atomicStore(u32, &state.turn_b, 0, .release);

        // Signal B again (next iteration / final ack)
        @atomicStore(u32, &state.turn_a, 1, .release);
        futexWake(&state.turn_a, 1);
    }
    const end = Timer.now();

    thread_b.join();

    const total_ticks = end - start;
    const per_exchange = @as(f64, @floatFromInt(total_ticks)) / @as(f64, @floatFromInt(iterations));

    return .{
        .one_way_ns = Timer.ticksToNs(@as(u64, @intFromFloat(per_exchange / 2.0)), timer.tsc_hz),
        .one_way_cycles = per_exchange / 2.0,
    };
}

// ═══════════════════════════════════════════════════════════════
//  Cross-platform  yield-based  context switch
// ═══════════════════════════════════════════════════════════════

/// Use atomic flags + cooperative yield() to measure scheduler
/// hand-off latency.  This works on all platforms but yields
/// slightly higher variance than futex.
const YieldState = struct {
    flag: u32 = 0, // 0 = A's turn, 1 = B's turn
    ready: u32 = 0,
    done: u32 = 0,
    iterations: usize = 0,
};

fn ctxSwitchYield(iterations: usize, timer: *const Timer) struct { one_way_ns: f64, one_way_cycles: f64 } {
    var state = YieldState{
        .iterations = iterations,
    };
    const pinned = platform.bindToCore(0);

    const thread_b = std.Thread.spawn(.{}, struct {
        fn run(s: *YieldState) void {
            if (pinned) _ = platform.bindToCore(0);

            @atomicStore(u32, &s.ready, 1, .release);

            while (@atomicLoad(u32, &s.done, .acquire) == 0) {
                // Wait for flag == 1 (our turn)
                while (@atomicLoad(u32, &s.flag, .acquire) != 1) {
                    std.Thread.yield() catch {};
                    if (@atomicLoad(u32, &s.done, .acquire) != 0) return;
                }
                // Process: clear flag (give turn back to A)
                @atomicStore(u32, &s.flag, 0, .release);
            }
        }
    }.run, .{&state}) catch {
        return .{ .one_way_ns = 0, .one_way_cycles = 0 };
    };

    // Wait for B to be ready
    while (@atomicLoad(u32, &state.ready, .acquire) == 0) {
        std.Thread.yield() catch {};
    }

    const start = Timer.now();
    for (0..iterations) |_| {
        // Signal B
        @atomicStore(u32, &state.flag, 1, .release);
        // Wait for B to respond (flag == 0)
        while (@atomicLoad(u32, &state.flag, .acquire) == 1) {
            std.Thread.yield() catch {};
        }
    }
    const end = Timer.now();

    @atomicStore(u32, &state.done, 1, .release);
    thread_b.join();

    const total_ticks = end - start;
    const per_exchange = @as(f64, @floatFromInt(total_ticks)) / @as(f64, @floatFromInt(iterations));

    return .{
        .one_way_ns = Timer.ticksToNs(@as(u64, @intFromFloat(per_exchange / 2.0)), timer.tsc_hz),
        .one_way_cycles = per_exchange / 2.0,
    };
}

// ═══════════════════════════════════════════════════════════════
//  Public  API
// ═══════════════════════════════════════════════════════════════

/// Run the best available context switch benchmark.
/// Returns the one-way latency (one hand-off between two threads).
pub fn runCtxSwitch(allocator: std.mem.Allocator, timer: *const Timer) ![]CtxSwitchResult {
    const iterations: usize = 1000;

    var results = std.ArrayList(CtxSwitchResult).init(allocator);
    const errs = results.ensureUnusedCapacity(2) catch {};

    // ── Fast path: Linux futex ──
    comptime if (builtin.os.tag == .linux) {
        std.debug.print("  Method: Linux futex\n", .{});
        const r = ctxSwitchFutex(iterations, timer);
        if (r.one_way_cycles > 0) {
            results.appendAssumeCapacity(CtxSwitchResult{
                .label = "Context Switch (futex)",
                .method = "linux-futex",
                .latency_ns = r.one_way_ns,
                .latency_cycles = r.one_way_cycles,
                .confidence = 0.80,
                .iterations = iterations,
            });
        }
    }

    // ── Fallback: yield-based ──
    comptime if (builtin.os.tag != .linux) {
        std.debug.print("  Method: cooperative yield\n", .{});
        const r = ctxSwitchYield(iterations, timer);
        if (r.one_way_cycles > 0) {
            results.appendAssumeCapacity(CtxSwitchResult{
                .label = "Context Switch (yield)",
                .method = "yield",
                .latency_ns = r.one_way_ns,
                .latency_cycles = r.one_way_cycles,
                .confidence = 0.60, // higher variance
                .iterations = iterations,
            });
        }
    }

    if (errs != {}) {
        // If allocation was tight, return empty
        if (results.items.len == 0) {
            results.appendAssumeCapacity(CtxSwitchResult{
                .label = "Context Switch",
                .method = "unavailable",
                .latency_ns = 0,
                .latency_cycles = 0,
                .confidence = 0,
                .iterations = 0,
            });
        }
    }

    return results.toOwnedSlice();
}

const std = @import("std");
const builtin = @import("builtin");

const platform = @import("platform.zig");
const timer_mod = @import("timer.zig");
const cache = @import("cache.zig");

const Timer = timer_mod.Timer;
const SYS = std.os.linux.SYS;

/// Read a sysfs file via raw Linux syscalls.
fn readSysFile(path: []const u8, buffer: []u8) usize {
    if (builtin.os.tag != .linux) return 0;
    // Build a null-terminated copy
    var zpath: [128]u8 = undefined;
    const n = @min(path.len, zpath.len - 1);
    @memcpy(zpath[0..n], path[0..n]);
    zpath[n] = 0;

    const fd = std.os.linux.syscall3(SYS.open, @intFromPtr(&zpath), @as(usize, 0), @as(usize, 0));
    if (fd >> 63 != 0) return 0; // check negative (error)

    const bytes_read = std.os.linux.syscall3(SYS.read, fd, @intFromPtr(buffer.ptr), buffer.len);
    _ = std.os.linux.syscall1(SYS.close, fd);

    if (bytes_read >> 63 != 0) return 0;
    return @as(usize, @intCast(bytes_read));
}

fn parseCpuRange(content: []const u8) u32 {
    const trimmed = std.mem.trim(u8, content, " \n\r\t");
    if (trimmed.len == 0) return 0;
    if (std.mem.indexOfScalar(u8, trimmed, '-')) |dash| {
        const end = std.fmt.parseInt(u32, std.mem.trim(u8, trimmed[dash + 1 ..], " \n\r"), 10) catch return 1;
        return end + 1;
    }
    var count: u32 = 0;
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |part| {
        const p = std.mem.trim(u8, part, " \n\r");
        if (p.len == 0) continue;
        _ = std.fmt.parseInt(u32, p, 10) catch {
            if (std.mem.indexOfScalar(u8, p, '-')) |dash| {
                const e = std.fmt.parseInt(u32, std.mem.trim(u8, p[dash + 1 ..], " \n\r"), 10) catch continue;
                const s = std.fmt.parseInt(u32, p[0..dash], 10) catch continue;
                count += e - s + 1;
            }
            continue;
        };
        count += 1;
    }
    return count;
}

fn countPhysicalCores() u32 {
    var buf: [128]u8 = undefined;
    var seen: u64 = 0;
    for (0..64) |cpu| {
        var pb: [64]u8 = undefined;
        const path = std.fmt.bufPrint(pb[0..], "/sys/devices/system/cpu/cpu{d}/topology/core_id", .{cpu}) catch break;
        const n = readSysFile(path, &buf);
        if (n == 0) break;
        const trimmed = std.mem.trim(u8, buf[0..n], " \n\r\t");
        if (trimmed.len == 0) break;
        const id = std.fmt.parseInt(u32, trimmed, 10) catch continue;
        if (id < 64) seen |= @as(u64, 1) << @intCast(id);
    }
    return @intCast(@popCount(seen));
}

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

fn bindToCore0() bool {
    if (builtin.os.tag != .linux) return false;
    var mask: usize = 1;
    const rc = std.os.linux.syscall3(SYS.sched_setaffinity, @as(usize, 0), @as(usize, @sizeOf(usize)), @intFromPtr(&mask));
    if (rc >> 63 != 0) return false;
    var result_mask: usize = 0;
    _ = std.os.linux.syscall3(SYS.sched_getaffinity, 0, @sizeOf(usize), @intFromPtr(&result_mask));
    return result_mask == 1;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.debug.print("=== Tau-Profiler Engine v0.1.0 ===\n", .{});
    std.debug.print("[1/4] Detecting platform...\n", .{});

    // Build PlatformInfo with stable string references
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
    if (builtin.os.tag == .linux) {
        var buf: [256]u8 = undefined;
        const n = readSysFile("/sys/devices/system/cpu/online", &buf);
        if (n > 0) info.logical_cores = parseCpuRange(buf[0..n]);
        info.physical_cores = countPhysicalCores();
    }

    std.debug.print("  OS: {s}, Arch: {s}\n", .{ info.os, info.arch });
    std.debug.print("  CPU: {s}\n", .{info.cpu_brand});
    std.debug.print("  Cores: {}/{} (phys/logical)\n", .{ info.physical_cores, info.logical_cores });

    var warnings: std.ArrayList([]const u8) = .empty;
    if (info.is_virtualized) {
        try warnings.append(allocator, "Running inside a VM -- results may have extra jitter");
    }

    std.debug.print("[2/4] Calibrating timer...\n", .{});
    var timer = Timer.init(io);
    if (timer.calibrated) {
        std.debug.print("  TSC freq: {d:.2} MHz\n", .{timer.tsc_hz / 1_000_000.0});
    } else {
        std.debug.print("  WARNING: TSC calibration failed\n", .{});
        try warnings.append(allocator, "TSC failed -- using OS clock");
    }

    const overhead = Timer.measureOverhead();
    std.debug.print("  Timer overhead: {d:.0} ticks\n", .{overhead});

    std.debug.print("[3/4] Binding to core 0...\n", .{});
    const bound = bindToCore0();
    if (!bound) {
        std.debug.print("  WARNING: Could not bind\n", .{});
        try warnings.append(allocator, "Not bound to a single core");
    } else {
        std.debug.print("  OK\n", .{});
    }

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

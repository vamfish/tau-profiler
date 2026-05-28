const std = @import("std");
const builtin = @import("builtin");

pub const MsrReader = union(enum) {
    windows: WindowsMsr,
    linux: LinuxMsr,
    none,

    pub fn init() MsrReader {
        if (builtin.os.tag == .windows) {
            if (WindowsMsr.init()) |w| return .{ .windows = w };
            return .none;
        }
        if (builtin.os.tag == .linux) {
            if (LinuxMsr.init()) |l| return .{ .linux = l };
            return .none;
        }
        return .none;
    }

    pub fn read(self: *MsrReader, msr_addr: u32) !u64 {
        return switch (self.*) {
            .windows => |*w| w.read(msr_addr),
            .linux => |*l| l.read(msr_addr),
            .none => error.MsrNotAvailable,
        };
    }

    pub fn available(self: MsrReader) bool {
        return self != .none;
    }

    pub fn deinit(self: *MsrReader) void {
        switch (self.*) {
            .windows => |*w| w.deinit(),
            .linux => |*l| l.deinit(),
            .none => {},
        }
        self.* = .none;
    }
};

// ── Windows: NtSystemDebugControl ──

const WindowsMsr = struct {
    const SysDbgReadMsr: u32 = 16;

    const TOKEN_ADJUST_PRIVILEGES: u32 = 0x0020;
    const TOKEN_QUERY: u32 = 0x0008;
    const SE_PRIVILEGE_ENABLED: u32 = 0x00000002;

    extern "ntdll" fn NtSystemDebugControl(
        command: u32,
        input: ?*anyopaque,
        input_len: u32,
        output: ?*anyopaque,
        output_len: u32,
        ret_len: ?*u32,
    ) callconv(.c) i32;

    extern "kernel32" fn GetCurrentProcess() callconv(.c) *anyopaque;
    extern "advapi32" fn OpenProcessToken(h: *anyopaque, access: u32, token: **anyopaque) callconv(.c) i32;
    extern "advapi32" fn LookupPrivilegeValueW(system: ?[*:0]const u16, name: [*:0]const u16, luid: *i64) callconv(.c) i32;
    extern "advapi32" fn AdjustTokenPrivileges(token: *anyopaque, disable_all: i32, new_state: *anyopaque, buf_len: u32, prev_state: ?*anyopaque, ret_len: ?*u32) callconv(.c) i32;
    extern "kernel32" fn CloseHandle(h: *anyopaque) callconv(.c) i32;

    extern "shell32" fn IsUserAnAdmin() callconv(.c) i32;

    fn enableDebugPrivilege() bool {
        var token: *anyopaque = undefined;
        if (OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token) == 0) {
            std.debug.print("  [MSR] OpenProcessToken failed\n", .{});
            return false;
        }
        defer _ = CloseHandle(token);

        var luid: i64 = undefined;
        const se_debug = [_:0]u16{ 'S', 'e', 'D', 'e', 'b', 'u', 'g', 'P', 'r', 'i', 'v', 'i', 'l', 'e', 'g', 'e', 0 };
        if (LookupPrivilegeValueW(null, @ptrCast(&se_debug), &luid) == 0) {
            std.debug.print("  [MSR] LookupPrivilegeValue failed\n", .{});
            return false;
        }

        const LUID_AND_ATTRIBUTES = extern struct { luid: i64, attributes: u32 };
        const tp = LUID_AND_ATTRIBUTES{ .luid = luid, .attributes = SE_PRIVILEGE_ENABLED };
        const TOKEN_PRIVILEGES = extern struct { count: u32, privileges: [1]LUID_AND_ATTRIBUTES };
        var new_state = TOKEN_PRIVILEGES{ .count = 1, .privileges = [1]LUID_AND_ATTRIBUTES{tp} };
        if (AdjustTokenPrivileges(token, 0, @ptrCast(&new_state), @sizeOf(TOKEN_PRIVILEGES), null, null) == 0) {
            std.debug.print("  [MSR] AdjustTokenPrivileges failed\n", .{});
            return false;
        }
        return true;
    }

    fn init() ?WindowsMsr {
        if (IsUserAnAdmin() == 0) {
            std.debug.print("  [MSR] Not running as Administrator\n", .{});
            return null;
        }
        if (!enableDebugPrivilege()) {
            std.debug.print("  [MSR] Could not enable SeDebugPrivilege\n", .{});
            // Continue anyway — some systems allow MSR without explicit privilege
        }

        var probe: u64 = 0;
        var addr: u32 = 0xCE;
        const status = NtSystemDebugControl(SysDbgReadMsr, @ptrCast(&addr), @sizeOf(u32), @ptrCast(&probe), @sizeOf(u64), null);
        if (status == @as(i32, @bitCast(@as(u32, 0xc0000022)))) {
            std.debug.print("  [MSR] Access denied (needs SeDebugPrivilege + admin)\n", .{});
            return null;
        }
        if (status == @as(i32, @bitCast(@as(u32, 0xc0000354)))) {
            std.debug.print("  [MSR] Kernel debugger not active (API blocked by Windows)\n", .{});
            std.debug.print("  [MSR] MSR access on Windows requires a kernel driver.\n", .{});
            std.debug.print("  [MSR] See: docs/windows-msr-driver-analysis.md\n", .{});
            return null;
        }
        std.debug.print("  [MSR] NtSystemDebugControl failed: status=0x{x}\n", .{@as(u32, @bitCast(status))});
        return null;
    }

    fn read(self: WindowsMsr, msr_addr: u32) !u64 {
        _ = self;
        var value: u64 = 0;
        var addr = msr_addr;
        const status = NtSystemDebugControl(SysDbgReadMsr, @ptrCast(&addr), @sizeOf(u32), @ptrCast(&value), @sizeOf(u64), null);
        if (status < 0) return error.MsrReadFailed;
        return value;
    }

    fn deinit(self: *WindowsMsr) void {
        _ = self;
    }
};

// ── Linux: /dev/cpu/N/msr (compiled only on Linux) ──

const LinuxMsr = if (builtin.os.tag == .linux)
    struct {
        fd: std.posix.fd_t,

        fn init() ?@This() {
            const fd = std.posix.open("/dev/cpu/0/msr", .{ .ACCMODE = .RDONLY }, 0) catch return null;
            return .{ .fd = fd };
        }

        fn read(self: *@This(), msr_addr: u32) !u64 {
            var buf: [8]u8 = undefined;
            const n = std.posix.pread(@intCast(self.fd), &buf, 8, @as(i64, @intCast(msr_addr)));
            if (n != 8) return error.MsrReadFailed;
            return std.mem.readInt(u64, &buf, .little);
        }

        fn deinit(self: *@This()) void {
            std.posix.close(self.fd);
        }
    }
else
    struct {
        fn init() ?@This() { return null; }
        fn read(_: *@This(), _: u32) !u64 { return error.MsrNotAvailable; }
        fn deinit(_: *@This()) void {}
    };

// ── MSR info structs ──

pub const MsrInfo = struct {
    max_non_turbo_ratio: u32 = 0,
    max_efficiency_ratio: u32 = 0,
    min_operating_ratio: u32 = 0,
    turbo_ratios_1c: [8]u32 = @splat(0),
    turbo_ratios_per_core: [32]u32 = @splat(0),
    pl1_power_w: f32 = 0,
    pl2_power_w: f32 = 0,
    pl1_time_s: f32 = 0,
    package_power_w: f32 = 0,
    energy_unit_j: f32 = 0,
    tjmax_c: u32 = 0,
    microcode_rev: u64 = 0,
};

pub fn readMsrInfo(reader: *MsrReader) !MsrInfo {
    if (!reader.available()) return error.MsrNotAvailable;
    var info = MsrInfo{};

    // MSR 0xCE: PLATFORM_INFO
    if (reader.read(0xCE)) |ce| {
        info.max_non_turbo_ratio = @intCast((ce >> 8) & 0xFF);
        info.max_efficiency_ratio = @intCast((ce >> 40) & 0xFF);
        info.min_operating_ratio = @intCast((ce >> 48) & 0xFF);
    } else |_| {}

    // MSR 0x1AD: TURBO_RATIO_LIMIT
    if (reader.read(0x1AD)) |val| {
        info.turbo_ratios_1c[0] = @intCast(val & 0xFF);
        info.turbo_ratios_1c[1] = @intCast((val >> 8) & 0xFF);
        info.turbo_ratios_1c[2] = @intCast((val >> 16) & 0xFF);
        info.turbo_ratios_1c[3] = @intCast((val >> 24) & 0xFF);
        info.turbo_ratios_1c[4] = @intCast((val >> 32) & 0xFF);
        info.turbo_ratios_1c[5] = @intCast((val >> 40) & 0xFF);
        info.turbo_ratios_1c[6] = @intCast((val >> 48) & 0xFF);
        info.turbo_ratios_1c[7] = @intCast((val >> 56) & 0xFF);
    } else |_| {}

    // MSR 0x610: PKG_POWER_LIMIT
    if (reader.read(0x610)) |val| {
        const power_unit: f32 = 0.125;
        info.pl1_power_w = @as(f32, @floatFromInt(val & 0x7FFF)) * power_unit;
        info.pl2_power_w = @as(f32, @floatFromInt((val >> 32) & 0x7FFF)) * power_unit;
        const time_val = (val >> 17) & 0x7F;
        const time_unit: f32 = 0.9765625;
        info.pl1_time_s = @as(f32, @floatFromInt(time_val)) * time_unit;
    } else |_| {}

    // MSR 0x606: RAPL_POWER_UNIT
    if (reader.read(0x606)) |val| {
        const e_unit: f32 = @floatFromInt(@as(u64, 1) << @intCast((val >> 8) & 0x1F));
        info.energy_unit_j = 1.0 / e_unit;
    } else |_| {}

    // MSR 0x611: PKG_ENERGY_STATUS
    if (reader.read(0x611)) |val| {
        info.package_power_w = @as(f32, @floatFromInt(val & 0xFFFFFFFF)) * info.energy_unit_j;
    } else |_| {}

    // MSR 0x1A2: TEMPERATURE_TARGET
    if (reader.read(0x1A2)) |val| {
        info.tjmax_c = @intCast((val >> 16) & 0xFF);
    } else |_| {}

    // MSR 0x8B: IA32_BIOS_UPDT_TRIG
    info.microcode_rev = reader.read(0x8B) catch 0;

    return info;
}

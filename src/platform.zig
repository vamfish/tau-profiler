const std = @import("std");
const builtin = @import("builtin");

pub const PlatformInfo = struct {
    os: []const u8,
    arch: []const u8,
    cpu_vendor: []const u8,
    cpu_brand: []const u8,
    physical_cores: u32,
    logical_cores: u32,
    page_size: u64,
    has_invariant_tsc: bool,
    is_virtualized: bool,
    virtualized_under: []const u8,
    l1_data_kb: u32,
    l1_inst_kb: u32,
    l2_cache_kb: u32,
    l3_cache_kb: u32,
    cpu_max_ghz: f32,
    cpu_base_ghz: f32,
};

// ─── Public API ────────────────────────────────────────────────

pub fn getOS() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "windows",
        .linux => "linux",
        .macos => "macos",
        else => "unknown",
    };
}

pub fn getArch() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => "unknown",
    };
}

pub fn getCpuVendor() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => getCpuVendorX86(),
        .aarch64 => "arm",
        else => "unknown",
    };
}

pub fn getInvariantTsc() bool {
    return switch (builtin.cpu.arch) {
        .x86_64 => getInvariantTscX86(),
        .aarch64 => true, // ARM generic timer (CNTVCT) is always invariant
        else => false,
    };
}

pub const VmInfo = struct { is_vm: bool, hv: []const u8 };

pub fn getVirtualization() VmInfo {
    return switch (builtin.cpu.arch) {
        .x86_64 => getVirtualizationX86(),
        .aarch64 => getVirtualizationAarch64(),
        else => .{ .is_vm = false, .hv = "none" },
    };
}

/// Fill a buffer with the CPU brand string. Returns the slice of buffer that contains the brand.
pub fn getCpuBrand(buffer: []u8) []u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => getCpuBrandX86(buffer),
        .aarch64 => getCpuBrandAarch64(buffer),
        else => {
            @memset(buffer, 0);
            const label = "generic";
            @memcpy(buffer[0..label.len], label);
            return buffer[0..label.len];
        },
    };
}

// ─── OS topology / affinity helpers ────────────────────────────

pub fn getPhysicalCores() u32 {
    return switch (builtin.os.tag) {
        .linux => getPhysicalCoresLinux(),
        .macos => getCoresSysctl("hw.physicalcpu"),
        .windows => getPhysicalCoresWindows(),
        else => 0,
    };
}

pub fn getLogicalCores() u32 {
    return switch (builtin.os.tag) {
        .linux => getLogicalCoresLinux(),
        .macos => getCoresSysctl("hw.logicalcpu"),
        .windows => getCoresWindows(),
        else => 0,
    };
}

pub fn bindToCore(core: u32) bool {
    return switch (builtin.os.tag) {
        .linux => bindToCoreLinux(core),
        .macos => false, // macOS has no portable cross-version affinity API
        .windows => bindToCoreWindows(core),
        else => false,
    };
}

// ═══════════════════════════════════════════════════════════════
//  x86-64  implementation  (CPUID)
// ═══════════════════════════════════════════════════════════════

fn getCpuVendorX86() []const u8 {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx)
        : [leaf] "{eax}" (0)
    );
    var vendor: [12]u8 = undefined;
    @memcpy(vendor[0..4], std.mem.asBytes(&ebx));
    @memcpy(vendor[4..8], std.mem.asBytes(&edx));
    @memcpy(vendor[8..12], std.mem.asBytes(&ecx));
    if (std.mem.eql(u8, &vendor, "GenuineIntel")) return "intel";
    if (std.mem.eql(u8, &vendor, "AuthenticAMD")) return "amd";
    return "unknown";
}

fn getInvariantTscX86() bool {
    var edx: u32 = undefined;
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx)
        : [leaf] "{eax}" (0x80000007)
    );
    return (edx & (1 << 8)) != 0;
}

fn getVirtualizationX86() VmInfo {
    // Use separate variables for each CPUID call to avoid register conflicts
    // CPUID leaf 1: check hypervisor bit
    var ecx1: u32 = undefined;
    var eax1: u32 = undefined;
    var ebx1: u32 = undefined;
    var edx1: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax1),
          [ebx] "={ebx}" (ebx1),
          [ecx] "={ecx}" (ecx1),
          [edx] "={edx}" (edx1)
        : [leaf] "{eax}" (@as(u32, 1))
    );
    const hv_present = (ecx1 & (1 << 31)) != 0;
    if (!hv_present) return .{ .is_vm = false, .hv = "none" };

    // CPUID leaf 0x40000000: get hypervisor signature
    var ecx2: u32 = undefined;
    var eax2: u32 = undefined;
    var ebx2: u32 = undefined;
    var edx2: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax2),
          [ebx] "={ebx}" (ebx2),
          [ecx] "={ecx}" (ecx2),
          [edx] "={edx}" (edx2)
        : [leaf] "{eax}" (@as(u32, 0x40000000))
    );
    var sig: [12]u8 = undefined;
    @memcpy(sig[0..4], std.mem.asBytes(&ebx2));
    @memcpy(sig[4..8], std.mem.asBytes(&ecx2));
    @memcpy(sig[8..12], std.mem.asBytes(&edx2));
    const end = std.mem.indexOfScalar(u8, &sig, 0) orelse 12;
    if (end >= 4 and std.mem.eql(u8, sig[0..4], "Micr")) {
        // Hyper-V detected. Check if the hypervisor supports leaf 0x40000003
        // (partition type). eax2 contains the max hypervisor CPUID leaf.
        const hv_max_leaf = eax2;
        if (hv_max_leaf >= 0x40000003) {
            // CPUID leaf 0x40000003: EAX[7:0] = partition type
            var ecx3: u32 = undefined;
            var eax3: u32 = undefined;
            var ebx3: u32 = undefined;
            var edx3: u32 = undefined;
            asm volatile ("cpuid"
                : [eax] "={eax}" (eax3),
                  [ebx] "={ebx}" (ebx3),
                  [ecx] "={ecx}" (ecx3),
                  [edx] "={edx}" (edx3)
                : [leaf] "{eax}" (@as(u32, 0x40000003))
            );
            // partition_type: 0=root (bare metal), 1=enlightened VM, 2=un-enlightened VM
            const partition_type = eax3 & 0xFF;
            if (partition_type == 0) {
                return .{ .is_vm = false, .hv = "Hyper-V (root partition)" };
            }
            return .{ .is_vm = true, .hv = "Hyper-V / WSL2" };
        }
        // Hypervisor doesn't expose partition info; assume bare metal if
        // the Hyper-V platform is active on the host.
        return .{ .is_vm = false, .hv = "Hyper-V (host)" };
    }
    if (end >= 4 and std.mem.eql(u8, sig[0..4], "KVMK")) return .{ .is_vm = true, .hv = "KVM" };
    if (end >= 4 and std.mem.eql(u8, sig[0..4], "VMwa")) return .{ .is_vm = true, .hv = "VMware" };
    if (end >= 4 and std.mem.eql(u8, sig[0..4], "XenV")) return .{ .is_vm = true, .hv = "Xen" };
    return .{ .is_vm = true, .hv = "unknown" };
}

pub const CpuFreqInfo = struct {
    base_ghz: f32 = 0,
    max_ghz: f32 = 0,
};

pub fn getCpuFreqX86() CpuFreqInfo {
    // First, get max supported CPUID leaf
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx)
        : [leaf] "{eax}" (@as(u32, 0))
    );
    const max_leaf = eax;

    if (max_leaf >= 0x16) {
        // CPUID leaf 0x16: Processor Frequency Info (Intel Skylake+)
        asm volatile ("cpuid"
            : [eax] "={eax}" (eax),
              [ebx] "={ebx}" (ebx),
              [ecx] "={ecx}" (ecx),
              [edx] "={edx}" (edx)
            : [leaf] "{eax}" (@as(u32, 0x16))
        );
        const base_mhz: f32 = @floatFromInt(eax & 0xFFFF);
        const max_mhz: f32 = @floatFromInt(ebx & 0xFFFF);
        if (base_mhz > 0 and max_mhz > 0) {
            return .{
                .base_ghz = base_mhz / 1000.0,
                .max_ghz = max_mhz / 1000.0,
            };
        }
    }

    if (max_leaf >= 0x15) {
        // CPUID leaf 0x15: TSC / Core Crystal Clock Info
        asm volatile ("cpuid"
            : [eax] "={eax}" (eax),
              [ebx] "={ebx}" (ebx),
              [ecx] "={ecx}" (ecx),
              [edx] "={edx}" (edx)
            : [leaf] "{eax}" (@as(u32, 0x15))
        );
        const crystal_hz = @as(f32, @floatFromInt(ecx)); // Core crystal clock in Hz
        if (crystal_hz > 0) {
            return .{
                .base_ghz = crystal_hz / 1_000_000_000.0,
                .max_ghz = 0,
            };
        }
    }

    return .{ .base_ghz = 0, .max_ghz = 0 };
}

pub const CacheInfo = struct {
    l1_data_kb: u32 = 0,
    l1_inst_kb: u32 = 0,
    l2_cache_kb: u32 = 0,
    l3_cache_kb: u32 = 0,
};

pub fn getCacheInfo() CacheInfo {
    return switch (builtin.cpu.arch) {
        .x86_64 => getCacheInfoX86(),
        .aarch64 => getCacheInfoAarch64(),
        else => .{},
    };
}

fn getCacheInfoX86() CacheInfo {
    var info: CacheInfo = .{};

    // Use CPUID leaf 0x4 (Deterministic Cache Parameters)
    // Iterate subleaves until Cache Type == 0
    var subleaf: u32 = 0;
    while (subleaf < 16) : (subleaf += 1) {
        var eax: u32 = undefined;
        var ebx: u32 = undefined;
        var ecx: u32 = undefined;
        var edx: u32 = undefined;
        asm volatile ("cpuid"
            : [eax] "={eax}" (eax),
              [ebx] "={ebx}" (ebx),
              [ecx] "={ecx}" (ecx),
              [edx] "={edx}" (edx)
            : [leaf] "{eax}" (@as(u32, 0x4)),
              [subleaf] "{ecx}" (subleaf)
        );
        const cache_type: u32 = eax & 0x1F;
        if (cache_type == 0) break; // no more caches

        const level: u32 = (eax >> 5) & 0x7;
        const line_size: u32 = (ebx & 0xFFF) + 1;
        const partitions: u32 = ((ebx >> 12) & 0x3FF) + 1;
        const ways: u32 = ((ebx >> 22) & 0x3FF) + 1;
        const sets: u32 = ecx + 1;
        const size_bytes: u32 = ways * partitions * line_size * sets;
        const size_kb: u32 = size_bytes / 1024;

        // Store per-instance cache sizes from CPUID.
        // The total capacity is computed later using core counts.
        switch (level) {
            1 => {
                if (cache_type == 1) info.l1_data_kb = size_kb;
                if (cache_type == 2) info.l1_inst_kb = size_kb;
            },
            2 => info.l2_cache_kb = size_kb,
            3 => info.l3_cache_kb = size_kb,
            else => {},
        }
    }

    return info;
}

fn getCacheInfoAarch64() CacheInfo {
    // AArch64: read cache info from system registers
    return .{};
}

fn getCpuBrandX86(buffer: []u8) []u8 {
    @memset(buffer, 0);
    for (0..3) |i| {
        const leaf: u32 = @intCast(0x80000002 + i);
        var eax: u32 = undefined;
        var ebx: u32 = undefined;
        var ecx: u32 = undefined;
        var edx: u32 = undefined;
        asm volatile ("cpuid"
            : [eax] "={eax}" (eax),
              [ebx] "={ebx}" (ebx),
              [ecx] "={ecx}" (ecx),
              [edx] "={edx}" (edx)
            : [leaf] "{eax}" (leaf)
        );
        const off = i * 16;
        if (off + 16 > buffer.len) break;
        @memcpy(buffer[off..][0..4], std.mem.asBytes(&eax));
        @memcpy(buffer[off + 4 ..][0..4], std.mem.asBytes(&ebx));
        @memcpy(buffer[off + 8 ..][0..4], std.mem.asBytes(&ecx));
        @memcpy(buffer[off + 12 ..][0..4], std.mem.asBytes(&edx));
    }
    const end = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    var slice = buffer[0..end];
    while (slice.len > 0 and slice[slice.len - 1] == ' ') {
        slice = slice[0 .. slice.len - 1];
    }
    return slice;
}

fn getPhysicalCoresLinux() u32 {
    return countCoresFromSysfs("physical_package_id", "core_id");
}

fn getLogicalCoresLinux() u32 {
    var buf: [256]u8 = undefined;
    const n = readSysFile("/sys/devices/system/cpu/online", &buf);
    if (n > 0) return parseCpuRange(buf[0..n]);
    return 0;
}

fn bindToCoreLinux(core: u32) bool {
    comptime if (builtin.os.tag == .linux) {
        const mask = @as(usize, 1) << @as(u6, @intCast(core));
        const SYS = std.os.linux.SYS;
        const rc = std.os.linux.syscall3(SYS.sched_setaffinity, @as(usize, 0), @as(usize, @sizeOf(usize)), @intFromPtr(&mask));
        if (rc >> 63 != 0) return false;
        var result_mask: usize = 0;
        _ = std.os.linux.syscall3(SYS.sched_getaffinity, 0, @sizeOf(usize), @intFromPtr(&result_mask));
        return result_mask == mask;
    };
    return false;
}

// ═══════════════════════════════════════════════════════════════
//  AArch64  implementation
// ═══════════════════════════════════════════════════════════════

fn getCpuBrandAarch64(buffer: []u8) []u8 {
    @memset(buffer, 0);

    // macOS: use sysctl
    if (builtin.os.tag == .macos) {
        return getCpuBrandMacos(buffer);
    }

    // Linux aarch64: /proc/cpuinfo
    if (builtin.os.tag == .linux) {
        return getCpuBrandFromProcCpuinfo(buffer);
    }

    // Windows ARM / others
    const label = "AArch64";
    @memcpy(buffer[0..label.len], label);
    return buffer[0..label.len];
}

fn getCpuBrandMacos(buffer: []u8) []u8 {
    comptime if (builtin.os.tag == .macos) {
        @memset(buffer, 0);
        // Try sysctl first for specific model (e.g. "Apple M1 Pro")
        var size: usize = buffer.len;
        var sysctl_name: [32]u8 = undefined;
        const sysctl_str = "machdep.cpu.brand_string";
        @memcpy(sysctl_name[0..sysctl_str.len], sysctl_str);
        sysctl_name[sysctl_str.len] = 0;
        const rc = std.c.sysctlbyname(
            @as([*:0]const u8, @ptrCast(&sysctl_name)),
            @as(?*anyopaque, @ptrCast(buffer.ptr)),
            &size,
            null,
            0,
        );
        if (rc == 0 and size > 0) {
            const end = std.mem.indexOfScalar(u8, buffer[0..size], 0) orelse size;
            var slice = buffer[0..end];
            while (slice.len > 0 and slice[slice.len - 1] == ' ') {
                slice = slice[0 .. slice.len - 1];
            }
            if (slice.len > 0) return slice;
        }
        // Fallback to generic Apple Silicon label
        const label = "Apple Silicon";
        @memcpy(buffer[0..label.len], label);
        return buffer[0..label.len];
    };
    return "Apple Silicon";
}

fn getCpuBrandFromProcCpuinfo(buffer: []u8) []u8 {
    const file = std.fs.openFileAbsolute("/proc/cpuinfo", .{}) catch return genericAarch64(buffer);
    defer file.close();

    const content = file.readToEndAllocOptions(std.heap.page_allocator, 4096, null, @alignOf(u8), 0) catch return genericAarch64(buffer);
    defer std.heap.page_allocator.free(content);

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "Model name") or
            std.mem.startsWith(u8, trimmed, "model name"))
        {
            const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
            var value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t\r");
            if (value.len > buffer.len) value = value[0..buffer.len];
            @memcpy(buffer[0..value.len], value);
            return buffer[0..value.len];
        }
    }
    // Also look for "Hardware" as fallback
    it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "Hardware")) {
            const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
            var value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t\r");
            if (value.len > buffer.len) value = value[0..buffer.len];
            @memcpy(buffer[0..value.len], value);
            return buffer[0..value.len];
        }
    }
    return genericAarch64(buffer);
}

fn genericAarch64(buffer: []u8) []u8 {
    const label = "AArch64 Processor";
    @memcpy(buffer[0..label.len], label);
    return buffer[0..label.len];
}

fn getVirtualizationAarch64() VmInfo {
    if (builtin.os.tag == .linux) {
        // Check /sys/hypervisor first
        if (std.fs.accessAbsolute("/sys/hypervisor/type", .{})) {
            const f = std.fs.openFileAbsolute("/sys/hypervisor/type", .{}) catch return .{ .is_vm = false, .hv = "none" };
            defer f.close();
            var buf: [64]u8 = undefined;
            const n = f.read(&buf) catch return .{ .is_vm = false, .hv = "none" };
            const t = std.mem.trim(u8, buf[0..n], " \n\r\t");
            if (t.len > 0) return .{ .is_vm = true, .hv = t };
        }
        // Check /proc/cpuinfo for hypervisor field
        const file = std.fs.openFileAbsolute("/proc/cpuinfo", .{}) catch return .{ .is_vm = false, .hv = "none" };
        defer file.close();
        const content = file.readToEndAllocOptions(std.heap.page_allocator, 4096, null, @alignOf(u8), 0) catch return .{ .is_vm = false, .hv = "none" };
        defer std.heap.page_allocator.free(content);
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "hypervisor")) {
                return .{ .is_vm = true, .hv = "hypervisor detected" };
            }
        }
    }
    return .{ .is_vm = false, .hv = "none" };
}

// ═══════════════════════════════════════════════════════════════
//  macOS  sysctl  helpers
// ═══════════════════════════════════════════════════════════════

fn getCoresSysctl(sysctl_name: []const u8) u32 {
    comptime if (builtin.os.tag == .macos) {
        var count: u32 = 0;
        var size: usize = @sizeOf(u32);
        var name_buf: [32]u8 = undefined;
        const n = @min(sysctl_name.len, name_buf.len - 1);
        @memcpy(name_buf[0..n], sysctl_name[0..n]);
        name_buf[n] = 0;
        const rc = std.c.sysctlbyname(
            @as([*:0]const u8, @ptrCast(&name_buf)),
            @as(?*anyopaque, @ptrCast(&count)),
            &size,
            null,
            0,
        );
        if (rc == 0) return count;
    };
    return 0;
}

// ═══════════════════════════════════════════════════════════════
//  Windows  helpers
// ═══════════════════════════════════════════════════════════════

const win32 = struct {
    const HANDLE = *anyopaque;
    const SYSTEM_INFO = extern struct {
        wProcessorArchitecture: u16,
        wReserved: u16,
        dwPageSize: u32,
        lpMinimumApplicationAddress: *anyopaque,
        lpMaximumApplicationAddress: *anyopaque,
        dwActiveProcessorMask: usize,
        dwNumberOfProcessors: u32,
        dwProcessorType: u32,
        dwAllocationGranularity: u32,
        wProcessorLevel: u16,
        wProcessorRevision: u16,
    };
    const CACHE_DESCRIPTOR = extern struct {
        Level: u8,
        Associativity: u8,
        LineSize: u16,
        Size: u32,
        Type: u32,
    };
    const SLPI = extern struct {
        Relationship: u32,
        _pad: u32,
        u: extern union {
            ProcessorCore: extern struct { Flags: u8 },
            NumaNode: u32,
            Cache: CACHE_DESCRIPTOR,
            Reserved: [2]u64,
        },
    };
    extern "kernel32" fn GetSystemInfo(lpSystemInfo: *SYSTEM_INFO) callconv(.c) void;
    extern "kernel32" fn SetThreadAffinityMask(hThread: HANDLE, dwThreadAffinityMask: usize) callconv(.c) usize;
    extern "kernel32" fn GetCurrentThread() callconv(.c) HANDLE;
    extern "kernel32" fn GetLogicalProcessorInformation(buffer: ?*SLPI, returnedLength: *u32) callconv(.c) i32;
};

fn getCoresWindows() u32 {
    // Returns logical cores (same as dwNumberOfProcessors)
    comptime if (builtin.os.tag != .windows) return 0;
    var sys_info: win32.SYSTEM_INFO = undefined;
    win32.GetSystemInfo(&sys_info);
    return @intCast(sys_info.dwNumberOfProcessors);
}

fn getPhysicalCoresWindows() u32 {
    comptime if (builtin.os.tag != .windows) return 0;
    var buf_len: u32 = 0;
    _ = win32.GetLogicalProcessorInformation(null, &buf_len);
    if (buf_len == 0) return 0;

    const entry_size = @sizeOf(win32.SLPI);
    const entry_count = buf_len / @as(u32, @intCast(entry_size));
    if (entry_count > 256) return 0;

    var buf: [256]win32.SLPI = undefined;
    const rc = win32.GetLogicalProcessorInformation(@ptrCast(&buf), &buf_len);
    if (rc == 0) return 0;

    var phys: u32 = 0;
    for (buf[0..@intCast(entry_count)]) |entry| {
        if (entry.Relationship == 0) { // RelationProcessorCore
            phys += 1;
        }
    }
    return phys;
}

fn bindToCoreWindows(core: u32) bool {
    comptime if (builtin.os.tag != .windows) return false;

    const mask: usize = @as(usize, 1) << @as(u6, @intCast(core));
    return win32.SetThreadAffinityMask(win32.GetCurrentThread(), mask) != 0;
}

// ═══════════════════════════════════════════════════════════════
//  Linux  sysfs  helpers
// ═══════════════════════════════════════════════════════════════

/// Read a sysfs file via raw Linux syscall. Returns number of bytes read.
pub fn readSysFile(path: []const u8, buffer: []u8) usize {
    comptime if (builtin.os.tag == .linux) {
        const SYS = std.os.linux.SYS;
        var zpath: [256]u8 = undefined;
        const n = @min(path.len, zpath.len - 1);
        @memcpy(zpath[0..n], path[0..n]);
        zpath[n] = 0;

        const fd = std.os.linux.syscall3(SYS.open, @intFromPtr(&zpath), @as(usize, 0), @as(usize, 0));
        if (fd >> 63 != 0) return 0;

        const bytes_read = std.os.linux.syscall3(SYS.read, fd, @intFromPtr(buffer.ptr), buffer.len);
        _ = std.os.linux.syscall1(SYS.close, fd);

        if (bytes_read >> 63 != 0) return 0;
        return @as(usize, @intCast(bytes_read));
    };
    return 0;
}

fn countCoresFromSysfs(comptime package_file: []const u8, comptime core_file: []const u8) u32 {
    comptime if (builtin.os.tag == .linux) {
        _ = package_file;
        var buf: [128]u8 = undefined;
        var seen: u64 = 0;
        const root = "/sys/devices/system/cpu";

        for (0..128) |cpu| {
            var pb: [256]u8 = undefined;
            const core_path = std.fmt.bufPrint(pb[0..], "{s}/cpu{d}/topology/{s}", .{ root, cpu, core_file }) catch break;
            const n = readSysFile(core_path, &buf);
            if (n == 0) break;
            const trimmed = std.mem.trim(u8, buf[0..n], " \n\r\t");
            if (trimmed.len == 0) break;
            const id = std.fmt.parseInt(u32, trimmed, 10) catch continue;
            if (id < 64) seen |= @as(u64, 1) << @intCast(id);
        }
        return @intCast(@popCount(seen));
    };
    return 0;
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

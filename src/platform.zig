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
};

/// Fill a buffer with the CPU brand string. Returns the slice of buffer that contains the brand.
pub fn getCpuBrand(buffer: []u8) []u8 {
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
    // Find null terminator
    const end = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    var slice = buffer[0..end];
    while (slice.len > 0 and slice[slice.len - 1] == ' ') {
        slice = slice[0 .. slice.len - 1];
    }
    return slice;
}

pub fn getCpuVendor() []const u8 {
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

pub fn getInvariantTsc() bool {
    if (builtin.cpu.arch != .x86_64) return false;
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx)
        : [leaf] "{eax}" (0x80000007)
    );
    return (edx & (1 << 8)) != 0;
}

pub fn getVirtualization() struct { is_vm: bool, hv: []const u8 } {
    if (builtin.cpu.arch != .x86_64) return .{ .is_vm = false, .hv = "none" };
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx)
        : [leaf] "{eax}" (1)
    );
    const hv_present = (ecx & (1 << 31)) != 0;
    if (!hv_present) return .{ .is_vm = false, .hv = "none" };
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx)
        : [leaf] "{eax}" (0x40000000)
    );
    var sig: [12]u8 = undefined;
    @memcpy(sig[0..4], std.mem.asBytes(&ebx));
    @memcpy(sig[4..8], std.mem.asBytes(&ecx));
    @memcpy(sig[8..12], std.mem.asBytes(&edx));
    const end = std.mem.indexOfScalar(u8, &sig, 0) orelse 12;
    if (end >= 4 and std.mem.eql(u8, sig[0..4], "Micr")) return .{ .is_vm = true, .hv = "Hyper-V / WSL2" };
    if (end >= 4 and std.mem.eql(u8, sig[0..4], "KVMK")) return .{ .is_vm = true, .hv = "KVM" };
    return .{ .is_vm = true, .hv = "unknown" };
}

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

const std = @import("std");
const builtin = @import("builtin");

/// Comprehensive CPU info extracted from CPUID.
pub const CpuidInfo = struct {
    // ── CPU identification ──
    vendor: []const u8,
    brand: []const u8,
    family: u32,
    model: u32,
    stepping: u32,
    ext_family: u32,
    ext_model: u32,
    cpuid_level: u32,
    cpuid_ext_level: u32,
    codename: []const u8,
    technology_nm: u32,
    socket: []const u8,

    // ── Topology ──
    physical_cores: u32,
    logical_cores: u32,
    smt_supported: bool,

    // ── Cache (detailed) ──
    cache: [16]CacheEntry,
    cache_count: u32,

    // ── Features ──
    features: [16][]const u8,
    features_count: u32,

    // ── Frequency ──
    base_freq_mhz: u32,
    max_freq_mhz: u32,
    bus_freq_mhz: u32,
    tsc_hz: u64,

    // ── Turbo ──
    turbo_supported: bool,
    turbo_ratios: [32]u32,
    turbo_ratio_count: u32,
    max_non_turbo_ratio: u32,
};

pub const CacheEntry = struct {
    level: u32,
    cache_type: u32, // 1=data, 2=instruction, 3=unified
    size_kb: u32,
    associativity: u32,
    line_size: u32,
    instances: u32,
    shared_by: u32,
};

const FeatureBit = struct { name: []const u8, reg: u8, bit: u32 };

/// Basic CPUID read: returns (eax, ebx, ecx, edx).
fn cpuid(leaf: u32, subleaf: u32) struct { eax: u32, ebx: u32, ecx: u32, edx: u32 } {
    if (builtin.cpu.arch != .x86_64) unreachable;
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx)
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf)
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

/// Run a full CPUID scan and return comprehensive info.
pub fn collect(vendor: []const u8, brand: []const u8, phys_cores: u32, logi_cores: u32, raw_tsc_hz: u64) !CpuidInfo {
    if (builtin.cpu.arch != .x86_64) return error.UnsupportedArch;

    var info = CpuidInfo{
        .vendor = vendor,
        .brand = brand,
        .family = 0,
        .model = 0,
        .stepping = 0,
        .ext_family = 0,
        .ext_model = 0,
        .cpuid_level = 0,
        .cpuid_ext_level = 0,
        .codename = "Unknown",
        .technology_nm = 0,
        .socket = "Unknown",
        .physical_cores = phys_cores,
        .logical_cores = logi_cores,
        .smt_supported = logi_cores > phys_cores,
        .cache = undefined,
        .cache_count = 0,
        .features = undefined,
        .features_count = 0,
        .base_freq_mhz = 0,
        .max_freq_mhz = 0,
        .bus_freq_mhz = 0,
        .tsc_hz = raw_tsc_hz,
        .turbo_supported = false,
        .turbo_ratios = undefined,
        .turbo_ratio_count = 0,
        .max_non_turbo_ratio = 0,
    };
    @memset(&info.turbo_ratios, 0);

    // ── Leaf 0: Max standard level ──
    const l0 = cpuid(0, 0);
    info.cpuid_level = l0.eax;

    // ── Leaf 1: Family/Model/Stepping, features ──
    const l1 = cpuid(1, 0);
    info.family = (l1.eax >> 8) & 0xF;
    info.model = (l1.eax >> 4) & 0xF;
    info.stepping = l1.eax & 0xF;
    info.ext_family = (l1.eax >> 20) & 0xFF;
    info.ext_model = (l1.eax >> 16) & 0xF;
    if (info.family == 0xF) info.family += info.ext_family;
    if (info.family == 0x6 or info.family == 0xF) info.model |= info.ext_model << 4;

    info.smt_supported = (l1.edx & (1 << 28)) != 0;

    // ── Feature bits ──
    const feature_names = &[_]FeatureBit{
        .{ .name = "MMX", .reg = 'd', .bit = 23 },
        .{ .name = "SSE", .reg = 'd', .bit = 25 },
        .{ .name = "SSE2", .reg = 'd', .bit = 26 },
        .{ .name = "SSE3", .reg = 'c', .bit = 0 },
        .{ .name = "SSSE3", .reg = 'c', .bit = 9 },
        .{ .name = "SSE4.1", .reg = 'c', .bit = 19 },
        .{ .name = "SSE4.2", .reg = 'c', .bit = 20 },
        .{ .name = "EM64T", .reg = 'd', .bit = 29 },
        .{ .name = "AES", .reg = 'c', .bit = 25 },
        .{ .name = "AVX", .reg = 'c', .bit = 28 },
        .{ .name = "FMA3", .reg = 'c', .bit = 12 },
        .{ .name = "RDRAND", .reg = 'c', .bit = 30 },
        .{ .name = "BMI1", .reg = '7', .bit = 3 },
        .{ .name = "BMI2", .reg = '7', .bit = 8 },
        .{ .name = "AVX2", .reg = '7', .bit = 5 },
        .{ .name = "AVX512F", .reg = '7', .bit = 16 },
        .{ .name = "AVX512DQ", .reg = '7', .bit = 17 },
        .{ .name = "AVX512BW", .reg = '7', .bit = 30 },
        .{ .name = "AVX512VL", .reg = '7', .bit = 31 },
        .{ .name = "AVX512CD", .reg = '7', .bit = 28 },
        .{ .name = "AVX512VNNI", .reg = '7', .bit = 11 },
        .{ .name = "SHA", .reg = '7', .bit = 29 },
        .{ .name = "RDSEED", .reg = '7', .bit = 18 },
        .{ .name = "ADX", .reg = '7', .bit = 19 },
        .{ .name = "CLFLUSHOPT", .reg = '7', .bit = 23 },
        .{ .name = "MOVBE", .reg = 'c', .bit = 22 },
        .{ .name = "POPCNT", .reg = 'c', .bit = 23 },
        .{ .name = "F16C", .reg = 'c', .bit = 29 },
        .{ .name = "CX8", .reg = 'd', .bit = 8 },
        .{ .name = "CX16", .reg = 'c', .bit = 13 },
        .{ .name = "FSGSBASE", .reg = '7', .bit = 0 },
        .{ .name = "RDTSCP", .reg = 'x', .bit = 27 },
    };

    var ecx7_0: u32 = 0;
    var ebx7_0: u32 = 0;
    if (info.cpuid_level >= 7) {
        const l7 = cpuid(7, 0);
        ebx7_0 = l7.ebx;
        ecx7_0 = l7.ecx;
    }

    var edx_ext: u32 = 0;
    if (info.cpuid_ext_level >= 0x80000001) {
        const lext = cpuid(0x80000001, 0);
        edx_ext = lext.edx;
    }

    info.features_count = 0;
    for (feature_names) |feat| {
        const val = switch (feat.reg) {
            'c' => l1.ecx,
            'd' => l1.edx,
            '7' => ebx7_0,
            '8' => ecx7_0,
            'x' => edx_ext,
            else => @as(u32, 0),
        };
        if ((val >> @as(u5, @intCast(feat.bit))) & 1 != 0) {
            if (info.features_count < info.features.len) {
                info.features[info.features_count] = feat.name;
                info.features_count += 1;
            }
        }
    }

    // ── Leaf 0x80000000: Extended CPUID level ──
    const lext0 = cpuid(0x80000000, 0);
    info.cpuid_ext_level = lext0.eax;

    // ── Cache topology from leaf 0x4 ──
    var subleaf: u32 = 0;
    while (subleaf < 16) : (subleaf += 1) {
        const l4 = cpuid(4, subleaf);
        const cache_type: u32 = l4.eax & 0x1F;
        if (cache_type == 0) break;

        const level: u32 = (l4.eax >> 5) & 0x7;
        const max_sharing: u32 = ((l4.eax >> 14) & 0xFFF) + 1;
        const line_size: u32 = (l4.ebx & 0xFFF) + 1;
        const partitions: u32 = ((l4.ebx >> 12) & 0x3FF) + 1;
        const ways: u32 = ((l4.ebx >> 22) & 0x3FF) + 1;
        const sets: u32 = l4.ecx + 1;
        const size_kb: u32 = (ways * partitions * line_size * sets) / 1024;
        const instances: u32 = logi_cores / max_sharing;

        if (info.cache_count < 16) {
            info.cache[info.cache_count] = CacheEntry{
                .level = level,
                .cache_type = cache_type,
                .size_kb = size_kb,
                .associativity = ways,
                .line_size = line_size,
                .instances = if (level < 3) instances else 1,
                .shared_by = max_sharing,
            };
            info.cache_count += 1;
        }
    }

    // ── Frequency ──
    if (info.cpuid_level >= 0x16) {
        const l16 = cpuid(0x16, 0);
        info.base_freq_mhz = l16.eax & 0xFFFF;
        info.max_freq_mhz = l16.ebx & 0xFFFF;
        info.bus_freq_mhz = l16.ecx & 0xFFFF;
    }
    if (info.bus_freq_mhz == 0 and info.cpuid_level >= 0x15) {
        const l15 = cpuid(0x15, 0);
        info.bus_freq_mhz = l15.ecx & 0xFFFF;
    }
    if (info.bus_freq_mhz == 0 and raw_tsc_hz > 0) {
        info.bus_freq_mhz = @as(u32, @intCast(raw_tsc_hz / 100_000_000));
    }

    // ── Lookup codename ──
    const id = cpuidLookup(info.family, info.ext_model, info.model);
    info.codename = id.codename;
    info.technology_nm = id.tech_nm;
    info.socket = id.socket;

    return info;
}

fn readTurboRatiosMSR(info: *CpuidInfo) !void {
    _ = info;
    // MSR read requires ring0 access. No-op for now.
}

/// Lookup table for Intel/AMD CPU codenames by Family/Model.
const CpuIdEntry = struct { family: u32, model: u32, codename: []const u8, tech_nm: u32, socket: []const u8 };

const intel_table = &[_]CpuIdEntry{
    .{ .family = 6, .model = 0x3C, .codename = "Haswell", .tech_nm = 22, .socket = "Socket 1150 LGA" },
    .{ .family = 6, .model = 0x3F, .codename = "Haswell-E", .tech_nm = 22, .socket = "Socket 2011-3 LGA" },
    .{ .family = 6, .model = 0x45, .codename = "Haswell-ULT", .tech_nm = 22, .socket = "Socket 1168 BGA" },
    .{ .family = 6, .model = 0x46, .codename = "Haswell", .tech_nm = 22, .socket = "Socket 1150 LGA" },
    .{ .family = 6, .model = 0x3D, .codename = "Broadwell", .tech_nm = 14, .socket = "Socket 1150 LGA" },
    .{ .family = 6, .model = 0x47, .codename = "Broadwell", .tech_nm = 14, .socket = "Socket 1150 LGA" },
    .{ .family = 6, .model = 0x4F, .codename = "Broadwell-E", .tech_nm = 14, .socket = "Socket 2011-3 LGA" },
    .{ .family = 6, .model = 0x56, .codename = "Broadwell-DE", .tech_nm = 14, .socket = "Socket 1667 BGA" },
    .{ .family = 6, .model = 0x4E, .codename = "Skylake-S", .tech_nm = 14, .socket = "Socket 1151 LGA" },
    .{ .family = 6, .model = 0x5E, .codename = "Skylake-H", .tech_nm = 14, .socket = "Socket 1440 BGA" },
    .{ .family = 6, .model = 0x55, .codename = "Cascade Lake-W", .tech_nm = 14, .socket = "Socket 2066 LGA" },
    .{ .family = 6, .model = 0x8E, .codename = "Kaby Lake", .tech_nm = 14, .socket = "Socket 1151 LGA" },
    .{ .family = 6, .model = 0x9E, .codename = "Kaby Lake-H", .tech_nm = 14, .socket = "Socket 1440 BGA" },
    .{ .family = 6, .model = 0xA5, .codename = "Comet Lake-S", .tech_nm = 14, .socket = "Socket 1200 LGA" },
    .{ .family = 6, .model = 0xA6, .codename = "Comet Lake", .tech_nm = 14, .socket = "Socket 1200 LGA" },
    .{ .family = 6, .model = 0x7D, .codename = "Ice Lake", .tech_nm = 10, .socket = "Socket 1526 BGA" },
    .{ .family = 6, .model = 0x7E, .codename = "Ice Lake", .tech_nm = 10, .socket = "Socket 1526 BGA" },
    .{ .family = 6, .model = 0xA7, .codename = "Rocket Lake-S", .tech_nm = 14, .socket = "Socket 1200 LGA" },
    .{ .family = 6, .model = 0x8C, .codename = "Tiger Lake", .tech_nm = 10, .socket = "Socket 1449 BGA" },
    .{ .family = 6, .model = 0x8D, .codename = "Tiger Lake-H", .tech_nm = 10, .socket = "Socket 1787 BGA" },
    .{ .family = 6, .model = 0x97, .codename = "Alder Lake-S", .tech_nm = 10, .socket = "Socket 1700 LGA" },
    .{ .family = 6, .model = 0x9A, .codename = "Alder Lake-P", .tech_nm = 10, .socket = "Socket 1744 BGA" },
    .{ .family = 6, .model = 0xB7, .codename = "Raptor Lake-S", .tech_nm = 10, .socket = "Socket 1700 LGA" },
    .{ .family = 6, .model = 0xBA, .codename = "Raptor Lake-P", .tech_nm = 10, .socket = "Socket 1744 BGA" },
    .{ .family = 6, .model = 0xBF, .codename = "Raptor Lake-HX", .tech_nm = 10, .socket = "Socket 1792 BGA" },
    .{ .family = 6, .model = 0xAA, .codename = "Meteor Lake", .tech_nm = 7, .socket = "Socket 2049 BGA" },
    .{ .family = 6, .model = 0xAC, .codename = "Meteor Lake", .tech_nm = 7, .socket = "Socket 2049 BGA" },
    .{ .family = 6, .model = 0xAD, .codename = "Arrow Lake-S", .tech_nm = 3, .socket = "Socket 1851 LGA" },
    .{ .family = 6, .model = 0xC6, .codename = "Lunar Lake", .tech_nm = 3, .socket = "Socket 2830 BGA" },
};

const amd_table = &[_]CpuIdEntry{
    .{ .family = 0x17, .model = 0x01, .codename = "Zen (Summit Ridge)", .tech_nm = 14, .socket = "Socket AM4" },
    .{ .family = 0x17, .model = 0x08, .codename = "Zen+ (Pinnacle Ridge)", .tech_nm = 12, .socket = "Socket AM4" },
    .{ .family = 0x17, .model = 0x11, .codename = "Zen (Raven Ridge)", .tech_nm = 14, .socket = "Socket AM4" },
    .{ .family = 0x17, .model = 0x18, .codename = "Zen+ (Picasso)", .tech_nm = 12, .socket = "Socket AM4" },
    .{ .family = 0x17, .model = 0x31, .codename = "Zen 2 (Matisse)", .tech_nm = 7, .socket = "Socket AM4" },
    .{ .family = 0x17, .model = 0x60, .codename = "Zen 2 (Renoir)", .tech_nm = 7, .socket = "Socket AM4" },
    .{ .family = 0x17, .model = 0x71, .codename = "Zen 2 (Matisse)", .tech_nm = 7, .socket = "Socket AM4" },
    .{ .family = 0x19, .model = 0x01, .codename = "Zen 3 (Vermeer)", .tech_nm = 7, .socket = "Socket AM4" },
    .{ .family = 0x19, .model = 0x21, .codename = "Zen 3 (Vermeer)", .tech_nm = 7, .socket = "Socket AM4" },
    .{ .family = 0x19, .model = 0x50, .codename = "Zen 3 (Cezanne)", .tech_nm = 7, .socket = "Socket AM4" },
    .{ .family = 0x19, .model = 0x61, .codename = "Zen 4 (Raphael)", .tech_nm = 5, .socket = "Socket AM5" },
    .{ .family = 0x19, .model = 0x70, .codename = "Zen 4 (Phoenix)", .tech_nm = 4, .socket = "Socket FP8" },
    .{ .family = 0x1A, .model = 0x40, .codename = "Zen 5 (Granite Ridge)", .tech_nm = 4, .socket = "Socket AM5" },
};

fn cpuidLookup(family: u32, ext_model: u32, model: u32) CpuIdEntry {
    _ = ext_model;
    const table: []const CpuIdEntry = if (family == 6) intel_table else if (family == 0x17 or family == 0x19 or family == 0x1A) amd_table else &.{};
    for (table) |entry| {
        if (entry.family == family and entry.model == model) return entry;
    }
    if (family == 6) return .{ .family = family, .model = model, .codename = "Intel Core (unknown gen)", .tech_nm = 0, .socket = "Unknown" };
    if (family == 0x17 or family == 0x19 or family == 0x1A) return .{ .family = family, .model = model, .codename = "AMD Ryzen (unknown gen)", .tech_nm = 0, .socket = "Unknown" };
    return .{ .family = family, .model = model, .codename = "Unknown", .tech_nm = 0, .socket = "Unknown" };
}

# CPU-Z Field Mapping: Data Sources & Zig Obtainability

Each CPU-Z field mapped to its source, with Zig implementation notes.

Legend:
- ✅ = Obtainable in Zig user-mode (CPUID or OS API)
- 🔶 = Needs kernel driver/ring0 on Windows (MSR, PCI, SMBus)
- ❌ = Needs external tools or cannot be done in pure Zig

---

## 1. APICs / Core Topology

| CPU-Z Field | Source | Zig | Notes |
|---|---|---|---|
| Socket 0, Core N (ID X), Thread M (APIC Y) | CPUID leaf 0xB (Extended Topology Enumeration) | ✅ | Subleaf iteration: ECX[15:8]=level type (0=SMT, 1=Core); EBX[15:0]=logical processors at this level; EDX=APIC ID |
| Number of sockets | CPUID leaf 0xB or OS API | ✅ | Leaf 0xB stack gives package-level count; Windows: `GetLogicalProcessorInformation` |
| Number of threads | CPUID leaf 1 EBX[23:16] or leaf 0xB | ✅ | Leaf 1 EBX gives logical count per package; leaf 0xB for precise enumeration |
| CPU Groups | Windows API `GetActiveProcessorCount` | ✅ | Windows kernel32 FFI |

## 2. Timers

| CPU-Z Field | Source | Zig | Notes |
|---|---|---|---|
| ACPI timer | ACPI PM Timer (I/O port) | 🔶 | I/O port access needs kernel driver on Windows; Linux: `/sys/devices/system/cpu/cpu0/acpi_cppc` |
| Perf timer | QPC/Hpet TSC | ✅ | TSC frequency from our calibration; HPET: ACPI table parse |
| Sys timer | Windows kernel timer resolution | 🔶 | `NtQueryTimerResolution` (undocumented NT API) |

## 3. Processor Identification

| CPU-Z Field | Source | Zig | Notes |
|---|---|---|---|
| Manufacturer | CPUID leaf 0 (EBX,EDX,ECX) | ✅ | Already implemented in `platform.zig` |
| Name | CPUID leaf 0x80000002-4 (brand string) | ✅ | Already implemented |
| Codename | Lookup table: Family + Model + Stepping | ✅ | Already implemented in `cpuid_info.zig` |
| Specification | Same as brand string | ✅ | Already available |
| Package (platform ID) | CPUID leaf 1 EBX[15:8] = platform ID | ✅ | Also lookup table for socket name |
| CPUID | Family.Model.Stepping from leaf 1 EAX | ✅ | Already implemented |
| Extended CPUID | Extended family/model from CPUID 0x80000001 | ✅ | Already implemented |
| Core Stepping | Stepping + revision from CPUID | ✅ | Leaf 1 EAX[3:0]=stepping; Intel ARK lookup for stepping name (B1, L1 etc.) |
| Technology | Lookup table by Family/Model | ✅ | Already implemented; enhanced table could use `intel_ark.json` |
| TDP Limit | MSR 0x610 (PKG_POWER_LIMIT) bits [14:0] | 🔶 | MSR read needs ring0; value is in 1/8 W units |
| Tjmax | MSR 0x1A2 (TEMPERATURE_TARGET) bits [23:16] | 🔶 | Or CPUID leaf 6 EAX bits [23:16] on some CPUs |
| Core Speed (real-time) | MSR 0x198 (PERF_STATUS) = current ratio | 🔶 | Or calculate from APERF/MPERF (MSR 0xE7/0xE8) |
| Multiplier x Bus Speed | current_ratio × BCLK | 🔶 | BCLK = TSC_freq / max_non_turbo_ratio |
| Base frequency (BCLK) | TSC frequency ÷ max non-turbo ratio | ✅ | TSC frequency from calibration; ratio from MSR 0xCE bits 15:8 |
| Stock frequency | CPUID leaf 0x16 EAX (base MHz) | ✅ | If 0x16 returns 0, use TSC calibration ÷ max_non_turbo |

## 4. Instruction Sets (Features)

| CPU-Z Field | Source | Zig | Notes |
|---|---|---|---|
| MMX | CPUID leaf 1 EDX[23] | ✅ | Already implemented |
| SSE, SSE2 | CPUID leaf 1 EDX[25,26] | ✅ | Already implemented |
| SSE3, SSSE3 | CPUID leaf 1 ECX[0,9] | ✅ | Already implemented |
| SSE4.1, SSE4.2 | CPUID leaf 1 ECX[19,20] | ✅ | Already implemented |
| EM64T | CPUID leaf 0x80000001 EDX[29] | ✅ | Need to implement |
| AES | CPUID leaf 1 ECX[25] | ✅ | Already implemented |
| AVX | CPUID leaf 1 ECX[28] | ✅ | Already implemented |
| AVX2 | CPUID leaf 7.0 EBX[5] | ✅ | Already implemented |
| AVX512F | CPUID leaf 7.0 EBX[16] | ✅ | Already implemented |
| AVX512DQ | CPUID leaf 7.0 EBX[17] | ✅ | Already implemented |
| AVX512BW | CPUID leaf 7.0 EBX[30] | ✅ | Already implemented |
| AVX512VL | CPUID leaf 7.0 EBX[31] | ✅ | Already implemented |
| AVX512CD | CPUID leaf 7.0 EBX[28] | ✅ | Already implemented |
| AVX512VNNI | CPUID leaf 7.0 ECX[11] | ✅ | Note: ECX not EBX — need to fix in cpuid_info.zig |
| FMA3 | CPUID leaf 1 ECX[12] | ✅ | Already implemented |
| AVX512-IFMA (missing) | CPUID leaf 7.0 EBX[21] | ✅ | Not yet listed in feature table |
| AVX512-VBMI (missing) | CPUID leaf 7.0 ECX[1] | ✅ | Not yet listed |
| AVX512-VBMI2 (missing) | CPUID leaf 7.0 ECX[6] | ✅ | Not yet listed |
| AVX512-VPOPCNTDQ (missing) | CPUID leaf 7.0 ECX[14] | ✅ | Not yet listed |
| AVX512-BITALG (missing) | CPUID leaf 7.0 ECX[12] | ✅ | Not yet listed |
| AVX512-BF16 (missing) | CPUID leaf 7.1 EAX[5] | ✅ | Need leaf 7 subleaf 1 |
| AVX512-FP16 (missing) | CPUID leaf 7.0 EDX[23] | ✅ | Not yet listed |
| TSX (missing) | CPUID leaf 7.0 EBX[11] | ✅ | Not yet listed |
| SGX (missing) | CPUID leaf 7.0 EBX[2] | ✅ | Not yet listed |
| CLWB (missing) | CPUID leaf 7.0 EBX[24] | ✅ | Not yet listed |
| PKU (missing) | CPUID leaf 7.0 ECX[3] | ✅ | Not yet listed |
| WAITPKG (missing) | CPUID leaf 7.0 ECX[5] | ✅ | Not yet listed |

**Comprehensive feature detection needs CPUID leaves:** 1(ECX,EDX), 7.0(EBX,ECX,EDX), 7.1(EAX), 0x80000001(ECX,EDX)

## 5. Cache Details

| CPU-Z Field | Source | Zig | Notes |
|---|---|---|---|
| L1 Data cache | CPUID leaf 4 | ✅ | Already implemented. Fixed: `instances = logi / max_sharing` for L1d |
| L1 Instruction cache | CPUID leaf 4 | ✅ | Already implemented |
| L2 cache | CPUID leaf 4 | ✅ | Already implemented |
| L3 cache | CPUID leaf 4 | ✅ | Already implemented |
| Cache line size | CPUID leaf 1 EBX[15:8] = CLFLUSH size (×8) | ✅ | Or from leaf 4 directly |

## 6. Microcode Revision

| CPU-Z Field | Source | Zig | Notes |
|---|---|---|---|
| Microcode Revision | MSR 0x8B (IA32_BIOS_UPDT_TRIG) | 🔶 | EDX:EAX = microcode revision. Needs ring0. Linux: `grep microcode /proc/cpuinfo` |

## 7. Turbo & Frequency Ratios

| CPU-Z Field | Source | Zig | Notes |
|---|---|---|---|
| Turbo Mode (supported, enabled) | MSR 0x1A0 bits [38,32] | 🔶 | IA32_MISC_ENABLE |
| Max non-turbo ratio | MSR 0xCE bits [15:8] | 🔶 | PLATFORM_INFO. Or CPUID leaf 0x16 ÷ BCLK |
| Max turbo ratio | MSR 0x1AD max value | 🔶 | TURBO_RATIO_LIMIT; max of all per-core values |
| Max efficiency ratio | MSR 0xCE bits [47:40] | 🔶 | Or from MSR 0x774 |
| Min operating ratio | MSR 0xCE bits [55:48] | 🔶 | PLATFORM_INFO |
| Ratio X cores | MSR 0x1AD (ratios for 1/2/3/4/... core active) | 🔶 | TURBO_RATIO_LIMIT1 (0x1AD) and LIMIT2 (0x1AE) |
| Core N max ratio | MSR 0x1AD per-core fields | 🔶 | Same as above, disassembled per-core |
| O/C bins | MSR 0x194 bits [63] | 🔶 | OVERCLOCKING_STATUS |

## 8. Power Limits (Package Power)

| CPU-Z Field | Source | Zig | Notes |
|---|---|---|---|
| Max Power | MSR 0x610 bits [46:32] (Max time window power) | 🔶 | PKG_POWER_LIMIT |
| Min Power | MSR 0x610 bits [30:16] (Min power) | 🔶 | PKG_POWER_LIMIT |
| Power Max (PL1) | MSR 0x610 bits [14:0] ÷ 8 | 🔶 | Units of 1/8 W |
| Short Power Max (PL2) | MSR 0x610 bits [46:32] ÷ 8 | 🔶 | PKG_POWER_LIMIT |
| Max Peak Power (PL4) | MSR 0x64E or MSR 0x601 | 🔶 | PP0_POWER_LIMIT / PKG_POWER_LIMIT |
| PL1 Time Window | MSR 0x610 bits [23:17] | 🔶 | In seconds (2^Y × Z / 4) |
| TDP Level | Multiple MSRs | 🔶 | MSR_CONFIG_TDP_NOMINAL/LEVEL1/LEVEL2 |
| Speedshift | MSR 0x770 (IA32_PM_ENABLE) bit 0 | 🔶 | 1=HWP enabled (Speedshift Autonomous) |

## 9. Temperatures & Voltages

| CPU-Z Field | Source | Zig | Notes |
|---|---|---|---|
| Package temperature | MSR 0x1B1 bits [22:16] | 🔶 | IA32_PACKAGE_THERM_STATUS; formula: Tjmax - (val >> 16) |
| Core N temperature | MSR 0x19C bits [22:16] per core | 🔶 | IA32_THERM_STATUS; same formula |
| VID Voltage | MSR 0x198 bits [47:32] or MSR 0x1B1 | 🔶 | IA32_PERF_STATUS; VID-to-voltage conversion |
| IA/GT/Ring/Agent Offset | MSR 0x150 (IA), 0x151 (GT), 0x152 (Ring) | 🔶 | VR voltage offsets |

## 10. Real-time Clock Speeds

| CPU-Z Field | Source | Zig | Notes |
|---|---|---|---|
| Core N clock speed | MSR 0x198 PERF_STATUS × BCLK | 🔶 | Or via APERF/MPERF ratio: (APERF_delta/MPERF_delta) × base_freq |
| CPU BCLK | MSR 0xCE ÷ TSC calibration | 🔶 | BCLK = TSC_freq / (MSR 0xCE bits 15:8) |
| LLC/Ring clock | MSR 0x620 × BCLK | 🔶 | MSR_RING_PERF_STATUS |
| Memory clock | SMBus or SPD read | 🔶 | Needs SMBus access on Windows (kernel driver) |

## 11. Real-time Power

| CPU-Z Field | Source | Zig | Notes |
|---|---|---|---|
| Package power | MSR 0x611 (PKG_ENERGY_STATUS) | 🔶 | Δ ÷ energy_unit; energy_unit = MSR 0x606 bits [12:8] |
| IA Cores power | MSR 0x639 (PP0_ENERGY_STATUS) | 🔶 | Same calculation |
| DRAM power | MSR 0x619 (DRAM_ENERGY_STATUS) | 🔶 | Same calculation |

## 12. Thread Dumps (Per-Thread CPUID)

| CPU-Z Field | Source | Zig | Notes |
|---|---|---|---|
| APIC ID | CPUID leaf 1 EBX[31:24] or leaf 0xB EDX | ✅ | Leaf 0xB is more accurate |
| Topology (Processor/Core/Thread ID) | CPUID leaf 0xB enumeration | ✅ | Subleaf iteration with level type |
| Max Multiplier | MSR 0xCE bits [15:8] | 🔶 | Same for all threads |
| Max Turbo Multiplier | MSR 0x1AD per-core max value | 🔶 | Per-core turbo ratios |
| Cache descriptors per thread | CPUID leaf 4 | ✅ | Standard deterministic cache enumeration |
| Per-thread CPUID dump (all leaves) | CPUID leaves 0..max_leaf | ✅ | Just iterate all leaves; print raw hex |

## 13. DMI / Chipset / Memory / SPD

| CPU-Z Field | Source | Zig | Notes |
|---|---|---|---|
| Chipset vendor/model | PCI config space (bus 0, dev 0, func 0) | 🔶 | Needs PCI config space access; Windows: kernel driver or SetupAPI |
| Memory type/size/channels | SMBIOS Type 17 or SPD via SMBus | 🔶 | Windows: WMI `Win32_PhysicalMemory`; requires COM or kernel driver |
| Memory timings (CL,RCD,RP,RAS) | SPD EEPROM via SMBus | 🔶 | I2C/SMBus device access; needs kernel driver on Windows |
| DRAM frequency | Memory controller registers or SPD | 🔶 | MSR 0xC1/C2 (IMC) on Intel; AMD: SMU |
| Graphics card info | PCI config space, GPU registers | ❌ | GPU registers need vendor-specific drivers |

## 14. Preferred Cores

| CPU-Z Field | Source | Zig | Notes |
|---|---|---|---|
| Preferred cores | MSR 0x1AD + MSR 0x1AE (turbo ratio per core) | 🔶 | Highest turbo ratio cores = preferred cores; also CPUID leaf 0x1A |

---

## Summary: Zig Obtainability Matrix

### ✅ User-mode (CPUID-based) — Already or Easily Implemented
- All CPUID leaves (0, 1, 4, 7, 0xB, 0x15, 0x16, 0x80000000-8)
- Brand string, vendor, family/model/stepping
- All feature flags (SSE, AVX, AVX-512, etc.)
- Cache topology (size, associativity, line size, sharing)
- Core/socket topology (APIC IDs, SMT layout)
- TSC frequency (our calibration)
- Codename lookup, technology node, socket type

### 🔶 MSR-based — Needs Kernel Driver on Windows
- **Linux**: `/dev/cpu/*/msr` (can `open` and `pread` in Zig)
- **Windows**: Needs WinRing0.sys, RTCore64.sys, or `\\.\PhysicalDrive` trick (admin)
- **macOS**: Needs KEXT (difficult)

MSR-based info:
- Turbo ratios (0x1AD, 0x1AE) — **most valuable missing piece**
- Power limits (0x610) — important for TDP
- Temperatures (0x19C, 0x1B1) — real-time monitoring
- Voltages (0x198, 0x150) — real-time monitoring
- Clock speeds (0x198, 0x620) — real-time per-core freq
- Package power (0x611) — energy monitoring
- Microcode revision (0x8B)
- Speedshift status (0x770)

### 🔶 PCI/SMBus — Needs Kernel Driver
- Chipset info (PCI config space)
- Memory SPD/timings (SMBus)
- DRAM frequency (IMC registers)

### ❌ External Tools Required
- GPU info (needs vendor-specific access)
- Motherboard sensors (SuperIO chip, needs I/O port access)

---

## How to Read MSRs from Zig on Windows

The `tau_profiler` engine runs in user mode. To read MSRs on Windows:

**Option A: Use the existing `\\.\Msr` device (needs driver)**
- Load `RTCore64.sys` driver (from RWEverything project, open-source)
- `CreateFile("\\.\RTCore64", ...)` → `DeviceIoControl`
- Or use `WinRing0.sys`

**Option B: Linux `/dev/cpu/N/msr` (native)**
- `open("/dev/cpu/0/msr", .{})` → `pread(fd, buf, msr_addr)`
- Needs `sudo modprobe msr`

**Option C: Add a `--driver` mode**
- Build `tau_profiler` as a Windows kernel driver (complex)

**Recommendation**: For Linux, add MSR reading directly (just `open("/dev/cpu/0/msr")`). For Windows, the user can install a third-party MSR driver and we can provide a separate tool that uses it.

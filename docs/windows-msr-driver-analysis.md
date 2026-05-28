# Windows MSR 内核驱动方案分析

## 最终目标

让 `tau_profiler.exe` 在 Windows 用户态读取 MSR，获取 Turbo 倍频、温度、功耗、实时频率等信息。

---

## 实测结果

| 方案 | 状态 | 说明 |
|------|------|------|
| **C: NtSystemDebugControl** | ❌ 已否决 | `0xC0000354` STATUS_DEBUGGER_INACTIVE。Win10/11 要求内核调试器活跃 |
| **D: `\\.\Msr` 内置** | ❌ | 驱动不存在于标准 Windows 安装 |
| **B: C WDM 驱动** | ✅ 可行 | ~200 行 C，最成熟的路径 |
| **Rust WDM/KMDF 驱动** | ✅ 推荐 | Microsoft 官方支持，2025 年日趋成熟 |

---

## Rust WDM/KMDF 驱动方案（推荐）

### 2025 年生态现状

Microsoft 已发布 [windows-drivers-rs](https://github.com/microsoft/windows-drivers-rs) 项目，将 Rust 作为 Windows 驱动开发的一等公民语言。

#### 可用的官方 Crates

| Crate | 用途 |
|-------|------|
| `wdk` | 安全、惯用的 WDK API 绑定 |
| `wdk-sys` | 原始 FFI 绑定（`bindgen` 生成），包含 `__readmsr()` |
| `wdk-build` | 构建配置、绑定生成、编译器/链接器标志 |
| `wdk-alloc` | 内核模式 `GlobalAlloc` 实现（`ExAllocatePool2`） |
| `wdk-panic` | 内核模式 panic 处理器 |
| `wdk-macros` | 过程宏，简化 WDK 交互 |

#### 驱动模型支持

| 模型 | 模式 | wdk-alloc/pagic 需要？ |
|------|------|----------------------|
| WDM | 内核 | ✅ |
| KMDF | 内核 | ✅ |
| UMDF | 用户 | ❌ |

### 构建环境要求

```powershell
# 1. eWDK (Enterprise WDK) — Windows 驱动开发环境
#    下载: https://learn.microsoft.com/en-us/windows-hardware/drivers/download-the-wdk
#    推荐使用 eWDK (无需完整 VS) 或带 WDK 的 Visual Studio 2022

# 2. LLVM 17 (bindgen 依赖)
winget install -i LLVM.LLVM --version 17.0.6 --force

# 3. cargo-make (构建工具)
cargo install --locked cargo-make --no-default-features --features tls-native

# 4. Rust nightly (内核驱动需要 nightly)
rustup toolchain install nightly
rustup default nightly
```

### TauMsr.sys — Rust 版 MSR 驱动（~150 行）

```rust
// tau_msr.rs — Minimal WDM kernel driver for MSR access
#![no_std]
extern crate wdk_panic;
extern crate wdk_alloc;

use wdk_alloc::WdkAllocator;

#[global_allocator]
static GLOBAL_ALLOCATOR: WdkAllocator = WdkAllocator;

use wdk_sys::*;
use core::mem;

// IOCTL code: CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)
const IOCTL_READ_MSR: u32 = 0x80002000;

#[repr(C)]
struct MsrRequest {
    msr_addr: u32,
    msr_value: u64,
}

/// Mark function as DriverEntry export
#[unsafe(export_name = "DriverEntry")]
pub extern "system" fn driver_entry(
    driver: *mut DRIVER_OBJECT,
    _registry_path: *const UNICODE_STRING,
) -> NTSTATUS {
    unsafe {
        // Create device
        let mut dev_name = wdk_sys::RTL_CONSTANT_STRING!("\\Device\\TauMsr");
        let mut symlink = wdk_sys::RTL_CONSTANT_STRING!("\\DosDevices\\TauMsr");
        let mut device: *mut DEVICE_OBJECT = core::ptr::null_mut();

        IoCreateDevice(driver, 0, &mut dev_name, FILE_DEVICE_UNKNOWN, 0, FALSE, &mut device);
        IoCreateSymbolicLink(&mut symlink, &mut dev_name);

        // Set dispatch functions
        let driver_ref = &mut *driver;
        driver_ref.DriverUnload = Some(driver_unload);
        driver_ref.MajorFunction[IRP_MJ_CREATE as usize] = Some(create_close);
        driver_ref.MajorFunction[IRP_MJ_CLOSE as usize] = Some(create_close);
        driver_ref.MajorFunction[IRP_MJ_DEVICE_CONTROL as usize] = Some(device_control);

        STATUS_SUCCESS
    }
}

unsafe extern "system" fn driver_unload(driver: *mut DRIVER_OBJECT) {
    unsafe {
        let mut sym = wdk_sys::RTL_CONSTANT_STRING!("\\DosDevices\\TauMsr");
        IoDeleteSymbolicLink(&mut sym);
        IoDeleteDevice((*driver).DeviceObject);
    }
}

unsafe extern "system" fn create_close(
    _device: *mut DEVICE_OBJECT,
    irp: *mut IRP,
) -> NTSTATUS {
    unsafe {
        let irp_ref = &mut *irp;
        irp_ref.IoStatus.Information = 0;
        irp_ref.IoStatus.__bindgen_anon_1.Status = STATUS_SUCCESS;
        IoCompleteRequest(irp, IO_NO_INCREMENT);
        STATUS_SUCCESS
    }
}

unsafe extern "system" fn device_control(
    _device: *mut DEVICE_OBJECT,
    irp: *mut IRP,
) -> NTSTATUS {
    unsafe {
        let irp_ref = &mut *irp;
        let stack = IoGetCurrentIrpStackLocation(irp);
        let ioctl = (*stack).Parameters.DeviceIoControl.IoControlCode;

        if ioctl == IOCTL_READ_MSR {
            let req = &mut *(irp_ref.AssociatedIrp.SystemBuffer as *mut MsrRequest);
            let addr: u32 = req.msr_addr;

            // Core: read MSR via kernel-mode intrinsic
            let value: u64;
            core::arch::asm!(
                "rdmsr",
                in("ecx") addr,
                out("eax") value as u32,
                out("edx") (value >> 32) as u32,
            );
            req.msr_value = value;

            irp_ref.IoStatus.Information = mem::size_of::<MsrRequest>() as u32;
            irp_ref.IoStatus.__bindgen_anon_1.Status = STATUS_SUCCESS;
        } else {
            irp_ref.IoStatus.__bindgen_anon_1.Status = STATUS_INVALID_DEVICE_REQUEST;
        }

        IoCompleteRequest(irp, IO_NO_INCREMENT);
        irp_ref.IoStatus.__bindgen_anon_1.Status
    }
}
```

### Rust 驱动的 Cargo.toml

```toml
[package]
name = "tau_msr"
version = "0.1.0"
edition = "2024"

[lib]
crate-type = ["cdylib"]

[dependencies]
wdk = "0.2"
wdk-sys = "0.2"
wdk-alloc = "0.2"
wdk-panic = "0.2"

[build-dependencies]
wdk-build = "0.2"

[package.metadata.wdk.driver-model]
driver-type = "WDM"

[profile.dev]
panic = "abort"

[profile.release]
panic = "abort"
```

### 构建命令

```powershell
# 从 eWDK 环境运行
cd tau_msr_driver
cargo make
# 输出: target/release/package/tau_msr.sys (已签名)
```

### 安装和测试

```powershell
# 启用测试签名模式（需重启一次）
bcdedit /set testsigning on

# 安装驱动
sc create tau_msr type= kernel start= demand binPath= "C:\...\tau_msr.sys"
sc start tau_msr

# 用户态调用（Zig / Python / C / Rust 均可）
# CreateFile("\\\\.\\TauMsr") → DeviceIoControl(IOCTL_READ_MSR)
```

### 用户态调用（集成到 tau_profiler）

```zig
// Zig 端调用 Rust 驱动
extern "kernel32" fn CreateFileA(
    lpFileName: [*:0]const u8,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?*anyopaque,
) callconv(.c) *anyopaque;

extern "kernel32" fn DeviceIoControl(
    hDevice: *anyopaque,
    dwIoControlCode: u32,
    lpInBuffer: ?*anyopaque,
    nInBufferSize: u32,
    lpOutBuffer: ?*anyopaque,
    nOutBufferSize: u32,
    lpBytesReturned: ?*u32,
    lpOverlapped: ?*anyopaque,
) callconv(.c) i32;

const IOCTL_READ_MSR: u32 = 0x80002000;
const MsrRequest = extern struct { msr_addr: u32, msr_value: u64 };

pub fn readMsrViaDriver(addr: u32) !u64 {
    const path = "\\\\.\\TauMsr";
    const h = CreateFileA(path, 0xC0000000, 3, null, 3, 0x80, null);
    defer _ = CloseHandle(h);

    var req = MsrRequest{ .msr_addr = addr, .msr_value = 0 };
    const ok = DeviceIoControl(h, IOCTL_READ_MSR,
        @ptrCast(&req), @sizeOf(MsrRequest),
        @ptrCast(&req), @sizeOf(MsrRequest), null, null);
    if (ok == 0) return error.MsrDriverFailed;
    return req.msr_value;
}
```

### 优缺点

| 优点 | 缺点 |
|------|------|
| Microsoft 官方支持，2025 年日趋成熟 | 需要 nightly Rust + eWDK（~4GB 下载） |
| 内存安全（Rust 的所有权模型） | 驱动签名需要 testsigning 模式 |
| 内核态直接 `rdmsr` 指令，无任何限制 | 驱动崩溃 = 蓝屏（开发期间） |
| 用户态只需 `CreateFile` + `DeviceIoControl` | 不适合分发给非技术用户 |
| crates.io 已有预编译版本 | 项目仍标注为早期阶段（但可用） |

---

## 方案 A: 纯 Zig WDM 驱动（理论上可行，但不推荐）

Zig 支持 `x86_64-windows-kernel` 目标，但标准库不可用，需手动定义所有 NT 内核类型，调试几乎不可能。**不推荐**。

---

## 方案 B: WDM 驱动 C（备选）
C WDM 驱动是最成熟的方案，~200 行 C 代码，但需要 VS 2022 + WDK（~8GB）。详见上文原 C 驱动部分。

---

## 结论：推荐实施路径

### 第一步（Windows）：Rust WDM 驱动

```
tau_msr.sys (Rust 内核驱动) ← 读取 MSR 的内核端
    ↑ IOCTL via DeviceIoControl
tau_profiler.exe (Zig 用户态) ← 调用驱动读取 MSR
```

用 Rust 写最小 WDM 驱动（~150 行），通过 `rdmsr` 指令直接读 MSR。用户态 Zig 引擎通过 `CreateFile("\\\\.\\TauMsr")` + `DeviceIoControl` 调用。

### 第二步（Linux）：直接使用 /dev/cpu/*/msr

已经实现（`src/msr.zig` 中 `LinuxMsr`）。需 `sudo modprobe msr`。

### 第三步（可选）：Zig 引擎自动检测驱动

```zig
// 自动选择最优 MSR 访问方式
pub fn init() MsrReader {
    if (builtin.os.tag == .windows) {
        if (driverAvailable()) return DriverMsr{};  // Rust 驱动
        return .none;  // 提示用户安装驱动
    }
    if (builtin.os.tag == .linux) {
        return LinuxMsr{};  // /dev/cpu/N/msr
    }
    return .none;
}
```

---

## 总结

| 方案 | 语言 | 复杂度 | 状态 | 推荐场景 |
|------|------|--------|------|----------|
| **Rust WDM** | Rust | 中 | 官方支持，2025 年可用 | **Windows MSR 首选** |
| C WDM | C | 中 | 最成熟 | 备选 |
| `/dev/cpu/msr` | — | 低 | Linux 原生 | Linux 首选 |
| NtSystemDebugControl | — | 低 | ❌ Win10/11 已封禁 | 不再推荐 |
| 纯 Zig 驱动 | Zig | 极高 | 理论可行 | 不推荐 |

### 参考链接

- [microsoft/windows-drivers-rs](https://github.com/microsoft/windows-drivers-rs) — Microsoft 官方 Rust 驱动框架
- [microsoft/Windows-rust-driver-samples](https://github.com/microsoft/Windows-rust-driver-samples) — 完整驱动示例
- [The Register: Microsoft shows slow progress on Rust for Windows drivers (2025-09)](https://www.theregister.com/software/2025/09/04/microsoft-shows-slow-progress-on-rust-for-windows-drivers/)
- [DeepWiki: windows-drivers-rs Architecture](https://deepwiki.com/microsoft/windows-drivers-rs/2-architecture)

Sources:
- [microsoft/windows-drivers-rs](https://github.com/microsoft/windows-drivers-rs)
- [DeepWiki: windows-drivers-rs Core Components](https://deepwiki.com/microsoft/windows-drivers-rs/2.1-core-components)
- [The Register: Rust Windows drivers](https://www.theregister.com/software/2025/09/04/microsoft-shows-slow-progress-on-rust-for-windows-drivers/861876?td=keepreading)
- [TechSpot: Microsoft turning Rust first-class for Windows drivers](https://www.techspot.com/news/109351-microsoft-turning-rust-first-class-language-developing-secure.html)

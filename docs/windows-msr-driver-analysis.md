# Windows MSR 内核驱动方案分析

## 最终目标

让 `tau_profiler.exe` 在 Windows 用户态读取 MSR，获取 Turbo 倍频、温度、功耗、实时频率等信息。

---

## 方案对比

| 方案 | 复杂度 | 工具依赖 | 安全性 | 推荐 |
|------|--------|----------|--------|------|
| **A: 纯 Zig WDM 驱动** | 极高 | WDK + Zig | 完全自控 | 不推荐 |
| **B: WDM 驱动 C+Zig 混合** | 高 | WDK + VS + Zig | 完全自控 | 可行 |
| **C: NtSystemDebugControl** | 低 | 无 | 完全自控 | **最推荐** |
| **D: `\\.\Msr` 内置设备** | 低 | 无 | 完全自控 | 可行 |
| **E: Minifilter/KMDF** | 中 | WDK + VS | 完全自控 | 可行但过重 |

---

## 方案 C: NtSystemDebugControl（最推荐，零依赖）

Windows 内核导出了一个"调试"函数，可以在用户态通过 `ntdll.dll` 调用直接读写 MSR。

### 原理

```c
// ntdll.dll 导出的系统调用
NTSTATUS NtSystemDebugControl(
    SysDbgReadMsr,           // 操作码: 16 = 读 MSR
    &msr_addr,               // 输入: MSR 地址
    sizeof(msr_addr),
    &msr_value,              // 输出: MSR 值
    sizeof(msr_value),
    NULL
);
```

### 前提条件

1. **管理员权限**（必须）
2. **SeDebugPrivilege** 特权（代码可自动激活）
3. Windows 10/11 均可用（虽然文档标注 deprecated，实测可用）

### Zig 实现（~60 行代码）

```zig
const std = @import("std");
const windows = std.os.windows;

// ntdll 函数声明
extern "ntdll" fn NtSystemDebugControl(
    command: u32,
    input: ?*anyopaque,
    input_len: u32,
    output: ?*anyopaque,
    output_len: u32,
    ret_len: ?*u32,
) callconv(windows.WINAPI) i32;

const SysDbgReadMsr: u32 = 16;
const SysDbgWriteMsr: u32 = 17;

pub fn readMsr(msr_addr: u32) !u64 {
    var value: u64 = 0;
    const status = NtSystemDebugControl(
        SysDbgReadMsr,
        @constCast(@ptrCast(&msr_addr)),
        @sizeOf(u32),
        @ptrCast(&value),
        @sizeOf(u64),
        null,
    );
    if (status < 0) return error.MsrReadFailed;
    return value;
}
```

### 优点
- **零依赖**：只调用 Windows 自带的 ntdll.dll
- **纯 Zig**：~60 行代码，不需要任何外部工具
- **无需编译驱动**：直接用户态调用
- **无需签名**：不是驱动，没有签名问题
- **Linux 对应**：Linux 上已有更简单的 `/dev/cpu/N/msr`

### 缺点
- 微软将此 API 标记为 deprecated（但不影响 Win10/11 使用）
- 未来 Windows 版本可能移除
- 需要管理员权限运行

### 风险
- API 可能在未来版本被移除（概率低）
- 部分杀毒软件可能标记为可疑行为

---

## 方案 D: `\\.\Msr` 内置设备（零依赖）

Windows 内核内置了一个 MSR 驱动，可通过以下方式启用：

```powershell
# 以管理员运行，安装 MSR 驱动（此驱动名为 "Msr" 但需要手动注册）
sc create msr type= kernel start= demand binPath= "C:\Windows\System32\drivers\msr.sys"
sc start msr
```

但 `msr.sys` 可能不存在于某些 Windows 版本上。可用性不确定。

---

## 方案 B: WDM 驱动 C+Zig 混合（如需完整驱动能力）

### 所需工具

| 工具 | 用途 | 获取方式 |
|------|------|----------|
| **Visual Studio 2022 Community** | C 编译器 + 构建系统 | 免费，[visualstudio.microsoft.com](https://visualstudio.microsoft.com) |
| **Windows Driver Kit (WDK)** | 内核头文件、库、驱动程序模板 | VS Installer → 勾选 "Windows Driver Kit" |
| **Windows SDK** | 基础 Windows 头文件 | VS Installer 自带 |
| **Zig** | 已有 | 已安装 0.17.0-dev |
| **测试签名证书** | 驱动签名（开发阶段的测试签名） | 系统自带 `makecert` 命令 |

### 驱动架构

```
tau_profiler.exe (用户态)
    ↓ CreateFile("\\\\.\\TauMsr")
    ↓ DeviceIoControl(IOCTL_READ_MSR, &msr_addr, ...)

tau_msr.sys (内核态 WDM 驱动)
    ↓ DriverEntry()
    ↓ IoCreateDevice("\\Device\\TauMsr")
    ↓ IRP_MJ_DEVICE_CONTROL → 处理 IOCTL
    ↓ __readmsr(msr_addr) → 返回 MSR 值
```

### 最小驱动 C 代码（~200 行）

```c
// tau_msr.c — 最小 WDM 驱动，只读 MSR
#include <ntddk.h>

#define IOCTL_READ_MSR  CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)

typedef struct { ULONG msr_addr; ULONG64 msr_value; } MSR_REQUEST;

DRIVER_INITIALIZE DriverEntry;
DRIVER_UNLOAD TauMsrUnload;
DRIVER_DISPATCH TauMsrCreateClose;
DRIVER_DISPATCH TauMsrDeviceControl;

NTSTATUS DriverEntry(PDRIVER_OBJECT drv, PUNICODE_STRING reg) {
    UNICODE_STRING dev_name = RTL_CONSTANT_STRING(L"\\Device\\TauMsr");
    UNICODE_STRING sym_link = RTL_CONSTANT_STRING(L"\\DosDevices\\TauMsr");
    PDEVICE_OBJECT dev = NULL;

    IoCreateDevice(drv, 0, &dev_name, FILE_DEVICE_UNKNOWN, 0, FALSE, &dev);
    IoCreateSymbolicLink(&sym_link, &dev_name);

    drv->DriverUnload = TauMsrUnload;
    drv->MajorFunction[IRP_MJ_CREATE] = TauMsrCreateClose;
    drv->MajorFunction[IRP_MJ_CLOSE] = TauMsrCreateClose;
    drv->MajorFunction[IRP_MJ_DEVICE_CONTROL] = TauMsrDeviceControl;
    return STATUS_SUCCESS;
}

void TauMsrUnload(PDRIVER_OBJECT drv) {
    UNICODE_STRING sym = RTL_CONSTANT_STRING(L"\\DosDevices\\TauMsr");
    IoDeleteSymbolicLink(&sym);
    IoDeleteDevice(drv->DeviceObject);
}

NTSTATUS TauMsrCreateClose(PDEVICE_OBJECT dev, PIRP irp) {
    irp->IoStatus.Status = STATUS_SUCCESS;
    IoCompleteRequest(irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
}

NTSTATUS TauMsrDeviceControl(PDEVICE_OBJECT dev, PIRP irp) {
    PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(irp);
    if (stack->Parameters.DeviceIoControl.IoControlCode == IOCTL_READ_MSR) {
        MSR_REQUEST* req = (MSR_REQUEST*)irp->AssociatedIrp.SystemBuffer;
        req->msr_value = __readmsr(req->msr_addr);
        irp->IoStatus.Information = sizeof(MSR_REQUEST);
        irp->IoStatus.Status = STATUS_SUCCESS;
    }
    IoCompleteRequest(irp, IO_NO_INCREMENT);
    return irp->IoStatus.Status;
}
```

### 构建命令

```powershell
# 编译驱动
cl /c /GS- /Gs- /kernel /Zi /I"C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0\km" tau_msr.c
link /DRIVER /SUBSYSTEM:NATIVE /OUT:tau_msr.sys tau_msr.obj ntoskrnl.lib

# 启用测试签名模式（管理员 PowerShell，需要重启）
bcdedit /set testsigning on

# 创建自签名证书
makecert -r -pe -ss PrivateCertStore -n "CN=TauProfiler" tau_msr.cer
signtool sign /v /s PrivateCertStore /n "TauProfiler" tau_msr.sys

# 安装驱动
sc create tau_msr type= kernel start= demand binPath= "C:\full\path\to\tau_msr.sys"
sc start tau_msr
```

### 缺点
- 需要安装 Visual Studio + WDK（~8GB 下载）
- 需要测试签名（每次重启按 F8 选择 "Disable Driver Signature Enforcement" 或永久开启 testsigning）
- 开发周期：驱动崩溃 = 蓝屏
- 不适合分发给普通用户

---

## 方案 A: 纯 Zig WDM 驱动（理论上可行，但不推荐）

Zig 支持 `x86_64-windows-kernel` 目标，但：
- Zig 标准库不可用（`std` 在 kernel 模式 99% 不兼容）
- 需要手动定义所有 NT 内核类型（`PDRIVER_OBJECT`, `PIRP`, `IO_STACK_LOCATION` 等）
- 需要手动链接 `ntoskrnl.lib`
- 调试困难（kernel debugger 不支持 Zig 符号）
- 文档几乎为零

**不推荐**，除非你想做前沿探索。

---

## 结论：推荐实施路径

### 第一步：立即实施方案 C（NtSystemDebugControl）

```zig
// 在 src/msr.zig 中实现
// 用户运行 tau_profiler.exe --msr（需要管理员）
// 单次调用即可读取 0x1AD、0xCE、0x198 等所有关键 MSR
```

**优点**：今天就能实现，零外部依赖，纯 Zig 用户态代码。

### 第二步（可选）：如需完整 MSR 访问 + 分发

- 编写方案 B 的最小 WDM C 驱动（~200 行）
- 编译为 `tau_msr.sys`
- Zig 引擎检测驱动是否存在，存在则通过 DeviceIoControl 读取
- 提供给高级用户手动安装

### 第三步（Linux）：直接使用 /dev/cpu/*/msr

- `open("/dev/cpu/0/msr", .{})` → `pread(fd, buf, msr_addr)`
- 需要 `sudo modprobe msr` 加载 msr 模块
- 纯 Zig，~20 行代码

---

## 方案 C 在 tau_profiler 中的集成设计

```zig
// src/msr.zig

pub const MsrReader = union(enum) {
    ntsd: NtSystemDebug,       // Windows: ntdll API
    dev_msr: DevMsr,           // Linux: /dev/cpu/N/msr
    none,                       // 不可用（无 admin 或权限不足）

    pub fn init() MsrReader { ... }    // 自动检测可用方法
    pub fn read(self: *MsrReader, addr: u32) !u64 { ... }
    pub fn deinit(self: *MsrReader) void { ... }
};

// 调用示例
var msr = MsrReader.init();
defer msr.deinit();
const turbo = msr.read(0x1AD) catch null;
const power = msr.read(0x610) catch null;
const temp = msr.read(0x19C) catch null;
```

使用方式：

```powershell
# Windows（需要管理员权限）
tau_profiler.exe --msr

# Linux（需要 msr 模块 + sudo）
sudo tau_profiler --msr
```

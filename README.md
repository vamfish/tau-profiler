# ⏱️ Tau-Profiler

> **Tau** (τ) — 测量内存层级延迟，从 CPU 周期到 DRAM 主存。

Tau-Profiler 是一个跨平台的内存延迟探测工具，通过指针链追逐（pointer-chase）基准测试，量化 L1/L2/L3/LLC/DRAM 每一层的访问延迟，并输出结构化的 JSON 结果。

支持 **Linux / macOS / Windows**，覆盖 **x86_64** 和 **AArch64**（Apple Silicon）。

---

## 工作原理

1. 分配指定大小的内存块，构建循环指针链并随机打乱
2. 执行指针追逐（pointer chasing），绕过硬件预取器
3. 用高精度硬件计数器（RDTSCP / CNTVCT）计量每次访问的周期数
4. 自动校准计时器频率，换算为纳秒
5. 扫描 4KB → 64MB 区间，生成延迟-容量曲线

### 支持的计时器

| 架构 | 计时器 | 精度 |
|------|--------|------|
| x86_64 | RDTSCP | ~1 CPU cycle |
| AArch64 | CNTVCT_EL0 | ~1 CPU cycle |
| 回退 | OS monotonic clock | ~1 ns |

---

## 前置条件

- [**Zig**](https://ziglang.org/download/) ≥ `0.17.0-dev.356`（master 分支构建）
- **Python 3**（可选，用于可视化客户端）

### 各平台 Zig 安装

<details>
<summary><b>🐧 Linux</b></summary>

```bash
# 方式一：直接下载
curl -fsSL https://ziglang.org/builds/zig-linux-x86_64-$(curl -sL https://ziglang.org/download/index.json | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['master']['version'])").tar.xz \
  | sudo tar xJ -C /usr/local --strip=1

# 方式二：snap（推荐）
sudo snap install zig --classic --channel=master

# 方式三：源码编译（go 工具链）
go install ziglang.org/go@latest
```

</details>

<details>
<summary><b>🍎 macOS</b></summary>

```bash
# 方式一：Homebrew（推荐）
brew install zig

# 方式二：下载二进制
curl -fsSL https://ziglang.org/builds/zig-macos-x86_64-$(curl -sL https://ziglang.org/download/index.json | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['master']['version'])").tar.xz \
  | sudo tar xJ -C /usr/local --strip=1
```

> Apple Silicon 用户：Homebrew 会自动安装 ARM 版本。
</details>

<details>
<summary><b>🪟 Windows</b></summary>

```powershell
# 方式一：winget（推荐）
winget install zig.zig

# 方式二：Chocolatey
choco install zig

# 方式三：直接下载
# 1. 访问 https://ziglang.org/download/
# 2. 下载 zig-windows-x86_64-*.zip
# 3. 解压并将 zig.exe 所在目录添加到 PATH
```
</details>

---

## 一键部署

### 🐧 Linux / 🍎 macOS

```bash
curl -fsSL https://raw.githubusercontent.com/vamfish/tau-profiler/master/scripts/install.sh | bash
```

或手动执行：

```bash
# 1. 克隆仓库
git clone https://github.com/vamfish/tau-profiler.git
cd tau-profiler

# 2. 构建
zig build -Doptimize=ReleaseFast

# 3. 运行（引擎模式，输出 JSON）
./zig-out/bin/tau_profiler

# 4. 或使用 Python 客户端查看格式化结果
pip install -U --quiet 2>/dev/null
python3 tau_client.py
```

### 🪟 Windows (PowerShell)

```powershell
# 1. 克隆仓库
git clone https://github.com/vamfish/tau-profiler.git
cd tau-profiler

# 2. 构建
zig build -Doptimize=ReleaseFast

# 3. 运行
.\zig-out\bin\tau_profiler.exe

# 4. 或使用 Python 客户端
python tau_client.py
```

### 一键安装脚本（`scripts/install.sh`）

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/vamfish/tau-profiler.git"
DEST="${1:-$HOME/.tau-profiler}"

echo "==> Tau-Profiler 一键安装"
echo "    目标路径: $DEST"

# 前置检查
if ! command -v zig &>/dev/null; then
    echo "==> Zig 未安装，正在自动安装..."
    case "$(uname -s)" in
        Linux)
            sudo snap install zig --classic --channel=master 2>/dev/null || {
                ZIG_VER=$(curl -sL https://ziglang.org/download/index.json | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['master']['version'])")
                curl -fsSL "https://ziglang.org/builds/zig-linux-x86_64-${ZIG_VER}.tar.xz" \
                  | sudo tar xJ -C /usr/local --strip=1
            }
            ;;
        Darwin)
            if command -v brew &>/dev/null; then
                brew install zig
            else
                echo "请先安装 Homebrew: https://brew.sh"
                exit 1
            fi
            ;;
    esac
fi

# 克隆或更新
if [ -d "$DEST" ]; then
    echo "==> 更新已有仓库..."
    git -C "$DEST" pull --ff-only
else
    echo "==> 克隆仓库..."
    git clone "$REPO" "$DEST"
fi

# 构建
echo "==> 构建 Release 版本..."
cd "$DEST"
zig build -Doptimize=ReleaseFast

# 添加到 PATH
BIN="$DEST/zig-out/bin"
if [[ ":$PATH:" != *":$BIN:"* ]]; then
    SHELL_RC="$HOME/.$(basename "$SHELL")rc"
    echo "export PATH=\"\$PATH:$BIN\"" >> "$SHELL_RC"
    echo "==> $BIN 已添加到 PATH ($SHELL_RC)"
fi

echo ""
echo "🎉 Tau-Profiler 安装完成！"
echo "    运行: tau_profiler"
echo "    查看: python3 $DEST/tau_client.py"
```

将此脚本保存为 `scripts/install.sh`，然后：

```bash
chmod +x scripts/install.sh
./scripts/install.sh
```

---

## 输出示例

运行后引擎输出 JSON 到 stdout，同时 stderr 打印进度信息：

```
=== Tau-Profiler Engine v0.2.0 ===
[1/4] Detecting platform...
  OS: linux, Arch: x86_64
  CPU: Intel(R) Core(TM) Ultra 9 285K
  Cores: 16/24 (phys/logical)
[2/4] Calibrating timer...
  Source: RDTSCP
  Freq:   5200.00 MHz
[3/4] Pinning to core 0...
  OK
[4/4] Running latency sweep (4KB -> 64MB)...
  Completed 15 measurements

  Tau_cycle: 192.31 ps
```

Python 客户端输出表格：

```
============================================================
  🖥️  系统平台信息
============================================================
  OS:        linux
  Arch:      x86_64
  CPU:       Intel(R) Core(TM) Ultra 9 285K
  Vendor:    intel
  Cores:     16P / 24L
  VM:        false (none)

============================================================
  ⏱️  计时器校准
============================================================
  TSC 频率:   5200.00 MHz
  τ_cycle:    192.31 ps

============================================================
  📊 内存层级延迟测试结果
============================================================
  层级                          大小    延迟(ns)    周期   置信度
  --------------------------- -------- ---------- -------- ------
  L1 Data Cache                   4KB      0.97     5.1    90%
  L1 Data Cache                   8KB      0.99     5.2    90%
  L1/L2 Transition               16KB      1.10     5.7    90%
  L2 Cache                       32KB      1.61     8.4    90%
  ...                           ...       ...      ...     ...

============================================================
  📈 关键时间常数 (Tau)
============================================================
  τ_cycle    (CPU 周期):      192.31 ps
  τ_L1       (L1 缓存):        0.98 ns  (980 ps)
  τ_L2       (L2 缓存):        2.03 ns
  τ_L3       (L3/LLC):         9.74 ns
  τ_DRAM     (主存):          87.50 ns

  🔬 从 CPU 周期到 DRAM 延迟跨度: ~455x
```

---

## JSON 输出结构

```json
{
  "version": 1,
  "timestamp": 1748240000,
  "status": "success",
  "calibration": {
    "tsc_hz": 5200000000,
    "calibrated": true
  },
  "platform": {
    "os": "linux",
    "arch": "x86_64",
    "cpu_vendor": "intel",
    "cpu_brand": "Intel(R) Core(TM) Ultra 9 285K",
    "physical_cores": 16,
    "logical_cores": 24,
    "page_size": 4096,
    "has_invariant_tsc": true,
    "is_virtualized": false,
    "virtualized_under": "none"
  },
  "results": [
    {"label":"L1 Data Cache","size_bytes":4096,"latency_ns":0.9714,"latency_cycles":5.05,"confidence":0.90}
  ],
  "warnings": []
}
```

---

## 项目结构

```
tau-profiler/
├── build.zig              # Zig 构建配置
├── build.zig.zon          # 包声明
├── src/
│   ├── main.zig           # 入口 + JSON 输出
│   ├── timer.zig          # 跨平台高精度计时器
│   ├── platform.zig       # 平台检测（OS/CPU/核数/虚拟化）
│   └── cache.zig          # 内存延迟基准测试逻辑
├── tau_client.py          # Python 可视化客户端
└── scripts/
    └── install.sh         # 一键安装脚本
```

---

## 构建选项

```bash
# Debug 构建（默认）
zig build

# Release 构建（推荐）
zig build -Doptimize=ReleaseFast

# 指定目标平台交叉编译
zig build -Dtarget=x86_64-windows   # Windows
zig build -Dtarget=aarch64-macos    # Apple Silicon
zig build -Dtarget=x86_64-linux     # Linux x86_64

# 运行测试
zig build test
```

---

## 许可

MIT

#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  Tau-Profiler — 一键安装脚本
#  支持 Linux / macOS，自动安装 Zig 编译器和构建工具
#
#  用法:
#    curl -fsSL https://raw.githubusercontent.com/vamfish/tau-profiler/master/scripts/install.sh | bash
#    或
#    curl -fsSL https://git.io/tau-profiler | bash
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

REPO="https://github.com/vamfish/tau-profiler.git"
DEST="${1:-$HOME/.tau-profiler}"
SKIP_ZIG="${SKIP_ZIG:-}"

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}==>${NC} $*"; }
ok()    { echo -e "${GREEN}  ✓${NC} $*"; }
warn()  { echo -e "${YELLOW}  ⚠${NC} $*"; }
err()   { echo -e "${RED}  ✗${NC} $*"; }

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Tau-Profiler 一键安装脚本           ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""
info "目标路径: $DEST"

# ── OS 检测 ──
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
    Linux)   OS="linux"   ;;
    Darwin)  OS="macos"   ;;
    *)
        err "不支持的操作系统: $OS"
        err "请手动安装: https://github.com/vamfish/tau-profiler"
        exit 1
        ;;
esac
info "系统: $OS / $ARCH"

# ── 前置条件检查 ──
echo ""
info "检查前置条件..."

# Python 3（可选，用于客户端）
if command -v python3 &>/dev/null; then
    ok "Python 3: $(python3 --version)"
else
    warn "Python 3 未安装 — tau_client.py 不可用（构建不受影响）"
fi

# Git
if command -v git &>/dev/null; then
    ok "Git: $(git --version | head -1)"
else
    err "Git 未安装，请先安装 Git"
    case "$OS" in
        linux)  echo "    sudo apt install git  # Debian/Ubuntu"
                echo "    sudo yum install git  # RHEL/CentOS" ;;
        macos)  echo "    brew install git" ;;
    esac
    exit 1
fi

# Curl
if command -v curl &>/dev/null; then
    ok "curl: $(curl --version | head -1 | awk '{print $2}')"
else
    err "curl 未安装"
    exit 1
fi

# ── Zig ──
echo ""
info "检查 Zig..."

if command -v zig &>/dev/null; then
    ZIG_VER="$(zig version 2>/dev/null || true)"
    ok "Zig: $ZIG_VER"
else
    if [ -n "$SKIP_ZIG" ]; then
        warn "跳过 Zig 安装（SKIP_ZIG=1）"
    else
        info "Zig 未安装，正在自动安装..."
        case "$OS" in
            linux)
                # 尝试 snap，失败则下载二进制
                if command -v snap &>/dev/null && sudo snap install zig --classic --channel=master 2>/dev/null; then
                    ok "Zig 已通过 snap 安装"
                else
                    info "通过二进制包安装..."
                    ZIG_VER="$(curl -sL --max-time 10 "https://ziglang.org/download/index.json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['master']['version'])
" 2>/dev/null || echo "0.17.0-dev.356+3140b375f")"
                    ZIG_URL="https://ziglang.org/builds/zig-linux-x86_64-${ZIG_VER}.tar.xz"
                    info "下载: $ZIG_URL"
                    curl -fsSL "$ZIG_URL" | sudo tar xJ -C /usr/local --strip=1 2>/dev/null || {
                        err "Zig 下载失败，请手动安装: https://ziglang.org/download/"
                        exit 1
                    }
                    ok "Zig $ZIG_VER 已安装"
                fi
                ;;
            macos)
                if command -v brew &>/dev/null; then
                    brew install zig 2>/dev/null
                    ok "Zig 已通过 Homebrew 安装"
                else
                    err "请先安装 Homebrew: https://brew.sh"
                    err "或从 https://ziglang.org/download/ 手动下载"
                    exit 1
                fi
                ;;
        esac
    fi
fi

# ── 克隆/更新 ──
echo ""
info "获取源代码..."

if [ -d "$DEST" ]; then
    info "更新已有仓库..."
    git -C "$DEST" pull --ff-only 2>&1 | tail -1
    ok "已更新到最新"
else
    git clone "$REPO" "$DEST" 2>&1 | tail -1
    ok "已克隆到 $DEST"
fi

cd "$DEST"

# ── 构建 ──
echo ""
info "构建 Release 版本..."
zig build -Doptimize=ReleaseFast 2>&1 | tail -3
if [ -f zig-out/bin/tau_profiler ] || [ -f zig-out/bin/tau_profiler.exe ]; then
    ok "构建成功"
else
    err "构建失败"
    exit 1
fi

# ── PATH 添加 ──
BIN_DIR="$DEST/zig-out/bin"
case "$SHELL" in
    */zsh)  RC_FILE="$HOME/.zshrc" ;;
    */bash) RC_FILE="$HOME/.bashrc" ;;
    *)      RC_FILE="$HOME/.profile" ;;
esac

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo "" >> "$RC_FILE"
    echo "# Tau-Profiler" >> "$RC_FILE"
    echo "export PATH=\"\$PATH:$BIN_DIR\"" >> "$RC_FILE"
    ok "已添加 \$PATH 到 $RC_FILE"
    warn "请执行: source $RC_FILE  或重新打开终端"
else
    ok "PATH 已配置"
fi

# ── 完成 ──
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     🎉 Tau-Profiler 安装完成！          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}运行引擎:${NC}     tau_profiler"
echo -e "  ${CYAN}可视化输出:${NC}   python3 $DEST/tau_client.py"
echo -e "  ${CYAN}更新:${NC}         git -C $DEST pull && zig build -Doptimize=ReleaseFast"
echo ""

#!/usr/bin/env bash
set -euo pipefail
REPO="https://github.com/vamfish/tau-profiler.git"
DEST="${1:-$HOME/.tau-profiler}"

echo "==> Tau-Profiler Installer"

if ! command -v zig &>/dev/null; then
    echo "==> Installing Zig..."
    case "$(uname -s)" in
        Linux) sudo snap install zig --classic --channel=master ;;
        Darwin) brew install zig ;;
        *) echo "Manual install: https://ziglang.org/download/"; exit 1 ;;
    esac
fi

echo "==> Cloning $REPO"
git clone "$REPO" "$DEST" 2>/dev/null || git -C "$DEST" pull --ff-only

echo "==> Building"
cd "$DEST"
zig build -Doptimize=ReleaseFast

BIN="$DEST/zig-out/bin"
if [[ ":$PATH:" != *":$BIN:"* ]]; then
    echo "export PATH=\"\$PATH:$BIN\"" >> "$HOME/.$(basename "$SHELL")rc"
fi

echo "Done! Run: tau_profiler"

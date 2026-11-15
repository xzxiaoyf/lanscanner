#!/bin/bash
# 构建并组装 LANScanner.app
#
#   ./build.sh                       # release，双架构 universal（默认）
#   ./build.sh release universal     # release，arm64 + x86_64
#   ./build.sh release native        # release，仅本机架构
#   ./build.sh release arm64         # release，仅 Apple Silicon
#   ./build.sh release x86_64        # release，仅 Intel
#   ./build.sh debug                 # debug，仅本机架构
#
# 说明：SwiftPM 没有 --arch 选项，双架构通过两个 --triple 分别构建后
#       用 lipo -create 合并。Xcode 完整安装的 macOS SDK 含两种架构，
#       因此 Intel 与 Apple Silicon 主机都能交叉编译出 universal 程序。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="LANScanner"
CONFIG="${1:-release}"
ARCH="${2:-}"
DEPLOY="11.0"

# 未指定架构时：release 默认双架构，debug 默认本机架构
if [ -z "$ARCH" ]; then
    if [ "$CONFIG" = "debug" ]; then ARCH="native"; else ARCH="universal"; fi
fi

case "$ARCH" in
    universal|native|arm64|x86_64) ;;
    *) echo "未知架构参数: $ARCH（可选 universal|native|arm64|x86_64）" >&2; exit 2 ;;
esac

TMPDIR_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/lanscanner-build.XXXXXX")"
trap 'rm -rf "$TMPDIR_BUILD"' EXIT

# 构建单一架构，stdout 只输出 bin 目录
build_arch() {
    local arch="$1"
    local triple="$arch-apple-macosx$DEPLOY"
    local scratch=".build/$arch"
    echo "==> swift build -c $CONFIG ($arch)" >&2
    swift build -c "$CONFIG" --triple "$triple" --scratch-path "$scratch" >&2

    local bindir
    bindir="$(swift build -c "$CONFIG" --triple "$triple" --scratch-path "$scratch" --show-bin-path 2>/dev/null | tail -1)"
    if [ ! -f "$bindir/$APP_NAME" ]; then
        bindir="$(pwd)/.build/$arch/$arch-apple-macosx/$CONFIG"
    fi
    if [ ! -f "$bindir/$APP_NAME" ]; then
        echo "$arch 构建产物缺失: $bindir/$APP_NAME" >&2
        exit 1
    fi
    if [ "$(lipo -archs "$bindir/$APP_NAME")" != "$arch" ]; then
        echo "$arch 构建产物架构不符: $(lipo -archs "$bindir/$APP_NAME")" >&2
        exit 1
    fi
    echo "$bindir"
}

case "$ARCH" in
    universal)
        ARM_BIN="$(build_arch arm64)/$APP_NAME"
        X86_BIN="$(build_arch x86_64)/$APP_NAME"
        [ -f "$ARM_BIN" ] || { echo "arm64 构建产物缺失: $ARM_BIN" >&2; exit 1; }
        [ -f "$X86_BIN" ] || { echo "x86_64 构建产物缺失: $X86_BIN" >&2; exit 1; }
        echo "==> lipo -create (x86_64 + arm64)" >&2
        BIN="$TMPDIR_BUILD/$APP_NAME"
        lipo -create -output "$BIN" "$X86_BIN" "$ARM_BIN"
        ;;
    native)
        echo "==> swift build -c $CONFIG (native)" >&2
        swift build -c "$CONFIG" >&2
        BIN="$(swift build -c "$CONFIG" --show-bin-path | tail -1)/$APP_NAME"
        ;;
    *)
        BIN="$(build_arch "$ARCH")/$APP_NAME"
        ;;
esac

if [ ! -f "$BIN" ]; then
    echo "构建产物未找到: $BIN" >&2
    exit 1
fi

APP="$APP_NAME.app"
# 就地覆盖，不删除旧 .app（避免覆盖正在运行 / 受保护的可执行文件时的删除限制）
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
chmod 755 "$APP/Contents/MacOS/$APP_NAME"
cp Support/Info.plist "$APP/Contents/Info.plist"
if [ -f Support/AppIcon.icns ]; then
    cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
if [ -f Support/oui.txt ]; then
    cp Support/oui.txt "$APP/Contents/Resources/oui.txt"
else
    echo "!! 缺少 Support/oui.txt，厂商识别将只能使用内置表" >&2
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Apple Silicon 要求可执行文件必须已签名；ad-hoc 签名即可原生运行。
# 覆盖 Mach-O 后偶发签名未落盘，签名后校验并在必要时重试一次。
codesign --force --sign - --timestamp=none "$APP"
if ! codesign --verify --strict "$APP" >/dev/null 2>&1; then
    sleep 0.3
    codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --strict "$APP"

echo "==> 完成: $(pwd)/$APP"
echo "    架构: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
echo "    版本: $(defaults read "$(pwd)/$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo 1.1.3)"
echo "    运行: open \"$APP\""
echo "    自检: \"$APP/Contents/MacOS/$APP_NAME\" --selftest"

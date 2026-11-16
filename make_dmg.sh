#!/bin/bash
# 生成可分发的 LANScanner DMG（默认先构建 Intel + Apple Silicon 双架构应用）
#
#   ./make_dmg.sh                         # 构建 universal .app + 生成 dist/LANScanner-<版本>-Universal.dmg
#   ./make_dmg.sh /path/to/输出.dmg        # 指定输出路径
#   BUILD=0 ./make_dmg.sh                  # 跳过编译，直接用现有 .app 打包
#   STYLE=0 ./make_dmg.sh                 # 不做访达窗口美化（无 GUI 权限时更稳）
set -euo pipefail
cd "$(dirname "$0")"

APP="LANScanner.app"
EXE="$APP/Contents/MacOS/LANScanner"
VOLNAME="LANScanner"
BUILD="${BUILD:-1}"
STYLE="${STYLE:-1}"

if [ "$BUILD" = "1" ]; then
    echo "==> 构建双架构应用"
    ./build.sh release universal
fi

# 版本号在构建之后读取，确保与新 Info.plist 一致
VERSION="$(defaults read "$(pwd)/$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo 1.1.4)"
OUT="${1:-dist/LANScanner-${VERSION}-Universal.dmg}"

if [ ! -f "$EXE" ]; then
    echo "未找到 $EXE，请先执行 ./build.sh release universal" >&2
    exit 1
fi
ARCHS="$(lipo -archs "$EXE")"
for required in x86_64 arm64; do
    case " $ARCHS " in
        *" $required "*) ;;
        *) echo "当前应用缺少 $required 架构 ($ARCHS)，请执行 ./build.sh release universal" >&2; exit 1 ;;
    esac
done
if ! codesign --verify --strict "$APP" >/dev/null 2>&1; then
    echo "应用签名无效，Apple Silicon 上会被系统拒绝运行" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lanscanner-dmg.XXXXXX")"
MNT=""
cleanup() {
    if [ -n "$MNT" ] && [ -d "$MNT" ]; then
        hdiutil detach "$MNT" -force -quiet >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

STAGE="$TMP/stage"
mkdir -p "$STAGE/.background" "$(dirname "$OUT")"
cp -R "$APP" "$STAGE/$APP"
ln -s /Applications "$STAGE/Applications"

# 首次打开修复脚本（Gatekeeper 隔离属性）
cat > "$STAGE/首次打开修复.command" <<'SH'
#!/bin/bash
# 把 LANScanner.app 拖进「应用程序」后，若系统提示「已损坏」或「无法验证开发者」，双击本文件。
APP="/Applications/LANScanner.app"
if [ ! -d "$APP" ]; then
    osascript -e 'display alert "未找到 /Applications/LANScanner.app" message "请先把 DMG 里的 LANScanner.app 拖到 Applications 文件夹，再运行本脚本。"' >/dev/null 2>&1 || true
    exit 1
fi
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
open "$APP"
SH
chmod 755 "$STAGE/首次打开修复.command"

cat > "$STAGE/安装说明.txt" <<TXT
LANScanner ${VERSION}  ·  Universal
========================================

【支持的 Mac】
  Intel (x86_64) 与 Apple Silicon (arm64，M1/M2/M3/M4…) 均为原生运行，
  不需要 Rosetta。系统要求 macOS 11.0 (Big Sur) 或更高版本。

【安装】
  把本窗口中的 LANScanner.app 拖到右侧 Applications（应用程序）图标上即可。

【首次打开（重要）】
  本应用为 ad-hoc 签名、未提交 Apple 公证，Gatekeeper 可能提示
  「无法打开，因为无法验证开发者」或「已损坏」。任选一种方式：

  A. 按住 Control 点击 LANScanner.app →「打开」→ 再点「打开」；
     或到「系统设置 → 隐私与安全性」点「仍要打开」。
  B. 双击本 DMG 里的「首次打开修复.command」（需先完成安装）。
  C. 在终端手工执行：
     xattr -dr com.apple.quarantine /Applications/LANScanner.app

【使用】
  打开应用 → 点顶部「扫描」选择要扫描的网络 → 点设备行右侧的 ›
  或右侧「端口」标签，即可扫描该设备的开放端口。
  OUI 厂商库与所需系统命令均已内置，完全离线可用，无需联网。
  顶部工具栏右侧会显示版本号（v${VERSION}），点 ⓘ 可查看构建时间；
  若显示的仍是旧版本号，说明打开的是旧副本或旧进程，请先退出应用再重开。

【手动 IP 范围】
  在「选择扫描网络」窗口右侧勾选「使用手动 IP 范围」后，
  「起始 IP」「结束 IP」才允许编辑；取消勾选会恢复为所选接口
  自动计算出的网段范围。方框或文字均可点击，也可用空格键切换。
  ${VERSION} 修复了自绘复选框无法勾选的问题，设置面板与网络唤醒
  页面中的同款复选框一并修复。

【网络唤醒 (WOL)】
  扫描结果加入列表：点设备行右侧的电源按钮，或在右侧详情点「加入 WOL」，
  也可用菜单「扫描 → 将选中设备加入唤醒列表」。
  发起唤醒：点顶部「网络唤醒」按钮或左侧导航栏最下方的闪电图标进入
  唤醒列表，选中设备后点
  「发送唤醒包」，或使用列表中的「全部唤醒」「唤醒」按钮。
  列表还支持手动添加 MAC、自定义广播地址 / 端口、移除设备；唤醒后
  可自动 ping 检测设备是否上线。设置面板里可调整默认端口与重复次数。
  目标网卡必须支持并启用 WoL 且保持供电，唤醒包仅在同一二层网段有效；
  Magic Packet 无确认机制，「发送成功」仅代表 UDP 包已发出。
  列表保存于 ~/Library/Application Support/LANScanner/wol-devices.json。

【MAC / 厂商与设备名识别】（换机器后若不生效，请先做诊断）
  完整 IEEE OUI 库（52,085 条前缀）已编译进程序本体，即使
  Contents/Resources/oui.txt 丢失、或只复制了可执行文件，厂商识别仍然可用。
  MAC 改为多通道采集：首选内核路由表（sysctl 直接读取，不依赖外部
  命令、PATH、DNS 或进程权限），再叠加 arp -a -n / arp -a / arp -an /
  指定接口 arp / netstat 主机路由 / 逐条 arp -n 作为备用。
  部分 Mac 上系统自带的 arp 会返回空结果或长时间挂起，这正是旧版
  「主机能发现、MAC 全为 —、厂商全未知」的原因；任一通道可用即可恢复。
  扫描结束前还会对「在线但表里没有 MAC」的设备做一次定向补探并
  重读内核表，避免 ARP 缓存被系统快速清理造成漏识别。
  如需自行更新厂商库，把新的 oui.txt 放在以下任一位置即可覆盖内嵌版本：
    LANScanner.app/Contents/Resources/oui.txt
    ~/Library/Application Support/LANScanner/oui.txt
    或设置环境变量 LANSCANNER_OUI=/path/to/oui.txt
  设备名主要来自系统 DNS/mDNS 反向解析（dscacheutil），arp -a 仅作
  快速补充；签名应用内 arp -a 的反向解析常会挂起，程序已设短时
  超时并自动改用系统反查，不会因此丢失 MAC 或厂商。
  若目标网络没有反向解析记录（多数家用路由器不提供），设备名会为空，
  属于网络环境差异；厂商名仍应正常显示。点 ⓘ 可查看 OUI 来源与条数。

【自检与跨机器诊断】
  /Applications/LANScanner.app/Contents/MacOS/LANScanner --version
  /Applications/LANScanner.app/Contents/MacOS/LANScanner --selftest
  /Applications/LANScanner.app/Contents/MacOS/LANScanner --arpdiag
  --version 会额外显示运行架构、系统版本与内核 ARP 通道条数；
  --selftest 打印 OUI 条数、各 ARP 来源状态和「MAC / 厂商 / 设备名」
  识别统计；--arpdiag 会导出每个来源的命令、退出码、超时情况、
  原始输出与最终合并结果。若某台机器 MAC / 厂商仍全为空，请把
  --arpdiag 的完整输出贴回开发者。
  应急验证（只走内核表，跳过所有外部 arp / netstat 命令）：
    LANSCANNER_ARP_KERNEL_ONLY=1 /Applications/LANScanner.app/Contents/MacOS/LANScanner --selftest

【关于权限】
  应用只读取本机网络配置与内核路由表，并调用系统自带的 ping / arp /
  netstat / dscacheutil / ifconfig / route / networksetup，不安装驱动、
  不修改系统设置、不上传任何数据。
TXT

# 背景图
if [ -f Support/DMG-Background.png ]; then
    cp Support/DMG-Background.png "$STAGE/.background/bg.png"
else
    swift Support/make_dmg_background.swift "$STAGE/.background/bg.png" >/dev/null
fi

RW="$TMP/rw.dmg"

# 预检 Finder Apple Events 权限：无权限时立即降级，避免等待超时
finder_available() {
    python3 - <<'PY'
import subprocess, sys
try:
    p = subprocess.run(
        ["osascript", "-e", 'tell application "Finder" to get name of startup disk'],
        timeout=8, capture_output=True)
    sys.exit(0 if p.returncode == 0 else 1)
except subprocess.TimeoutExpired:
    sys.exit(1)
PY
}

apply_layout() {
    cat > "$TMP/layout.applescript" <<'AS'
tell application "Finder"
    tell disk "LANScanner"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {120, 120, 880, 600}
        set opts to icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 96
        try
            set background picture of opts to file ".background:bg.png"
        end try
        try
            set position of item "LANScanner.app" of container window to {190, 200}
            set position of item "Applications" of container window to {570, 200}
            set position of item "安装说明.txt" of container window to {380, 350}
            set position of item "首次打开修复.command" of container window to {380, 430}
        end try
        try
            update without registering applications
        end try
        delay 1
        close
    end tell
end tell
AS
    # Apple Events 可能在无权限环境挂起，用超时保护，失败则退回标准 DMG
    python3 - "$TMP/layout.applescript" <<'PY'
import subprocess, sys
try:
    p = subprocess.run(["osascript", sys.argv[1]], timeout=20,
                       capture_output=True, text=True)
    sys.exit(p.returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
PY
}

make_styled() {
    finder_available || return 1
    hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ \
        -format UDRW -ov "$RW" >/dev/null || return 1
    mkdir -p "$TMP/mnt"
    hdiutil attach "$RW" -mountpoint "$TMP/mnt" -nobrowse -noautoopen \
        -readwrite >/dev/null || return 1
    MNT="$TMP/mnt"
    if ! apply_layout >/dev/null 2>&1; then
        echo "!! 访达窗口布局定制不可用，使用标准布局" >&2
        return 1
    fi
    sync
    hdiutil detach "$MNT" -force -quiet >/dev/null || return 1
    MNT=""
    hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov \
        -o "$OUT" >/dev/null || return 1
    return 0
}

if [ "$STYLE" = "1" ] && make_styled; then
    echo "==> 已生成带拖放布局的 DMG"
else
    if [ -n "$MNT" ]; then
        hdiutil detach "$MNT" -force -quiet >/dev/null 2>&1 || true
        MNT=""
    fi
    # 标准布局不需要背景图，去掉隐藏目录保持卷内容干净
    rm -rf "$STAGE/.background"
    echo "==> 生成标准 DMG"
    hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ \
        -format UDZO -ov "$OUT" >/dev/null
fi

if [ ! -f "$OUT" ]; then
    echo "DMG 生成失败" >&2
    exit 1
fi

# 挂载回读，确认卷内内容、架构、签名与 OUI 资源
VERIFY="$TMP/verify"
mkdir -p "$VERIFY"
hdiutil attach "$OUT" -mountpoint "$VERIFY" -nobrowse -noautoopen >/dev/null
MNT="$VERIFY"
echo "==> DMG 内容校验"
ls -1 "$VERIFY" | sed 's/^/    /'
echo "    架构: $(lipo -archs "$VERIFY/$EXE")"
echo "    签名: $(codesign -dv "$VERIFY/$APP" 2>&1 | grep -E '^Signature=' || echo '无效')"
echo "    OUI:  $(wc -l < "$VERIFY/$APP/Contents/Resources/oui.txt") 条"
if "$VERIFY/$EXE" --selftest > "$TMP/selftest.log" 2>&1; then
    echo "    自检: 完整通过"
else
    echo "    自检: 异常退出"
fi
grep -E '^\[OK\]' "$TMP/selftest.log" | head -6 | sed 's/^/    /'
if ! grep -q "端口扫描完成" "$TMP/selftest.log"; then
    echo "    [WARN] 自检未跑到结束，可能中途崩溃："
    tail -5 "$TMP/selftest.log" | sed 's/^/    /'
fi
hdiutil detach "$VERIFY" -force -quiet >/dev/null
MNT=""

echo "==> 完成: $(pwd)/$OUT"
echo "    大小: $(du -h "$OUT" | cut -f1)"
echo "    校验: shasum -a 256 \"$OUT\""
shasum -a 256 "$OUT"

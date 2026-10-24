#!/bin/bash
# Reader for macOS —— 构建脚本（原生 arm64，不依赖 Xcode / SwiftPM）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Reader"
TARGET="arm64-apple-macos13.0"
BUILD="$ROOT/.build"
APP="$ROOT/dist/$APP_NAME.app"

mkdir -p "$BUILD"

SRC=()
while IFS= read -r f; do SRC+=("$f"); done < <(find "$ROOT/Sources" -name '*.swift' | sort)
if [ "${#SRC[@]}" -eq 0 ]; then
    echo "✗ Sources/ 下没有 Swift 文件" >&2
    exit 1
fi

# ---- 生成 compile_commands.json ----
# 让 VSCode 的 Swift 扩展（sourcekit-lsp）在没有 SwiftPM 的情况下
# 也能提供补全 / 跳转 / 诊断。sourcekit-lsp 支持 swiftPM、compilationDatabase、
# buildServer 三种工程模式，这里用的是 compilationDatabase。
python3 - "$ROOT" "$TARGET" "${SRC[@]}" <<'PY'
import json, os, sys
root, target = sys.argv[1], sys.argv[2]
files = sys.argv[3:]
sdk = os.popen("xcrun --show-sdk-path").read().strip()
args = ["swiftc", "-target", target, "-sdk", sdk] + files
entries = [{"directory": root, "file": f, "arguments": args} for f in files]
with open(os.path.join(root, "compile_commands.json"), "w") as fh:
    json.dump(entries, fh, indent=2, ensure_ascii=False)
print("==> compile_commands.json 已生成（%d 个源文件）" % len(entries))
PY

echo "==> 编译 ($TARGET)"
swiftc -O \
    -target "$TARGET" \
    -module-cache-path "$BUILD/modulecache" \
    -o "$BUILD/$APP_NAME" \
    "${SRC[@]}"

# ---- 应用图标 ----
# 用 tools/MakeIcon.swift 处理成符合 macOS 规范的圆角矩形图标：
#   · SVG 走 NSImage 按矢量光栅化（清晰 + 保留透明度）
#     —— 不要用 qlmanage，它渲染的 SVG 会带一层不透明白底
#   · 量出图案包围盒后重新居中
#   · 套 824×824 / 圆角 185.4 的 macOS 图标网格
# 底色和图案占比可以用环境变量覆盖：
#   ICON_BG='#E4F5F0' ICON_SCALE=0.66 ./build.sh
ICNS="$ROOT/Resources/AppIcon.icns"
SVG_SRC="$ROOT/Resources/阅读.svg"
PNG_SRC="$ROOT/Resources/阅读.png"
ICON_BG="${ICON_BG:-#F1F1F4}"
ICON_SCALE="${ICON_SCALE:-0.60}"
MAKEICON="$BUILD/makeicon"

need_icon=0
if [ ! -f "$ICNS" ]; then
    need_icon=1
elif { [ -f "$SVG_SRC" ] && [ "$SVG_SRC" -nt "$ICNS" ]; } || { [ -f "$PNG_SRC" ] && [ "$PNG_SRC" -nt "$ICNS" ]; }; then
    need_icon=1
fi

if [ "$need_icon" -eq 1 ]; then
    echo "==> 生成应用图标"
    ICONSET="$BUILD/AppIcon.iconset"
    BASE="$BUILD/iconbase.png"
    rm -rf "$ICONSET" "$BASE"
    mkdir -p "$ICONSET"

    ICON_SRC=""
    if [ -f "$SVG_SRC" ]; then ICON_SRC="$SVG_SRC"
    elif [ -f "$PNG_SRC" ]; then ICON_SRC="$PNG_SRC"; fi

    if [ -n "$ICON_SRC" ]; then
        if [ ! -x "$MAKEICON" ] || [ "$ROOT/tools/MakeIcon.swift" -nt "$MAKEICON" ]; then
            swiftc -O -target "$TARGET" -module-cache-path "$BUILD/modulecache" \
                  -o "$MAKEICON" "$ROOT/tools/MakeIcon.swift"
        fi
        "$MAKEICON" "$ICON_SRC" "$BASE" "$ICON_SCALE" "$ICON_BG"

        gen() { sips -z "$2" "$2" "$BASE" --out "$ICONSET/$1.png" >/dev/null; }
        gen icon_16x16       16
        gen icon_16x16@2x    32
        gen icon_32x32       32
        gen icon_32x32@2x    64
        gen icon_128x128     128
        gen icon_128x128@2x  256
        gen icon_256x256     256
        gen icon_256x256@2x  512
        gen icon_512x512     512
        gen icon_512x512@2x  1024
        iconutil -c icns "$ICONSET" -o "$ICNS"
        echo "  已生成 $(basename "$ICNS")（10 个尺寸，底色 $ICON_BG，图案占比 $ICON_SCALE）"
    else
        echo "  (没有图标源文件，跳过)"
    fi
fi

echo "==> 组装 $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ICNS" ]; then
    cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign 跳过)"

echo "✅ 构建完成"
echo "   产物: $APP"
echo -n "   架构: "; lipo -info "$APP/Contents/MacOS/$APP_NAME" | sed 's/.*architecture: //'

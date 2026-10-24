#!/bin/bash
# 一键验证：构建 + 单测 + 全部自检 + 离屏渲染
# 改动完跑一遍，有问题会立刻停在这一步。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$ROOT/dist/Reader.app/Contents/MacOS/Reader"
OUT="${TMPDIR:-/tmp}/reader-verify"
mkdir -p "$OUT"

# 自检一律用临时存档 —— 绝不碰用户真实的
# ~/Library/Application Support/Reader/.cache.dat
export READER_CACHE_PATH="$OUT/.cache.dat"

step() { printf "\n\033[1m==> %s\033[0m\n" "$1"; }

step "1/5 构建"
bash "$ROOT/build.sh" | tail -4

step "2/5 单元测试"
bash "$ROOT/test.sh" | tail -2

step "3/5 应用启动冒烟"
"$BIN" "$ROOT/samples/长篇小说样例.txt" >"$OUT/smoke.log" 2>&1 &
PID=$!
sleep 5
if kill -0 "$PID" 2>/dev/null; then
    echo "  ✅ 启动正常，5 秒无崩溃"
    kill "$PID" 2>/dev/null || true
else
    echo "  ❌ 启动即崩溃，日志："; cat "$OUT/smoke.log"; exit 1
fi
sleep 1

step "4/5 窗口自检"
"$BIN" --library-selftest 2>&1 | grep -vE "Secure coding|_TIPropertyValue|imkxpc_set" | grep -E "一致|上报|onAllRemoved|打开后 isVisible|表格行数"
"$BIN" --dump-touchbar 2>&1 | grep -E "懒加载|三处一致|mini|进度标签" | head -3

step "4.5/5 关窗自检（曾因主窗口漏设 isReleasedWhenClosed 而段错误）"
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
BEFORE_CRASH=$(find "$CRASH_DIR" -name "Reader*.ips" 2>/dev/null | wc -l | tr -d ' ')
set +e
"$BIN" --close-selftest "$ROOT/samples/长篇小说样例.txt" >"$OUT/close.log" 2>&1
CLOSE_CODE=$?
set -e
sleep 3
AFTER_CRASH=$(find "$CRASH_DIR" -name "Reader*.ips" 2>/dev/null | wc -l | tr -d ' ')
if [ "$CLOSE_CODE" -ne 0 ]; then
    echo "  ❌ 关窗自检退出码 $CLOSE_CODE（应为 0）"; cat "$OUT/close.log"; exit 1
fi
if [ "$AFTER_CRASH" -gt "$BEFORE_CRASH" ]; then
    echo "  ❌ 关窗产生了新的崩溃报告"; find "$CRASH_DIR" -name "Reader*.ips" -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1; exit 1
fi
echo "  ✅ 关掉主窗口后干净退出，无崩溃"

step "4.6/5 启动前打开文件自检（曾崩在 open(url:)：窗口还没建）"
BEFORE_CRASH=$(find "$CRASH_DIR" -name "Reader*.ips" 2>/dev/null | wc -l | tr -d ' ')
set +e
"$BIN" --early-open-selftest >"$OUT/earlyopen.log" 2>&1
OPEN_CODE=$?
set -e
sleep 3
AFTER_CRASH=$(find "$CRASH_DIR" -name "Reader*.ips" 2>/dev/null | wc -l | tr -d ' ')
if [ "$OPEN_CODE" -ne 0 ] || [ "$AFTER_CRASH" -gt "$BEFORE_CRASH" ]; then
    echo "  ❌ 启动前打开文件失败（退出码 $OPEN_CODE）"; cat "$OUT/earlyopen.log"; exit 1
fi
grep -E "✅" "$OUT/earlyopen.log" | sed 's/^/  /'

step "5/5 离屏渲染"
"$BIN" --render-page "$ROOT/samples/长篇小说样例.txt" "$OUT/page.png" 2 2>&1 | tail -1
"$BIN" --dark --render-page "$ROOT/samples/长篇小说样例.txt" "$OUT/page-dark.png" 2 2>&1 | tail -1
"$BIN" --render-library "$OUT/library.png" 2>&1 | tail -1
"$BIN" --render-settings "$OUT/settings.png" 2>&1 | tail -1
"$BIN" --render-bookmarks "$OUT/bookmarks.png" 2>&1 | tail -1
"$BIN" --dump-pages "$ROOT/samples/长篇小说样例.txt" 2>&1 >"$OUT/pages.tsv" | tail -1

echo
echo "✅ 全部通过。渲染产物在 $OUT/"

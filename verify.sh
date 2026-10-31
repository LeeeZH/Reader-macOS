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
# --smoke-launch：走真实启动路径，但用开发工具安静模式（不弹窗、不抢焦点）
"$BIN" --smoke-launch "$ROOT/samples/古文观止.txt" >"$OUT/smoke.log" 2>&1 &
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
"$BIN" --close-selftest "$ROOT/samples/古文观止.txt" >"$OUT/close.log" 2>&1
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

step "4.65/5 异步打开自检（open 立即返回 / 加载中转圈 / 后台完成才上屏 / 连开只认最后一本）"
set +e
"$BIN" --open-async-selftest >"$OUT/open-async.log" 2>&1
ASYNC_CODE=$?
set -e
grep -E "✅|❌" "$OUT/open-async.log" | sed 's/^/  /'
if [ "$ASYNC_CODE" -ne 0 ]; then
    echo "  ❌ 异步打开自检失败（退出码 $ASYNC_CODE）"; cat "$OUT/open-async.log"; exit 1
fi

step "4.7/5 目录菜单自检（一级菜单 + 3000 章全部列出 + 当前章定位 + 跳转）"
set +e
"$BIN" --toc-selftest >"$OUT/toc.log" 2>&1
TOC_CODE=$?
set -e
grep -E "一级菜单|重建|✅|❌" "$OUT/toc.log" | sed 's/^/  /'
if [ "$TOC_CODE" -ne 0 ]; then
    echo "  ❌ 目录自检失败（退出码 $TOC_CODE）"; cat "$OUT/toc.log"; exit 1
fi

step "4.8/5 章节搜索自检（章节号 / 中文数字 / 标题模糊 + 跳转）"
set +e
"$BIN" --chapter-search-selftest >"$OUT/search.log" 2>&1
SEARCH_CODE=$?
set -e
grep -E "✅|❌|跳转后" "$OUT/search.log" | sed 's/^/  /'
if [ "$SEARCH_CODE" -ne 0 ]; then
    echo "  ❌ 章节搜索自检失败（退出码 $SEARCH_CODE）"; cat "$OUT/search.log"; exit 1
fi

step "4.9/5 全文搜索自检（⌘F 面板 / 不自动跳页 / 关闭清空 / 高亮 / 环绕 / 大小写）"
set +e
"$BIN" --find-selftest >"$OUT/find.log" 2>&1
FIND_CODE=$?
set -e
grep -E "✅|❌" "$OUT/find.log" | sed 's/^/  /'
if [ "$FIND_CODE" -ne 0 ]; then
    echo "  ❌ 全文搜索自检失败（退出码 $FIND_CODE）"; cat "$OUT/find.log"; exit 1
fi

step "4.10/5 窗口置顶自检（floating level / 失焦不隐藏 / 三处联动 / 存档往返）"
set +e
"$BIN" --always-on-top-selftest >"$OUT/top.log" 2>&1
TOP_CODE=$?
set -e
grep -E "✅|❌|level =" "$OUT/top.log" | sed 's/^/  /'
if [ "$TOP_CODE" -ne 0 ]; then
    echo "  ❌ 窗口置顶自检失败（退出码 $TOP_CODE）"; cat "$OUT/top.log"; exit 1
fi

step "4.11/5 章节解析 golden 比对（--dump-chapters 必须与基准逐字节一致）"
"$BIN" --dump-chapters "$ROOT/samples/古文观止.txt" >"$OUT/chapters.tsv" 2>/dev/null
if diff -q "$ROOT/samples/golden-chapters.tsv" "$OUT/chapters.tsv" >/dev/null; then
    echo "  ✅ 章节表与基准一致（3 章：偏移 / 标题长度 / 标题）"
else
    echo "  ❌ 章节表与基准不一致："
    diff "$ROOT/samples/golden-chapters.tsv" "$OUT/chapters.tsv" | head -20
    exit 1
fi

step "4.12/5 分页 golden 比对（--dump-pages 必须与基准逐字节一致）"
# 逐页的「页首偏移 / 覆盖字数 / 行数」是 Windows parity 的唯一自动化判据。
# 任何触碰排版（字体、行距、边距、标题字体…）的改动都必须跑这一步：
# 默认设置下这里变了，就说明老用户的阅读位置会整体错位。
"$BIN" --dump-pages "$ROOT/samples/古文观止.txt" >"$OUT/pages.tsv" 2>"$OUT/pages.log"
if diff -q "$ROOT/samples/golden-pages.tsv" "$OUT/pages.tsv" >/dev/null; then
    echo "  ✅ 分页与基准一致（$(($(wc -l <"$OUT/pages.tsv") - 1)) 页）· $(tail -1 "$OUT/pages.log")"
else
    echo "  ❌ 分页与基准不一致："
    diff "$ROOT/samples/golden-pages.tsv" "$OUT/pages.tsv" | head -20
    exit 1
fi

step "4.13/5 背景图片（拉伸 / 平铺 / 平铺翻转 / 文件缺失回落纯色）"
BG="$ROOT/samples/bg-tile.png"
for mode in 0 1 2; do
    "$BIN" --render-page "$ROOT/samples/古文观止.txt" "$OUT/page-bg-$mode.png" 0 \
        --bg-image "$BG" --bg-mode "$mode" >/dev/null 2>&1
done
# 文件缺失时必须回落纯色、正常出图（不弹窗、不崩）
set +e
"$BIN" --render-page "$ROOT/samples/古文观止.txt" "$OUT/page-bg-missing.png" 0 \
    --bg-image "$OUT/definitely-no-such-image.png" >/dev/null 2>&1
BG_CODE=$?
set -e
if [ "$BG_CODE" -ne 0 ]; then
    echo "  ❌ 背景图文件缺失时渲染失败（退出码 $BG_CODE）"; exit 1
fi
echo "  ✅ 三种铺法出图正常；文件缺失回落纯色且不崩"

step "4.14/5 快捷键自检（菜单键位 / 录制 / 冲突提示 / 切页与关窗状态 / 还原 / 文案全称）"
set +e
"$BIN" --shortcut-selftest >"$OUT/shortcut.log" 2>&1
SHORTCUT_CODE=$?
set -e
grep -E "✅|❌" "$OUT/shortcut.log" | sed 's/^/  /'
if [ "$SHORTCUT_CODE" -ne 0 ]; then
    echo "  ❌ 快捷键自检失败（退出码 $SHORTCUT_CODE）"; cat "$OUT/shortcut.log"; exit 1
fi

step "5/5 离屏渲染"
"$BIN" --render-page "$ROOT/samples/古文观止.txt" "$OUT/page.png" 2 2>&1 | tail -1
"$BIN" --dark --render-page "$ROOT/samples/古文观止.txt" "$OUT/page-dark.png" 2 2>&1 | tail -1
"$BIN" --render-page "$ROOT/samples/古文观止.txt" "$OUT/page-find.png" 0 --find "之" 2>&1 | tail -1
# 章节标题独立字体（M3）：同一页换标题字体各渲一张，肉眼对比用
"$BIN" --render-page "$ROOT/samples/古文观止.txt" "$OUT/page-title-same.png" 0 2>&1 | tail -1
"$BIN" --render-page "$ROOT/samples/古文观止.txt" "$OUT/page-title-separate.png" 0 \
    --title-font "Songti SC" --title-size 26 2>&1 | tail -1
"$BIN" --render-library "$OUT/library.png" 2>&1 | tail -1
"$BIN" --render-settings "$OUT/settings.png" 2>&1 | tail -1
"$BIN" --render-bookmarks "$OUT/bookmarks.png" 2>&1 | tail -1
"$BIN" --render-chapter-search "$OUT/chapter-search.png" 2>&1 | tail -1
"$BIN" --render-find "$OUT/find.png" "之" 2>&1 | tail -1

echo
echo "✅ 全部通过。渲染产物在 $OUT/"

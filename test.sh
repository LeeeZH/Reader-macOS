#!/bin/bash
# 核心逻辑单测（不依赖 GUI / AppKit）
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/.build"
mkdir -p "$BUILD"
# Core + Layout + Views 都可单测（Views 需要 AppKit，命令行工具里也能跑）。
# 注意**不含** Sources/App，那里有 main.swift 的顶层代码。
SRC=()
while IFS= read -r f; do SRC+=("$f"); done < <(find "$ROOT/Sources/Core" "$ROOT/Sources/Layout" "$ROOT/Sources/Views" -name '*.swift' | sort)
swiftc -target arm64-apple-macos13.0 \
    -module-cache-path "$BUILD/modulecache" \
    -o "$BUILD/CoreTests" "${SRC[@]}" "$ROOT/Tests/main.swift"
exec "$BUILD/CoreTests"

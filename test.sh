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
# C 桥接（系统 zlib 的 raw inflate）——和 build.sh 保持一致
C_OBJ=()
while IFS= read -r f; do
    obj="$BUILD/$(basename "$f" .c).o"
    clang -O2 -arch arm64 -mmacosx-version-min=13.0 -c "$f" -o "$obj"
    C_OBJ+=("$obj")
done < <(find "$ROOT/Sources" -name '*.c' | sort)
swiftc -target arm64-apple-macos13.0 \
    -module-cache-path "$BUILD/modulecache" \
    -import-objc-header "$ROOT/Sources/Core/ReaderBridging.h" \
    -o "$BUILD/CoreTests" "${SRC[@]}" "${C_OBJ[@]}" "$ROOT/Tests/main.swift" -lz
exec "$BUILD/CoreTests"

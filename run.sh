#!/bin/bash
# 构建并运行。默认 open 启动；--console 则在终端前台运行（方便看崩溃日志）
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$ROOT/build.sh"
if [ "${1:-}" = "--console" ]; then
    exec "$ROOT/dist/Reader.app/Contents/MacOS/Reader"
fi
open "$ROOT/dist/Reader.app"

#!/bin/bash
# nanobot 一键重启脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================"
echo "   nanobot Docker 重启脚本"
echo "======================================"
echo ""

"$SCRIPT_DIR/stop.sh"
echo ""
"$SCRIPT_DIR/start.sh"

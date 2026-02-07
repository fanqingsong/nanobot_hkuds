#!/bin/bash
# nanobot 一键停止脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "======================================"
echo "   nanobot Docker 停止脚本"
echo "======================================"
echo ""

# 检查服务是否在运行
if ! docker compose ps | grep -q "nanobot"; then
    echo "⚠️  nanobot 服务未运行"
    exit 0
fi

echo "🛑 停止 nanobot 服务..."
docker compose down

echo ""
echo "======================================"
echo "   ✅ nanobot 已停止"
echo "======================================"
echo ""
echo "💡 提示:"
echo "   重新启动: bin/start.sh"
echo "   完全清理: bin/clean.sh (删除容器和镜像)"
echo ""

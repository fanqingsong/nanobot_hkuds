#!/bin/bash
# nanobot 完全清理脚本（删除容器和镜像）

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "======================================"
echo "   nanobot 清理脚本"
echo "======================================"
echo ""
echo "⚠️  此操作将删除 nanobot 容器和镜像"
echo "   配置文件 (~/.nanobot) 将保留"
echo ""
read -p "确认继续? (y/N) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ 已取消"
    exit 0
fi

echo "🛑 停止并删除容器..."
docker compose down --rmi all --volumes --remove-orphans

echo ""
echo "======================================"
echo "   ✅ 清理完成"
echo "======================================"
echo ""
echo "💡 提示:"
echo "   重新部署: bin/start.sh"
echo ""

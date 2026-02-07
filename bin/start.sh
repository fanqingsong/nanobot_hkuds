#!/bin/bash
# nanobot 一键启动脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "======================================"
echo "   nanobot Docker 启动脚本"
echo "======================================"
echo ""

# 构建镜像（如果不存在）
if ! docker image inspect nanobot:latest &>/dev/null; then
    echo "📦 Docker 镜像不存在，开始构建..."
    echo "   使用华为云镜像加速..."
    docker compose build
else
    echo "✅ Docker 镜像已存在"
fi

# 检查配置目录是否存在
if [ ! -d "$HOME/.nanobot" ]; then
    echo ""
    echo "⚠️  配置目录不存在，正在初始化..."
    docker run -v "$HOME/.nanobot:/root/.nanobot" --rm nanobot onboard
    echo ""
    echo "✅ 配置已初始化，请编辑 ~/.nanobot/config.json 添加 API Keys"
    echo "   编辑完成后按任意键继续..."
    read -n 1 -s
fi

echo ""
echo "🚀 启动 nanobot 服务..."
docker compose up -d

echo ""
echo "======================================"
echo "   ✅ nanobot 启动成功！"
echo "======================================"
echo ""
echo "📊 查看日志: docker compose logs -f"
echo "🛑 停止服务: bin/stop.sh"
echo "📝 查看状态: docker compose ps"
echo ""

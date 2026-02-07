# 使用华为云镜像加速 - Python 3.12 slim 基础镜像
FROM swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/library/python:3.12-slim

# 设置工作目录
WORKDIR /app

# 安装 Node.js 20 (使用华为云镜像加速)
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates gnupg git && \
    mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    apt-get purge -y gnupg && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

# 安装 uv 包管理器 (使用 pip + 华为云镜像源)
RUN pip install -i https://mirrors.huaweicloud.com/repository/pypi/simple uv

# Install Python dependencies first (cached layer)
# 配置使用华为云 PyPI 镜像源
COPY pyproject.toml README.md LICENSE ./
RUN mkdir -p nanobot bridge && touch nanobot/__init__.py && \
    uv pip install --system --no-cache . --index-url https://mirrors.huaweicloud.com/repository/pypi/simple && \
    rm -rf nanobot bridge

# Copy the full source and install (使用华为云镜像源)
COPY nanobot/ nanobot/
COPY bridge/ bridge/
RUN uv pip install --system --no-cache . --index-url https://mirrors.huaweicloud.com/repository/pypi/simple

# Build the WhatsApp bridge (使用华为云 npm 镜像加速)
WORKDIR /app/bridge
RUN npm config set registry https://mirrors.huaweicloud.com/repository/npm/ && \
    npm install && npm run build
WORKDIR /app

# Create config directory
RUN mkdir -p /root/.nanobot

# Gateway default port
EXPOSE 18790

ENTRYPOINT ["nanobot"]
CMD ["status"]

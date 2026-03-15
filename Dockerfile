# 主镜像（前端 bridge 暂时跳过，网络受限时可先在宿主机 cd bridge && yarn install && yarn build 再恢复多阶段构建）
FROM swr.cn-north-4.myhuaweicloud.com/ddn-k8s/docker.io/library/python:3.12-slim
WORKDIR /app
RUN pip install -i https://mirrors.huaweicloud.com/repository/pypi/simple uv
COPY pyproject.toml README.md LICENSE ./
RUN mkdir -p nanobot bridge && touch nanobot/__init__.py && \
    uv pip install --system --no-cache ".[feishu]" --index-url https://mirrors.huaweicloud.com/repository/pypi/simple && \
    rm -rf nanobot bridge
COPY nanobot/ nanobot/
COPY bridge/ bridge/
RUN uv pip install --system --no-cache ".[feishu]" --index-url https://mirrors.huaweicloud.com/repository/pypi/simple

# Create config directory
RUN mkdir -p /root/.nanobot

# Gateway default port
EXPOSE 18790

ENTRYPOINT ["nanobot"]
CMD ["status"]

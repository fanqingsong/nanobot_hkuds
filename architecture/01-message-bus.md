# 消息总线层设计

## 概述

消息总线层（Message Bus Layer）是 nanobot 架构的核心组件，负责实现聊天通道（Channels）与 Agent 核心（Agent Core）之间的完全解耦。通过异步队列机制，实现生产者-消费者模式的消息传递。

## 核心文件

```
nanobot/bus/
├── queue.py      # 异步消息队列实现
└── events.py     # 消息事件定义
```

## 架构设计

### 1. 消息流向

```
┌─────────────┐         ┌─────────────────────────────────┐         ┌─────────────┐
│  Channels   │────────>│      Message Bus Layer          │────────>│  Agent Core │
│  (Producer) │         │  ┌───────────────────────────┐  │         │  (Consumer) │
└─────────────┘         │  │  inbound: asyncio.Queue   │  │         └─────────────┘
                        │  └───────────────────────────┘  │
                        │  ┌───────────────────────────┐  │
                        │  │ outbound: asyncio.Queue  │  │
                        │  └───────────────────────────┘  │
                        └─────────────────────────────────┘
                               ▲                               │
                               └───────────────────────────────┘
```

### 2. 核心类设计

#### MessageBus ([`queue.py`](../nanobot/bus/queue.py:8))

```python
class MessageBus:
    """异步消息总线，实现 Channels 和 Agent 的解耦"""

    inbound: asyncio.Queue[InboundMessage]   # 入站消息队列
    outbound: asyncio.Queue[OutboundMessage] # 出站消息队列

    async def publish_inbound(msg: InboundMessage) -> None:
        """发布入站消息（Channel -> Agent）"""

    async def consume_inbound() -> InboundMessage:
        """消费入站消息（阻塞直到可用）"""

    async def publish_outbound(msg: OutboundMessage) -> None:
        """发布出站消息（Agent -> Channel）"""

    async def consume_outbound() -> OutboundMessage:
        """消费出站消息（阻塞直到可用）"""
```

**设计要点**：

1. **双向队列**：`inbound` 和 `outbound` 分别处理入站和出站消息
2. **异步非阻塞**：基于 `asyncio.Queue`，支持高并发
3. **类型安全**：使用泛型确保消息类型安全
4. **状态监控**：提供 `inbound_size` 和 `outbound_size` 属性

### 3. 消息类型定义

#### InboundMessage ([`events.py`](../nanobot/bus/events.py:9))

```python
@dataclass
class InboundMessage:
    """从聊天通道接收的消息"""

    channel: str                      # 通道名称（telegram/discord/...）
    sender_id: str                    # 发送者ID
    chat_id: str                      # 聊天ID
    content: str                      # 消息内容
    timestamp: datetime               # 时间戳
    media: list[str]                  # 媒体附件列表
    metadata: dict[str, Any]          # 通道特定的元数据
    session_key_override: str | None  # 会话键覆盖（用于线程作用域会话）

    @property
    def session_key(self) -> str:
        """生成会话键（默认：channel:chat_id）"""
        return self.session_key_override or f"{self.channel}:{self.chat_id}"
```

#### OutboundMessage ([`events.py`](../nanobot/bus/events.py:28))

```python
@dataclass
class OutboundMessage:
    """发送到聊天通道的消息"""

    channel: str                      # 目标通道
    chat_id: str                      # 目标聊天ID
    content: str                      # 消息内容
    reply_to: str | None              # 回复的消息ID
    media: list[str]                  # 媒体附件
    metadata: dict[str, Any]          # 通道特定的元数据
```

## 技术实现

### 1. 异步队列机制

```python
import asyncio

class MessageBus:
    def __init__(self):
        # 创建无界队列（可根据需求改为有界队列）
        self.inbound = asyncio.Queue()
        self.outbound = asyncio.Queue()

    async def publish_inbound(self, msg: InboundMessage) -> None:
        """非阻塞发布消息"""
        await self.inbound.put(msg)

    async def consume_inbound(self) -> InboundMessage:
        """阻塞等待消息"""
        return await self.inbound.get()
```

**特性**：
- **协程安全**：`asyncio.Queue` 内部使用锁和事件，保证线程安全
- **无界队列**：默认无界，可避免阻塞（也可改为有界队列实现背压）
- **高效调度**：基于事件循环，避免线程切换开销

### 2. 使用模式

#### Channel 侧（生产者）

```python
class TelegramChannel(BaseChannel):
    async def _on_message_received(self, update):
        msg = InboundMessage(
            channel="telegram",
            sender_id=str(update.message.from_user.id),
            chat_id=str(update.message.chat_id),
            content=update.message.text,
        )
        await self.bus.publish_inbound(msg)
```

#### Agent 侧（消费者）

```python
class AgentLoop:
    async def run(self):
        while self._running:
            # 阻塞等待消息（带超时）
            try:
                msg = await asyncio.wait_for(
                    self.bus.consume_inbound(),
                    timeout=1.0
                )
            except asyncio.TimeoutError:
                continue

            # 处理消息
            await self._process_message(msg)
```

#### 通道管理器（出站消费者）

```python
class ChannelManager:
    async def _dispatch_outbound(self):
        """分发出站消息到相应通道"""
        while True:
            try:
                msg = await asyncio.wait_for(
                    self.bus.consume_outbound(),
                    timeout=1.0
                )
            except asyncio.TimeoutError:
                continue

            channel = self.channels.get(msg.channel)
            if channel:
                await channel.send(msg)
```

## 设计优势

### 1. 完全解耦

- **通道独立**：Channel 不需要知道 Agent 的存在
- **Agent 独立**：Agent 不需要知道 Channel 的实现
- **易于测试**：可以轻松模拟消息总线进行单元测试

### 2. 高并发支持

- **异步处理**：基于协程，支持大量并发连接
- **非阻塞**：Channel 和 Agent 可以并行运行
- **流量缓冲**：队列自动缓冲消息峰值

### 3. 灵活扩展

- **多通道支持**：可以轻松添加新的 Channel
- **多消费者**：可以有多个 Agent 消费同一队列（未来扩展）
- **消息过滤**：可以在总线层面添加消息路由/过滤逻辑

### 4. 可观测性

```python
class MessageBus:
    @property
    def inbound_size(self) -> int:
        """入站队列大小（监控用）"""
        return self.inbound.qsize()

    @property
    def outbound_size(self) -> int:
        """出站队列大小（监控用）"""
        return self.outbound.qsize()
```

## 性能考虑

### 1. 内存管理

- **无界队列风险**：消息积压可能导致内存溢出
- **解决方案**：可实现有界队列 + 背压机制

```python
# 有界队列示例
self.inbound = asyncio.Queue(maxsize=1000)

async def publish_inbound(self, msg: InboundMessage) -> None:
    """队列满时阻塞"""
    await self.inbound.put(msg)
```

### 2. 消息序列化

当前消息在内存中传递，无需序列化。如需跨进程/跨网络传输，可添加序列化层：

```python
import pickle

async def publish_inbound(self, msg: InboundMessage) -> None:
    """跨进程传输"""
    data = pickle.dumps(msg)
    await self.inbound.put(data)
```

## 扩展方向

### 1. 消息路由

```python
class RouterMessageBus(MessageBus):
    """支持按 channel/chat_id 路由的消息总线"""

    async def publish_inbound(self, msg: InboundMessage) -> None:
        # 根据路由规则分发
        if msg.channel == "telegram":
            await self.telegram_queue.put(msg)
        else:
            await self.general_queue.put(msg)
```

### 2. 消息过滤

```python
class FilterMessageBus(MessageBus):
    """支持消息过滤的消息总线"""

    def __init__(self, filters: list[Callable]):
        self.filters = filters

    async def publish_inbound(self, msg: InboundMessage) -> None:
        # 应用过滤器
        for f in self.filters:
            if not f(msg):
                return  # 过滤掉
        await super().publish_inbound(msg)
```

### 3. 消息持久化

```python
class PersistentMessageBus(MessageBus):
    """支持消息持久化的消息总线"""

    async def publish_inbound(self, msg: InboundMessage) -> None:
        # 持久化到磁盘
        await self._persist(msg)
        await super().publish_inbound(msg)
```

## 总结

消息总线层是 nanobot 架构的基石，通过简洁的异步队列实现了：

✅ **解耦**：Channels 和 Agent 完全独立
✅ **高性能**：异步非阻塞，支持高并发
✅ **可扩展**：易于添加新通道和功能
✅ **可观测**：提供队列状态监控

这种设计使得 nanobot 能够轻松支持 10+ 种聊天通道，同时保持代码的简洁和可维护性。

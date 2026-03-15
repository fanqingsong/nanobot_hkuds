# 通道系统设计

## 概述

通道系统（Channels）负责连接各种聊天平台（Telegram、WhatsApp、Feishu 等），将平台特定的消息格式转换为统一的 `InboundMessage`，并将 Agent 的响应转换为平台特定的格式发送。

## 核心文件

```
nanobot/channels/
├── base.py       # 通道基类
├── manager.py    # 通道管理器
├── registry.py   # 通道注册表（自动发现）
├── telegram.py   # Telegram 实现
├── whatsapp.py   # WhatsApp 实现
├── feishu.py     # 飞书实现
├── discord.py    # Discord 实现
├── slack.py      # Slack 实现
├── email.py      # Email 实现
├── matrix.py     # Matrix 实现
├── qq.py         # QQ 实现
├── dingtalk.py   # 钉钉实现
└── mochat.py     # 微信企业版实现
```

## 架构设计

### 1. 通道架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Channel Manager                          │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Channel Registry (auto-discovery)                  │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
│  │ Telegram │  │ WhatsApp │  │ Feishu   │  │ Discord  │  │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘  │
└───────┼────────────┼────────────┼────────────┼──────────┘
        │            │            │            │
        └────────────┴────────────┴────────────┘
                            │
                    ┌───────▼────────┐
                    │  Message Bus   │
                    └────────────────┘
```

### 2. 核心类设计

#### BaseChannel ([`base.py`](../nanobot/channels/base.py:15))

```python
class BaseChannel(ABC):
    """聊天通道实现的抽象基类"""

    name: str = "base"                      # 通道名称
    display_name: str = "Base"              # 显示名称
    transcription_api_key: str = ""         # 音频转文字 API Key

    def __init__(self, config: Any, bus: MessageBus):
        self.config = config
        self.bus = bus
        self._running = False

    @abstractmethod
    async def start(self) -> None:
        """启动通道并开始监听消息"""

    @abstractmethod
    async def stop(self) -> None:
        """停止通道并清理资源"""

    @abstractmethod
    async def send(self, msg: OutboundMessage) -> None:
        """通过此通道发送消息"""

    def is_allowed(self, sender_id: str) -> bool:
        """检查 sender_id 是否被允许"""

    async def _handle_message(
        self,
        sender_id: str,
        chat_id: str,
        content: str,
        media: list[str] | None = None,
        metadata: dict[str, Any] | None = None,
        session_key: str | None = None,
    ) -> None:
        """处理来自聊天平台的入站消息"""
```

#### ChannelManager ([`manager.py`](../nanobot/channels/manager.py:15))

```python
class ChannelManager:
    """管理聊天通道并协调消息路由"""

    def __init__(self, config: Config, bus: MessageBus):
        self.config = config
        self.bus = bus
        self.channels: dict[str, BaseChannel] = {}
        self._dispatch_task: asyncio.Task | None = None

        self._init_channels()

    async def start_all(self) -> None:
        """启动所有通道和出站分发器"""

    async def stop_all(self) -> None:
        """停止所有通道和分发器"""
```

#### Channel Registry ([`registry.py`](../nanobot/channels/registry.py:15))

```python
def discover_channel_names() -> list[str]:
    """通过扫描包返回所有通道模块名称（零导入）"""
    import nanobot.channels as pkg

    return [
        name
        for _, name, ispkg in pkgutil.iter_modules(pkg.__path__)
        if name not in _INTERNAL and not ispkg
    ]

def load_channel_class(module_name: str) -> type[BaseChannel]:
    """导入 module_name 并返回第一个 BaseChannel 子类"""
    mod = importlib.import_module(f"nanobot.channels.{module_name}")
    for attr in dir(mod):
        obj = getattr(mod, attr)
        if isinstance(obj, type) and issubclass(obj, _Base) and obj is not _Base:
            return obj
    raise ImportError(f"No BaseChannel subclass in nanobot.channels.{module_name}")
```

## 核心功能

### 1. 通道自动发现 ([`manager.py`](../nanobot/channels/manager.py:33))

```python
def _init_channels(self) -> None:
    """通过 pkgutil 扫描初始化通道"""
    from nanobot.channels.registry import discover_channel_names, load_channel_class

    groq_key = self.config.providers.groq.api_key

    # 自动发现并加载通道
    for modname in discover_channel_names():
        section = getattr(self.config.channels, modname, None)
        if not section or not getattr(section, "enabled", False):
            continue

        try:
            cls = load_channel_class(modname)
            channel = cls(section, self.bus)
            channel.transcription_api_key = groq_key
            self.channels[modname] = channel
            logger.info("{} channel enabled", cls.display_name)
        except ImportError as e:
            logger.warning("{} channel not available: {}", modname, e)

    self._validate_allow_from()
```

**优势**：
- 无需硬编码通道列表
- 添加新通道无需修改管理器代码
- 支持可选依赖（某些通道可能未安装）

### 2. 通道生命周期

#### 启动流程 ([`manager.py`](../nanobot/channels/manager.py:69))

```python
async def start_all(self) -> None:
    """启动所有通道和出站分发器"""
    if not self.channels:
        logger.warning("No channels enabled")
        return

    # 1. 启动出站分发器
    self._dispatch_task = asyncio.create_task(self._dispatch_outbound())

    # 2. 启动所有通道
    tasks = []
    for name, channel in self.channels.items():
        logger.info("Starting {} channel...", name)
        tasks.append(asyncio.create_task(self._start_channel(name, channel)))

    # 3. 等待所有完成（它们应该永远运行）
    await asyncio.gather(*tasks, return_exceptions=True)

async def _start_channel(self, name: str, channel: BaseChannel) -> None:
    """启动通道并记录异常"""
    try:
        await channel.start()
    except Exception as e:
        logger.error("Failed to start channel {}: {}", name, e)
```

#### 停止流程 ([`manager.py`](../nanobot/channels/manager.py:87))

```python
async def stop_all(self) -> None:
    """停止所有通道和分发器"""
    logger.info("Stopping all channels...")

    # 1. 停止分发器
    if self._dispatch_task:
        self._dispatch_task.cancel()
        try:
            await self._dispatch_task
        except asyncio.CancelledError:
            pass

    # 2. 停止所有通道
    for name, channel in self.channels.items():
        try:
            await channel.stop()
            logger.info("Stopped {} channel", name)
        except Exception as e:
            logger.error("Error stopping {}: {}", name, e)
```

### 3. 出站消息分发 ([`manager.py`](../nanobot/channels/manager.py:107))

```python
async def _dispatch_outbound(self) -> None:
    """将出站消息分发到适当的通道"""
    logger.info("Outbound dispatcher started")

    while True:
        try:
            msg = await asyncio.wait_for(
                self.bus.consume_outbound(),
                timeout=1.0
            )

            # 检查是否应该发送此消息
            if msg.metadata.get("_progress"):
                if msg.metadata.get("_tool_hint") and not self.config.channels.send_tool_hints:
                    continue
                if not msg.metadata.get("_tool_hint") and not self.config.channels.send_progress:
                    continue

            # 分发到相应通道
            channel = self.channels.get(msg.channel)
            if channel:
                try:
                    logger.info(f"Dispatching outbound to channel={msg.channel} chat_id={msg.chat_id}")
                    await channel.send(msg)
                except Exception as e:
                    logger.error("Error sending to {}: {}", msg.channel, e)
            else:
                logger.warning("Unknown channel: {}", msg.channel)

        except asyncio.TimeoutError:
            continue
        except asyncio.CancelledError:
            break
```

**特性**：
- 支持进度消息过滤
- 错误隔离（一个通道失败不影响其他）
- 优雅的通道缺失处理

### 4. 权限控制 ([`base.py`](../nanobot/channels/base.py:79))

```python
def is_allowed(self, sender_id: str) -> bool:
    """检查 sender_id 是否被允许"""
    allow_list = getattr(self.config, "allow_from", [])

    # 空列表 = 拒绝所有
    if not allow_list:
        logger.warning("{}: allow_from is empty — all access denied", self.name)
        return False

    # "*" = 允许所有
    if "*" in allow_list:
        return True

    # 检查是否在列表中
    sender_str = str(sender_id)
    if sender_str in allow_list:
        return True

    # 支持复合 ID（如 "user|channel"）
    if "|" in sender_str:
        for part in sender_str.split("|"):
            if part and part in allow_list:
                return True

    return False
```

**安全特性**：
- 默认拒绝（空列表）
- 显式允许所有（`["*"]`）
- 支持复合 ID 匹配

## 通道实现示例

### Telegram 通道

```python
class TelegramChannel(BaseChannel):
    """Telegram 通道实现"""

    name = "telegram"
    display_name = "Telegram"

    def __init__(self, config: TelegramConfig, bus: MessageBus):
        super().__init__(config, bus)
        self.bot = telegram.Bot(token=config.token)
        self.proxy = config.proxy

    async def start(self):
        """启动 Telegram 长轮询"""
        self._running = True

        async with self.bot:
            await self.bot.start()

    async def _on_message(self, update: telegram.Update):
        """处理 Telegram 更新"""
        if not update.message:
            return

        await self._handle_message(
            sender_id=update.message.from_user.id,
            chat_id=update.message.chat_id,
            content=update.message.text,
            media=[...],
        )

    async def send(self, msg: OutboundMessage):
        """发送消息到 Telegram"""
        await self.bot.send_message(
            chat_id=msg.chat_id,
            text=msg.content,
            reply_to_message_id=msg.reply_to,
        )
```

### Feishu 通道

```python
class FeishuChannel(BaseChannel):
    """飞书通道实现（WebSocket 长连接）"""

    name = "feishu"
    display_name = "Feishu/Lark"

    async def start(self):
        """启动 WebSocket 长连接"""
        self._running = True

        # 建立 WebSocket 连接
        async with aiohttp.ClientSession() as session:
            async with session.ws_connect(self.ws_url) as ws:
                while self._running:
                    msg = await ws.receive()
                    await self._handle_event(json.loads(msg.data))

    async def send(self, msg: OutboundMessage):
        """发送消息到飞书"""
        await self.client.post("/api/v1/bot/send", json={
            "chat_id": msg.chat_id,
            "msg_type": "text",
            "content": {"text": msg.content},
        })
```

## 配置模式

### 通用配置结构

```python
class TelegramConfig(Base):
    enabled: bool = False
    token: str = ""                          # Bot Token
    allow_from: list[str] = []               # 允许的用户 ID
    proxy: str | None = None                 # HTTP/SOCKS5 代理
    reply_to_message: bool = False           # 是否回复原消息
    group_policy: Literal["open", "mention"] = "mention"  # 群组策略
```

### 配置文件示例

```json
{
  "channels": {
    "telegram": {
      "enabled": true,
      "token": "123456:ABC-DEF...",
      "allowFrom": ["*"],
      "proxy": "http://127.0.0.1:7890"
    },
    "feishu": {
      "enabled": true,
      "appId": "cli_xxx",
      "appSecret": "xxx",
      "allowFrom": ["ou_xxx"]
    }
  }
}
```

## 特殊功能

### 1. 音频转文字

```python
async def transcribe_audio(self, file_path: str | Path) -> str:
    """通过 Groq Whisper 转录音频文件"""
    if not self.transcription_api_key:
        return ""

    try:
        from nanobot.providers.transcription import GroqTranscriptionProvider

        provider = GroqTranscriptionProvider(api_key=self.transcription_api_key)
        return await provider.transcribe(file_path)
    except Exception as e:
        logger.warning("{}: audio transcription failed: {}", self.name, e)
        return ""
```

**支持**：
- Telegram 语音消息
- WhatsApp 音频
- 飞书语音

### 2. 群组策略

```python
class TelegramConfig(Base):
    group_policy: Literal["open", "mention"] = "mention"
```

- `open`：响应所有消息
- `mention`：只在 @bot 或回复时响应

### 3. 媒体处理

不同通道对媒体的支持不同：

| 通道 | 图片 | 文件 | 音频 | 视频 |
|------|------|------|------|------|
| Telegram | ✅ | ✅ | ✅ | ✅ |
| WhatsApp | ✅ | ✅ | ✅ | ✅ |
| Feishu | ✅ | ✅ | ✅ | ❌ |
| Discord | ✅ | ✅ | ✅ | ✅ |

## 扩展新通道

### 步骤 1：创建通道类

```python
# nanobot/channels/myplatform.py
from nanobot.channels.base import BaseChannel
from nanobot.bus.events import OutboundMessage

class MyPlatformChannel(BaseChannel):
    name = "myplatform"
    display_name = "My Platform"

    async def start(self):
        """连接并监听消息"""
        # 实现连接逻辑
        pass

    async def stop(self):
        """断开连接"""
        # 实现断开逻辑
        pass

    async def send(self, msg: OutboundMessage):
        """发送消息"""
        # 实现发送逻辑
        pass
```

### 步骤 2：添加配置类

```python
# nanobot/config/schema.py
class MyPlatformConfig(Base):
    enabled: bool = False
    apiKey: str = ""
    allowFrom: list[str] = Field(default_factory=list)
```

### 步骤 3：配置并启用

```json
{
  "channels": {
    "myplatform": {
      "enabled": true,
      "apiKey": "xxx",
      "allowFrom": ["*"]
    }
  }
}
```

## 总结

通道系统实现了：

✅ **统一接口**：所有平台使用相同的 API
✅ **自动发现**：通过插件模式自动发现新通道
✅ **权限控制**：灵活的访问控制列表
✅ **错误隔离**：单个通道失败不影响其他
✅ **异步支持**：全异步实现，高并发
✅ **扩展性**：轻松添加新平台

这种设计使得 nanobot 能够支持 10+ 种聊天平台，同时保持代码的简洁和可维护性。

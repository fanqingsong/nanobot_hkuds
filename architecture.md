# nanobot 系统架构设计文档

> nanobot 是一个超轻量级（约 14,000 行代码）的个人 AI 助手系统，采用**事件驱动 + 消息总线**的异步架构。

## 目录

- [系统架构概览](#系统架构概览)
- [核心架构层次](#核心架构层次)
- [核心组件详解](#核心组件详解)
- [技术栈总结](#技术栈总结)
- [架构优势](#架构优势)
- [关键设计模式](#关键设计模式)
- [代码结构](#代码结构)

---

## 系统架构概览

**nanobot** 的核心设计理念是：**极简内核 + 插件化扩展**。

相比 OpenClaw 等大型框架，nanobot 将核心代码压缩到 99% 更小（约 3,100 行 Agent 核心代码），同时保持了完整的 AI Agent 功能。

### 设计原则

1. **解耦优先**：通过消息总线实现各层完全解耦
2. **异步优先**：全链路异步，支持高并发处理
3. **插件化**：Channel、Provider、Tool 均支持热插拔
4. **极简主义**：只保留核心功能，避免过度设计

---

## 核心架构层次

```
┌─────────────────────────────────────────────────────────────┐
│                     Chat Channels Layer                     │
│  (Telegram/WhatsApp/Feishu/Discord/Slack/Email/QQ/Matrix)  │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                    Message Bus Layer                        │
│           (asyncio.Queue: inbound/outbound)                 │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                     Agent Core Layer                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  AgentLoop                                            │  │
│  │  - Context Building (history, memory, skills)         │  │
│  │  - LLM Interaction with Tools                         │  │
│  │  - Response Generation                               │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │  Tools   │  │ Memory   │  │Session   │  │ Subagent │   │
│  │ Registry │  │ Manager  │  │ Manager  │  │ Manager  │   │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘   │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                   Provider Layer                            │
│    (OpenAI/Anthropic/Azure/LiteLLM/Custom Provider)        │
└─────────────────────────────────────────────────────────────┘
```

### 数据流向

```
用户消息 → Channel → InboundQueue → AgentLoop → Provider → Tool Execution
                                                              ↓
用户 ← Channel ← OutboundQueue ← AgentLoop ← Provider ← Response
```

---

## 核心组件详解

### 1. 消息总线层 ([`bus/queue.py`](nanobot/bus/queue.py))

**职责**：解耦 Channels 和 Agent Core，提供异步消息传递

```python
class MessageBus:
    inbound: asyncio.Queue[InboundMessage]   # 入站消息队列
    outbound: asyncio.Queue[OutboundMessage] # 出站消息队列
```

**关键特性**：
- 基于 `asyncio.Queue` 实现生产者-消费者模式
- 支持并发读写，无阻塞
- 提供队列状态监控（`inbound_size`、`outbound_size`）

**消息类型**：
```python
@dataclass
class InboundMessage:
    channel: str      # 通道名称
    sender_id: str    # 发送者ID
    chat_id: str      # 聊天ID
    content: str      # 消息内容
    media: list | None = None  # 媒体附件
    metadata: dict | None = None  # 元数据

@dataclass
class OutboundMessage:
    channel: str
    chat_id: str
    content: str
    metadata: dict | None = None
```

---

### 2. Agent 循环引擎 ([`agent/loop.py`](nanobot/agent/loop.py:36))

**职责**：核心处理引擎，协调整个 Agent 的运行流程

#### 处理流程

```python
async def run(self):
    while self._running:
        msg = await self.bus.consume_inbound()
        # 1. 会话管理
        session = self.sessions.get_or_create(msg.session_key)

        # 2. 构建上下文（历史+记忆+技能）
        messages = self.context.build_messages(
            history=session.get_history(),
            current_message=msg.content,
            channel=msg.channel
        )

        # 3. Agent 循环（LLM + Tools）
        final_content, tools_used, all_msgs = await self._run_agent_loop(messages)

        # 4. 保存会话
        self._save_turn(session, all_msgs)

        # 5. 发送响应
        await self.bus.publish_outbound(OutboundMessage(...))
```

#### Agent 迭代循环

```python
async def _run_agent_loop(self, messages, max_iterations=40):
    while iteration < max_iterations:
        # 调用 LLM
        response = await self.provider.chat_with_retry(messages, tools)

        if response.has_tool_calls:
            # 执行工具调用
            for tool_call in response.tool_calls:
                result = await self.tools.execute(
                    tool_call.name,
                    tool_call.arguments
                )
                messages = add_tool_result(messages, result)
        else:
            # 返回最终响应
            final_content = response.content
            break
```

**关键特性**：
- **最大迭代限制**：防止无限工具调用循环
- **进度流式传输**：实时返回思考过程和工具提示
- **错误恢复**：重试机制 + 会话防污染
- **支持子代理**：可生成独立子 Agent 处理复杂任务

---

### 3. 通道管理器 ([`channels/manager.py`](nanobot/channels/manager.py:15))

**职责**：管理所有聊天通道的生命周期和消息路由

#### 插件化架构

```python
class ChannelManager:
    def _init_channels(self):
        # 自动发现并加载通道插件
        for modname in discover_channel_names():
            section = getattr(config.channels, modname, None)
            if section and section.enabled:
                cls = load_channel_class(modname)
                channel = cls(section, self.bus)
                self.channels[modname] = channel
```

#### 支持的通道

| 通道 | 实现方式 | 特点 |
|------|---------|------|
| **Telegram** | 长轮询 | 支持群组 @mention、代理 |
| **WhatsApp** | WebSocket Bridge | 通过独立 Bridge 服务 |
| **Feishu/Lark** | WebSocket | 支持富文本、表情反应 |
| **Discord** | WebSocket Gateway | 支持 Slash Command |
| **Slack** | WebSocket API | 支持线程隔离、文件发送 |
| **Email** | IMAP + SMTP | 异步收发邮件 |
| **Matrix** | Matrix SDK | 支持 E2EE 加密 |
| **QQ** | QQ 协议 | 支持群聊 |
| **DingTalk** | Stream 模式 | 企业级部署 |

#### 统一接口

```python
class BaseChannel(ABC):
    @abstractmethod
    async def start(self):
        """启动通道"""

    @abstractmethod
    async def send(self, msg: OutboundMessage):
        """发送消息"""

    @abstractmethod
    def is_running(self) -> bool:
        """检查运行状态"""
```

---

### 4. Provider 抽象层 ([`providers/base.py`](nanobot/providers/base.py:69))

**职责**：统一 LLM 提供商接口，支持多模型切换

#### 核心接口

```python
class LLMProvider(ABC):
    @abstractmethod
    async def chat(
        self,
        messages: list[dict],
        tools: list[dict],
        model: str
    ) -> LLMResponse:
        """调用 LLM 获取响应"""

    async def chat_with_retry(self, messages, tools, model):
        """带重试的聊天（处理限流、网络错误）"""
```

#### 响应格式

```python
@dataclass
class LLMResponse:
    content: str | None
    tool_calls: list[ToolCallRequest]
    finish_reason: str  # stop/length/error
    usage: dict[str, int]
    reasoning_content: str | None  # Kimi、DeepSeek-R1 思维链
    thinking_blocks: list[dict] | None  # Anthropic 扩展思考
```

#### 支持的 Provider

| Provider | 模型支持 | 特点 |
|----------|---------|------|
| **OpenAI** | GPT-4、GPT-3.5 | 原生支持 |
| **Anthropic** | Claude 系列 | 支持 Prompt Caching、扩展思考 |
| **Azure OpenAI** | GPT 系列 | 企业级部署 |
| **LiteLLM** | 100+ 模型 | 统一接口、支持 Qwen、DeepSeek 等 |
| **Custom** | 自定义 | 灵活扩展 |

---

### 5. 工具系统 ([`agent/tools/registry.py`](nanobot/agent/tools/registry.py:8))

**职责**：动态管理 Agent 可调用的工具

#### 工具注册

```python
class ToolRegistry:
    def __init__(self):
        self._tools: dict[str, Tool] = {}

    def register(self, tool: Tool):
        """注册工具"""
        self._tools[tool.name] = tool

    async def execute(self, name: str, params: dict) -> str:
        """执行工具"""
        tool = self._tools.get(name)
        # 参数验证
        params = tool.cast_params(params)
        errors = tool.validate_params(params)
        if errors:
            return f"Error: {errors}"

        result = await tool.execute(**params)
        return result
```

#### 内置工具

| 工具 | 功能 | 配置 |
|------|------|------|
| **read_file** | 读取文件 | 支持工作区限制 |
| **write_file** | 写入文件 | 自动创建目录 |
| **edit_file** | 编辑文件 | 精确替换 |
| **list_dir** | 列出目录 | 递归支持 |
| **exec** | Shell 命令 | 超时控制、沙箱 |
| **web_search** | 网页搜索 | 多 Provider（Tavily、Bing、DuckDuckGo） |
| **web_fetch** | 网页抓取 | Markdown 渲染 |
| **message** | 跨通道发送 | 支持回复、线程 |
| **cron** | 定时任务 | 自然语言设置 |
| **spawn** | 子代理 | 独立上下文 |

#### MCP 集成

支持 **Model Context Protocol**，可动态加载外部工具服务器：

```python
await connect_mcp_servers(
    {"filesystem": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", str(workspace)]}},
    tools,
    stack
)
```

---

### 6. 会话与记忆管理

**职责**：管理用户会话状态和长期记忆

#### Session Manager

```python
class Session:
    key: str           # "telegram:123456"
    messages: list[dict]  # 对话历史
    created_at: datetime
    updated_at: datetime

class SessionManager:
    def get_or_create(self, key: str) -> Session:
        """获取或创建会话"""

    def save(self, session: Session):
        """持久化到磁盘"""
```

#### Memory Consolidator

智能压缩历史，防止超出上下文窗口：

```python
class MemoryConsolidator:
    async def maybe_consolidate_by_tokens(self, session: Session):
        """当历史过长时，用 LLM 压缩成摘要"""
        if estimated_tokens > self.context_window * 0.8:
            summary = await self.provider.chat([
                {"role": "system", "content": "Summarize this conversation"},
                *messages
            ])
            # 保存摘要到长期记忆，清空短期历史
```

---

### 7. 子代理系统 ([`agent/subagent.py`](nanobot/agent/subagent.py))

**职责**：处理复杂的多步骤任务

```python
class SubagentManager:
    async def spawn(
        self,
        prompt: str,
        session_key: str
    ) -> str:
        """生成独立子 Agent"""
        subagent = AgentLoop(...)
        result = await subagent.process_direct(
            prompt,
            session_key=session_key
        )
        return result
```

**特性**：
- 独立上下文，不污染主会话
- 支持并行执行
- 可按会话批量取消

---

## 技术栈总结

| 层次 | 技术选择 | 说明 |
|------|---------|------|
| **语言** | Python 3.11+ | 使用现代 Python 特性 |
| **异步框架** | asyncio | 全链路异步，高并发 |
| **配置管理** | Pydantic + pydantic-settings | 类型安全、环境变量支持 |
| **CLI** | Typer + prompt_toolkit + Rich | 美观的交互式终端 |
| **日志** | Loguru | 结构化日志、异常追踪 |
| **HTTP/WebSocket** | httpx（同步）、aiohttp（异步） | 高性能网络库 |
| **LLM SDK** | 原生 OpenAI/Anthropic SDK + LiteLLM | 多 Provider 支持 |

---

## 架构优势

### 1. 超轻量
- 核心 Agent 仅 **~3,100 行**代码
- 总代码量 **~14,000 行**（含所有通道和 Provider）
- 启动速度快，资源占用低

### 2. 高度解耦
- **消息总线**实现 Channels 和 Agent 完全解耦
- 各层可独立开发和测试
- 易于替换和升级组件

### 3. 可扩展性强
- **新增 Channel**：继承 `BaseChannel`（2 步）
- **新增 Provider**：继承 `LLMProvider`（2 步）
- **新增 Tool**：继承 `Tool` 并注册

### 4. 异步高性能
- 全链路异步，支持高并发处理
- 非阻塞 I/O，资源利用率高
- 支持流式响应，用户体验好

### 5. 跨平台支持
- 支持 Windows/Linux/macOS
- Docker 部署
- Linux Systemd 服务

### 6. 研究友好
- 代码清晰简洁，易于理解
- 模块化设计，便于修改和实验
- 完整的类型注解和文档

---

## 关键设计模式

### 1. 观察者模式
**应用**：消息总线的事件分发
```python
# Channels 发布事件
await bus.publish_inbound(InboundMessage(...))

# Agent 订阅并处理
msg = await bus.consume_inbound()
```

### 2. 策略模式
**应用**：Provider 抽象层
```python
# 不同 Provider 有不同的 chat 策略
provider = OpenAIProvider()  # 或 AnthropicProvider
response = await provider.chat(messages, tools)
```

### 3. 插件模式
**应用**：Channel 和 Tool 的动态发现
```python
# 自动发现并加载插件
for modname in discover_channel_names():
    cls = load_channel_class(modname)
    channel = cls(config, bus)
```

### 4. 单例模式
**应用**：全局管理器
```python
# Session 和 ToolRegistry 使用单例
session = session_manager.get_or_create(key)
```

### 5. 建造者模式
**应用**：ContextBuilder 构建消息上下文
```python
messages = context.build_messages(
    history=history,
    current_message=msg,
    channel=channel
)
```

### 6. 工厂模式
**应用**：动态创建 Provider 和 Channel
```python
provider = provider_factory.create(config)
channel = channel_factory.create(name, config, bus)
```

---

## 代码结构

```
nanobot/
├── agent/                 # Agent 核心模块
│   ├── loop.py           # Agent 循环引擎 (~500 行)
│   ├── context.py        # 上下文构建器
│   ├── memory.py         # 记忆管理
│   ├── subagent.py       # 子代理管理
│   └── tools/            # 工具系统
│       ├── registry.py   # 工具注册表
│       ├── base.py       # 工具基类
│       ├── filesystem.py # 文件系统工具
│       ├── shell.py      # Shell 执行工具
│       ├── web.py        # Web 搜索/抓取工具
│       ├── message.py    # 跨通道消息工具
│       ├── cron.py       # 定时任务工具
│       ├── spawn.py      # 子代理工具
│       └── mcp.py        # MCP 集成
│
├── channels/             # 聊天通道
│   ├── manager.py        # 通道管理器
│   ├── base.py           # 通道基类
│   ├── registry.py       # 通道注册表
│   ├── telegram.py       # Telegram
│   ├── whatsapp.py       # WhatsApp
│   ├── feishu.py         # 飞书
│   ├── discord.py        # Discord
│   ├── slack.py          # Slack
│   ├── email.py          # Email
│   ├── matrix.py         # Matrix
│   ├── qq.py             # QQ
│   ├── dingtalk.py       # 钉钉
│   └── mochat.py         # 微信
│
├── providers/            # LLM 提供商
│   ├── base.py           # Provider 基类
│   ├── registry.py       # Provider 注册表
│   ├── openai_provider.py
│   ├── anthropic_provider.py
│   ├── azure_openai_provider.py
│   ├── litellm_provider.py
│   └── custom_provider.py
│
├── bus/                  # 消息总线
│   ├── queue.py          # 异步消息队列
│   └── events.py         # 消息事件定义
│
├── session/              # 会话管理
│   └── manager.py        # Session 管理器
│
├── config/               # 配置管理
│   ├── schema.py         # Pydantic 配置模型
│   ├── loader.py         # 配置加载器
│   └── paths.py          # 路径管理
│
├── cli/                  # 命令行界面
│   └── commands.py       # CLI 命令
│
├── cron/                 # 定时任务
│   ├── service.py        # Cron 服务
│   └── types.py          # 任务类型
│
├── heartbeat/            # 心跳检测
│   └── service.py        # 心跳服务
│
├── utils/                # 工具函数
│   └── helpers.py        # 辅助函数
│
└── skills/               # 技能系统
    └── README.md         # 技能文档
```

### 代码量统计

| 模块 | 行数 | 说明 |
|------|------|------|
| Agent Core | ~3,100 | 核心 Agent 逻辑 |
| Channels | ~3,500 | 所有聊天通道 |
| Providers | ~1,800 | LLM Provider |
| Tools | ~2,000 | 工具系统 |
| Config | ~1,200 | 配置管理 |
| CLI | ~1,000 | 命令行界面 |
| 其他 | ~1,800 | 辅助模块 |
| **总计** | **~14,400** | |

---

## 总结

**nanobot** 是一个精心设计的**微内核架构** AI Agent 系统：

- ✅ **极简内核**：核心功能精简到极致
- 🔌 **插件化**：高度可扩展的插件系统
- 🚀 **高性能**：全异步架构，支持高并发
- 🧩 **解耦设计**：各层独立，易于维护
- 📚 **研究友好**：代码清晰，适合二次开发

相比 OpenClaw 等大型框架，nanobot 用 99% 更少的代码实现了完整功能，是学习和研究 AI Agent 架构的优秀参考实现。

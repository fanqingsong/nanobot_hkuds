# Agent 循环引擎设计

## 概述

Agent 循环引擎（Agent Loop）是 nanobot 的核心处理引擎，负责协调消息处理、LLM 调用、工具执行和响应生成的完整流程。

## 核心文件

```
nanobot/agent/
├── loop.py        # Agent 循环引擎（~500 行）
├── context.py     # 上下文构建器
├── memory.py      # 记忆管理器
└── subagent.py    # 子代理管理器
```

## 架构设计

### 1. 核心流程

```
┌─────────────────────────────────────────────────────────────┐
│                    Agent Loop Engine                        │
│                                                              │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌───────┐ │
│  │ 接收消息  │ -> │ 构建上下文 │ -> │ LLM 调用 │ -> │ 工具执行│ │
│  └──────────┘    └──────────┘    └──────────┘    └───────┘ │
│       │                                              │       │
│       v                                              v       │
│   MessageBus                                    ToolRegistry │
│                                                              │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌───────┐ │
│  │ 会话管理  │ <- │ 记忆压缩  │ <- │ 响应生成 │ <- │ 迭代循环│ │
│  └──────────┘    └──────────┘    └──────────┘    └───────┘ │
└─────────────────────────────────────────────────────────────┘
```

### 2. 核心类设计

#### AgentLoop ([`loop.py`](../nanobot/agent/loop.py:36))

```python
class AgentLoop:
    """Agent 核心处理引擎"""

    def __init__(
        self,
        bus: MessageBus,                      # 消息总线
        provider: LLMProvider,                # LLM 提供商
        workspace: Path,                      # 工作空间
        model: str | None = None,             # 模型名称
        max_iterations: int = 40,             # 最大迭代次数
        context_window_tokens: int = 65_536,  # 上下文窗口
        web_search_config: WebSearchConfig,   # 网络搜索配置
        web_proxy: str | None,                # 网络代理
        exec_config: ExecToolConfig,          # 执行工具配置
        cron_service: CronService,            # 定时任务服务
        restrict_to_workspace: bool,          # 限制在工作空间
        session_manager: SessionManager,      # 会话管理器
        mcp_servers: dict,                    # MCP 服务器配置
        channels_config: ChannelsConfig,      # 通道配置
    ):
```

## 关键流程实现

### 1. 主循环 ([`loop.py`](../nanobot/agent/loop.py:250))

```python
async def run(self) -> None:
    """运行 Agent 循环，将消息作为任务分发以保持对 /stop 的响应"""
    self._running = True
    await self._connect_mcp()

    while self._running:
        try:
            # 从消息总线消费消息（带超时）
            msg = await asyncio.wait_for(
                self.bus.consume_inbound(),
                timeout=1.0
            )
        except asyncio.TimeoutError:
            continue

        # 处理特殊命令
        cmd = msg.content.strip().lower()
        if cmd == "/stop":
            await self._handle_stop(msg)
        elif cmd == "/restart":
            await self._handle_restart(msg)
        else:
            # 异步分发消息处理
            task = asyncio.create_task(self._dispatch(msg))
            self._active_tasks.setdefault(msg.session_key, []).append(task)
            task.add_done_callback(lambda t: self._cleanup_task(msg.session_key, t))
```

**设计要点**：

1. **超时机制**：1 秒超时，允许响应 /stop 命令
2. **异步分发**：每个消息独立任务，支持并发处理
3. **任务追踪**：按会话管理活跃任务，支持批量取消

### 2. 消息处理流程 ([`loop.py`](../nanobot/agent/loop.py:338))

```python
async def _process_message(
    self,
    msg: InboundMessage,
    session_key: str | None = None,
    on_progress: Callable | None = None,
) -> OutboundMessage | None:
    """处理单条入站消息并返回响应"""

    # 1. 获取或创建会话
    key = session_key or msg.session_key
    session = self.sessions.get_or_create(key)

    # 2. 处理斜杠命令
    cmd = msg.content.strip().lower()
    if cmd == "/new":
        # 清空会话
        session.clear()
        return OutboundMessage(content="New session started.")
    if cmd == "/help":
        return OutboundMessage(content=self._get_help_text())

    # 3. 记忆压缩（防止超出上下文窗口）
    await self.memory_consolidator.maybe_consolidate_by_tokens(session)

    # 4. 设置工具上下文（用于跨通道消息传递）
    self._set_tool_context(msg.channel, msg.chat_id, msg.metadata.get("message_id"))

    # 5. 构建初始消息（历史 + 当前消息）
    history = session.get_history(max_messages=0)
    initial_messages = self.context.build_messages(
        history=history,
        current_message=msg.content,
        media=msg.media,
        channel=msg.channel,
        chat_id=msg.chat_id,
    )

    # 6. 运行 Agent 循环
    final_content, tools_used, all_msgs = await self._run_agent_loop(
        initial_messages,
        on_progress=on_progress
    )

    # 7. 保存会话
    self._save_turn(session, all_msgs, skip=len(history))

    # 8. 再次记忆压缩
    await self.memory_consolidator.maybe_consolidate_by_tokens(session)

    return OutboundMessage(
        channel=msg.channel,
        chat_id=msg.chat_id,
        content=final_content
    )
```

### 3. Agent 迭代循环 ([`loop.py`](../nanobot/agent/loop.py:179))

```python
async def _run_agent_loop(
    self,
    initial_messages: list[dict],
    on_progress: Callable | None = None,
) -> tuple[str | None, list[str], list[dict]]:
    """运行 Agent 迭代循环"""

    messages = initial_messages
    iteration = 0
    final_content = None
    tools_used: list[str] = []

    while iteration < self.max_iterations:
        iteration += 1

        # 1. 获取工具定义
        tool_defs = self.tools.get_definitions()

        # 2. 调用 LLM
        response = await self.provider.chat_with_retry(
            messages=messages,
            tools=tool_defs,
            model=self.model,
        )

        # 3. 处理工具调用
        if response.has_tool_calls:
            # 发送进度更新
            if on_progress:
                await on_progress(self._tool_hint(response.tool_calls))

            # 添加助手指令到历史
            tool_call_dicts = [
                tc.to_openai_tool_call()
                for tc in response.tool_calls
            ]
            messages = self.context.add_assistant_message(
                messages,
                response.content,
                tool_call_dicts,
            )

            # 执行工具
            for tool_call in response.tool_calls:
                tools_used.append(tool_call.name)
                result = await self.tools.execute(
                    tool_call.name,
                    tool_call.arguments
                )
                messages = self.context.add_tool_result(
                    messages,
                    tool_call.id,
                    tool_call.name,
                    result
                )
        else:
            # 4. 返回最终响应
            messages = self.context.add_assistant_message(
                messages,
                response.content
            )
            final_content = response.content
            break

    # 最大迭代保护
    if final_content is None and iteration >= self.max_iterations:
        final_content = f"Max iterations ({self.max_iterations}) reached."

    return final_content, tools_used, messages
```

**设计要点**：

1. **迭代限制**：默认 40 次，防止无限循环
2. **工具调用**：LLM 决定调用哪些工具及参数
3. **错误恢复**：LLM 返回错误时不污染会话历史
4. **进度反馈**：支持流式返回思考过程

## 核心功能

### 1. 会话管理

```python
# 会话键生成
session_key = f"{channel}:{chat_id}"

# 获取或创建会话
session = self.sessions.get_or_create(session_key)

# 获取历史
history = session.get_history(max_messages=500)

# 保存当前轮次
self._save_turn(session, messages, skip=len(history))
```

### 2. 记忆压缩

```python
# 在处理前和处理后都进行记忆压缩
await self.memory_consolidator.maybe_consolidate_by_tokens(session)
```

**触发条件**：
- 估计 token 数超过上下文窗口的 80%
- 压缩策略：将旧消息摘要到 MEMORY.md

### 3. 工具上下文设置

```python
def _set_tool_context(self, channel: str, chat_id: str, message_id: str | None):
    """为需要路由信息的工具设置上下文"""
    for tool_name in ("message", "spawn", "cron"):
        tool = self.tools.get(tool_name)
        if hasattr(tool, "set_context"):
            tool.set_context(channel, chat_id, message_id)
```

**用途**：
- `message` 工具需要知道发送到哪个通道
- `spawn` 工具需要知道原始通道用于结果通知
- `cron` 工具需要知道设置定时任务的通道

### 4. 斜杠命令

| 命令 | 功能 |
|------|------|
| `/new` | 开始新会话（清空历史） |
| `/stop` | 停止当前会话的所有任务 |
| `/restart` | 重启 Bot |
| `/help` | 显示帮助信息 |

### 5. 任务管理

```python
# 追踪活跃任务
self._active_tasks: dict[str, list[asyncio.Task]] = {}

# 停止命令
async def _handle_stop(self, msg: InboundMessage):
    """取消会话的所有任务和子代理"""
    tasks = self._active_tasks.pop(msg.session_key, [])
    for task in tasks:
        task.cancel()

    sub_cancelled = await self.subagents.cancel_by_session(msg.session_key)

    content = f"Stopped {len(tasks) + sub_cancelled} task(s)."
    await self.bus.publish_outbound(OutboundMessage(
        channel=msg.channel,
        chat_id=msg.chat_id,
        content=content
    ))
```

## 性能优化

### 1. 异步分发

```python
# 每个消息独立任务，支持并发
task = asyncio.create_task(self._dispatch(msg))
```

**优势**：
- 多个会话可并发处理
- 不会阻塞主循环

### 2. MCP 延迟连接

```python
async def _connect_mcp(self) -> None:
    """懒加载 MCP 服务器连接"""
    if self._mcp_connected or not self._mcp_servers:
        return

    self._mcp_connecting = True
    try:
        await connect_mcp_servers(self._mcp_servers, self.tools, self._mcp_stack)
        self._mcp_connected = True
    finally:
        self._mcp_connecting = False
```

**优势**：
- 首次需要时才连接
- 避免启动时间过长

### 3. 工具结果截断

```python
_TOOL_RESULT_MAX_CHARS = 16_000

def _save_turn(self, session: Session, messages: list[dict], skip: int):
    """保存新轮次消息，截断大型工具结果"""
    for m in messages[skip:]:
        if role == "tool" and len(content) > self._TOOL_RESULT_MAX_CHARS:
            entry["content"] = content[:self._TOOL_RESULT_MAX_CHARS] + "\n... (truncated)"
```

**优势**：
- 防止单个工具结果占用过多 token
- 保持上下文可控

## 错误处理

### 1. LLM 错误

```python
if response.finish_reason == "error":
    logger.error("LLM returned error: {}", response.content[:200])
    final_content = "Sorry, I encountered an error."
    break
```

**策略**：
- 不保存错误响应到历史
- 防止错误污染会话

### 2. 工具执行错误

```python
try:
    result = await self.tools.execute(tool_call.name, tool_call.arguments)
except Exception as e:
    result = f"Error: {str(e)}\n\n[Analyze the error and try a different approach.]"
```

**策略**：
- 捕获异常并返回给 LLM
- 引导 LLM 尝试不同方法

### 3. 消息处理错误

```python
try:
    response = await self._process_message(msg)
    if response:
        await self.bus.publish_outbound(response)
except asyncio.CancelledError:
    raise
except Exception:
    logger.exception("Error processing message")
    await self.bus.publish_outbound(OutboundMessage(
        content="Sorry, I encountered an error."
    ))
```

**策略**：
- 捕获所有异常
- 返回友好错误消息
- 记录详细日志

## 扩展点

### 1. 自定义工具

```python
# 在初始化时注册自定义工具
self.tools.register(MyCustomTool())
```

### 2. 自定义记忆策略

```python
# 替换记忆压缩器
self.memory_consolidator = CustomMemoryConsolidator(...)
```

### 3. 自定义子代理

```python
# 替换子代理管理器
self.subagents = CustomSubagentManager(...)
```

## 总结

Agent 循环引擎是 nanobot 的核心，实现了：

✅ **完整的 Agent 循环**：消息处理 -> LLM 调用 -> 工具执行 -> 响应生成
✅ **会话管理**：按 `channel:chat_id` 管理对话状态
✅ **记忆压缩**：智能压缩历史防止超出上下文窗口
✅ **任务管理**：支持并发处理和批量取消
✅ **错误恢复**：多层错误处理保证稳定性
✅ **进度反馈**：流式返回思考过程

这种设计使得 nanobot 能够提供流畅的 AI Agent 体验，同时保持代码的简洁和可维护性。

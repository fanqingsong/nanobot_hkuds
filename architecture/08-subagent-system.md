# 子代理系统设计

## 概述

子代理系统（Subagent System）允许 Agent 生成独立的子代理来处理复杂的多步骤任务，每个子代理拥有独立的上下文和工具执行环境。

## 核心文件

```
nanobot/agent/
└── subagent.py    # 子代理管理器（~230 行）
```

## 架构设计

### 1. 子代理架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Main Agent Loop                          │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Subagent Manager                                  │    │
│  │  ┌─────────────────────────────────────────────┐    │    │
│  │  │  spawn(task, label, session_key)            │    │    │
│  │  │  - 创建独立任务                             │    │    │
│  │  │  - 异步执行                                 │    │    │
│  │  │  - 结果通知                                 │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
│                           │                                  │
│         ┌─────────────────┼─────────────────┐               │
│         ▼                 ▼                 ▼               │
│  ┌──────────┐      ┌──────────┐      ┌──────────┐          │
│  │Subagent 1│      │Subagent 2│      │Subagent 3│          │
│  │- Task A  │      │- Task B  │      │- Task C  │          │
│  └────┬─────┘      └────┬─────┘      └────┬─────┘          │
│       │                 │                 │                 │
│       └─────────────────┴─────────────────┘                 │
│                           │                                  │
│                    ┌──────▼────────┐                        │
│                    │ Message Bus   │                        │
│                    │ (system msg)  │                        │
│                    └───────────────┘                        │
└─────────────────────────────────────────────────────────────┘
```

### 2. 核心类设计

#### SubagentManager ([`subagent.py`](../nanobot/agent/subagent.py:22))

```python
class SubagentManager:
    """管理后台子代理执行"""

    def __init__(
        self,
        provider: LLMProvider,
        workspace: Path,
        bus: MessageBus,
        model: str | None = None,
        web_search_config: WebSearchConfig | None = None,
        web_proxy: str | None = None,
        exec_config: ExecToolConfig | None = None,
        restrict_to_workspace: bool = False,
    ):
        self.provider = provider
        self.workspace = workspace
        self.bus = bus
        self.model = model or provider.get_default_model()
        self.web_search_config = web_search_config or WebSearchConfig()
        self.web_proxy = web_proxy
        self.exec_config = exec_config or ExecToolConfig()
        self.restrict_to_workspace = restrict_to_workspace

        # 任务追踪
        self._running_tasks: dict[str, asyncio.Task] = {}
        self._session_tasks: dict[str, set[str]] = {}  # session_key -> {task_id, ...}
```

## 核心功能

### 1. 生成子代理 ([`subagent.py`](../nanobot/agent/subagent.py:49))

```python
async def spawn(
    self,
    task: str,
    label: str | None = None,
    origin_channel: str = "cli",
    origin_chat_id: str = "direct",
    session_key: str | None = None,
) -> str:
    """生成子代理在后台执行任务"""
    # 1. 生成任务 ID
    task_id = str(uuid.uuid4())[:8]
    display_label = label or task[:30] + ("..." if len(task) > 30 else "")

    # 2. 记录原始通道（用于结果通知）
    origin = {"channel": origin_channel, "chat_id": origin_chat_id}

    # 3. 创建异步任务
    bg_task = asyncio.create_task(
        self._run_subagent(task_id, task, display_label, origin)
    )

    # 4. 追踪任务
    self._running_tasks[task_id] = bg_task
    if session_key:
        self._session_tasks.setdefault(session_key, set()).add(task_id)

    # 5. 添加清理回调
    def _cleanup(_: asyncio.Task) -> None:
        self._running_tasks.pop(task_id, None)
        if session_key and (ids := self._session_tasks.get(session_key)):
            ids.discard(task_id)
            if not ids:
                del self._session_tasks[session_key]

    bg_task.add_done_callback(_cleanup)

    logger.info("Spawned subagent [{}]: {}", task_id, display_label)
    return f"Subagent [{display_label}] started (id: {task_id}). I'll notify you when it completes."
```

### 2. 子代理执行 ([`subagent.py`](../nanobot/agent/subagent.py:81))

```python
async def _run_subagent(
    self,
    task_id: str,
    task: str,
    label: str,
    origin: dict[str, str],
) -> None:
    """执行子代理任务并宣布结果"""
    logger.info("Subagent [{}] starting task: {}", task_id, label)

    try:
        # 1. 构建子代理工具（不含 message 和 spawn 工具）
        tools = ToolRegistry()
        allowed_dir = self.workspace if self.restrict_to_workspace else None

        # 文件系统工具
        tools.register(ReadFileTool(workspace=self.workspace, allowed_dir=allowed_dir))
        tools.register(WriteFileTool(workspace=self.workspace, allowed_dir=allowed_dir))
        tools.register(EditFileTool(workspace=self.workspace, allowed_dir=allowed_dir))
        tools.register(ListDirTool(workspace=self.workspace, allowed_dir=allowed_dir))

        # Shell 工具
        tools.register(ExecTool(
            working_dir=str(self.workspace),
            timeout=self.exec_config.timeout,
            restrict_to_workspace=self.restrict_to_workspace,
            path_append=self.exec_config.path_append,
        ))

        # Web 工具
        tools.register(WebSearchTool(config=self.web_search_config, proxy=self.web_proxy))
        tools.register(WebFetchTool(proxy=self.web_proxy))

        # 2. 构建系统提示
        system_prompt = self._build_subagent_prompt()

        # 3. 构建初始消息
        messages: list[dict[str, Any]] = [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": task},
        ]

        # 4. 运行 Agent 循环（限制迭代次数）
        max_iterations = 15
        iteration = 0
        final_result: str | None = None

        while iteration < max_iterations:
            iteration += 1

            # 调用 LLM
            response = await self.provider.chat_with_retry(
                messages=messages,
                tools=tools.get_definitions(),
                model=self.model,
            )

            # 处理工具调用
            if response.has_tool_calls:
                tool_call_dicts = [
                    tc.to_openai_tool_call()
                    for tc in response.tool_calls
                ]
                messages.append(build_assistant_message(
                    response.content or "",
                    tool_calls=tool_call_dicts,
                ))

                # 执行工具
                for tool_call in response.tool_calls:
                    result = await tools.execute(tool_call.name, tool_call.arguments)
                    messages.append({
                        "role": "tool",
                        "tool_call_id": tool_call.id,
                        "name": tool_call.name,
                        "content": result,
                    })
            else:
                # 返回最终结果
                final_result = response.content
                break

        # 5. 处理完成
        if final_result is None:
            final_result = "Task completed but no final response was generated."

        logger.info("Subagent [{}] completed successfully", task_id)
        await self._announce_result(task_id, label, task, final_result, origin, "ok")

    except Exception as e:
        error_msg = f"Error: {str(e)}"
        logger.error("Subagent [{}] failed: {}", task_id, e)
        await self._announce_result(task_id, label, task, error_msg, origin, "error")
```

### 3. 结果通知 ([`subagent.py`](../nanobot/agent/subagent.py:166))

```python
async def _announce_result(
    self,
    task_id: str,
    label: str,
    task: str,
    result: str,
    origin: dict[str, str],
    status: str,
) -> None:
    """通过消息总线向主 Agent 宣布子代理结果"""
    status_text = "completed successfully" if status == "ok" else "failed"

    announce_content = f"""[Subagent '{label}' {status_text}]

Task: {task}

Result:
{result}

Summarize this naturally for the user. Keep it brief (1-2 sentences). Do not mention technical details like "subagent" or task IDs."""

    # 作为系统消息注入以触发主 Agent
    msg = InboundMessage(
        channel="system",
        sender_id="subagent",
        chat_id=f"{origin['channel']}:{origin['chat_id']}",
        content=announce_content,
    )

    await self.bus.publish_inbound(msg)
    logger.debug("Subagent [{}] announced result to {}:{}", task_id, origin['channel'], origin['chat_id'])
```

### 4. 子代理提示 ([`subagent.py`](../nanobot/agent/subagent.py:198))

```python
def _build_subagent_prompt(self) -> str:
    """为子代理构建专注的系统提示"""
    from nanobot.agent.context import ContextBuilder
    from nanobot.agent.skills import SkillsLoader

    time_ctx = ContextBuilder._build_runtime_context(None, None)
    parts = [f"""# Subagent

{time_ctx}

You are a subagent spawned by the main agent to complete a specific task.
Stay focused on the assigned task. Your final response will be reported back to the main agent.

## Workspace
{self.workspace}"""]

    # 添加技能摘要
    skills_summary = SkillsLoader(self.workspace).build_skills_summary()
    if skills_summary:
        parts.append(f"## Skills\n\nRead SKILL.md with read_file to use a skill.\n\n{skills_summary}")

    return "\n\n".join(parts)
```

## 任务管理

### 1. 按会话取消 ([`subagent.py`](../nanobot/agent/subagent.py:220))

```python
async def cancel_by_session(self, session_key: str) -> int:
    """取消给定会话的所有子代理（返回取消数量）"""
    tasks = [
        self._running_tasks[tid]
        for tid in self._session_tasks.get(session_key, [])
        if tid in self._running_tasks and not self._running_tasks[tid].done()
    ]

    # 取消所有任务
    for t in tasks:
        t.cancel()

    # 等待所有任务完成（取消）
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)

    return len(tasks)
```

### 2. 运行中计数 ([`subagent.py`](../nanobot/agent/subagent.py:230))

```python
def get_running_count(self) -> int:
    """返回当前运行的子代理数量"""
    return len(self._running_tasks)
```

## 设计特点

### 1. 独立上下文

```python
# 子代理有自己的工具和上下文
tools = ToolRegistry()
# 不包含 message 工具（防止无限递归）
# 不包含 spawn 工具（防止子代理生成子代理）
```

### 2. 有限迭代

```python
# 子代理限制迭代次数（默认 15 次）
max_iterations = 15
```

**原因**：
- 子代理任务应该相对简单
- 避免子代理消耗过多资源
- 主 Agent 可以处理复杂任务

### 3. 结果摘要

```python
# 结果通过主 Agent 摘要后返回给用户
announce_content = f"""[Subagent '{label}' {status_text}]

Task: {task}

Result:
{result}

Summarize this naturally for the user. Keep it brief (1-2 sentences)."""
```

**优势**：
- 用户看到自然语言摘要
- 隐藏技术细节（任务 ID、子代理等）
- 保持对话连贯性

### 4. 会话关联

```python
# 子代理与会话关联
if session_key:
    self._session_tasks.setdefault(session_key, set()).add(task_id)

# 支持批量取消
await self.subagents.cancel_by_session(session_key)
```

## 使用场景

### 1. 后台任务

```python
# 用户："下载这个大文件并分析"
# Agent：生成子代理处理
result = await subagents.spawn(
    task="Download https://example.com/large.zip and analyze the contents",
    label="Download and analyze",
    origin_channel="telegram",
    origin_chat_id=chat_id,
    session_key=session_key,
)
# 返回："Subagent [Download and analyze] started (id: abc123). I'll notify you when it completes."
```

### 2. 并行任务

```python
# 用户："同时检查这三个网站的状态"
# Agent：生成三个子代理
for url in urls:
    await subagents.spawn(
        task=f"Check status of {url}",
        label=f"Check {url}",
        session_key=session_key,
    )
```

### 3. 独立研究

```python
# 用户："研究一下这个主题并写个报告"
# Agent：生成子代理深入研究
result = await subagents.spawn(
    task="Research quantum computing applications in cryptography and write a detailed report",
    label="Quantum crypto research",
    session_key=session_key,
)
```

## 错误处理

### 1. 子代理失败

```python
except Exception as e:
    error_msg = f"Error: {str(e)}"
    logger.error("Subagent [{}] failed: {}", task_id, e)
    await self._announce_result(task_id, label, task, error_msg, origin, "error")
```

### 2. 任务完成但无响应

```python
if final_result is None:
    final_result = "Task completed but no final response was generated."
```

### 3. 最大迭代保护

```python
if final_result is None and iteration >= max_iterations:
    final_result = "Subagent reached max iterations without completing."
```

## 性能考虑

### 1. 异步执行

```python
# 子代理在后台异步运行
bg_task = asyncio.create_task(self._run_subagent(...))
```

**优势**：
- 不阻塞主 Agent
- 支持多个子代理并行运行
- 用户可以继续对话

### 2. 资源限制

```python
# 限制子代理迭代次数
max_iterations = 15  # vs 主 Agent 的 40 次
```

**原因**：
- 子代理任务应该相对简单
- 避免子代理消耗过多资源
- 防止子代理卡在复杂任务上

### 3. 任务追踪

```python
# 追踪所有运行中的任务
self._running_tasks: dict[str, asyncio.Task] = {}

# 按会话追踪
self._session_tasks: dict[str, set[str]] = {}
```

**优势**：
- 支持批量取消
- 监控任务状态
- 防止内存泄漏

## 总结

子代理系统实现了：

✅ **独立执行**：子代理有独立上下文和工具
✅ **异步处理**：不阻塞主 Agent
✅ **结果通知**：完成时自动通知
✅ **会话关联**：支持按会话管理
✅ **错误处理**：完善的异常处理
✅ **资源控制**：限制迭代次数和工具

这种设计使得 nanobot 能够处理复杂的后台任务，同时保持主 Agent 的响应性和稳定性。

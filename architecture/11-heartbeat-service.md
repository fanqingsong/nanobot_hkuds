# 心跳服务设计

## 概述

心跳服务（Heartbeat Service）负责定期唤醒 Agent 检查是否有待处理的任务，通过虚拟工具调用实现智能决策，避免不可靠的文本解析。

## 核心文件

```
nanobot/heartbeat/
└── service.py     # 心跳服务（~170 行）
```

## 架构设计

### 1. 心跳架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Heartbeat Service                        │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Periodic Loop                                      │    │
│  │  ┌─────────────────────────────────────────────┐    │    │
│  │  │  - 每 N 分钟触发一次                         │    │    │
│  │  │  - 读取 HEARTBEAT.md                          │    │    │
│  │  │  - 调用 LLM 决策                             │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
│                           │                                  │
│                           ▼                                  │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Decision Phase (Virtual Tool Call)                │    │
│  │  ┌─────────────────────────────────────────────┐    │    │
│  │  │  - LLM 分析 HEARTBEAT.md                     │    │    │
│  │  │  - 调用 heartbeat 工具                        │    │    │
│  │  │  - 返回 skip/run 决策                         │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
│                           │                                  │
│                           ▼                                  │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Execution Phase (if run)                          │    │
│  │  ┌─────────────────────────────────────────────┐    │    │
│  │  │  - 调用 on_execute 回调                      │    │    │
│  │  │  - 运行 Agent Loop                           │    │    │
│  │  │  - 获取响应                                  │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
│                           │                                  │
│                           ▼                                  │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Notification Phase                                │    │
│  │  ┌─────────────────────────────────────────────┐    │    │
│  │  │  - 调用 on_notify 回调                       │    │    │
│  │  │  - 发送响应到用户通道                        │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### 2. 核心类设计

#### HeartbeatService ([`service.py`](../nanobot/heartbeat/service.py:40))

```python
class HeartbeatService:
    """定期心跳服务，唤醒 Agent 检查任务"""

    def __init__(
        self,
        workspace: Path,
        provider: LLMProvider,
        model: str,
        on_execute: Callable[[str], Coroutine[Any, Any, str]] | None = None,
        on_notify: Callable[[str], Coroutine[Any, Any, None]] | None = None,
        interval_s: int = 30 * 60,  # 30 分钟
        enabled: bool = True,
    ):
        self.workspace = workspace
        self.provider = provider
        self.model = model
        self.on_execute = on_execute      # 执行回调
        self.on_notify = on_notify        # 通知回调
        self.interval_s = interval_s
        self.enabled = enabled
        self._running = False
        self._task: asyncio.Task | None = None

    @property
    def heartbeat_file(self) -> Path:
        return self.workspace / "HEARTBEAT.md"
```

## 核心功能

### 1. 启动服务 ([`service.py`](../nanobot/heartbeat/service.py:108))

```python
async def start(self) -> None:
    """启动心跳服务"""
    if not self.enabled:
        logger.info("Heartbeat disabled")
        return
    if self._running:
        logger.warning("Heartbeat already running")
        return

    self._running = True
    self._task = asyncio.create_task(self._run_loop())
    logger.info("Heartbeat started (every {}s)", self.interval_s)
```

### 2. 主循环 ([`service.py`](../nanobot/heartbeat/service.py:128))

```python
async def _run_loop(self) -> None:
    """主心跳循环"""
    while self._running:
        try:
            # 等待间隔时间
            await asyncio.sleep(self.interval_s)

            # 执行心跳检查
            if self._running:
                await self._tick()
        except asyncio.CancelledError:
            break
        except Exception as e:
            logger.error("Heartbeat error: {}", e)
```

### 3. 心跳检查 ([`service.py`](../nanobot/heartbeat/service.py:140))

```python
async def _tick(self) -> None:
    """执行单次心跳 tick"""
    # 1. 读取 HEARTBEAT.md
    content = self._read_heartbeat_file()
    if not content:
        logger.debug("Heartbeat: HEARTBEAT.md missing or empty")
        return

    logger.info("Heartbeat: checking for tasks...")

    try:
        # 2. 决策阶段
        action, tasks = await self._decide(content)

        if action != "run":
            logger.info("Heartbeat: OK (nothing to report)")
            return

        # 3. 执行阶段
        logger.info("Heartbeat: tasks found, executing...")
        if self.on_execute:
            response = await self.on_execute(tasks)

            # 4. 通知阶段
            if response and self.on_notify:
                logger.info("Heartbeat: completed, delivering response")
                await self.on_notify(response)
    except Exception:
        logger.exception("Heartbeat execution failed")
```

### 4. 决策阶段 ([`service.py`](../nanobot/heartbeat/service.py:85))

```python
async def _decide(self, content: str) -> tuple[str, str]:
    """阶段 1：通过虚拟工具调用让 LLM 决策 skip/run"""
    response = await self.provider.chat_with_retry(
        messages=[
            {
                "role": "system",
                "content": "You are a heartbeat agent. Call the heartbeat tool to report your decision."
            },
            {
                "role": "user",
                "content": (
                    "Review the following HEARTBEAT.md and decide whether there are active tasks.\n\n"
                    f"{content}"
                )
            },
        ],
        tools=_HEARTBEAT_TOOL,  # 虚拟工具
        model=self.model,
    )

    if not response.has_tool_calls:
        return "skip", ""

    # 解析工具调用
    args = response.tool_calls[0].arguments
    return args.get("action", "skip"), args.get("tasks", "")
```

### 5. 虚拟工具定义 ([`service.py`](../nanobot/heartbeat/service.py:14))

```python
_HEARTBEAT_TOOL = [
    {
        "type": "function",
        "function": {
            "name": "heartbeat",
            "description": "Report heartbeat decision after reviewing tasks.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": ["skip", "run"],
                        "description": "skip = nothing to do, run = has active tasks",
                    },
                    "tasks": {
                        "type": "string",
                        "description": "Natural-language summary of active tasks (required for run)",
                    },
                },
                "required": ["action"],
            },
        },
    }
]
```

## HEARTBEAT.md 格式

### 1. 基本格式

```markdown
# Heartbeat Tasks

## Daily Tasks

- [ ] Check system status
- [ ] Review logs
- [ ] Send daily report

## Reminders

- [ ] Meeting at 3 PM
- [ ] Call John at 5 PM

## Monitoring

- [ ] Check disk usage
- [ ] Review error logs
```

### 2. 有任务状态

```markdown
# Heartbeat Tasks

## Active

- [x] Deploy to production (done)
- [ ] Update documentation (in progress)

## Pending

- [ ] Review PR #123
- [ ] Fix bug in authentication
```

### 3. 空状态

```markdown
# Heartbeat Tasks

No active tasks. Everything is quiet.
```

## 回调集成

### 1. 执行回调

```python
async def on_execute(tasks: str) -> str:
    """执行任务并返回响应"""
    # 通过 Agent Loop 执行
    response = await agent_loop.process_direct(
        content=tasks,
        session_key="system:heartbeat",
    )
    return response
```

### 2. 通知回调

```python
async def on_notify(response: str) -> None:
    """通知用户"""
    # 发送到默认通道
    await bus.publish_outbound(OutboundMessage(
        channel="telegram",
        chat_id=default_chat_id,
        content=response,
    ))
```

## 使用场景

### 1. 定期检查

```markdown
# HEARTBEAT.md

## Daily Checks

- [ ] Check server status
- [ ] Review error logs
- [ ] Verify backups
```

**行为**：每次心跳检查这些任务，如果有未完成的，通过 Agent 处理。

### 2. 提醒系统

```markdown
# HEARTBEAT.md

## Reminders

- [ ] Team standup at 10 AM
- [ ] Submit weekly report by Friday
```

**行为**：心跳检查时间，如果是周五且未提交报告，提醒用户。

### 3. 监控告警

```markdown
# HEARTBEAT.md

## Monitoring

- [ ] Check disk usage (warn if > 80%)
- [ ] Review error logs (alert if > 10 errors/hour)
```

**行为**：心跳运行检查命令，如果超过阈值，生成告警。

### 4. 空状态

```markdown
# HEARTBEAT.md

All systems operational. No active tasks.
```

**行为**：心跳检测到没有任务，跳过执行。

## 设计优势

### 1. 虚拟工具调用

**旧方法**：文本解析
```python
# 不可靠的文本解析
if "HEARTBEAT_OK" in content:
    return "skip"
```

**新方法**：虚拟工具调用
```python
# LLM 通过工具调用决策
response = await provider.chat(messages, tools=_HEARTBEAT_TOOL)
action = response.tool_calls[0].arguments.get("action")
```

**优势**：
- 避免脆弱的文本解析
- LLM 理解上下文后决策
- 结构化返回结果

### 2. 两阶段执行

```
Phase 1: Decision (轻量)
  - 读取 HEARTBEAT.md
  - LLM 快速决策
  - 返回 skip/run

Phase 2: Execution (仅当 run)
  - 运行完整 Agent Loop
  - 处理复杂任务
  - 返回结果
```

**优势**：
- 无任务时快速返回
- 有任务时完整处理
- 避免 LLM 浪费

### 3. 灵活性

```markdown
# HEARTBEAT.md

## Complex Logic

If the database backup failed more than 3 times in the last hour:
- [ ] Alert the ops team
- [ ] Switch to backup database
- [ ] Create incident ticket
```

**优势**：
- 支持复杂逻辑
- 自然语言描述
- LLM 理解并执行

## 手动触发

```python
async def trigger_now(self) -> str | None:
    """手动触发心跳"""
    content = self._read_heartbeat_file()
    if not content:
        return None

    action, tasks = await self._decide(content)
    if action != "run" or not self.on_execute:
        return None

    return await self.on_execute(tasks)
```

**使用场景**：
- 测试心跳配置
- 立即执行待处理任务
- 调试心跳逻辑

## 总结

心跳服务实现了：

✅ **定期检查**：按间隔自动唤醒检查
✅ **智能决策**：通过 LLM 理解上下文
✅ **两阶段执行**：决策和执行分离
✅ **虚拟工具**：避免脆弱的文本解析
✅ **灵活配置**：通过 HEARTBEAT.md 配置
✅ **手动触发**：支持立即执行

这种设计使得 nanobot 能够主动检查和处理待办任务，而不是被动等待用户输入，实现了更智能的 Agent 行为。

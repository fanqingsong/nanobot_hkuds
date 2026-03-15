# 上下文构建器设计

## 概述

上下文构建器（Context Builder）负责为每次 LLM 调用构建完整的消息上下文，包括系统提示、历史消息、记忆、技能和运行时信息。

## 核心文件

```
nanobot/agent/
└── context.py    # 上下文构建器（~190 行）
```

## 架构设计

### 1. 上下文组成

```
┌─────────────────────────────────────────────────────────────┐
│                    LLM Message Context                      │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  System Prompt                                      │    │
│  │  - Identity (nanobot 🐈)                           │    │
│  │  - Runtime (OS, Python version)                    │    │
│  │  - Workspace path                                  │    │
│  │  - Platform policy                                 │    │
│  │  - Guidelines                                      │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Bootstrap Files (optional)                         │    │
│  │  - AGENTS.md                                        │    │
│  │  - SOUL.md                                          │    │
│  │  - USER.md                                          │    │
│  │  - TOOLS.md                                         │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Memory (optional)                                  │    │
│  │  - MEMORY.md content                                │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Active Skills (optional)                           │    │
│  │  - Skills marked as "always"                        │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Skills Summary                                     │    │
│  │  - Available skills list                            │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  History Messages                                   │    │
│  │  - Previous conversation turns                      │    │
│  └─────────────────────────────────────────────────────┘    │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Current User Message                               │    │
│  │  - Runtime context (time, channel, chat_id)         │    │
│  │  - User message text                                │    │
│  │  - Media attachments (base64 images)                │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### 2. 核心类设计

#### ContextBuilder ([`context.py`](../nanobot/agent/context.py:16))

```python
class ContextBuilder:
    """构建 Agent 的上下文（系统提示 + 消息）"""

    BOOTSTRAP_FILES = ["AGENTS.md", "SOUL.md", "USER.md", "TOOLS.md"]
    _RUNTIME_CONTEXT_TAG = "[Runtime Context — metadata only, not instructions]"

    def __init__(self, workspace: Path):
        self.workspace = workspace
        self.memory = MemoryStore(workspace)
        self.skills = SkillsLoader(workspace)
```

## 核心功能

### 1. 系统提示构建 ([`context.py`](../nanobot/agent/context.py:27))

```python
def build_system_prompt(self, skill_names: list[str] | None = None) -> str:
    """从身份、引导文件、记忆和技能构建系统提示"""
    parts = [self._get_identity()]

    # 1. 添加引导文件
    bootstrap = self._load_bootstrap_files()
    if bootstrap:
        parts.append(bootstrap)

    # 2. 添加记忆
    memory = self.memory.get_memory_context()
    if memory:
        parts.append(f"# Memory\n\n{memory}")

    # 3. 添加始终启用的技能
    always_skills = self.skills.get_always_skills()
    if always_skills:
        always_content = self.skills.load_skills_for_context(always_skills)
        if always_content:
            parts.append(f"# Active Skills\n\n{always_content}")

    # 4. 添加技能摘要
    skills_summary = self.skills.build_skills_summary()
    if skills_summary:
        parts.append(f"""# Skills

The following skills extend your capabilities. To use a skill, read its SKILL.md file using the read_file tool.
Skills with available="false" need dependencies installed first.

{skills_summary}""")

    return "\n\n---\n\n".join(parts)
```

#### 身份部分 ([`context.py`](../nanobot/agent/context.py:56))

```python
def _get_identity(self) -> str:
    """获取核心身份部分"""
    workspace_path = str(self.workspace.expanduser().resolve())
    system = platform.system()
    runtime = f"{'macOS' if system == 'Darwin' else system} {platform.machine()}, Python {platform.python_version()}"

    # 平台特定策略
    if system == "Windows":
        platform_policy = """## Platform Policy (Windows)
- You are running on Windows. Do not assume GNU tools like `grep`, `sed`, or `awk` exist.
- Prefer Windows-native commands or file tools when they are more reliable.
"""
    else:
        platform_policy = """## Platform Policy (POSIX)
- You are running on a POSIX system. Prefer UTF-8 and standard shell tools.
- Use file tools when they are simpler or more reliable than shell commands.
"""

    return f"""# nanobot 🐈

You are nanobot, a helpful AI assistant.

## Runtime
{runtime}

## Workspace
Your workspace is at: {workspace_path}
- Long-term memory: {workspace_path}/memory/MEMORY.md (write important facts here)
- History log: {workspace_path}/memory/HISTORY.md (grep-searchable)
- Custom skills: {workspace_path}/skills/{{skill-name}}/SKILL.md

{platform_policy}

## nanobot Guidelines
- State intent before tool calls, but NEVER predict or claim results before receiving them.
- Before modifying a file, read it first. Do not assume files or directories exist.
- After writing or editing a file, re-read it if accuracy matters.
- If a tool call fails, analyze the error before retrying with a different approach.
- Ask for clarification when the request is ambiguous.

Reply directly with text for conversations. Only use the 'message' tool to send to a specific chat channel."""
```

**设计要点**：

1. **运行时信息**：操作系统、Python 版本
2. **工作空间路径**：告诉 Agent 文件系统根目录
3. **平台策略**：根据 OS 给出不同的工具使用建议
4. **指导原则**：Agent 行为准则

### 2. 引导文件加载 ([`context.py`](../nanobot/agent/context.py:109))

```python
def _load_bootstrap_files(self) -> str:
    """从工作空间加载所有引导文件"""
    parts = []

    for filename in self.BOOTSTRAP_FILES:
        file_path = self.workspace / filename
        if file_path.exists():
            content = file_path.read_text(encoding="utf-8")
            parts.append(f"## {filename}\n\n{content}")

    return "\n\n".join(parts) if parts else ""
```

**引导文件说明**：

| 文件 | 用途 |
|------|------|
| `AGENTS.md` | Agent 身份和角色定义 |
| `SOUL.md` | Agent 性格和价值观 |
| `USER.md` | 用户偏好和期望 |
| `TOOLS.md` | 工具使用指南 |

### 3. 运行时上下文 ([`context.py`](../nanobot/agent/context.py:100))

```python
@staticmethod
def _build_runtime_context(channel: str | None, chat_id: str | None) -> str:
    """构建运行时元数据块（注入到用户消息前）"""
    now = datetime.now().strftime("%Y-%m-%d %H:%M (%A)")
    tz = time.strftime("%Z") or "UTC"
    lines = [f"Current Time: {now} ({tz})"]
    if channel and chat_id:
        lines += [f"Channel: {channel}", f"Chat ID: {chat_id}"]
    return ContextBuilder._RUNTIME_CONTEXT_TAG + "\n" + "\n".join(lines)
```

**运行时上下文包含**：
- 当前时间（含时区）
- 通道名称
- 聊天 ID

**特点**：
- 标记为"元数据"，避免 Agent 将其误解为指令
- 在保存会话时被剥离，不污染历史

### 4. 消息构建 ([`context.py`](../nanobot/agent/context.py:121))

```python
def build_messages(
    self,
    history: list[dict[str, Any]],
    current_message: str,
    skill_names: list[str] | None = None,
    media: list[str] | None = None,
    channel: str | None = None,
    chat_id: str | None = None,
) -> list[dict[str, Any]]:
    """构建 LLM 调用的完整消息列表"""
    # 1. 构建运行时上下文
    runtime_ctx = self._build_runtime_context(channel, chat_id)

    # 2. 构建用户内容（处理媒体）
    user_content = self._build_user_content(current_message, media)

    # 3. 合并运行时上下文和用户内容
    if isinstance(user_content, str):
        merged = f"{runtime_ctx}\n\n{user_content}"
    else:
        merged = [{"type": "text", "text": runtime_ctx}] + user_content

    # 4. 返回完整消息列表
    return [
        {"role": "system", "content": self.build_system_prompt(skill_names)},
        *history,
        {"role": "user", "content": merged},
    ]
```

### 5. 媒体处理 ([`context.py`](../nanobot/agent/context.py:147))

```python
def _build_user_content(self, text: str, media: list[str] | None) -> str | list[dict[str, Any]]:
    """构建带可选 base64 编码图片的用户消息内容"""
    if not media:
        return text

    images = []
    for path in media:
        p = Path(path)
        if not p.is_file():
            continue

        # 读取图片
        raw = p.read_bytes()

        # 检测 MIME 类型
        mime = detect_image_mime(raw) or mimetypes.guess_type(path)[0]
        if not mime or not mime.startswith("image/"):
            continue

        # Base64 编码
        b64 = base64.b64encode(raw).decode()
        images.append({
            "type": "image_url",
            "image_url": {"url": f"data:{mime};base64,{b64}"}
        })

    if not images:
        return text

    # 返回多模态内容
    return images + [{"type": "text", "text": text}]
```

**支持的媒体格式**：
- 图片：PNG, JPEG, GIF, WebP 等
- 自动检测 MIME 类型（通过魔数）
- Base64 编码嵌入消息

### 6. 消息操作辅助方法

#### 添加工具结果 ([`context.py`](../nanobot/agent/context.py:169))

```python
def add_tool_result(
    self,
    messages: list[dict[str, Any]],
    tool_call_id: str,
    tool_name: str,
    result: str,
) -> list[dict[str, Any]]:
    """添加工具结果到消息列表"""
    messages.append({
        "role": "tool",
        "tool_call_id": tool_call_id,
        "name": tool_name,
        "content": result
    })
    return messages
```

#### 添加助手指令 ([`context.py`](../nanobot/agent/context.py:177))

```python
def add_assistant_message(
    self,
    messages: list[dict[str, Any]],
    content: str | None,
    tool_calls: list[dict[str, Any]] | None = None,
    reasoning_content: str | None = None,
    thinking_blocks: list[dict] | None = None,
) -> list[dict[str, Any]]:
    """添加助手指令到消息列表"""
    messages.append(build_assistant_message(
        content,
        tool_calls=tool_calls,
        reasoning_content=reasoning_content,
        thinking_blocks=thinking_blocks,
    ))
    return messages
```

**支持的扩展功能**：
- `reasoning_content`：Kimi、DeepSeek-R1 的思维链
- `thinking_blocks`：Anthropic 的扩展思考

## 设计模式

### 1. 建造者模式

ContextBuilder 使用建造者模式逐步构建复杂的消息上下文：

```python
# 1. 构建系统提示
system_prompt = context.build_system_prompt()

# 2. 构建用户消息
user_content = context._build_user_content(message, media)

# 3. 组合完整消息
messages = [
    {"role": "system", "content": system_prompt},
    *history,
    {"role": "user", "content": user_content},
]
```

### 2. 策略模式

根据不同平台（Windows/POSIX）使用不同的策略：

```python
if system == "Windows":
    platform_policy = "# Windows policy..."
else:
    platform_policy = "# POSIX policy..."
```

### 3. 模板方法模式

定义消息构建的骨架，子步骤可定制：

```python
def build_messages(self, history, current_message, ...):
    # 模板方法
    runtime_ctx = self._build_runtime_context(channel, chat_id)
    user_content = self._build_user_content(current_message, media)
    return [system, *history, user]
```

## 扩展点

### 1. 自定义引导文件

在工作空间添加自定义引导文件：

```bash
# workspace/AGENTS.md
You are a code review assistant with expertise in Python and TypeScript.

# workspace/USER.md
- Prefer detailed explanations with code examples.
- Always suggest tests for new code.
```

### 2. 自定义技能

```python
# workspace/skills/code-review/SKILL.md
...
```

### 3. 自定义记忆

```python
# workspace/memory/MEMORY.md
## Project Context
This is a Python project using FastAPI and PostgreSQL.

## Important Notes
- The database schema is in `models.py`
- API routes are defined in `routes/`
```

## 性能优化

### 1. 文件缓存

```python
# MemoryStore 内部缓存文件内容
class MemoryStore:
    def __init__(self, workspace: Path):
        self._cache: dict[str, str] = {}

    def get_memory_context(self) -> str:
        if "memory" not in self._cache:
            self._cache["memory"] = self._load_memory()
        return self._cache["memory"]
```

### 2. 延迟加载

```python
# 只在需要时加载技能
def build_skills_summary(self) -> str:
    if not hasattr(self, '_skills_summary'):
        self._skills_summary = self._build_summary()
    return self._skills_summary
```

## 总结

上下文构建器是 nanobot 智能的关键，实现了：

✅ **动态上下文**：根据会话和历史动态构建
✅ **可定制性**：通过引导文件和技能轻松定制
✅ **多模态支持**：支持文本 + 图片
✅ **平台感知**：根据 OS 调整行为指导
✅ **运行时感知**：Agent 知道当前时间和来源通道

这种设计使得 nanobot 能够提供上下文感知的智能响应，同时保持配置的灵活性。

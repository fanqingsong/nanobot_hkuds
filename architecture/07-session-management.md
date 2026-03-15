# 会话管理系统设计

## 概述

会话管理系统（Session Management）负责管理用户对话的持久化状态，包括历史消息、元数据和记忆压缩状态。

## 核心文件

```
nanobot/session/
└── manager.py    # 会话管理器（~210 行）
```

## 架构设计

### 1. 会话架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Session Manager                          │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  In-Memory Cache (_cache)                           │    │
│  │  ┌─────────────────────────────────────────────┐    │    │
│  │  │  session_key -> Session object              │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
│                           │                                  │
│                           ▼                                  │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Persistent Storage (JSONL files)                  │    │
│  │  ┌─────────────────────────────────────────────┐    │    │
│  │  │  workspace/sessions/{key}.jsonl             │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 2. 核心数据结构

#### Session ([`manager.py`](../nanobot/session/manager.py:17))

```python
@dataclass
class Session:
    """对话会话"""

    key: str                              # 会话键（channel:chat_id）
    messages: list[dict[str, Any]]        # 消息列表（JSONL 格式）
    created_at: datetime                  # 创建时间
    updated_at: datetime                  # 更新时间
    metadata: dict[str, Any]              # 元数据
    last_consolidated: int = 0            # 已压缩的消息数

    def add_message(self, role: str, content: str, **kwargs: Any) -> None:
        """添加消息到会话"""
        msg = {
            "role": role,
            "content": content,
            "timestamp": datetime.now().isoformat(),
            **kwargs
        }
        self.messages.append(msg)
        self.updated_at = datetime.now()

    def get_history(self, max_messages: int = 500) -> list[dict[str, Any]]:
        """返回未压缩的消息（用于 LLM 输入）"""
        unconsolidated = self.messages[self.last_consolidated:]
        sliced = unconsolidated[-max_messages:]

        # 删除开头的非用户消息（避免孤立的 tool_result 块）
        for i, m in enumerate(sliced):
            if m.get("role") == "user":
                sliced = sliced[i:]
                break

        # 清理输出
        out = []
        for m in sliced:
            entry = {"role": m["role"], "content": m.get("content", "")}
            for k in ("tool_calls", "tool_call_id", "name"):
                if k in m:
                    entry[k] = m[k]
            out.append(entry)

        return out

    def clear(self) -> None:
        """清空所有消息并重置会话"""
        self.messages = []
        self.last_consolidated = 0
        self.updated_at = datetime.now()
```

**设计要点**：

1. **增量追加**：消息只追加不删除，保持 LLM cache 友好
2. **压缩指针**：`last_consolidated` 标记已压缩位置
3. **用户对齐**：`get_history` 从用户消息开始，避免孤立块
4. **时间戳**：每条消息记录时间

#### SessionManager ([`manager.py`](../nanobot/session/manager.py:73))

```python
class SessionManager:
    """管理对话会话"""

    def __init__(self, workspace: Path):
        self.workspace = workspace
        self.sessions_dir = ensure_dir(self.workspace / "sessions")
        self.legacy_sessions_dir = get_legacy_sessions_dir()
        self._cache: dict[str, Session] = {}

    def _get_session_path(self, key: str) -> Path:
        """获取会话文件路径"""
        safe_key = safe_filename(key.replace(":", "_"))
        return self.sessions_dir / f"{safe_key}.jsonl"

    def get_or_create(self, key: str) -> Session:
        """获取现有会话或创建新会话"""
        if key in self._cache:
            return self._cache[key]

        session = self._load(key)
        if session is None:
            session = Session(key=key)

        self._cache[key] = session
        return session

    def save(self, session: Session) -> None:
        """保存会话到磁盘"""
        path = self._get_session_path(session.key)

        with open(path, "w", encoding="utf-8") as f:
            # 写入元数据行
            metadata_line = {
                "_type": "metadata",
                "key": session.key,
                "created_at": session.created_at.isoformat(),
                "updated_at": session.updated_at.isoformat(),
                "metadata": session.metadata,
                "last_consolidated": session.last_consolidated
            }
            f.write(json.dumps(metadata_line, ensure_ascii=False) + "\n")

            # 写入消息行
            for msg in session.messages:
                f.write(json.dumps(msg, ensure_ascii=False) + "\n")

        self._cache[session.key] = session

    def invalidate(self, key: str) -> None:
        """从内存缓存中移除会话"""
        self._cache.pop(key, None)

    def list_sessions(self) -> list[dict[str, Any]]:
        """列出所有会话"""
        sessions = []

        for path in self.sessions_dir.glob("*.jsonl"):
            try:
                with open(path, encoding="utf-8") as f:
                    first_line = f.readline().strip()
                    if first_line:
                        data = json.loads(first_line)
                        if data.get("_type") == "metadata":
                            key = data.get("key") or path.stem.replace("_", ":", 1)
                            sessions.append({
                                "key": key,
                                "created_at": data.get("created_at"),
                                "updated_at": data.get("updated_at"),
                                "path": str(path)
                            })
            except Exception:
                continue

        return sorted(sessions, key=lambda x: x.get("updated_at", ""), reverse=True)
```

## 核心功能

### 1. 会话键生成

```python
# 默认会话键
session_key = f"{channel}:{chat_id}"
# 示例：telegram:123456, discord:789012

# 自定义会话键（用于线程作用域）
session_key = f"{channel}:{chat_id}:{thread_id}"
# 示例：slack:channel_id:thread_ts
```

### 2. 会话加载 ([`manager.py`](../nanobot/session/manager.py:116))

```python
def _load(self, key: str) -> Session | None:
    """从磁盘加载会话"""
    path = self._get_session_path(key)

    # 迁移旧路径
    if not path.exists():
        legacy_path = self._get_legacy_session_path(key)
        if legacy_path.exists():
            try:
                shutil.move(str(legacy_path), str(path))
                logger.info("Migrated session {} from legacy path", key)
            except Exception:
                logger.exception("Failed to migrate session {}", key)

    if not path.exists():
        return None

    try:
        messages = []
        metadata = {}
        created_at = None
        last_consolidated = 0

        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue

                data = json.loads(line)

                if data.get("_type") == "metadata":
                    # 元数据行
                    metadata = data.get("metadata", {})
                    created_at = datetime.fromisoformat(data["created_at"]) if data.get("created_at") else None
                    last_consolidated = data.get("last_consolidated", 0)
                else:
                    # 消息行
                    messages.append(data)

        return Session(
            key=key,
            messages=messages,
            created_at=created_at or datetime.now(),
            metadata=metadata,
            last_consolidated=last_consolidated
        )
    except Exception as e:
        logger.warning("Failed to load session {}: {}", key, e)
        return None
```

**JSONL 格式**：

```jsonl
{"_type":"metadata","key":"telegram:123456","created_at":"2024-01-01T00:00:00","updated_at":"2024-01-01T01:00:00","metadata":{},"last_consolidated":0}
{"role":"user","content":"Hello","timestamp":"2024-01-01T00:00:01"}
{"role":"assistant","content":"Hi there!","timestamp":"2024-01-01T00:00:02"}
{"role":"user","content":"How are you?","timestamp":"2024-01-01T00:00:03"}
{"role":"assistant","content":"I'm doing well!","timestamp":"2024-01-01T00:00:04"}
```

**优势**：
- 每行一个 JSON 对象，易于追加
- 元数据在第一行，快速读取
- 支持增量解析

### 3. 内存缓存

```python
class SessionManager:
    def __init__(self, workspace: Path):
        self._cache: dict[str, Session] = {}

    def get_or_create(self, key: str) -> Session:
        """优先从缓存获取"""
        if key in self._cache:
            return self._cache[key]

        session = self._load(key)
        if session is None:
            session = Session(key=key)

        self._cache[key] = session
        return session

    def invalidate(self, key: str) -> None:
        """使缓存失效"""
        self._cache.pop(key, None)
```

**缓存策略**：
- LRU（最近最少使用）隐式策略
- 可手动失效（会话清空时）
- 自动保存到磁盘

### 4. 会话持久化

```python
class SessionManager:
    def save(self, session: Session) -> None:
        """保存会话到磁盘"""
        path = self._get_session_path(session.key)

        # 确保目录存在
        path.parent.mkdir(parents=True, exist_ok=True)

        with open(path, "w", encoding="utf-8") as f:
            # 1. 写入元数据
            metadata_line = {
                "_type": "metadata",
                "key": session.key,
                "created_at": session.created_at.isoformat(),
                "updated_at": session.updated_at.isoformat(),
                "metadata": session.metadata,
                "last_consolidated": session.last_consolidated
            }
            f.write(json.dumps(metadata_line, ensure_ascii=False) + "\n")

            # 2. 写入消息
            for msg in session.messages:
                f.write(json.dumps(msg, ensure_ascii=False) + "\n")

        # 3. 更新缓存
        self._cache[session.key] = session
```

## 会话生命周期

### 1. 创建会话

```python
# 首次对话
session_key = f"{channel}:{chat_id}"
session = session_manager.get_or_create(session_key)
# 如果不存在，会创建新的 Session 对象
```

### 2. 更新会话

```python
# 添加消息
session.add_message("user", user_message)
session.add_message("assistant", assistant_response)

# 保存
session_manager.save(session)
```

### 3. 清空会话

```python
# /new 命令
session.clear()
session_manager.save(session)
session_manager.invalidate(session.key)
```

### 4. 列出会话

```python
# 列出所有会话
sessions = session_manager.list_sessions()
# 返回：[{"key": "...", "created_at": "...", "updated_at": "..."}]
```

## 压缩集成

### 1. 压缩指针

```python
@dataclass
class Session:
    last_consolidated: int = 0  # 已压缩的消息数

    def get_history(self, max_messages: int = 500) -> list[dict]:
        """只返回未压缩的消息"""
        unconsolidated = self.messages[self.last_consolidated:]
        return unconsolidated[-max_messages:]
```

### 2. 压缩后更新

```python
# 压缩完成后
session.last_consolidated = len(session.messages)
session_manager.save(session)
```

## 安全考虑

### 1. 路径安全

```python
def safe_filename(filename: str) -> str:
    """生成安全的文件名"""
    # 移除危险字符
    safe = filename.replace("/", "_").replace("\\", "_")
    # 移除开头的点
    safe = safe.lstrip(".")
    # 限制长度
    return safe[:255]
```

### 2. 会话隔离

```python
# 不同通道的会话完全隔离
telegram_session = session_manager.get_or_create("telegram:123456")
discord_session = session_manager.get_or_create("discord:789012")

# 不同聊天完全隔离
user1 = session_manager.get_or_create("telegram:111")
user2 = session_manager.get_or_create("telegram:222")
```

## 性能优化

### 1. 延迟加载

```python
# 只在需要时加载会话
session = session_manager.get_or_create(session_key)
# 如果会话不在缓存中，才从磁盘加载
```

### 2. 增量保存

```python
# 只在修改时保存
if session_was_modified:
    session_manager.save(session)
```

### 3. 历史截断

```python
# 避免返回过长历史
history = session.get_history(max_messages=500)
```

## 迁移支持

### 1. 旧路径迁移

```python
def _load(self, key: str) -> Session | None:
    path = self._get_session_path(key)

    # 如果新路径不存在，尝试旧路径
    if not path.exists():
        legacy_path = self._get_legacy_session_path(key)
        if legacy_path.exists():
            try:
                shutil.move(str(legacy_path), str(path))
                logger.info("Migrated session {} from legacy path", key)
            except Exception:
                logger.exception("Failed to migrate session {}", key)
```

**旧路径**：`~/.nanobot/sessions/`
**新路径**：`{workspace}/sessions/`

## 总结

会话管理系统实现了：

✅ **持久化**：对话状态永久保存
✅ **缓存**：内存缓存提升性能
✅ **隔离**：不同会话完全隔离
✅ **压缩集成**：支持记忆压缩
✅ **迁移支持**：平滑迁移旧数据
✅ **JSONL 格式**：易于读写和解析

这种设计使得 nanobot 能够提供连贯的对话体验，同时保持数据的持久化和可管理性。

# 工具系统设计

## 概述

工具系统（Tools System）是 nanobot Agent 与外部环境交互的核心机制，提供了文件操作、Shell 执行、Web 搜索、跨通道消息等功能。

## 核心文件

```
nanobot/agent/tools/
├── base.py         # 工具基类
├── registry.py     # 工具注册表
├── filesystem.py   # 文件系统工具
├── shell.py        # Shell 执行工具
├── web.py          # Web 工具（搜索/抓取）
├── message.py      # 跨通道消息工具
├── cron.py         # 定时任务工具
├── spawn.py        # 子代理工具
└── mcp.py          # MCP 集成
```

## 架构设计

### 1. 工具系统架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Agent Loop Engine                        │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Tool Registry                                      │    │
│  │  ┌─────────────────────────────────────────────┐    │    │
│  │  │  - register(tool)                           │    │    │
│  │  │  - execute(name, params)                    │    │    │
│  │  │  - get_definitions()                        │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
│                           │                                  │
│         ┌─────────────────┼─────────────────┐               │
│         ▼                 ▼                 ▼               │
│  ┌──────────┐      ┌──────────┐      ┌──────────┐          │
│  │ File Tools│     │Shell Tool│     │ Web Tools│          │
│  │ - read   │      │ - exec   │      │ - search │          │
│  │ - write  │      │          │      │ - fetch  │          │
│  │ - edit   │      │          │      │          │          │
│  └──────────┘      └──────────┘      └──────────┘          │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 2. 核心类设计

#### Tool 基类 ([`base.py`](../nanobot/agent/tools/base.py:7))

```python
class Tool(ABC):
    """Agent 工具的抽象基类"""

    _TYPE_MAP = {
        "string": str,
        "integer": int,
        "number": (int, float),
        "boolean": bool,
        "array": list,
        "object": dict,
    }

    @property
    @abstractmethod
    def name(self) -> str:
        """工具名称（用于函数调用）"""
        pass

    @property
    @abstractmethod
    def description(self) -> str:
        """工具功能描述"""
        pass

    @property
    @abstractmethod
    def parameters(self) -> dict[str, Any]:
        """工具参数的 JSON Schema"""
        pass

    @abstractmethod
    async def execute(self, **kwargs: Any) -> str:
        """执行工具并返回结果"""
        pass

    def cast_params(self, params: dict[str, Any]) -> dict[str, Any]:
        """在验证前应用安全的 schema 驱动类型转换"""
        schema = self.parameters or {}
        return self._cast_object(params, schema)

    def validate_params(self, params: dict[str, Any]) -> list[str]:
        """验证工具参数（返回错误列表）"""
        if not isinstance(params, dict):
            return [f"parameters must be an object, got {type(params).__name__}"]

        schema = self.parameters or {}
        return self._validate(params, {**schema, "type": "object"}, "")

    def to_schema(self) -> dict[str, Any]:
        """转换为 OpenAI 函数 schema 格式"""
        return {
            "type": "function",
            "function": {
                "name": self.name,
                "description": self.description,
                "parameters": self.parameters,
            },
        }
```

#### ToolRegistry ([`registry.py`](../nanobot/agent/tools/registry.py:8))

```python
class ToolRegistry:
    """Agent 工具的注册表"""

    def __init__(self):
        self._tools: dict[str, Tool] = {}

    def register(self, tool: Tool) -> None:
        """注册工具"""
        self._tools[tool.name] = tool

    def unregister(self, name: str) -> None:
        """注销工具"""
        self._tools.pop(name, None)

    def get(self, name: str) -> Tool | None:
        """获取工具"""
        return self._tools.get(name)

    def get_definitions(self) -> list[dict[str, Any]]:
        """获取所有工具的 OpenAI 格式定义"""
        return [tool.to_schema() for tool in self._tools.values()]

    async def execute(self, name: str, params: dict[str, Any]) -> str:
        """执行工具"""
        tool = self._tools.get(name)
        if not tool:
            return f"Error: Tool '{name}' not found"

        try:
            # 类型转换
            params = tool.cast_params(params)

            # 参数验证
            errors = tool.validate_params(params)
            if errors:
                return f"Error: Invalid parameters: {('; '.join(errors))}"

            # 执行工具
            result = await tool.execute(**params)
            if isinstance(result, str) and result.startswith("Error"):
                return result + "\n\n[Analyze the error and try a different approach.]"
            return result
        except Exception as e:
            return f"Error executing {name}: {str(e)}"
```

## 内置工具

### 1. 文件系统工具

#### ReadFileTool

```python
class ReadFileTool(Tool):
    name = "read_file"
    description = "Read the contents of a file"
    parameters = {
        "type": "object",
        "properties": {
            "path": {
                "type": "string",
                "description": "Path to the file to read"
            }
        },
        "required": ["path"]
    }

    def __init__(self, workspace: Path, allowed_dir: Path | None = None):
        self.workspace = workspace
        self.allowed_dir = allowed_dir

    async def execute(self, path: str) -> str:
        # 解析路径
        full_path = self._resolve_path(path)

        # 检查权限
        if self.allowed_dir and not self._is_allowed(full_path):
            return f"Error: Access denied - path is outside allowed directory"

        # 读取文件
        try:
            return full_path.read_text(encoding="utf-8")
        except Exception as e:
            return f"Error: {str(e)}"
```

#### WriteFileTool

```python
class WriteFileTool(Tool):
    name = "write_file"
    description = "Write content to a file (creates directories if needed)"
    parameters = {
        "type": "object",
        "properties": {
            "path": {"type": "string"},
            "content": {"type": "string"}
        },
        "required": ["path", "content"]
    }

    async def execute(self, path: str, content: str) -> str:
        full_path = self._resolve_path(path)

        # 创建目录
        full_path.parent.mkdir(parents=True, exist_ok=True)

        # 写入文件
        try:
            full_path.write_text(content, encoding="utf-8")
            return f"Successfully wrote {len(content)} bytes to {path}"
        except Exception as e:
            return f"Error: {str(e)}"
```

#### EditFileTool

```python
class EditFileTool(Tool):
    name = "edit_file"
    description = "Make exact string replacements in a file"
    parameters = {
        "type": "object",
        "properties": {
            "path": {"type": "string"},
            "old_text": {"type": "string"},
            "new_text": {"type": "string"}
        },
        "required": ["path", "old_text", "new_text"]
    }

    async def execute(self, path: str, old_text: str, new_text: str) -> str:
        full_path = self._resolve_path(path)

        try:
            content = full_path.read_text(encoding="utf-8")

            if old_text not in content:
                return f"Error: old_text not found in file"

            new_content = content.replace(old_text, new_text, 1)
            full_path.write_text(new_content, encoding="utf-8")

            return "Successfully edited file"
        except Exception as e:
            return f"Error: {str(e)}"
```

### 2. Shell 工具

#### ExecTool

```python
class ExecTool(Tool):
    name = "exec"
    description = "Execute a shell command"
    parameters = {
        "type": "object",
        "properties": {
            "command": {
                "type": "string",
                "description": "Shell command to execute"
            },
            "timeout": {
                "type": "integer",
                "description": "Timeout in seconds"
            }
        },
        "required": ["command"]
    }

    def __init__(
        self,
        working_dir: str,
        timeout: int = 60,
        restrict_to_workspace: bool = False,
        path_append: list[str] | None = None,
    ):
        self.working_dir = working_dir
        self.timeout = timeout
        self.restrict_to_workspace = restrict_to_workspace
        self.path_append = path_append or []

    async def execute(self, command: str, timeout: int | None = None) -> str:
        # 安全检查
        if self.restrict_to_workspace:
            if not self._is_safe_command(command):
                return "Error: Command not allowed in restricted mode"

        # 执行命令
        try:
            process = await asyncio.create_subprocess_shell(
                command,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=self.working_dir,
            )

            stdout, stderr = await asyncio.wait_for(
                process.communicate(),
                timeout=timeout or self.timeout
            )

            output = stdout.decode("utf-8", errors="replace")
            errors = stderr.decode("utf-8", errors="replace")

            if errors:
                return f"{output}\n[stderr]\n{errors}"
            return output
        except asyncio.TimeoutError:
            process.kill()
            return f"Error: Command timed out after {timeout} seconds"
```

### 3. Web 工具

#### WebSearchTool

```python
class WebSearchTool(Tool):
    name = "web_search"
    description = "Search the web for information"
    parameters = {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": "Search query"
            },
            "num_results": {
                "type": "integer",
                "description": "Number of results to return"
            }
        },
        "required": ["query"]
    }

    def __init__(self, config: WebSearchConfig, proxy: str | None = None):
        self.config = config
        self.proxy = proxy

    async def execute(self, query: str, num_results: int = 10) -> str:
        # Tavily
        if self.config.tavily.api_key:
            return await self._search_tavily(query, num_results)

        # Bing
        if self.config.bing.api_key:
            return await self._search_bing(query, num_results)

        # DuckDuckGo（免费）
        return await self._search_duckduckgo(query, num_results)

    async def _search_tavily(self, query: str, num_results: int) -> str:
        import aiohttp

        async with aiohttp.ClientSession() as session:
            async with session.post(
                "https://api.tavily.com/search",
                json={
                    "api_key": self.config.tavily.api_key,
                    "query": query,
                    "max_results": num_results,
                },
                proxy=self.proxy,
            ) as resp:
                data = await resp.json()

                results = []
                for result in data.get("results", []):
                    results.append(f"- {result['title']}\n  {result['url']}\n  {result.get('content', '')[:200]}")

                return "\n\n".join(results)
```

#### WebFetchTool

```python
class WebFetchTool(Tool):
    name = "web_fetch"
    description = "Fetch and render a web page as markdown"
    parameters = {
        "type": "object",
        "properties": {
            "url": {
                "type": "string",
                "description": "URL to fetch"
            }
        },
        "required": ["url"]
    }

    async def execute(self, url: str) -> str:
        from nanobot.providers.web_fetch import WebFetcher

        fetcher = WebFetcher(proxy=self.proxy)
        content = await fetcher.fetch(url)

        if content.startswith("Error"):
            return content

        return f"# {url}\n\n{content}"
```

### 4. 跨通道消息工具

#### MessageTool

```python
class MessageTool(Tool):
    name = "message"
    description = "Send a message to a specific chat channel"
    parameters = {
        "type": "object",
        "properties": {
            "channel": {
                "type": "string",
                "description": "Channel name (telegram, discord, etc.)"
            },
            "to": {
                "type": "string",
                "description": "Chat ID to send to"
            },
            "content": {
                "type": "string",
                "description": "Message content"
            }
        },
        "required": ["channel", "to", "content"]
    }

    def __init__(self, send_callback: Callable[[OutboundMessage], Awaitable[None]]):
        self.send_callback = send_callback
        self._context: dict[str, str] = {}
        self._sent_in_turn = False

    def set_context(self, channel: str, chat_id: str, message_id: str | None = None):
        """设置上下文（用于回复）"""
        self._context = {
            "channel": channel,
            "chat_id": chat_id,
            "message_id": message_id,
        }
        self._sent_in_turn = False

    def start_turn(self):
        """开始新轮次（重置标志）"""
        self._sent_in_turn = False

    async def execute(self, channel: str, to: str, content: str) -> str:
        msg = OutboundMessage(
            channel=channel,
            chat_id=to,
            content=content,
            reply_to=self._context.get("message_id"),
        )

        await self.send_callback(msg)
        self._sent_in_turn = True

        return f"Message sent to {channel}:{to}"
```

### 5. 定时任务工具

#### CronTool

```python
class CronTool(Tool):
    name = "cron"
    description = "Schedule or manage cron jobs"
    parameters = {
        "type": "object",
        "properties": {
            "action": {
                "type": "string",
                "enum": ["list", "add", "remove", "enable", "disable"],
                "description": "Action to perform"
            },
            "schedule": {
                "type": "string",
                "description": "Cron schedule (e.g. 'every 5 minutes', 'at 2024-01-01 00:00')"
            },
            "task": {
                "type": "string",
                "description": "Task description"
            }
        },
        "required": ["action"]
    }

    def __init__(self, cron_service: CronService):
        self.cron_service = cron_service

    def set_context(self, channel: str, chat_id: str, message_id: str | None = None):
        """设置上下文（用于任务通知）"""
        self._context = {
            "channel": channel,
            "chat_id": chat_id,
        }

    async def execute(self, action: str, **kwargs) -> str:
        if action == "list":
            jobs = self.cron_service.list_jobs()
            return "\n".join(f"- {job.name}: {job.schedule}" for job in jobs)

        elif action == "add":
            schedule = parse_schedule(kwargs.get("schedule", ""))
            task = kwargs.get("task", "")

            job = self.cron_service.add_job(
                name=f"Cron job",
                schedule=schedule,
                message=task,
                deliver=True,
                channel=self._context["channel"],
                to=self._context["chat_id"],
            )
            return f"Added cron job: {job.id}"

        # ... 其他操作
```

### 6. 子代理工具

#### SpawnTool

```python
class SpawnTool(Tool):
    name = "spawn"
    description = "Spawn a subagent to handle a complex task"
    parameters = {
        "type": "object",
        "properties": {
            "task": {
                "type": "string",
                "description": "Task description"
            },
            "label": {
                "type": "string",
                "description": "Short label for the task"
            }
        },
        "required": ["task"]
    }

    def __init__(self, manager: SubagentManager):
        self.manager = manager

    def set_context(self, channel: str, chat_id: str, message_id: str | None = None):
        """设置上下文（用于结果通知）"""
        self._context = {
            "channel": channel,
            "chat_id": chat_id,
        }

    async def execute(self, task: str, label: str | None = None) -> str:
        result = await self.manager.spawn(
            task=task,
            label=label,
            origin_channel=self._context["channel"],
            origin_chat_id=self._context["chat_id"],
        )
        return result
```

## MCP 集成

### MCP 工具加载

```python
async def connect_mcp_servers(
    servers: dict,
    tools: ToolRegistry,
    stack: AsyncExitStack,
) -> None:
    """连接 MCP 服务器并加载工具"""
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client

    for name, config in servers.items():
        try:
            # 创建服务器参数
            server_params = StdioServerParameters(
                command=config["command"],
                args=config.get("args", []),
            )

            # 连接服务器
            stdio_transport, stdio_write = await stdio_client(server_params)
            stdio_session = ClientSession(stdio_transport, stdio_write)

            await stdio_session.initialize()

            # 列出工具
            response = await stdio_session.list_tools()

            # 注册 MCP 工具
            for tool in response.tools:
                tools.register(MCPTool(
                    name=tool.name,
                    description=tool.description,
                    session=stdio_session,
                ))

            await stack.enter_async_context(stdio_session)
        except Exception as e:
            logger.warning("Failed to connect MCP server {}: {}", name, e)
```

### MCP 工具封装

```python
class MCPTool(Tool):
    """MCP 工具封装"""

    def __init__(self, name: str, description: str, session: ClientSession):
        self._name = name
        self._description = description
        self._session = session
        self._schema = None

    @property
    def name(self) -> str:
        return self._name

    @property
    def description(self) -> str:
        return self._description

    @property
    def parameters(self) -> dict:
        # 延迟加载 schema
        if not self._schema:
            tools = asyncio.run(self._session.list_tools())
            for tool in tools.tools:
                if tool.name == self._name:
                    self._schema = tool.inputSchema
        return self._schema or {}

    async def execute(self, **kwargs) -> str:
        result = await self._session.call_tool(self._name, kwargs)
        return str(result)
```

## 工具注册

### 默认工具注册

```python
class AgentLoop:
    def _register_default_tools(self) -> None:
        """注册默认工具集"""
        allowed_dir = self.workspace if self.restrict_to_workspace else None

        # 文件系统工具
        for cls in (ReadFileTool, WriteFileTool, EditFileTool, ListDirTool):
            self.tools.register(cls(workspace=self.workspace, allowed_dir=allowed_dir))

        # Shell 工具
        self.tools.register(ExecTool(
            working_dir=str(self.workspace),
            timeout=self.exec_config.timeout,
            restrict_to_workspace=self.restrict_to_workspace,
            path_append=self.exec_config.path_append,
        ))

        # Web 工具
        self.tools.register(WebSearchTool(config=self.web_search_config, proxy=self.web_proxy))
        self.tools.register(WebFetchTool(proxy=self.web_proxy))

        # 消息工具
        self.tools.register(MessageTool(send_callback=self.bus.publish_outbound))

        # 子代理工具
        self.tools.register(SpawnTool(manager=self.subagents))

        # 定时任务工具
        if self.cron_service:
            self.tools.register(CronTool(self.cron_service))
```

## 自定义工具

### 创建自定义工具

```python
from nanobot.agent.tools.base import Tool

class MyCustomTool(Tool):
    @property
    def name(self) -> str:
        return "my_custom_tool"

    @property
    def description(self) -> str:
        return "Does something custom"

    @property
    def parameters(self) -> dict:
        return {
            "type": "object",
            "properties": {
                "input": {
                    "type": "string",
                    "description": "Input parameter"
                }
            },
            "required": ["input"]
        }

    async def execute(self, input: str) -> str:
        # 实现工具逻辑
        result = do_something(input)
        return f"Result: {result}"
```

### 注册自定义工具

```python
# 在 AgentLoop 初始化时
self.tools.register(MyCustomTool())
```

## 总结

工具系统实现了：

✅ **统一接口**：所有工具使用相同的 API
✅ **类型安全**：JSON Schema 参数验证
✅ **错误处理**：统一的错误返回格式
✅ **扩展性**：轻松添加自定义工具
✅ **MCP 集成**：支持 Model Context Protocol
✅ **权限控制**：工作区限制和安全检查

这种设计使得 nanobot Agent 能够与外部环境灵活交互，同时保持代码的安全性和可维护性。

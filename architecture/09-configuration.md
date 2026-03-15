# 配置管理系统设计

## 概述

配置管理系统（Configuration Management）负责加载、验证和管理 nanobot 的所有配置，支持多种配置源和类型安全的配置访问。

## 核心文件

```
nanobot/config/
├── schema.py      # Pydantic 配置模型
├── loader.py      # 配置加载器
└── paths.py       # 路径管理
```

## 架构设计

### 1. 配置架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Configuration Layer                      │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Config Loader (loader.py)                         │    │
│  │  ┌─────────────────────────────────────────────┐    │    │
│  │  │  - load_config(path)                        │    │    │
│  │  │  - save_config(config, path)                │    │    │
│  │  │  - _migrate_config(data)                    │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
│                           │                                  │
│                           ▼                                  │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Config Schema (schema.py)                         │    │
│  │  ┌─────────────────────────────────────────────┐    │    │
│  │  │  - ProvidersConfig                          │    │    │
│  │  │  - ChannelsConfig                           │    │    │
│  │  │  - ToolsConfig                              │    │    │
│  │  │  - AgentConfig                              │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 2. 核心数据结构

#### Config ([`schema.py`](../nanobot/config/schema.py))

```python
class Config(Base):
    """nanobot 主配置"""

    # Agent 配置
    agent: AgentConfig = Field(default_factory=AgentConfig)

    # 提供商配置
    providers: ProvidersConfig = Field(default_factory=ProvidersConfig)

    # 通道配置
    channels: ChannelsConfig = Field(default_factory=ChannelsConfig)

    # 工具配置
    tools: ToolsConfig = Field(default_factory=ToolsConfig)

    # Cron 配置
    cron: CronConfig = Field(default_factory=CronConfig)

    # 心跳配置
    heartbeat: HeartbeatConfig = Field(default_factory=HeartbeatConfig)
```

## 配置模型

### 1. Provider 配置

```python
class ProvidersConfig(Base):
    """LLM 提供商配置"""

    openai: OpenAIConfig = Field(default_factory=OpenAIConfig)
    anthropic: AnthropicConfig = Field(default_factory=AnthropicConfig)
    azure: AzureOpenAIConfig = Field(default_factory=AzureOpenAIConfig)
    litellm: LiteLLMConfig = Field(default_factory=LiteLLMConfig)
    custom: CustomProviderConfig = Field(default_factory=CustomProviderConfig)

class OpenAIConfig(Base):
    apiKey: str = ""
    baseUrl: str = "https://api.openai.com/v1"

class AnthropicConfig(Base):
    apiKey: str = ""

class AzureOpenAIConfig(Base):
    endpoint: str = ""
    apiKey: str = ""
    deployment: str = ""
    apiVersion: str = "2024-02-01"

class LiteLLMConfig(Base):
    model: str = ""
    apiKey: str = ""
    dropParams: list[str] = Field(default_factory=list)

class CustomProviderConfig(Base):
    baseUrl: str = ""
    apiKey: str = ""
```

### 2. Channel 配置

```python
class ChannelsConfig(Base):
    """聊天通道配置"""

    telegram: TelegramConfig = Field(default_factory=TelegramConfig)
    whatsapp: WhatsAppConfig = Field(default_factory=WhatsAppConfig)
    feishu: FeishuConfig = Field(default_factory=FeishuConfig)
    discord: DiscordConfig = Field(default_factory=DiscordConfig)
    slack: SlackConfig = Field(default_factory=SlackConfig)
    email: EmailConfig = Field(default_factory=EmailConfig)
    matrix: MatrixConfig = Field(default_factory=MatrixConfig)
    qq: QQConfig = Field(default_factory=QQConfig)
    dingtalk: DingTalkConfig = Field(default_factory=DingTalkConfig)
    mochat: MoChatConfig = Field(default_factory=MoChatConfig)

    # 全局设置
    send_progress: bool = False
    send_tool_hints: bool = False

class TelegramConfig(Base):
    enabled: bool = False
    token: str = ""
    allow_from: list[str] = Field(default_factory=list)
    proxy: str | None = None
    reply_to_message: bool = False
    group_policy: Literal["open", "mention"] = "mention"

class FeishuConfig(Base):
    enabled: bool = False
    app_id: str = ""
    app_secret: str = ""
    encrypt_key: str = ""
    verification_token: str = ""
    allow_from: list[str] = Field(default_factory=list)
    react_emoji: str = "THUMBSUP"
    group_policy: Literal["open", "mention"] = "mention"
```

### 3. Tools 配置

```python
class ToolsConfig(Base):
    """工具配置"""

    restrict_to_workspace: bool = False

    exec: ExecToolConfig = Field(default_factory=ExecToolConfig)
    web_search: WebSearchConfig = Field(default_factory=WebSearchConfig)

class ExecToolConfig(Base):
    timeout: int = 60
    path_append: list[str] = Field(default_factory=list)
    restrict_to_workspace: bool = False

class WebSearchConfig(Base):
    tavily: TavilyConfig = Field(default_factory=TavilyConfig)
    bing: BingConfig = Field(default_factory=BingConfig)
    duckduckgo: DuckDuckGoConfig = Field(default_factory=DuckDuckGoConfig)

class TavilyConfig(Base):
    apiKey: str = ""
```

### 4. Agent 配置

```python
class AgentConfig(Base):
    """Agent 配置"""

    model: str = ""
    max_iterations: int = 40
    context_window: int = 65_536
    system_prompt: str = ""
```

### 5. Cron 配置

```python
class CronConfig(Base):
    """定时任务配置"""

    enabled: bool = True
    auto_reload: bool = True
```

### 6. Heartbeat 配置

```python
class HeartbeatConfig(Base):
    """心跳配置"""

    enabled: bool = True
    interval_s: int = 30 * 60  # 30 分钟
```

## 配置加载

### 1. 加载器 ([`loader.py`](../nanobot/config/loader.py:26))

```python
def load_config(config_path: Path | None = None) -> Config:
    """从文件加载配置或创建默认配置"""
    path = config_path or get_config_path()

    if path.exists():
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)

            # 迁移旧配置
            data = _migrate_config(data)

            # 验证并创建配置对象
            return Config.model_validate(data)
        except (json.JSONDecodeError, ValueError) as e:
            print(f"Warning: Failed to load config from {path}: {e}")
            print("Using default configuration.")

    # 返回默认配置
    return Config()
```

### 2. 配置迁移 ([`loader.py`](../nanobot/config/loader.py:68))

```python
def _migrate_config(data: dict) -> dict:
    """迁移旧配置格式到当前格式"""
    # 迁移 tools.exec.restrictToWorkspace -> tools.restrictToWorkspace
    tools = data.get("tools", {})
    exec_cfg = tools.get("exec", {})
    if "restrictToWorkspace" in exec_cfg and "restrictToWorkspace" not in tools:
        tools["restrictToWorkspace"] = exec_cfg.pop("restrictToWorkspace")

    return data
```

### 3. 配置保存 ([`loader.py`](../nanobot/config/loader.py:51))

```python
def save_config(config: Config, config_path: Path | None = None) -> None:
    """保存配置到文件"""
    path = config_path or get_config_path()
    path.parent.mkdir(parents=True, exist_ok=True)

    # 转换为 camelCase（保持向后兼容）
    data = config.model_dump(by_alias=True)

    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
```

## 配置路径

### 1. 默认路径 ([`loader.py`](../nanobot/config/loader.py:19))

```python
def get_config_path() -> Path:
    """获取配置文件路径"""
    if _current_config_path:
        return _current_config_path
    return Path.home() / ".nanobot" / "config.json"

def set_config_path(path: Path) -> None:
    """设置当前配置路径（用于多实例支持）"""
    global _current_config_path
    _current_config_path = path
```

### 2. 工作空间路径

```python
def get_workspace_path() -> Path:
    """获取工作空间路径"""
    # 从配置文件路径推导
    config_path = get_config_path()

    # 如果配置在 ~/.nanobot/config.json
    # 工作空间在 ~/.nanobot/workspace
    if config_path.parent.name == ".nanobot":
        return config_path.parent / "workspace"

    # 否则使用配置文件所在目录
    return config_path.parent
```

## 配置文件示例

### 完整配置

```json
{
  "agent": {
    "model": "gpt-4o-mini",
    "maxIterations": 40,
    "contextWindow": 65536
  },
  "providers": {
    "openai": {
      "apiKey": "sk-...",
      "baseUrl": "https://api.openai.com/v1"
    },
    "anthropic": {
      "apiKey": "sk-ant-..."
    },
    "litellm": {
      "model": "qwen/qwen-2.5-72b-instruct",
      "apiKey": "..."
    }
  },
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
  },
  "tools": {
    "restrictToWorkspace": false,
    "exec": {
      "timeout": 60,
      "pathAppend": ["/usr/local/bin"]
    },
    "webSearch": {
      "tavily": {
        "apiKey": "tvly-..."
      }
    }
  },
  "cron": {
    "enabled": true,
    "autoReload": true
  },
  "heartbeat": {
    "enabled": true,
    "intervalS": 1800
  }
}
```

## 类型安全

### 1. Pydantic 验证

```python
class Config(Base):
    """Base 支持 camelCase 和 snake_case"""
    model_config = ConfigDict(
        alias_generator=to_camel,
        populate_by_name=True
    )

# 支持两种格式
config1 = Config(agent_model="gpt-4")       # camelCase
config2 = Config(agent_model="gpt-4")       # snake_case
```

### 2. 默认值

```python
class TelegramConfig(Base):
    enabled: bool = False                  # 默认禁用
    token: str = ""                        # 默认空字符串
    allow_from: list[str] = Field(default_factory=list)  # 默认空列表
```

### 3. 必填字段

```python
class ExecToolConfig(Base):
    timeout: int = 60                      # 有默认值
```

## 多实例支持

### 1. 配置路径隔离

```python
# 实例 1
set_config_path(Path("/home/user/.nanobot/instance1/config.json"))
config1 = load_config()
workspace1 = get_workspace_path()

# 实例 2
set_config_path(Path("/home/user/.nanobot/instance2/config.json"))
config2 = load_config()
workspace2 = get_workspace_path()
```

### 2. 工作空间隔离

```
~/.nanobot/
├── instance1/
│   ├── config.json
│   └── workspace/
│       ├── sessions/
│       ├── memory/
│       └── jobs.json
└── instance2/
    ├── config.json
    └── workspace/
        ├── sessions/
        ├── memory/
        └── jobs.json
```

## 环境变量

### 1. 支持环境变量

```python
from pydantic_settings import BaseSettings

class OpenAIConfig(BaseSettings):
    apiKey: str = ""

    class Config:
        env_prefix = "OPENAI_"
        env_file = ".env"

# 使用环境变量
# export OPENAI_API_KEY=sk-...
config = OpenAIConfig()  # apiKey 从环境变量读取
```

### 2. .env 文件

```bash
# .env
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
TELEGRAM_BOT_TOKEN=123456:ABC-DEF...
```

## 配置验证

### 1. 自动验证

```python
# Pydantic 自动验证
config = Config.model_validate(data)

# 验证失败时抛出 ValidationError
try:
    config = Config.model_validate(data)
except ValidationError as e:
    print(f"Config validation failed: {e}")
```

### 2. 自定义验证

```python
from pydantic import field_validator

class TelegramConfig(Base):
    enabled: bool = False
    token: str = ""

    @field_validator("token")
    @classmethod
    def validate_token(cls, v: str, info) -> str:
        if info.data.get("enabled") and not v:
            raise ValueError("token is required when enabled")
        return v
```

## 总结

配置管理系统实现了：

✅ **类型安全**：Pydantic 提供完整的类型验证
✅ **默认值**：所有配置都有合理的默认值
✅ **配置迁移**：自动迁移旧配置格式
✅ **多实例支持**：支持多个独立实例
✅ **环境变量**：支持从环境变量加载敏感信息
✅ **灵活配置**：支持 camelCase 和 snake_case

这种设计使得 nanobot 的配置既灵活又安全，同时保持了类型安全和易用性。

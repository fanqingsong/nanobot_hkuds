# Provider 抽象层设计

## 概述

Provider 抽象层（Provider Layer）负责统一不同大语言模型（LLM）提供商的接口，使得 nanobot 能够轻松切换和扩展支持的模型。

## 核心文件

```
nanobot/providers/
├── base.py                    # Provider 基类
├── registry.py                # Provider 注册表
├── openai_provider.py         # OpenAI 实现
├── anthropic_provider.py      # Anthropic 实现
├── azure_openai_provider.py   # Azure OpenAI 实现
├── litellm_provider.py        # LiteLLM 实现
├── custom_provider.py         # 自定义 Provider
└── transcription.py           # 音频转文字服务
```

## 架构设计

### 1. Provider 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Agent Loop Engine                        │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Provider Abstraction Layer                         │    │
│  │  ┌─────────────────────────────────────────────┐    │    │
│  │  │  LLMProvider Interface                      │    │    │
│  │  │  - chat(messages, tools, model)             │    │    │
│  │  │  - chat_with_retry(...)                     │    │    │
│  │  │  - get_default_model()                      │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
│                           │                                  │
│         ┌─────────────────┼─────────────────┐               │
│         ▼                 ▼                 ▼               │
│  ┌──────────┐      ┌──────────┐      ┌──────────┐          │
│  │  OpenAI  │      │Anthropic │      │ LiteLLM  │          │
│  └──────────┘      └──────────┘      └──────────┘          │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 2. 核心数据结构

#### ToolCallRequest ([`base.py`](../nanobot/providers/base.py:13))

```python
@dataclass
class ToolCallRequest:
    """来自 LLM 的工具调用请求"""

    id: str                                      # 调用 ID
    name: str                                    # 工具名称
    arguments: dict[str, Any]                    # 工具参数
    provider_specific_fields: dict | None        # 提供商特定字段
    function_provider_specific_fields: dict | None  # 函数特定字段

    def to_openai_tool_call(self) -> dict[str, Any]:
        """序列化为 OpenAI 风格的 tool_call payload"""
        return {
            "id": self.id,
            "type": "function",
            "function": {
                "name": self.name,
                "arguments": json.dumps(self.arguments, ensure_ascii=False),
            },
        }
```

#### LLMResponse ([`base.py`](../nanobot/providers/base.py:39))

```python
@dataclass
class LLMResponse:
    """来自 LLM 提供商的响应"""

    content: str | None                          # 文本内容
    tool_calls: list[ToolCallRequest]            # 工具调用列表
    finish_reason: str = "stop"                  # 结束原因
    usage: dict[str, int]                        # Token 使用量
    reasoning_content: str | None = None         # 思维链（Kimi、DeepSeek-R1）
    thinking_blocks: list[dict] | None = None    # 扩展思考（Anthropic）

    @property
    def has_tool_calls(self) -> bool:
        """检查响应是否包含工具调用"""
        return len(self.tool_calls) > 0
```

#### GenerationSettings ([`base.py`](../nanobot/providers/base.py:55))

```python
@dataclass(frozen=True)
class GenerationSettings:
    """LLM 调用的默认生成参数"""

    temperature: float = 0.7
    max_tokens: int = 4096
    reasoning_effort: str | None = None          # 推理强度（o1 系列）
```

### 3. 核心接口

#### LLMProvider ([`base.py`](../nanobot/providers/base.py:69))

```python
class LLMProvider(ABC):
    """LLM 提供商的抽象基类"""

    _CHAT_RETRY_DELAYS = (1, 2, 4)               # 重试延迟
    _TRANSIENT_ERROR_MARKERS = (                 # 瞬态错误标记
        "429", "rate limit", "timeout", "connection"
    )

    def __init__(self, settings: GenerationSettings | None = None):
        self.settings = settings or GenerationSettings()

    @abstractmethod
    async def chat(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]],
        model: str,
    ) -> LLMResponse:
        """调用 LLM 获取响应"""
        pass

    async def chat_with_retry(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]],
        model: str,
    ) -> LLMResponse:
        """带重试的聊天（处理限流、网络错误）"""
        for delay in self._CHAT_RETRY_DELAYS:
            try:
                return await self.chat(messages, tools, model)
            except Exception as e:
                if self._is_transient_error(e):
                    logger.warning("LLM call failed (retrying in {}s): {}", delay, e)
                    await asyncio.sleep(delay)
                else:
                    raise

        # 最后一次尝试
        return await self.chat(messages, tools, model)

    def _is_transient_error(self, error: Exception) -> bool:
        """判断是否为瞬态错误"""
        error_str = str(error).lower()
        return any(marker in error_str for marker in self._TRANSIENT_ERROR_MARKERS)

    def get_default_model(self) -> str:
        """获取默认模型名称"""
        return "gpt-4o-mini"
```

## Provider 实现

### 1. OpenAI Provider

```python
class OpenAIProvider(LLMProvider):
    """OpenAI API 实现"""

    def __init__(
        self,
        api_key: str,
        base_url: str = "https://api.openai.com/v1",
        settings: GenerationSettings | None = None,
    ):
        super().__init__(settings)
        self.client = AsyncOpenAI(api_key=api_key, base_url=base_url)

    async def chat(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]],
        model: str,
    ) -> LLMResponse:
        """调用 OpenAI Chat Completions API"""
        response = await self.client.chat.completions.create(
            model=model,
            messages=messages,
            tools=tools,
            temperature=self.settings.temperature,
            max_tokens=self.settings.max_tokens,
        )

        # 解析响应
        choice = response.choices[0]
        tool_calls = [
            ToolCallRequest(
                id=tc.id,
                name=tc.function.name,
                arguments=json.loads(tc.function.arguments),
            )
            for tc in choice.message.tool_calls or []
        ]

        return LLMResponse(
            content=choice.message.content,
            tool_calls=tool_calls,
            finish_reason=choice.finish_reason,
            usage=response.usage.model_dump(),
        )

    def get_default_model(self) -> str:
        return "gpt-4o-mini"
```

### 2. Anthropic Provider

```python
class AnthropicProvider(LLMProvider):
    """Anthropic Claude API 实现"""

    def __init__(
        self,
        api_key: str,
        settings: GenerationSettings | None = None,
    ):
        super().__init__(settings)
        self.client = AsyncAnthropic(api_key=api_key)

    async def chat(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]],
        model: str,
    ) -> LLMResponse:
        """调用 Anthropic Messages API"""
        # 转换消息格式（Anthropic 不支持 system role 在 messages 中）
        system_msg = next(
            (m.pop("content") for m in messages if m.get("role") == "system"),
            None
        )
        messages = [m for m in messages if m.get("role") != "system"]

        response = await self.client.messages.create(
            model=model,
            system=system_msg,
            messages=messages,
            tools=tools,
            temperature=self.settings.temperature,
            max_tokens=self.settings.max_tokens,
        )

        # 解析响应
        tool_calls = []
        for block in response.content:
            if block.type == "tool_use":
                tool_calls.append(ToolCallRequest(
                    id=block.id,
                    name=block.name,
                    arguments=block.input,
                ))

        # 提取 thinking blocks（扩展思考）
        thinking_blocks = [
            block.model_dump()
            for block in response.content
            if block.type == "thinking"
        ]

        return LLMResponse(
            content=response.stop_reason == "end_turn" and response.content[0].text or None,
            tool_calls=tool_calls,
            finish_reason=response.stop_reason,
            usage=response.usage.model_dump(),
            thinking_blocks=thinking_blocks or None,
        )

    def get_default_model(self) -> str:
        return "claude-3-5-sonnet-20241022"
```

### 3. Azure OpenAI Provider

```python
class AzureOpenAIProvider(LLMProvider):
    """Azure OpenAI 实现"""

    def __init__(
        self,
        api_key: str,
        endpoint: str,
        deployment: str,
        api_version: str = "2024-02-01",
        settings: GenerationSettings | None = None,
    ):
        super().__init__(settings)
        self.client = AsyncAzureOpenAI(
            api_key=api_key,
            azure_endpoint=endpoint,
            api_version=api_version,
        )
        self.deployment = deployment

    async def chat(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]],
        model: str,
    ) -> LLMResponse:
        """调用 Azure OpenAI"""
        response = await self.client.chat.completions.create(
            model=self.deployment,  # 使用部署名称
            messages=messages,
            tools=tools,
            temperature=self.settings.temperature,
            max_tokens=self.settings.max_tokens,
        )

        # 解析响应（与 OpenAI 相同）
        choice = response.choices[0]
        tool_calls = [...]

        return LLMResponse(
            content=choice.message.content,
            tool_calls=tool_calls,
            finish_reason=choice.finish_reason,
            usage=response.usage.model_dump(),
        )
```

### 4. LiteLLM Provider

```python
class LiteLLMProvider(LLMProvider):
    """LiteLLM 统一接口实现（支持 100+ 模型）"""

    def __init__(
        self,
        model: str,
        api_key: str | None = None,
        settings: GenerationSettings | None = None,
    ):
        super().__init__(settings)
        self.model = model
        self.api_key = api_key

    async def chat(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]],
        model: str,
    ) -> LLMResponse:
        """通过 LiteLLM 调用任意模型"""
        import litellm

        response = await litellm.acompletion(
            model=model or self.model,
            messages=messages,
            tools=tools,
            temperature=self.settings.temperature,
            max_tokens=self.settings.max_tokens,
            api_key=self.api_key,
        )

        # 解析响应
        choice = response.choices[0]
        tool_calls = [...]

        return LLMResponse(
            content=choice.message.content,
            tool_calls=tool_calls,
            finish_reason=choice.finish_reason,
            usage=response.usage,
        )

    def get_default_model(self) -> str:
        return self.model or "gpt-4o-mini"
```

**支持的模型**：
- OpenAI: GPT-4、GPT-3.5
- Anthropic: Claude 系列
- Google: Gemini
- Cohere: Command 系列
- Azure OpenAI
- Qwen (通义千问)
- DeepSeek
- Moonshot (月之暗面)
- MiniMax
- 以及更多...

## 配置模式

### Provider 配置

```python
class ProvidersConfig(Base):
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
```

### 配置文件示例

```json
{
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
  }
}
```

## 特殊功能

### 1. 思维链支持

```python
# DeepSeek-R1、Kimi 等
@dataclass
class LLMResponse:
    reasoning_content: str | None = None  # 思维链内容

# 在上下文中使用
messages = context.add_assistant_message(
    messages,
    content="最终答案",
    reasoning_content="<thinking>思考过程...</thinking>",
)
```

### 2. 扩展思考支持

```python
# Anthropic Claude 扩展思考
@dataclass
class LLMResponse:
    thinking_blocks: list[dict] | None = None

# 在上下文中使用
messages = context.add_assistant_message(
    messages,
    content="最终答案",
    thinking_blocks=[...],
)
```

### 3. Prompt Caching (Anthropic)

```python
class AnthropicProvider(LLMProvider):
    async def chat(self, messages, tools, model):
        # 启用 prompt caching
        response = await self.client.messages.create(
            model=model,
            messages=messages,
            tools=tools,
            system={
                "type": "text",
                "text": system_prompt,
                "cache_control": {"type": "ephemeral"}  # 缓存系统提示
            },
        )
```

## 错误处理

### 1. 瞬态错误重试

```python
async def chat_with_retry(self, messages, tools, model) -> LLMResponse:
    for delay in self._CHAT_RETRY_DELAYS:
        try:
            return await self.chat(messages, tools, model)
        except Exception as e:
            if self._is_transient_error(e):
                await asyncio.sleep(delay)
            else:
                raise
```

**瞬态错误**：
- 429 Rate Limit
- 超时
- 连接错误

### 2. 错误响应处理

```python
if response.finish_reason == "error":
    logger.error("LLM returned error: {}", response.content)
    final_content = "Sorry, I encountered an error."
    # 不保存到历史，防止污染
```

## 扩展新 Provider

### 步骤 1：创建 Provider 类

```python
# nanobot/providers/my_provider.py
from nanobot.providers.base import LLMProvider, LLMResponse, ToolCallRequest

class MyProvider(LLMProvider):
    def __init__(self, api_key: str, settings: GenerationSettings | None = None):
        super().__init__(settings)
        self.client = MyClient(api_key=api_key)

    async def chat(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]],
        model: str,
    ) -> LLMResponse:
        response = await self.client.chat(
            model=model,
            messages=messages,
            tools=tools,
        )

        # 解析响应
        tool_calls = [...]
        return LLMResponse(
            content=response.content,
            tool_calls=tool_calls,
            finish_reason=response.finish_reason,
        )

    def get_default_model(self) -> str:
        return "my-model-v1"
```

### 步骤 2：注册 Provider

```python
# nanobot/providers/registry.py
PROVIDER_REGISTRY = {
    "openai": OpenAIProvider,
    "anthropic": AnthropicProvider,
    "myprovider": MyProvider,
}
```

### 步骤 3：配置并使用

```python
provider = MyProvider(api_key="...")
response = await provider.chat(messages, tools, model)
```

## 总结

Provider 抽象层实现了：

✅ **统一接口**：所有 LLM 使用相同的 API
✅ **重试机制**：自动处理瞬态错误
✅ **多模型支持**：支持主流 LLM 提供商
✅ **扩展性**：轻松添加新 Provider
✅ **高级功能**：思维链、Prompt Caching 等
✅ **类型安全**：完整的数据结构定义

这种设计使得 nanobot 能够支持多种 LLM，同时保持代码的简洁和一致性。

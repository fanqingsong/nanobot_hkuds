# nanobot 架构设计文档

本目录包含 nanobot 项目的完整架构设计文档。

## 📚 文档索引

### 总览文档

- **[00-overview.md](00-overview.md)** - nanobot 系统架构总览
  - 设计理念和原则
  - 核心架构层次
  - 技术栈总结
  - 代码结构

### 核心模块文档

#### 1. [消息总线层](01-message-bus.md)
**职责**：实现 Channels 和 Agent Core 的完全解耦
- 异步消息队列（asyncio.Queue）
- 双向消息传递（inbound/outbound）
- 类型安全的消息定义

#### 2. [Agent 循环引擎](02-agent-loop.md)
**职责**：核心处理引擎，协调整个 Agent 运行流程
- 主循环和消息分发
- Agent 迭代循环（LLM + Tools）
- 会话管理和记忆压缩
- 斜杠命令和任务管理

#### 3. [上下文构建器](03-context-builder.md)
**职责**：为每次 LLM 调用构建完整的消息上下文
- 系统提示构建
- 引导文件加载
- 运行时上下文注入
- 媒体处理（多模态）

#### 4. [通道系统](04-channels.md)
**职责**：连接各种聊天平台
- 通道抽象接口
- 自动发现和注册
- 10+ 聊天平台支持
- 权限控制和媒体处理

#### 5. [Provider 抽象层](05-providers.md)
**职责**：统一不同 LLM 提供商的接口
- 统一的 Provider 接口
- 多种实现（OpenAI/Anthropic/Azure/LiteLLM）
- 重试机制和错误处理
- 思维链和 Prompt Caching

#### 6. [工具系统](06-tools-system.md)
**职责**：Agent 与外部环境交互的核心机制
- 工具基类和注册表
- 内置工具（文件、Shell、Web、消息等）
- MCP 集成
- 自定义工具扩展

#### 7. [会话管理](07-session-management.md)
**职责**：管理用户对话的持久化状态
- 会话数据结构
- JSONL 持久化格式
- 内存缓存和增量加载
- 压缩集成

#### 8. [子代理系统](08-subagent-system.md)
**职责**：生成独立子代理处理复杂任务
- 子代理生成和执行
- 独立上下文和工具
- 结果通知机制
- 按会话管理

#### 9. [配置管理](09-configuration.md)
**职责**：加载、验证和管理所有配置
- Pydantic 配置模型
- 类型安全的配置访问
- 配置迁移和持久化
- 多实例支持

#### 10. [定时任务服务](10-cron-service.md)
**职责**：管理和执行定时任务
- 多种调度表达式（cron/interval/at）
- 任务持久化和热重载
- 一次性任务支持
- 公共 API

#### 11. [心跳服务](11-heartbeat-service.md)
**职责**：定期唤醒 Agent 检查待处理任务
- 虚拟工具调用决策
- 两阶段执行（决策+执行）
- HEARTBEAT.md 配置
- 手动触发支持

## 🎯 快速导航

### 按角色导航

**架构师/系统设计师**
- [系统架构总览](00-overview.md)
- [消息总线层](01-message-bus.md)
- [Agent 循环引擎](02-agent-loop.md)

**开发者（添加新功能）**
- [工具系统](06-tools-system.md) - 添加新工具
- [通道系统](04-channels.md) - 添加新通道
- [Provider 抽象层](05-providers.md) - 添加新 Provider

**运维/部署**
- [配置管理](09-configuration.md)
- [定时任务服务](10-cron-service.md)

**研究人员**
- [上下文构建器](03-context-builder.md) - 理解 Prompt 工程
- [子代理系统](08-subagent-system.md) - 理解多 Agent 协作

### 按主题导航

**异步编程**
- [消息总线层](01-message-bus.md) - asyncio.Queue 实现
- [Agent 循环引擎](02-agent-loop.md) - 异步分发和任务管理

**LLM 集成**
- [Provider 抽象层](05-providers.md) - 统一 LLM 接口
- [上下文构建器](03-context-builder.md) - 消息上下文构建

**数据处理**
- [会话管理](07-session-management.md) - 对话持久化
- [配置管理](09-configuration.md) - 配置加载和验证

**扩展机制**
- [工具系统](06-tools-system.md) - 工具注册和执行
- [通道系统](04-channels.md) - 通道自动发现
- [子代理系统](08-subagent-system.md) - 后台任务执行

## 📖 阅读建议

### 初次阅读

1. **先读总览**：[00-overview.md](00-overview.md) 了解全局架构
2. **核心流程**：[02-agent-loop.md](02-agent-loop.md) 理解 Agent 如何运行
3. **关键机制**：[01-message-bus.md](01-message-bus.md) 和 [03-context-builder.md](03-context-builder.md)

### 深入理解

1. **工具系统**：[06-tools-system.md](06-tools-system.md) - Agent 如何与环境交互
2. **通道系统**：[04-channels.md](04-channels.md) - 多平台支持实现
3. **Provider 层**：[05-providers.md](05-providers.md) - LLM 抽象

### 高级特性

1. **子代理**：[08-subagent-system.md](08-subagent-system.md) - 复杂任务处理
2. **定时任务**：[10-cron-service.md](10-cron-service.md) - 自动化任务
3. **心跳服务**：[11-heartbeat-service.md](11-heartbeat-service.md) - 主动检查

## 🔍 关键概念

### 设计模式

| 模式 | 应用 | 文档 |
|------|------|------|
| **观察者模式** | 消息总线 | [01-message-bus.md](01-message-bus.md) |
| **策略模式** | Provider 抽象 | [05-providers.md](05-providers.md) |
| **插件模式** | Channel/Tool 发现 | [04-channels.md](04-channels.md), [06-tools-system.md](06-tools-system.md) |
| **建造者模式** | 上下文构建 | [03-context-builder.md](03-context-builder.md) |
| **工厂模式** | 动态创建 | [04-channels.md](04-channels.md) |

### 核心技术栈

- **语言**：Python 3.11+
- **异步框架**：asyncio
- **配置管理**：Pydantic + pydantic-settings
- **CLI**：Typer + prompt_toolkit + Rich
- **日志**：Loguru
- **HTTP/WebSocket**：httpx, aiohttp

### 性能指标

- **核心代码**：~3,100 行（Agent Loop）
- **总代码量**：~14,400 行
- **支持通道**：10+ 聊天平台
- **支持 Provider**：OpenAI/Anthropic/Azure/LiteLLM 等
- **内置工具**：10+ 工具

## 🛠️ 扩展指南

### 添加新工具

详见 [工具系统](06-tools-system.md) 的"自定义工具"章节

### 添加新通道

详见 [通道系统](04-channels.md) 的"扩展新通道"章节

### 添加新 Provider

详见 [Provider 抽象层](05-providers.md) 的"扩展新 Provider"章节

## 📝 更新日志

- **2024-03-15**：创建完整架构文档系列
- 包含 11 个子模块的详细设计文档
- 涵盖从总览到每个组件的实现细节

## 🤝 贡献

如果你发现文档有任何问题或需要补充，欢迎提交 PR 或 Issue。

---

**文档版本**：1.0.0
**最后更新**：2024-03-15
**维护者**：nanobot 团队

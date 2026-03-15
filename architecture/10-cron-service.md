# 定时任务服务设计

## 概述

定时任务服务（Cron Service）负责管理和执行定时任务，支持多种调度表达式（cron、interval、at），并持久化任务状态。

## 核心文件

```
nanobot/cron/
├── service.py     # Cron 服务（~380 行）
└── types.py       # 类型定义
```

## 架构设计

### 1. Cron 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Cron Service                             │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Job Store (JSON)                                  │    │
│  │  ┌─────────────────────────────────────────────┐    │    │
│  │  │  workspace/jobs.json                        │    │    │
│  │  │  - 持久化任务列表                           │    │    │
│  │  │  - 支持热重载                               │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
│                           │                                  │
│                           ▼                                  │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Timer Loop                                         │    │
│  │  ┌─────────────────────────────────────────────┐    │    │
│  │  │  - 计算下次运行时间                         │    │    │
│  │  │  - 异步等待                                  │    │    │
│  │  │  - 执行到期任务                              │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
│                           │                                  │
│                           ▼                                  │
│  ┌─────────────────────────────────────────────────────┐    │
│  │  Job Callback                                       │    │
│  │  ┌─────────────────────────────────────────────┐    │    │
│  │  │  - 通过 Agent 执行任务                      │    │    │
│  │  │  - 返回结果                                  │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### 2. 核心数据结构

#### CronJob ([`types.py`](../nanobot/cron/types.py))

```python
@dataclass
class CronJob:
    """定时任务"""
    id: str                              # 任务 ID（8 位 UUID）
    name: str                            # 任务名称
    enabled: bool                        # 是否启用
    schedule: CronSchedule               # 调度配置
    payload: CronPayload                 # 任务负载
    state: CronJobState                  # 任务状态
    created_at_ms: int                   # 创建时间（毫秒）
    updated_at_ms: int                   # 更新时间（毫秒）
    delete_after_run: bool = False       # 运行后删除（一次性任务）

@dataclass
class CronSchedule:
    """调度配置"""
    kind: Literal["cron", "every", "at"]  # 调度类型
    at_ms: int | None = None              # at 模式的时间戳
    every_ms: int | None = None           # every 模式的间隔（毫秒）
    expr: str | None = None               # cron 表达式
    tz: str | None = None                 # 时区（仅 cron 模式）

@dataclass
class CronPayload:
    """任务负载"""
    kind: Literal["agent_turn"] = "agent_turn"
    message: str = ""                     # 任务消息
    deliver: bool = False                 # 是否投递到通道
    channel: str | None = None            # 投递通道
    to: str | None = None                 # 投递目标

@dataclass
class CronJobState:
    """任务状态"""
    next_run_at_ms: int | None = None     # 下次运行时间
    last_run_at_ms: int | None = None     # 上次运行时间
    last_status: str | None = None        # 上次运行状态
    last_error: str | None = None         # 上次错误信息
```

## 核心功能

### 1. 启动服务 ([`service.py`](../nanobot/cron/service.py:175))

```python
async def start(self) -> None:
    """启动 Cron 服务"""
    self._running = True

    # 1. 加载任务存储
    self._load_store()

    # 2. 重新计算下次运行时间
    self._recompute_next_runs()

    # 3. 保存存储
    self._save_store()

    # 4. 启动定时器
    self._arm_timer()

    logger.info("Cron service started with {} jobs", len(self._store.jobs))
```

### 2. 计算下次运行时间 ([`service.py`](../nanobot/cron/service.py:20))

```python
def _compute_next_run(schedule: CronSchedule, now_ms: int) -> int | None:
    """计算下次运行时间（毫秒）"""
    if schedule.kind == "at":
        # 一次性任务
        return schedule.at_ms if schedule.at_ms and schedule.at_ms > now_ms else None

    if schedule.kind == "every":
        # 间隔任务
        if not schedule.every_ms or schedule.every_ms <= 0:
            return None
        return now_ms + schedule.every_ms

    if schedule.kind == "cron" and schedule.expr:
        # Cron 表达式任务
        try:
            from zoneinfo import ZoneInfo
            from croniter import croniter

            base_time = now_ms / 1000
            tz = ZoneInfo(schedule.tz) if schedule.tz else datetime.now().astimezone().tzinfo
            base_dt = datetime.fromtimestamp(base_time, tz=tz)
            cron = croniter(schedule.expr, base_dt)
            next_dt = cron.get_next(datetime)
            return int(next_dt.timestamp() * 1000)
        except Exception:
            return None

    return None
```

### 3. 启动定时器 ([`service.py`](../nanobot/cron/service.py:208))

```python
def _arm_timer(self) -> None:
    """调度下次定时器 tick"""
    if self._timer_task:
        self._timer_task.cancel()

    # 获取最近的下次运行时间
    next_wake = self._get_next_wake_ms()
    if not next_wake or not self._running:
        return

    # 计算延迟
    delay_ms = max(0, next_wake - _now_ms())
    delay_s = delay_ms / 1000

    # 创建定时任务
    async def tick():
        await asyncio.sleep(delay_s)
        if self._running:
            await self._on_timer()

    self._timer_task = asyncio.create_task(tick())
```

### 4. 执行到期任务 ([`service.py`](../nanobot/cron/service.py:227))

```python
async def _on_timer(self) -> None:
    """处理定时器 tick - 运行到期任务"""
    # 1. 重新加载（支持热重载）
    self._load_store()

    # 2. 查找到期任务
    now = _now_ms()
    due_jobs = [
        j for j in self._store.jobs
        if j.enabled and j.state.next_run_at_ms and now >= j.state.next_run_at_ms
    ]

    # 3. 执行任务
    for job in due_jobs:
        await self._execute_job(job)

    # 4. 保存存储
    self._save_store()

    # 5. 重新启动定时器
    self._arm_timer()
```

### 5. 执行单个任务 ([`service.py`](../nanobot/cron/service.py:245))

```python
async def _execute_job(self, job: CronJob) -> None:
    """执行单个任务"""
    start_ms = _now_ms()
    logger.info("Cron: executing job '{}' ({})", job.name, job.id)

    try:
        response = None
        if self.on_job:
            response = await self.on_job(job)

        job.state.last_status = "ok"
        job.state.last_error = None
        logger.info("Cron: job '{}' completed", job.name)

    except Exception as e:
        job.state.last_status = "error"
        job.state.last_error = str(e)
        logger.error("Cron: job '{}' failed: {}", job.name, e)

    # 更新状态
    job.state.last_run_at_ms = start_ms
    job.updated_at_ms = _now_ms()

    # 处理一次性任务
    if job.schedule.kind == "at":
        if job.delete_after_run:
            # 删除任务
            self._store.jobs = [j for j in self._store.jobs if j.id != job.id]
        else:
            # 禁用任务
            job.enabled = False
            job.state.next_run_at_ms = None
    else:
        # 计算下次运行时间
        job.state.next_run_at_ms = _compute_next_run(job.schedule, _now_ms())
```

## 公共 API

### 1. 列出任务 ([`service.py`](../nanobot/cron/service.py:280))

```python
def list_jobs(self, include_disabled: bool = False) -> list[CronJob]:
    """列出所有任务"""
    store = self._load_store()
    jobs = store.jobs if include_disabled else [j for j in store.jobs if j.enabled]
    return sorted(jobs, key=lambda j: j.state.next_run_at_ms or float('inf'))
```

### 2. 添加任务 ([`service.py`](../nanobot/cron/service.py:286))

```python
def add_job(
    self,
    name: str,
    schedule: CronSchedule,
    message: str,
    deliver: bool = False,
    channel: str | None = None,
    to: str | None = None,
    delete_after_run: bool = False,
) -> CronJob:
    """添加新任务"""
    store = self._load_store()
    _validate_schedule_for_add(schedule)

    now = _now_ms()

    job = CronJob(
        id=str(uuid.uuid4())[:8],
        name=name,
        enabled=True,
        schedule=schedule,
        payload=CronPayload(
            kind="agent_turn",
            message=message,
            deliver=deliver,
            channel=channel,
            to=to,
        ),
        state=CronJobState(next_run_at_ms=_compute_next_run(schedule, now)),
        created_at_ms=now,
        updated_at_ms=now,
        delete_after_run=delete_after_run,
    )

    store.jobs.append(job)
    self._save_store()
    self._arm_timer()

    logger.info("Cron: added job '{}' ({})", name, job.id)
    return job
```

### 3. 删除任务 ([`service.py`](../nanobot/cron/service.py:326))

```python
def remove_job(self, job_id: str) -> bool:
    """通过 ID 删除任务"""
    store = self._load_store()
    before = len(store.jobs)
    store.jobs = [j for j in store.jobs if j.id != job_id]
    removed = len(store.jobs) < before

    if removed:
        self._save_store()
        self._arm_timer()
        logger.info("Cron: removed job {}", job_id)

    return removed
```

### 4. 启用/禁用任务 ([`service.py`](../nanobot/cron/service.py:340))

```python
def enable_job(self, job_id: str, enabled: bool = True) -> CronJob | None:
    """启用或禁用任务"""
    store = self._load_store()
    for job in store.jobs:
        if job.id == job_id:
            job.enabled = enabled
            job.updated_at_ms = _now_ms()
            if enabled:
                job.state.next_run_at_ms = _compute_next_run(job.schedule, _now_ms())
            else:
                job.state.next_run_at_ms = None
            self._save_store()
            self._arm_timer()
            return job
    return None
```

### 5. 手动运行任务 ([`service.py`](../nanobot/cron/service.py:356))

```python
async def run_job(self, job_id: str, force: bool = False) -> bool:
    """手动运行任务"""
    store = self._load_store()
    for job in store.jobs:
        if job.id == job_id:
            if not force and not job.enabled:
                return False
            await self._execute_job(job)
            self._save_store()
            self._arm_timer()
            return True
    return False
```

## 调度表达式

### 1. Cron 表达式

```python
# 标准 cron 表达式
schedule = CronSchedule(
    kind="cron",
    expr="0 9 * * *",           # 每天早上 9 点
    tz="Asia/Shanghai"
)

# 复杂表达式
schedule = CronSchedule(
    kind="cron",
    expr="0 */2 * * *",         # 每 2 小时
    tz="UTC"
)
```

### 2. Interval 表达式

```python
# 每隔一段时间
schedule = CronSchedule(
    kind="every",
    every_ms=5 * 60 * 1000      # 每 5 分钟
)
```

### 3. At 表达式

```python
# 一次性任务
schedule = CronSchedule(
    kind="at",
    at_ms=int(datetime(2024, 1, 1, 9, 0).timestamp() * 1000)
)
```

## 任务持久化

### 1. 存储格式 ([`service.py`](../nanobot/cron/service.py:130))

```json
{
  "version": 1,
  "jobs": [
    {
      "id": "abc123",
      "name": "Daily report",
      "enabled": true,
      "schedule": {
        "kind": "cron",
        "expr": "0 9 * * *",
        "tz": "Asia/Shanghai"
      },
      "payload": {
        "kind": "agent_turn",
        "message": "Generate daily report",
        "deliver": true,
        "channel": "telegram",
        "to": "123456"
      },
      "state": {
        "nextRunAtMs": 1704067200000,
        "lastRunAtMs": 1703980800000,
        "lastStatus": "ok",
        "lastError": null
      },
      "createdAtMs": 1703900000000,
      "updatedAtMs": 1703980800000,
      "deleteAfterRun": false
    }
  ]
}
```

### 2. 热重载 ([`service.py`](../nanobot/cron/service.py:78))

```python
def _load_store(self) -> CronStore:
    """从磁盘加载任务（自动检测外部修改）"""
    if self._store and self.store_path.exists():
        mtime = self.store_path.stat().st_mtime
        if mtime != self._last_mtime:
            logger.info("Cron: jobs.json modified externally, reloading")
            self._store = None

    if self._store:
        return self._store

    # 重新加载
    if self.store_path.exists():
        data = json.loads(self.store_path.read_text(encoding="utf-8"))
        jobs = [CronJob(...) for j in data.get("jobs", [])]
        self._store = CronStore(jobs=jobs)
    else:
        self._store = CronStore()

    return self._store
```

## 使用示例

### 1. 通过 Tool 添加

```python
# 用户："每天早上 9 点提醒我喝水"
# Agent 解析并调用 cron tool
await tools.execute("cron", {
    "action": "add",
    "schedule": "every day at 9am",
    "task": "Remind me to drink water",
})
```

### 2. 自然语言解析

```python
# 解析自然语言时间表达式
def parse_schedule(natural: str) -> CronSchedule:
    """解析自然语言调度表达式"""
    natural = natural.lower()

    # "every 5 minutes"
    if "every" in natural:
        minutes = extract_number(natural)
        return CronSchedule(kind="every", every_ms=minutes * 60 * 1000)

    # "at 9am"
    if "at " in natural:
        time_str = extract_time(natural)
        return CronSchedule(kind="cron", expr=f"0 {time_str} * * *")

    # "every day at 9am"
    if "every day" in natural:
        time_str = extract_time(natural)
        return CronSchedule(kind="cron", expr=f"0 {time_str} * * *")

    # 默认：cron 表达式
    return CronSchedule(kind="cron", expr=natural)
```

## 总结

定时任务服务实现了：

✅ **多种调度**：支持 cron、interval、at 三种模式
✅ **持久化**：任务状态持久化到磁盘
✅ **热重载**：自动检测外部修改
✅ **一次性任务**：支持运行后自动删除
✅ **时区支持**：支持时区感知的 cron 表达式
✅ **任务管理**：完整的增删改查 API

这种设计使得 nanobot 能够处理各种定时任务需求，从简单的提醒到复杂的周期性报告生成。

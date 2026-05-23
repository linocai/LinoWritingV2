# Lino Writing v2 · 后端施工计划

> 本文档是后端施工 Agent 的唯一行动依据。
> 标注 `[SHARED]` 的章节与 `PLAN_FRONTEND.md` **逐字相同**——这是前后端的契约层。修改任何 SHARED 章节前，必须同步修改另一份文档；否则两侧会南辕北辙。
>
> 文档版本：v0.5（定稿）
> 关联文档：`PLAN_FRONTEND.md`

---

## 0. 项目目标 [SHARED]

**Lino Writing v2** 是 Lino 个人使用的中文小说写作工具，核心目标一句话：

> 「我出想法，让 Agent 来写作。」

形态：Mac 原生 APP + 云端后端，预留 iOS。单用户。

**最在意的三件事**（按优先级）：
1. 角色卡定死——必须严格遵循
2. 角色必须记住自己之前做过什么
3. 剧情走向不偏离我的意图

**不在意**：文笔的极致打磨（交给 LLM 默认能力即可）。

**与旧项目（`/Users/linotsai/Lino/LinoWriting`）的关系**：
旧项目仅作参考，不复用任何代码、数据或文档。新项目从零开始。

---

## 1. 术语表 [SHARED]

| 术语 | 英文 | 含义 |
|---|---|---|
| 书 | book | 一部独立小说，多本书互相隔离 |
| 章节 | chapter | 书内一章。状态机驱动 |
| 用户提示 | user_prompt | 用户写的 ~50 字章节意图 |
| 结构化提示 | structured_prompt | Agent 把 user_prompt 扩写成的结构化 JSON（目标 / 必发生 / 禁发生 / 出场角色 / 风格） |
| 角色卡 | character | 角色的完整画像，分冻结区与活动区 |
| 时间线事件 | timeline_event | 「角色 X 在第 N 章做了/经历了什么」的最小记录 |
| 章节摘要 | summary | ~200 字的章节摘要 |
| 世界设定 | world_setting | 书的整体背景（200-300 字 markdown） |
| 写作风格 | style_directive | 用户手写的全书写作风格指引 |
| Context Pack | context_pack | 写作 Agent 单次调用时拼装的上下文包（无需持久化） |
| Agent | agent | LLM 任务单元。本系统共 3 个：Expander / Writer / Extractor |

---

## 2. 数据模型 [SHARED]

5 张业务表 + 1 张调试表。所有「可扩展字段」用 JSON 列承载，避免频繁迁移。

### 2.1 `books`
| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | UUID PK | 系统生成 |
| `title` | TEXT NOT NULL | 书名 |
| `cover_color` | TEXT | 封面色，hex 字符串，如 `#3A86FF`。可空 |
| `world_setting` | TEXT | 世界设定，200-300 字 markdown。可空 |
| `style_directive` | TEXT | 写作风格指引，用户手写。可空 |
| `created_at` | TIMESTAMPTZ NOT NULL | |
| `updated_at` | TIMESTAMPTZ NOT NULL | |
| `last_opened_at` | TIMESTAMPTZ | 书架排序用 |

### 2.2 `characters`
| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | UUID PK | |
| `book_id` | UUID FK → books.id ON DELETE CASCADE | |
| `name` | TEXT NOT NULL | 角色名 |
| `role` | TEXT | 主角 / 配角 / 反派 / 路人 等，自由文本 |
| `frozen_fields` | JSONB NOT NULL DEFAULT '{}' | 冻结区，仅用户可改 |
| `live_fields` | JSONB NOT NULL DEFAULT '{}' | 活动区，用户和 Agent 都可改 |
| `created_at` | TIMESTAMPTZ NOT NULL | |
| `updated_at` | TIMESTAMPTZ NOT NULL | |

**`frozen_fields` 推荐结构**（不强制，JSON 自由扩展）：
```json
{
  "core_traits": "聪明、谨慎、刀子嘴豆腐心",
  "appearance": "...",
  "background": "...",
  "voice": "说话喜欢用反问句，口头禅「啧」"
}
```

**`live_fields` 推荐结构**：
```json
{
  "current_status": "在山洞中养伤",
  "goals": ["找到失踪的妹妹"],
  "relationships": {"林夕": "盟友", "黑刀": "宿敌"},
  "secrets_known": ["黑刀真名", "宝藏藏在第三座山"],
  "abilities": ["御剑", "辨毒"]
}
```

### 2.3 `chapters`
| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | UUID PK | |
| `book_id` | UUID FK → books.id ON DELETE CASCADE | |
| `index` | INTEGER NOT NULL | 第几章，1 开始；同 book 内唯一 |
| `title` | TEXT | 章节标题，可空 |
| `user_prompt` | TEXT | 用户 50 字 prompt |
| `structured_prompt` | JSONB | 见 §2.6 schema。Expander 写入后用户可改 |
| `draft_text` | TEXT | 正文。Writer 写入后用户可改 |
| `summary` | TEXT | Extractor 抽出的 ~200 字摘要 |
| `status` | TEXT NOT NULL | 见 §2.7 枚举 |
| `created_at` | TIMESTAMPTZ NOT NULL | |
| `updated_at` | TIMESTAMPTZ NOT NULL | |

唯一约束：`(book_id, index)`。

### 2.4 `timeline_events`
| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | UUID PK | |
| `book_id` | UUID FK → books.id ON DELETE CASCADE | |
| `character_id` | UUID FK → characters.id ON DELETE CASCADE | |
| `chapter_id` | UUID FK → chapters.id ON DELETE CASCADE | 事件出处 |
| `event_type` | TEXT NOT NULL | 见 §2.7 枚举 |
| `event_text` | TEXT NOT NULL | 一句话，建议 ≤ 60 字 |
| `created_at` | TIMESTAMPTZ NOT NULL | |

索引：`(book_id, character_id, created_at DESC)`，`(book_id, chapter_id)`。

### 2.5 `agent_logs`（仅调试用，轻量）
| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | UUID PK | |
| `chapter_id` | UUID FK → chapters.id ON DELETE SET NULL | 可空 |
| `agent_name` | TEXT NOT NULL | `expander` / `writer` / `extractor` |
| `input_preview` | TEXT | 截断 1KB |
| `output_preview` | TEXT | 截断 2KB |
| `latency_ms` | INTEGER | |
| `tokens_in` | INTEGER | |
| `tokens_out` | INTEGER | |
| `error` | TEXT | 出错信息，否则 NULL |
| `created_at` | TIMESTAMPTZ NOT NULL | |

**不存全量 IO**。需要全量时去 stdout / 文件日志。

### 2.6 `structured_prompt` JSON schema [SHARED]

```json
{
  "chapter_goal": "本章要达成的剧情目标，一两句话",
  "must_happen": ["必须发生的事件 1", "事件 2"],
  "must_not_happen": ["不能出现的事件或元素 1"],
  "characters_involved": ["角色卡 id 列表（UUID 字符串）"],
  "scene_setting": "场景描述（地点、时间、氛围）",
  "narrative_pov": "first_person / third_person_limited / third_person_omniscient",
  "target_word_count": 3000,
  "extra_notes": "其他给写作 Agent 的提示"
}
```
所有字段均为可选；最低要求只有 `chapter_goal` 非空。

### 2.7 枚举 [SHARED]

**`chapters.status`**（5 个状态，简化的状态机）：
```
draft           ── 刚建章，只有 user_prompt
prompt_ready    ── Expander 跑完，structured_prompt 已生成（用户可改）
writing         ── Writer 流式生成中（瞬时状态）
draft_ready     ── 正文生成完毕（用户可改、可重新生成）
finalized       ── 用户点了「完成」，Extractor 已落库
```

允许的转移：
```
draft → prompt_ready                      (POST /expand)
prompt_ready → prompt_ready               (PATCH structured_prompt；用户改)
prompt_ready → writing → draft_ready      (POST /write)
draft_ready → writing → draft_ready       (重新生成)
draft_ready → finalized                   (POST /finalize)
finalized → draft_ready                   (用户「重新打开」；重跑 finalize 时覆盖时间线/摘要)
```

**`timeline_events.event_type`**：
```
action            角色主动做了什么
experience        角色经历了什么（被动）
relation_change   角色关系变化
secret_learned    角色得知秘密
ability_gained    角色获得能力 / 物品
state_change      角色状态变化（受伤 / 痊愈 / 转移地点等）
```

---

## 3. API 契约 [SHARED]

**Base URL**：`/api/v1`
**鉴权**：所有端点要求 `Authorization: Bearer <API_TOKEN>`。Token 通过环境变量配置。
**内容类型**：除 SSE 端点外，全部 `application/json; charset=utf-8`。
**时间格式**：ISO 8601 字符串，UTC。

### 3.1 错误响应格式 [SHARED]

所有非 2xx 响应统一格式：
```json
{
  "error": {
    "kind": "validation | not_found | conflict | upstream | internal | unauthorized",
    "message": "人类可读消息",
    "retryable": false,
    "details": {}
  }
}
```

### 3.2 端点清单

#### 健康检查
```
GET    /api/v1/health
       → 200 {"status": "ok", "version": "..."}
```

#### 书架
```
GET    /api/v1/books
       → 200 { "items": [Book, ...] }

POST   /api/v1/books
       body: { "title": "...", "cover_color": "#3A86FF" }
       → 201 Book

GET    /api/v1/books/{book_id}
       → 200 Book

PATCH  /api/v1/books/{book_id}
       body: 任意 Book 子字段（title / cover_color / world_setting / style_directive）
       → 200 Book

DELETE /api/v1/books/{book_id}
       → 204

POST   /api/v1/books/{book_id}/touch
       (打开书时调用，更新 last_opened_at)
       → 204
```

`Book` 响应 shape：
```json
{
  "id": "uuid",
  "title": "string",
  "cover_color": "string | null",
  "world_setting": "string | null",
  "style_directive": "string | null",
  "chapter_count": 0,
  "character_count": 0,
  "created_at": "iso8601",
  "updated_at": "iso8601",
  "last_opened_at": "iso8601 | null"
}
```

#### 角色卡
```
GET    /api/v1/books/{book_id}/characters
       → 200 { "items": [Character, ...] }

POST   /api/v1/books/{book_id}/characters
       body: { "name": "...", "role": "...", "frozen_fields": {...}, "live_fields": {...} }
       → 201 Character

GET    /api/v1/characters/{character_id}
       → 200 Character

PATCH  /api/v1/characters/{character_id}
       body: 任意 Character 子字段
       → 200 Character

DELETE /api/v1/characters/{character_id}
       → 204

GET    /api/v1/characters/{character_id}/timeline
       query: ?limit=50&before=<iso8601>
       → 200 { "items": [TimelineEvent, ...] }
```

`Character` 响应 shape：
```json
{
  "id": "uuid",
  "book_id": "uuid",
  "name": "string",
  "role": "string | null",
  "frozen_fields": { ... },
  "live_fields": { ... },
  "created_at": "iso8601",
  "updated_at": "iso8601"
}
```

`TimelineEvent` 响应 shape：
```json
{
  "id": "uuid",
  "book_id": "uuid",
  "character_id": "uuid",
  "chapter_id": "uuid",
  "chapter_index": 3,
  "event_type": "action | experience | relation_change | secret_learned | ability_gained | state_change",
  "event_text": "string",
  "created_at": "iso8601"
}
```

#### 章节
```
GET    /api/v1/books/{book_id}/chapters
       → 200 { "items": [ChapterSummary, ...] }
       ChapterSummary 只含: id, index, title, status, updated_at

POST   /api/v1/books/{book_id}/chapters
       body: { "user_prompt": "...", "title": "...?" }
       index 由后端自动分配（当前最大 + 1）
       → 201 Chapter

GET    /api/v1/chapters/{chapter_id}
       → 200 Chapter

PATCH  /api/v1/chapters/{chapter_id}
       body: 任意 Chapter 子字段（title / user_prompt / structured_prompt / draft_text）
       注意：直接 PATCH 不会触发 Agent；只是手工编辑落库
       → 200 Chapter

DELETE /api/v1/chapters/{chapter_id}
       → 204
       注：删除会把后续章节 index 自然空出，不重排
```

`Chapter` 响应 shape：
```json
{
  "id": "uuid",
  "book_id": "uuid",
  "index": 1,
  "title": "string | null",
  "user_prompt": "string | null",
  "structured_prompt": { ...见 §2.6 } | null,
  "draft_text": "string | null",
  "summary": "string | null",
  "status": "draft | prompt_ready | writing | draft_ready | finalized",
  "created_at": "iso8601",
  "updated_at": "iso8601"
}
```

#### 流程动作（核心）
```
POST   /api/v1/chapters/{chapter_id}/expand
       body: {} （强制重跑用 ?force=true）
       前置：status == draft 或 prompt_ready（force 时不限）
       动作：调用 Expander Agent，落 structured_prompt，status → prompt_ready
       → 200 Chapter

POST   /api/v1/chapters/{chapter_id}/write
       Accept: text/event-stream
       前置：status == prompt_ready 或 draft_ready
       动作：SSE 流式生成正文。期间 status = writing；结束 status = draft_ready
       → 200 SSE stream（见 §4）

POST   /api/v1/chapters/{chapter_id}/finalize
       body: {}
       前置：status == draft_ready
       动作：跑 Extractor → 更新角色卡 live_fields、追加 timeline_events、写 summary
            status → finalized
       → 200 { "chapter": Chapter, "updated_character_ids": [...], "added_event_ids": [...] }

POST   /api/v1/chapters/{chapter_id}/reopen
       body: {}
       前置：status == finalized
       动作：删除本章产生的 timeline_events、清空 summary；status → draft_ready
            角色卡的 live_fields 不自动回滚（用户自行处理或下次 finalize 时被覆盖）
       → 200 Chapter
```

#### 调试
```
GET    /api/v1/admin/logs?chapter_id=...&limit=50
       → 200 { "items": [AgentLog, ...] }
```

---

## 4. SSE 协议（写作流式） [SHARED]

`POST /api/v1/chapters/{id}/write` 返回 `text/event-stream`。事件类型：

```
event: started
data: {"chapter_id": "uuid"}

event: token
data: {"text": "续写的文本片段"}

event: progress
data: {"chars": 1234}

event: done
data: {"chapter": { ...完整 Chapter，status=draft_ready }}

event: error
data: {"error": {"kind": "upstream", "message": "...", "retryable": true}}
```

- 每条 SSE message 之间用空行分隔；`data` 为单行 JSON。
- 客户端遇到 `done` 或 `error` 即关闭连接。
- 心跳：服务端每 15 秒发一条注释行 `: keepalive\n\n`。

---

## 5. 后端项目结构

```
LinoWritingV2/Backend/
├── app/
│   ├── __init__.py
│   ├── main.py                    # FastAPI app, mount routers, lifespan
│   ├── config.py                  # Pydantic Settings（DATABASE_URL, GROK_API_KEY, API_TOKEN, MODEL_NAME 等）
│   ├── db.py                      # SQLAlchemy engine + session
│   ├── auth.py                    # Bearer token middleware
│   ├── errors.py                  # 异常类型 + 全局异常 handler
│   │
│   ├── models/                    # SQLAlchemy 2.0 declarative
│   │   ├── __init__.py
│   │   ├── book.py
│   │   ├── character.py
│   │   ├── chapter.py
│   │   ├── timeline_event.py
│   │   └── agent_log.py
│   │
│   ├── schemas/                   # Pydantic v2 schemas
│   │   ├── __init__.py
│   │   ├── book.py
│   │   ├── character.py
│   │   ├── chapter.py
│   │   ├── timeline.py
│   │   └── structured_prompt.py   # §2.6 schema
│   │
│   ├── routers/
│   │   ├── __init__.py
│   │   ├── health.py
│   │   ├── books.py
│   │   ├── characters.py
│   │   ├── chapters.py            # 含 expand / write / finalize / reopen
│   │   └── admin.py
│   │
│   ├── services/
│   │   ├── __init__.py
│   │   ├── context_pack.py        # build_writing_context()
│   │   ├── chapter_state.py       # 状态机 + 转移合法性
│   │   └── extractor_apply.py     # 把 Extractor 输出落库（更新 live_fields, 追加 timeline, 写 summary）
│   │
│   ├── agents/
│   │   ├── __init__.py
│   │   ├── base.py                # AgentInput / AgentResult 基类
│   │   ├── prompt_expander.py
│   │   ├── writer.py              # 支持流式
│   │   └── extractor.py
│   │
│   └── llm/
│       ├── __init__.py
│       ├── base.py                # LLMClient 接口
│       ├── grok.py                # GrokClient（OpenAI 兼容 API）
│       └── errors.py
│
├── alembic/
│   ├── versions/
│   ├── env.py
│   └── script.py.mako
├── alembic.ini
│
├── tests/
│   ├── conftest.py                # 测试用 in-memory SQLite / pytest fixtures
│   ├── test_books.py
│   ├── test_characters.py
│   ├── test_chapters_flow.py      # 端到端：建章 → expand → write → finalize
│   ├── test_context_pack.py
│   └── test_agents_with_mock.py
│
├── docker-compose.yml             # postgres + backend
├── Dockerfile
├── pyproject.toml
├── .env.example
└── README.md
```

---

## 6. Agent 实现规范

### 6.1 通用：`LLMClient` 接口

```python
class LLMClient(Protocol):
    def complete(self, *, system: str, user: str, **kwargs) -> str: ...
    def complete_json(self, *, system: str, user: str, schema: dict, **kwargs) -> dict: ...
    def complete_stream(self, *, system: str, user: str, **kwargs) -> Iterator[str]: ...
```

**`GrokClient`** 实现：
- xAI API 端点：`https://api.x.ai/v1/chat/completions`（OpenAI 兼容）
- 模型名走配置（默认 `grok-4`，可改为 `grok-4-mini` 等便宜模型）
- `complete_json` 用 `response_format: {"type": "json_object"}` + system prompt 内嵌 schema
- 重试：网络错误重试 2 次，指数退避；非 retryable 错误直接抛
- 超时：默认 180s（写作）/ 60s（其他）

### 6.2 PromptExpanderAgent

**输入**：
- `book`: 含 world_setting, style_directive
- `chapter.user_prompt`: 50 字
- `recent_summaries`: 最近 2 章摘要（如有）
- `all_characters`: 该书所有角色卡的精简版（id, name, role, 一句话画像）

**输出**：符合 §2.6 schema 的 JSON。

**System prompt 要点**：
- 你是一个中文小说的剧情扩写助手
- 根据用户的简短意图，扩写为结构化的章节蓝图
- 必须从 `all_characters` 里选定 `characters_involved`（用 id）
- 必须发生 / 禁发生 要具体、可验证
- 风格上参考 `style_directive`（若有）

### 6.3 WriterAgent

**输入**（即 Context Pack，由 `services/context_pack.py` 拼装）：
```python
{
  "world_setting": str,
  "style_directive": str,
  "structured_prompt": dict,
  "characters": [
    {"id": ..., "name": ..., "role": ..., "frozen_fields": {...}, "live_fields": {...}}
    # 仅 structured_prompt.characters_involved 里的
  ],
  "timelines": {
    "<character_id>": [recent 15 events, oldest → newest]
  },
  "recent_summaries": [
    {"index": 1, "summary": "..."},
    {"index": 2, "summary": "..."}
  ]
}
```

**输出**：流式纯文本正文。

**System prompt 要点**：
- 你是一个中文小说的写作执行者
- 严格遵守 `frozen_fields`（人设不能漂）
- 必须发生的事必须写到；禁发生的事一字不提
- 利用 `timelines` 保持角色行为的连续性（他知道什么、不知道什么、目标是什么）
- 风格遵循 `style_directive`
- 目标字数 `target_word_count`，允许 ±20%

### 6.4 ExtractorAgent

**输入**：
- `chapter.draft_text`：本章正文
- `characters`：该书所有角色卡（完整）

**输出 JSON**：
```json
{
  "summary": "200 字章节摘要",
  "timeline_events": [
    {"character_id": "uuid", "event_type": "action", "event_text": "..."},
    ...
  ],
  "character_updates": [
    {
      "character_id": "uuid",
      "live_fields_patch": {
        "current_status": "新值",
        "goals": ["新值"],
        "secrets_known": ["追加项"]
      }
    }
  ]
}
```

**System prompt 要点**：
- 从正文中抽取本章发生的关键事件，按出场角色归属
- 每条事件一句话，≤ 60 字
- 角色 live_fields 的 patch：只输出**需要变化**的子字段，未变化的不输出
- `secrets_known` / `abilities` / `goals` 等数组字段：用「全量替换」语义（你输出什么就是新值）；不是追加
- summary：200 字内，第三人称客观叙述本章发生了什么
- **不要修改 frozen_fields**（即使发现矛盾，也只在 live 上调整）

**落库**（`services/extractor_apply.py`）：
1. 写 `chapter.summary`
2. 对每条 character_update：合并 patch 到 `live_fields`（浅合并，子字段全量替换）
3. 批量插入 `timeline_events`
4. 全部在单个事务里完成；失败回滚，状态保持 draft_ready

### 6.5 Context Pack 构建函数

`app/services/context_pack.py`：
```python
def build_expander_context(db, book, chapter) -> dict: ...
def build_writer_context(db, book, chapter) -> dict: ...
def build_extractor_context(db, book, chapter) -> dict: ...
```
所有调用 Agent 之处都先过这三个函数，**Agent 内部不查 DB**。

---

## 7. 配置与环境变量

`.env.example`：
```
# Database
DATABASE_URL=postgresql+psycopg://novelos:novelos@localhost:5432/novelos

# Auth
API_TOKEN=change-me-to-a-long-random-string

# Grok
GROK_API_KEY=xai-...
GROK_BASE_URL=https://api.x.ai/v1
MODEL_NAME=grok-4
MODEL_NAME_FAST=grok-4-mini   # 可选：给 Expander/Extractor 用便宜模型

# Misc
LOG_LEVEL=INFO
CORS_ORIGINS=*
```

---

## 8. 本地开发流程

```bash
cd LinoWritingV2/Backend

# 一键起 Postgres + 后端
docker compose up -d postgres
cp .env.example .env  # 填入 GROK_API_KEY、改 API_TOKEN

# Python 环境（推荐 uv 或 pip）
uv sync   # 或 pip install -e .[dev]

# DB 迁移
alembic upgrade head

# 跑服务
uvicorn app.main:app --reload --port 8787
```

健康检查：`curl -H "Authorization: Bearer <token>" http://localhost:8787/api/v1/health`

---

## 9. 测试要求

最低限度：
- 端到端流程测试（用 MockLLMClient）：建书 → 加角色 → 建章 → expand → write → finalize → 验证 timeline + live_fields 已更新
- 状态机转移测试：非法转移返回 409 conflict
- 鉴权测试：缺 token → 401；错 token → 401
- Context Pack 测试：出场角色过滤、最近摘要数限制

**禁止**：跑真实 Grok 的测试默认 skip（用 env var `RUN_LIVE_LLM=1` 才跑）。

---

## 10. 部署

**云端**：单台 VPS 起 Docker Compose（Postgres + 后端 + Caddy/Nginx 终结 TLS）。
**域名**：用户自行准备。
**备份**：每日 `pg_dump` 到对象存储（实现不强求，提供脚本即可）。

部署文件放 `Backend/deploy/`：
- `docker-compose.prod.yml`
- `Caddyfile` 或 `nginx.conf`
- `backup.sh`

---

## 11. 显式不做的事

为了不让复杂度回流，以下事项**v2 阶段一律不做**：

- ❌ 多用户 / 用户系统 / OAuth
- ❌ Audit Agent（Knowledge / Continuity / NamedEntity 三审）
- ❌ Revision Agent（自动重写）
- ❌ Canon Edit History（细粒度版本/回滚）
- ❌ Context Pack 持久化表
- ❌ Knowledge Matrix 可见性矩阵
- ❌ 章节版本表（用 PATCH 直接覆盖 draft_text）
- ❌ 章节导入 / Bootstrap Agent
- ❌ WebSocket（流式用 SSE 即可）
- ❌ 自动语义检索 / 向量库（每章 Context Pack 用 SQL 查询即可）

---

## 12. 与前端的交付约定

**Agent 协同要求**：
- 任何修改 §0-§4（SHARED 章节）的需求，必须**同时**改 `PLAN_FRONTEND.md` 对应章节；不允许单边修改。
- API 行为以本文件 §3 为准，前端按此对接。
- SSE 协议以本文件 §4 为准。
- 完成后向 Integrator 交付：可运行的后端 + 一份 OpenAPI JSON（FastAPI 自动生成，位于 `/docs` 与 `/openapi.json`）+ 一份「已实现端点 ✓ / 已知偏差」清单。

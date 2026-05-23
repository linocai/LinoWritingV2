# Lino Writing v2 · 前端施工计划

> 本文档是前端施工 Agent 的唯一行动依据。
> 标注 `[SHARED]` 的章节与 `PLAN_BACKEND.md` **逐字相同**——这是前后端的契约层。修改任何 SHARED 章节前，必须同步修改另一份文档；否则两侧会南辕北辙。
>
> 文档版本：v0.5（定稿）
> 关联文档：`PLAN_BACKEND.md`

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

## 5. 前端项目结构

技术栈：**SwiftUI**（Xcode 项目，含 macOS 与 iOS 双 target；先实现 macOS，iOS 设计上预留）。

```
LinoWritingV2/App/
├── LinoWriting.xcodeproj
├── LinoWriting/                       # 主应用源码（双平台共享）
│   ├── App/
│   │   ├── LinoWritingApp.swift       # @main, root scene
│   │   └── AppEnvironment.swift       # 注入 stores / services
│   │
│   ├── Models/                        # 与后端契约对齐的 DTO
│   │   ├── Book.swift
│   │   ├── Character.swift
│   │   ├── Chapter.swift
│   │   ├── StructuredPrompt.swift
│   │   ├── TimelineEvent.swift
│   │   └── AgentLog.swift
│   │
│   ├── Services/
│   │   ├── APIClient.swift            # 统一封装 URLSession + 鉴权 header
│   │   ├── SSEClient.swift            # text/event-stream 解析（用 URLSession bytes API）
│   │   ├── KeychainStore.swift        # 存 API token / base URL
│   │   ├── ErrorMapping.swift         # 后端错误 envelope → AppError
│   │   └── Settings.swift             # 用户偏好（窗口大小、最近选书 id 等）
│   │
│   ├── Stores/                        # ObservableObject / @Observable
│   │   ├── AppStore.swift             # 顶层：当前书、token 状态
│   │   ├── BookshelfStore.swift       # 书架列表
│   │   ├── BookStore.swift            # 当前书的元数据 + 子 store 协调
│   │   ├── CharactersStore.swift      # 当前书的角色卡列表
│   │   ├── ChaptersStore.swift        # 当前书的章节列表
│   │   ├── ChapterEditorStore.swift   # 当前打开的章节（含流式写作状态）
│   │   └── TimelineStore.swift        # 角色时间线（按需加载）
│   │
│   ├── Views/
│   │   ├── Root/
│   │   │   ├── RootView.swift         # 切换：未连接配置 / 书架 / 工作台
│   │   │   └── SettingsView.swift     # 配置后端 URL + token
│   │   │
│   │   ├── Bookshelf/
│   │   │   ├── BookshelfView.swift    # 网格卡片
│   │   │   ├── BookCardView.swift
│   │   │   └── NewBookSheet.swift
│   │   │
│   │   ├── Workspace/
│   │   │   ├── WorkspaceView.swift    # 三栏布局
│   │   │   ├── Sidebar/
│   │   │   │   ├── ChapterListView.swift
│   │   │   │   └── NewChapterSheet.swift
│   │   │   ├── Editor/
│   │   │   │   ├── ChapterEditorView.swift     # 5 步 stepper
│   │   │   │   ├── Step1_PromptInputView.swift
│   │   │   │   ├── Step2_StructuredPromptView.swift
│   │   │   │   ├── Step3_DraftView.swift       # 流式渲染
│   │   │   │   └── ChapterToolbar.swift        # 状态显示 + 完成按钮
│   │   │   └── RightPanel/
│   │   │       ├── RightPanelView.swift        # 四 tab：角色卡 / 时间线 / 摘要 / 世界设定
│   │   │       ├── CharacterCardListView.swift
│   │   │       ├── CharacterCardEditorView.swift   # 文档式 inline 编辑（重点）
│   │   │       ├── TimelineTabView.swift
│   │   │       ├── SummariesTabView.swift
│   │   │       └── WorldSettingTabView.swift
│   │   │
│   │   └── Components/
│   │       ├── InlineEditableText.swift          # 点击编辑、失焦保存
│   │       ├── InlineEditableTags.swift          # 数组字段（goals/secrets_known 等）
│   │       ├── DotIndicator.swift                # 字段旁的小红点（标 Agent 新改）
│   │       ├── StatusBadge.swift                 # 章节状态徽章
│   │       └── ErrorBanner.swift
│   │
│   ├── Resources/
│   │   ├── Assets.xcassets
│   │   └── Localizable.xcstrings              # 默认 zh-Hans
│   │
│   └── Platform/                              # 平台差异收敛在这
│       ├── PlatformAliases.swift              # NSColor/UIColor 等别名
│       └── KeyboardShortcuts.swift
│
├── LinoWritingTests/
│   ├── APIClientTests.swift
│   ├── SSEClientTests.swift
│   └── StoreTests.swift
│
└── README.md
```

**双平台原则**：
- 默认 SwiftUI 跨平台 API；
- 平台差异（NSColor / UIColor、菜单、`.frame(minWidth:)` 等）统一放 `Platform/` 下用 `#if os(macOS)` 收敛；
- 严禁在 View 文件里散落 `#if os(...)`。

---

## 6. 关键 UX 与实现要点

### 6.1 启动与配置

- App 启动检测 Keychain 里是否有 `api_base_url` + `api_token`；没有 → 弹 `SettingsView` 强制配置；有 → 进 `BookshelfView`。
- 顶部菜单（macOS）：`LinoWriting → 设置...` 随时可改。
- 网络层每次请求都加 `Authorization: Bearer <token>`。

### 6.2 书架

- 网格布局（macOS 三列，iOS 两列），每张卡片：纯色封面 + 书名 + 「N 章 · 上次打开 XX」。
- 排序：按 `last_opened_at desc, updated_at desc`。
- 点击卡片：先 `POST /books/{id}/touch` 再进 Workspace。
- 右上角 `+` 按钮 → `NewBookSheet`（书名、封面色，可空），创建后直接进 Workspace。
- 卡片右键 / 长按菜单：改名、改封面色、删除（二次确认）。

### 6.3 Workspace 三栏布局

```
┌──────────┬───────────────────────────┬──────────────┐
│ 章节列表  │   ChapterEditorView       │ RightPanel   │
│ (200pt)  │   (flex)                  │ (320pt)      │
│          │                           │              │
│ 第1章 ✓  │  ┌─Step1: prompt──────┐   │ [角色卡] tab │
│ 第2章 ✓  │  │ ...                │   │ [时间线]     │
│ 第3章 ▶  │  │   [扩写]           │   │ [摘要]       │
│ ...      │  └────────────────────┘   │ [世界设定]   │
│          │  ┌─Step2: 结构化提示─┐    │              │
│ + 新章节  │  │ ...                │   │              │
│          │  │   [写作]           │   │              │
│          │  └────────────────────┘   │              │
│          │  ┌─Step3: 正文────────┐   │              │
│          │  │ 流式生成中...      │   │              │
│          │  │   [完成]           │   │              │
│          │  └────────────────────┘   │              │
└──────────┴───────────────────────────┴──────────────┘
```

- 左栏可折叠（macOS：拖拽分隔条；iOS：抽屉）。
- 右栏可折叠或切换为浮层（iOS）。

### 6.4 章节编辑器（5 步 stepper）

按 `chapter.status` 决定可见 / 可操作的步骤：

| 状态 | Step1 | Step2 | Step3 | 主操作 |
|---|---|---|---|---|
| `draft` | 可编辑 | 隐藏/灰 | 隐藏 | 「扩写」 |
| `prompt_ready` | 折叠可展开 | 可编辑 | 隐藏 | 「写作」 |
| `writing` | 折叠 | 折叠 | 流式渲染 | （进行中） |
| `draft_ready` | 折叠 | 折叠 | 可编辑 | 「完成」/「重新生成」 |
| `finalized` | 只读 | 只读 | 只读 | 「重新打开」 |

**关键交互**：
- Step1 输入框限制建议字数（不强制；超过给软提示）。
- 「扩写」按钮 → `POST /chapters/{id}/expand`。Loading 期间禁用按钮，错误显示 `ErrorBanner`。
- 「写作」按钮 → 打开 SSE 流。每个 `token` event 追加到本地缓冲，View 实时渲染。`done` 事件落到 store 并切到 `draft_ready`。流被中断也要让 UI 回到可恢复状态（按钮再次可用）。
- 「完成」按钮 → `POST /chapters/{id}/finalize`，成功后右侧角色卡面板要刷新（带小红点）。

### 6.5 角色卡编辑器（重点重做项）

**这是上一代项目最大的痛点。新版要求**：

- **不是表单**。每个字段是 inline-editable 文本块，点击即可进入编辑，失焦自动保存（PATCH）。
- 视觉上**冻结区与活动区分两段**显示，冻结区有锁图标但仍可编辑（只是视觉提醒「这是定死的」）。
- 数组字段（`goals`、`secrets_known`、`abilities` 等）：标签式 UI，回车新增、点 × 删除。
- 对象字段（`relationships`）：键值对列表 UI。
- 任何由 Agent 在最近一次 finalize 改动过的字段，**字段名旁显示一个小红点**（`DotIndicator`）。用户点击该字段查看或编辑后，小红点消失。
- 小红点状态记在前端 store（不需要后端字段）；策略：每次 `finalize` 成功返回的 `updated_character_ids` 全部标记为「有新改动」；点击进入编辑该角色卡的任一活动字段就清除该角色的标记。
  - 简化版可接受：finalize 后整张卡显一个小红点徽章，点开即清。先按这个做，再迭代到字段级。
- 「+ 新建角色卡」表单：只要 `name`，其余可选，进入后立刻可编辑全部字段。
- 「删除角色卡」需二次确认，并提示「该角色的所有时间线也会被删除」。

### 6.6 时间线 tab

- 顶部下拉选角色（默认当前 structured_prompt.characters_involved 的第一个）。
- 列表显示该角色的事件：`第 N 章 · [event_type 标签] · event_text`。
- 倒序，按 `created_at desc`，分页 `before=<created_at>` 加载更多。
- 每条 event 可编辑 `event_text` 与 `event_type`（PATCH 走 `/timeline_events/{id}`——后端补一个 PATCH 端点，加进 §3.2 时同步两边文档；首版可不开，后端先不实现，前端先只读）。

> **注**：v0.5 仍为**只读时间线**。"编辑事件"作为后续迭代。Integrator 校验时如未在 §3.2 出现 timeline PATCH 端点，前端按只读处理。

### 6.7 摘要 tab

- 列表显示所有已 finalized 章节的 `第 N 章 · title · summary`。
- 倒序。点击跳转到该章节。

### 6.8 世界设定 tab

- 双区：`world_setting` 与 `style_directive`。
- 都是 markdown 文本框（不需要富文本，纯文本编辑+monospace 字体即可）。
- 失焦自动 PATCH 到 `/books/{id}`。

### 6.9 错误与加载

- 全局 `ErrorBanner` 组件，顶部下滑出现，3s 自动消失，可点击关闭。
- 流式写作中断 → banner 提示「写作中断，可点重新生成」。
- 401 → 弹出 SettingsView 让用户改 token。

---

## 7. 网络层与流式实现

### 7.1 `APIClient`

- 基于 `URLSession`，统一注入 `Authorization` header 与 `Content-Type: application/json`。
- 返回 `Result<T, AppError>` 或 `async throws`。
- 解析后端 §3.1 错误 envelope → `AppError`。
- Base URL 从 `KeychainStore.shared.baseURL` 读取，运行时可变。

### 7.2 `SSEClient`

- 用 `URLSession.bytes(for:)` 拿 `AsyncSequence<UInt8>`。
- 自行解析 `event:` / `data:` 行（按空行分包）。
- 暴露 `AsyncStream<SSEEvent>` 给 `ChapterEditorStore` 消费。
- 支持取消（`task.cancel()`）；取消时不算错误。

### 7.3 Store 流式状态

`ChapterEditorStore` 在写作期间维护：
```swift
enum WritingState {
    case idle
    case streaming(buffer: String, chars: Int)
    case done
    case failed(AppError)
}
```
View 直接绑定 `streaming.buffer` 渲染。

---

## 8. 配置项与持久化

| 项 | 存储位置 | 说明 |
|---|---|---|
| API base URL | Keychain | 由用户在 SettingsView 填 |
| API token | Keychain | 同上 |
| 最近打开书 id | UserDefaults | 启动后可自动恢复 |
| 窗口大小、分栏比例 | UserDefaults（macOS）/ SceneStorage（iOS） | |
| 角色卡字段「有新改动」标记 | 内存 + 可选 UserDefaults | 不持久化也可接受 |

---

## 9. 本地开发流程

```bash
cd LinoWritingV2/App

# 打开 Xcode 项目
open LinoWriting.xcodeproj

# 首次运行：
# 1. 选 macOS scheme，Run
# 2. 弹出 SettingsView，填 http://localhost:8787 与 API_TOKEN
# 3. 进入空书架，新建第一本书
```

要求 Xcode 16+，macOS 14+，iOS 17+（SwiftUI 新 Observation 框架可选用）。

---

## 10. 测试要求

- `APIClient` 单测：404 / 401 / 5xx envelope 解析；正常请求序列化反序列化。
- `SSEClient` 单测：构造一段 SSE 字节流，验证事件正确切分与解析。
- `Store` 单测（用 mock `APIClient`）：建章 → expand → write → finalize 流程下，store 状态变化符合预期。
- UI snapshot 测试可选，不强求。

---

## 11. 显式不做的事

为了不让复杂度回流，以下事项**v2 阶段一律不做**：

- ❌ 多账号 / 登录页 / 注册流程
- ❌ 富文本编辑器（正文用 `TextEditor` 即可）
- ❌ 多人协作 / 在线状态
- ❌ 应用内购 / 计费 UI
- ❌ 复杂主题切换（跟随系统 light/dark 即可）
- ❌ 章节版本对比 / diff 视图
- ❌ 全文搜索 / 全局检索
- ❌ 自定义 Agent prompt（system prompt 由后端决定）
- ❌ 离线模式（v2 不做本地缓存层）

---

## 12. 与后端的交付约定

**Agent 协同要求**：
- 任何修改 §0-§4（SHARED 章节）的需求，必须**同时**改 `PLAN_BACKEND.md` 对应章节；不允许单边修改。
- 请求/响应 payload shape 与 §3 完全一致；如发现不一致以 `PLAN_BACKEND.md` 为准并立刻标 issue。
- SSE 协议以 §4 为准。
- 后端启动后可访问 `/openapi.json` 拿到完整 OpenAPI 描述，作为对接校验依据。
- 完成后向 Integrator 交付：可运行的 Xcode 项目 + 一份「已实现 View ✓ / 已对接端点 ✓ / 已知偏差」清单。

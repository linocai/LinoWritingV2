# Lino Writing v2 · PROJECT PLAN

> 本文档是 v0.6 起的**单一项目行动依据**。前端、后端、契约层全部合并在此。
> v0.1–v0.5 期间使用 `PLAN_FRONTEND.md` / `PLAN_BACKEND.md` 双契约工作流，作为 v0.5 契约存档保留，不再更新。
>
> 文档版本：v0.6（已发布）
> 关联存档：`PLAN_FRONTEND.md`（v0.5 前端契约存档）、`PLAN_BACKEND.md`（v0.5 后端契约存档）

---

## 0. 文档定位与工作流约定

### 0.1 单一行动依据

自 v0.6 起，本文档同时承担:
- 项目当前状态总览
- 升级路线图与候选池
- 当前迭代（v0.6/v0.7/…）的 Phase 拆分与接口契约
- 候选方案设计存档

**任何代码改动开始前，必须先回到本文档定义/更新对应 Phase。**

### 0.2 三 Agent 工作流

| 角色 | 职责 | 输入 | 输出 |
|---|---|---|---|
| **planner** | 拆 Phase、定接口契约、做技术选型 | 用户需求 + 当前 PROJECT_PLAN | 更新 §4 或 §5 的 Phase 段 |
| **builder** | 按 Phase 严格实施代码 | PROJECT_PLAN 的某个 Phase | 代码 + 测试 |
| **reviewer** | 独立审计、对照 plan 检查实现完整性 | 代码 + PROJECT_PLAN | 审查报告 |

**单一行动依据原则**：builder 只看本文档；reviewer 只对照本文档；任何超出本文档范围的需求，planner 必须先把需求落进文档，再由 builder 执行。

### 0.3 版本号约定

- **MAJOR.MINOR.PATCH** 三段式
- 前端：`App/project.yml` 的 `MARKETING_VERSION`
- 后端：`Backend/pyproject.toml` 的 `version` + `Backend/app/main.py` 的 FastAPI `version` + `Backend/app/routers/health.py` 的 health response
- 测试：`Backend/tests/test_auth.py` 的 assertion
- 发版时统一同步以上 5 处，并在 git commit message 标注

---

## 1. 当前版本状态 (v0.6 — 已发布)

### 1.1 v0.6 新增能力(在 v0.5 基础上)

**前端**
- 响应式三档窗口断点(< 800 / 800-1099 / ≥ 1100):窄屏自动折叠 Sidebar / RightPanel 成 sheet,最小窗口降到 880×580 [§5.K.3]
- 苹果风美学:Sidebar `.regularMaterial` + RightPanel `.thinMaterial`、`.toolbarRole(.editor)`、`.windowToolbarStyle(.unifiedCompact)`、章节卡 / 角色卡 / 时间线卡 Material 化 [§5.K.4]
- 全局 `.smooth` 动画:状态切换 / 章节切换 / 角色卡切换 / StatusBadge contentTransition [§5.K.4]
- 章节正文字体可切 serif/sans(`Settings.editorFontDesign`,默认 serif) [§5.K.4]
- Toast 错误条(右下角 `.thinMaterial` 胶囊,取代 v0.5 ErrorBanner) [§5.K.4]
- BookCard / ChapterList row hover 抬升 + macOS pointing-hand cursor [§5.K.4]
- App 内 LLM Provider 管理(Connection / LLM Providers 两 tab,增删改 + 设 active,Preset 一键预填 xAI / OpenAI / OpenRouter / DeepSeek / Custom) [§5.E.6]
- 章节"导入文本"入口(ChapterToolbar 按钮 → ImportChapterSheet,可选跑 Extractor,imported 章节在 sidebar 加角标) [§5.A.6]
- 测试:34 个 XCTest(17 v0.5 + 10 ProviderKeys + 6 ChaptersStore import + 1 nil-encoding regression)

**后端**
- `provider_keys` + `system_settings` 数据层 + 6 个 CRUD/active 端点(api_key 永末 4 位掩码,`api_key_mask` 字段命名清晰) [§5.E.3 / §5.E.4]
- LLM client 工厂(per-request 实例化,`OpenAICompatibleClient` 单一实现 — 任意 OpenAI 兼容 endpoint 都能接入) [§5.E.5]
- `.env` 兼容性迁移(首次启动从 `GROK_API_KEY` 自动播种 active key,保护 v0.5 部署) [§5.E.7]
- `POST /chapters/{id}/import` 端点(响应与 finalize 同 shape,严守 status 白名单避免 SSE race) [§5.A.4]
- Writer context_pack 加 `style_samples`(最近 2 章 head 400 + tail 400 字,agent 与 imported 章节一视同仁) [§5.A.5]
- `chapter.source` 字段(`'agent' | 'imported'`) [§5.A.3]
- 测试:57 个 pytest(12 v0.5 + 14 provider_keys + 8 llm_factory + 9 chapter_import + 5 style_samples + 4 writer_prompt + 4 env_migration + 1 SSE no-key regression)

### 1.2 v0.5 能力(继承,无变更)

**前端**:书架、3 栏 Workspace、5 步章节编辑器、SSE 流式写作、角色卡 inline 编辑、右栏 4 tab、Keychain。

**后端**:5 张业务表 + 1 张调试表、23 个 v0.5 端点(总 29 个 with v0.6 新增)、3 个 Agent、Context Pack 装配、Extractor 事务性写入。

### 1.3 v0.6 已知残留 todo(移入升级候选池)

- 字段级 dot indicator(当前是卡片级简化版) → §3 B
- TimelineEvent 编辑(当前只读) → §3 C
- Admin Log Panel UI(APIClient 已暴露 `listAgentLogs`,UI 缺) → §3 D
- A-2 reviewer 留下的 4 个非阻塞 🟡(import 副作用编排 helper / Sheet load-then-dismiss 顺序 / errorBus 断言风格 / 880×580 窗口下 sheet 显示 GUI 验证) — 留 v0.6.1
- 上线前需把 `CODE_SIGNING_ALLOWED: NO` 切回 Automatic

---

## 2. 项目结构总览

```
LinoWritingV2/
├── PROJECT_PLAN.md            ← 本文档（v0.6+ 单一行动依据）
├── PLAN_FRONTEND.md           ← v0.5 前端契约存档
├── PLAN_BACKEND.md            ← v0.5 后端契约存档
│
├── App/                       ← SwiftUI 前端
│   ├── project.yml            ← xcodegen 配置，版本号在此
│   ├── LinoWriting.xcodeproj  ← 生成产物
│   ├── LinoWriting/
│   │   ├── App/               ← @main, AppEnvironment (DI)
│   │   ├── Models/            ← 11 个 Codable DTO
│   │   ├── Services/          ← APIClient, SSEClient, Keychain, ErrorMapping, Settings
│   │   ├── Stores/            ← 7 个 ObservableObject
│   │   ├── Views/             ← Root, Bookshelf, Workspace, Components
│   │   ├── Platform/          ← #if os(macOS) 隔离
│   │   └── Resources/         ← Assets, AppIcon, Localizable.xcstrings
│   ├── LinoWritingTests/      ← XCTest 17 个
│   └── README.md
│
└── Backend/                   ← FastAPI 后端
    ├── pyproject.toml         ← 版本号 & 依赖
    ├── app/
    │   ├── main.py            ← FastAPI app
    │   ├── config.py          ← Pydantic Settings
    │   ├── auth.py / errors.py / db.py
    │   ├── models/            ← 5 个 SQLAlchemy 模型
    │   ├── schemas/           ← Pydantic DTOs
    │   ├── routers/           ← health/books/characters/chapters/admin
    │   ├── services/          ← context_pack / chapter_state / extractor_apply
    │   ├── agents/            ← base / prompt_expander / writer / extractor
    │   └── llm/               ← grok / base / errors
    ├── alembic/               ← 迁移脚本
    ├── tests/                 ← pytest 12 个
    ├── deploy/                ← docker-compose.prod / Caddyfile / backup.sh
    └── README.md
```

---

## 3. 升级候选池

候选项分为 4 种状态：
- 🟢 **就绪**：方案已讨论，详案见 §5，可随时进 v0.X 清单
- 🟡 **粗线**：方向已定，详案待补
- 🔵 **待讨论**：仅记录方向，未做设计
- ⚫ **已剔除**：明确不做（不进路线图）

| 编号 | 主题 | 状态 | 详案 |
|---|---|---|---|
| **A** | 前文导入 + 文风学习 | 🟢 就绪 | §5.A |
| **B** | 字段级 dot indicator（v0.5 残留） | 🟡 粗线 | §5.B |
| **C** | TimelineEvent 编辑（v0.5 残留） | 🟡 粗线 | §5.C |
| **D** | Admin Log Panel UI（v0.5 残留） | 🟡 粗线 | §5.D |
| **E** | 多 LLM Key 管理（OpenAI-compatible 统一协议，App 内管理） | 🟢 就绪 | §5.E |
| **F** | 章节/全书导出（markdown / txt） | 🔵 待讨论 | — |
| **J** | 全文搜索 | 🔵 待讨论 | — |
| **K** | 响应式布局 + 苹果风美学升级 | 🟢 就绪 | §5.K |

剔除项（不进路线图）：
- ⚫ G. 卷/章节分组
- ⚫ H. 写作统计面板
- ⚫ I. 章节历史版本/diff

---

## 4. 当前迭代

### 4.1 v0.6 — ✅ 已发布

**目标**：试运营就绪版。让 app 在多窗口尺寸下美观、支持 App 内填写多家 LLM Key、能导入用户已写的章节让 Writer 学到本人文风。**目标达成**。

**清单**：

```
[x] A — 前文导入 + 文风学习（§5.A）        ✅ A-1 + A-2 全过
[x] E — 多 LLM Key 管理 OpenAI-compatible  ✅ E-1 + E-2 + E-3 全过
[x] K — 响应式布局 + 苹果风美学升级（§5.K）✅ K-1 + K-2 + K-3 全过

[ ] B / C / D / F / J — 推后到 v0.7+
```

**实际 Phase 落地时间线**(commit 顺序):
- `f6c02c0` E-1 后端 provider_keys 数据层
- `4a9e948` E-2 后端 LLM client 工厂 + OpenAI-compatible 单实现
- `87a95c2` K-1 前端响应式断点
- `8da4472` A-1 后端 chapter import + style_samples
- `c14b267` K-2 前端 Material + Toolbar + Toast
- `1248cad` K-3 前端动画 + serif 字体 + StatusBadge transition
- `9431c7e` E-3 前端 LLM Providers UI
- `<this commit>` A-2 前端 import 按钮 + Sheet + v0.6 发版同步

**Phase 排序**：

| 序号 | Phase | 依赖 | 可并行 | 说明 |
|---|---|---|---|---|
| 1 | **E-1** 后端 provider_keys 数据层 | — | — | 数据库基石，先打 |
| 2 | **E-2** 后端 LLM client 工厂 + OpenAI-compatible 统一 client | E-1 | — | grok.py 重命名为 openai_compatible.py，所有 LLM 调用切换到 factory，per-request 实例化 |
| 3 | **A-1** 后端 chapter import + style_samples | E-2 | — | A 需要 LLM 通路稳定（Extractor 会走 factory） |
| 4 | **K-1** 前端响应式断点 | — | ✅ 可与 E-1/E-2/A-1 并行 | 纯前端，不碰契约 |
| 5 | **K-2** 前端 Material + Toolbar + Window | K-1 | — | 视觉打磨 |
| 6 | **K-3** 前端动画 + 字体 + Toast | K-2 | — | 微观打磨 |
| 7 | **E-3** 前端 LLM Providers UI | E-2 | ✅ 可与 K-2/K-3 并行 | SettingsView 重构 |
| 8 | **A-2** 前端 import 按钮 + Sheet | A-1 + K-2 | — | 等 toolbar 风格定型后做按钮 |

**关键约束**：
- E-2 完成前不能开始 A-1（A-1 的 import 路径要走新 factory）
- K-1 必须先于 K-2（断点逻辑定型后再做 Material 视觉）
- 发版前 E-3 + A-2 都必须完成（试运营要 Key 管理 UI 与导入入口）

**发版同步清单**（提醒）：
- 前端 `App/project.yml` 的 `MARKETING_VERSION` → `0.6`
- 后端 `Backend/pyproject.toml` + `Backend/app/main.py` + `Backend/app/routers/health.py` + `Backend/tests/test_auth.py` → `0.6.0`
- 本文档 §7 变更日志加新条目
- git commit 标 `v0.6: …`

---

## 5. 候选方案详案

### 5.A 前文导入 + 文风学习 🟢

#### 5.A.1 动机

- 作者已在别处写到第 N 章，想接入工具继续写 → 需要把已写章节"灌"进系统
- 作者偶尔某一章想自己手写 → 跳过 Agent 流程
- 上述两个场景的核心目的都是：**让后续 Writer 学到作者本人的文风**。当前 `Book.style_directive` 仅是高层指令，Writer 看不到任何原文。

#### 5.A.2 设计决策（已拍板）

| 决策点 | 选择 |
|---|---|
| Extractor 是否跑 | **可选，默认开**（导入对话框勾选框） |
| 文风学习实现 | **最近 N 章原文片段**（Writer context_pack 新增 `style_samples`） |
| UI 入口 | **ChapterEditor 顶部按钮**（与"展开提纲"平行） |
| 批量导入 | **不做**（MVP 仅单章） |

#### 5.A.3 数据模型变更

`chapters` 表新增字段：

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `source` | TEXT NOT NULL | `'agent'` | 取值 `'agent'` \| `'imported'`，标识章节是 Agent 生成还是用户导入 |

Alembic 迁移脚本：`add_chapter_source.py`，对存量章节回填 `'agent'`。

#### 5.A.4 后端 API

**新端点：`POST /api/v1/chapters/{id}/import`**

请求体：
```json
{
  "draft_text": "string, required, 章节正文",
  "title": "string, optional, 若提供则覆盖现有 title",
  "summary": "string, optional, 若提供且 run_extractor=false 时直接用",
  "run_extractor": true
}
```

约束：
- 章节当前 `status` ∈ {`draft`, `prompt_ready`, `draft_ready`}（即未 finalized 且未在 SSE 写作流中）
- `writing` 状态**不允许** import — SSE writer worker 与 import 路径会 race(stream 完成时会把 status 翻回 `draft_ready` 并覆盖 draft_text)。前端在 `writing` 状态下应禁用导入按钮,提示用户先取消或等待流结束
- 否则返回 `409 conflict`

行为：
1. 写入 `draft_text`、`title`（如有）、`summary`（如有），标 `source='imported'`
2. 如果 `run_extractor=true`：同步跑 Extractor（复用 finalize 路径的 `extractor_apply` 逻辑），自动产出 live_fields 增量 / timeline events / summary
3. 章节 `status` → `finalized`
4. 返回与 `POST /chapters/{id}/finalize` 同 shape 的 envelope：`{ chapter, updated_character_ids }`

#### 5.A.5 Context Pack 改造（文风学习的关键）

`Backend/app/services/context_pack.py:33` `build_writer_context` 新增字段 `style_samples`：

```python
"style_samples": [
    {
        "chapter_index": 14,
        "head": "<前 400 字>",
        "tail": "<后 400 字>",
    },
    {
        "chapter_index": 15,
        "head": "...",
        "tail": "...",
    },
]
```

- 取最近 N 章（默认 N=2）的 `draft_text`
- 每章头 X 字 + 尾 X 字（默认 X=400）
- agent 写的和 imported 的章节**一视同仁**
- WriterAgent 的 prompt 模板新增"参考前文文风"段落

可调参数（先写死，后续如需开放则放进 `Book` 表）：
- `STYLE_SAMPLES_CHAPTER_COUNT = 2`
- `STYLE_SAMPLES_CHARS_PER_SIDE = 400`

#### 5.A.6 前端变更

- `App/LinoWriting/Services/APIClient.swift` 新增 `importChapter(id:body:)`
- `App/LinoWriting/Stores/ChaptersStore.swift` 新增 `importChapter(...)`，提交后刷新章节到 finalized
- `ChapterEditorView` 顶部 toolbar 新增"导入文本"按钮（与"展开提纲"平行）
- 新增 `ImportChapterSheet`：
  - 多行文本框（必填，draft_text）
  - title 可选输入框
  - summary 可选输入框
  - 勾选框「导入后让 Agent 提取角色更新和时间线」（默认 ✓）
- 章节列表对 `source='imported'` 的章节加一个小角标（可选，可放 v0.6.1）

#### 5.A.7 Phase 拆分

**Phase A-1：后端 + 契约**
1. Alembic 迁移加 `chapter.source`
2. `POST /chapters/{id}/import` 端点 + service 层（复用 `extractor_apply`）
3. `build_writer_context` 加 `style_samples`，改 WriterAgent prompt 模板
4. pytest 新增 `tests/test_chapter_import.py`：导入路径 / extractor on/off / style_samples 进入 prompt / 已 finalized 章节拒绝导入
5. 更新本文档 §5.A 状态为 ✅ 已实施

**Phase A-2：前端**
1. APIClient + ChaptersStore 加 importChapter
2. ChapterEditorView toolbar 按钮 + ImportChapterSheet
3. 章节列表 source 角标（可选）
4. XCTest 至少补 store 层 import 路径
5. 端到端手动验证：导入 → 下一章 Writer 输出能看到文风模仿

---

### 5.B 字段级 dot indicator 🟡

**v0.5 状态**：卡片级简化版。`pendingHighlightIds` 在 finalize 后写入，用户点击该角色时清除。

**v0.6+ 目标**：精确到字段级 — Extractor 改了 `live_fields.{key}` 后，UI 在该 key 旁边显示小红点，用户点击/编辑后消除。

**待补设计**：
- 后端：Extractor 返回结构需要附带"改动了哪些 key"的 patch 描述
- 前端：CharacterCardEditorView 渲染每个 live field 时检查 patch 元数据
- 存储：是放 `Character` 表还是 `agent_logs` 派生

→ 待 v0.X 排期时由 planner 补完详案。

---

### 5.C TimelineEvent 编辑 🟡

**v0.5 状态**：只读列表。

**v0.6+ 目标**：用户可编辑 `event_text` 和 `event_type`。

**待补设计**：
- 后端：新增 `PATCH /api/v1/timeline_events/{id}`（schema、auth、错误处理）
- 前端：TimelineTabView 的每条 event 加 inline 编辑入口
- 是否允许删除 event（v0.5 不允许）

→ 待 v0.X 排期时由 planner 补完详案。

---

### 5.D Admin Log Panel UI 🟡

**v0.5 状态**：`APIClient.listAgentLogs` 已可用，无 UI。

**v0.6+ 目标**：调试/开发用的日志面板，列出最近 N 条 Agent 调用（含 prompt、response、耗时、token 数）。

**待补设计**：
- 入口位置（设置页 / 隐藏菜单 / 独立 view）
- 分页 / 过滤（按 agent type、按 chapter）
- 是否暴露 raw prompt（敏感性？）

→ 待 v0.X 排期时由 planner 补完详案。

---

### 5.E 多 LLM Key 管理（OpenAI-compatible 统一协议） 🟢

#### 5.E.1 动机

- v0.5 LLM Key 在后端 `.env` 里（`GROK_API_KEY`），用户改 Key 必须 SSH 上服务器
- 试运营场景下用户需要随时换 Key（限额、轮换、备份）
- v0.5 的 `GrokClient` 实际就是 **OpenAI-compatible client**（POST `/chat/completions`、`messages` 数组、`response_format: json_object`、SSE `data:` 流），并非 Grok 特定
- 因此 v0.6 不再做"多 provider 各写一个客户端"，而是统一走 **OpenAI compatible 协议**——只要 endpoint 暴露 `/chat/completions` 即可接入（xAI / OpenAI / OpenRouter / DeepSeek / 自部署 vLLM / Together / Groq …），用户在 base_url 里填什么就调什么

#### 5.E.2 设计决策（已拍板）

| 决策点 | 选择 |
|---|---|
| Key 存储位置 | **上传到后端数据库**（前端 SettingsView 调端点写入） |
| LLM 协议 | **统一 OpenAI compatible**（唯一一份 client 实现） |
| 多 Key 语义 | **任意条数**，每条由 (label, base_url, api_key, model_name) 构成；不再区分 provider 类型 |
| active 选择粒度 | **全局一个 active key**（不做 Book/Agent 级别） |
| Key 加密 | v0.6 **明文存储**（单用户私人 backend，简化）；v0.7+ 可加 KMS / Vault |

#### 5.E.3 数据模型

**新增表 `provider_keys`**：

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | UUID PK | |
| `key_label` | TEXT NOT NULL | 用户起的别名，如 "主 Grok"、"备用 Grok"、"OpenRouter Claude" |
| `provider_hint` | TEXT | 可选自由标签（`'xai'` \| `'openai'` \| `'openrouter'` \| `'deepseek'` \| `'custom'` …），仅用于前端 UI 分组/图标，**后端不据此分支** |
| `base_url` | TEXT NOT NULL | OpenAI compatible endpoint 根地址，如 `https://api.x.ai/v1`、`https://api.openai.com/v1`、`https://openrouter.ai/api/v1`（**必填**，无默认值） |
| `api_key` | TEXT NOT NULL | 明文（v0.6） |
| `model_name` | TEXT NOT NULL | 该 Key 默认调用的 model 字符串（如 `grok-4`、`gpt-5`、`anthropic/claude-sonnet-4.5`） |
| `created_at` | TIMESTAMPTZ NOT NULL | |
| `updated_at` | TIMESTAMPTZ NOT NULL | |

**新增表 `system_settings`**（单行配置，未来可扩）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | INT PK (固定 1) | |
| `active_provider_key_id` | UUID FK → provider_keys.id ON DELETE SET NULL | 当前 active key |
| `updated_at` | TIMESTAMPTZ NOT NULL | |

Alembic 迁移：`add_provider_keys_and_settings.py`。首次启动时如果 `.env` 里仍有 `GROK_API_KEY` 且 `provider_keys` 空，自动迁移成一条记录并设为 active（兼容 v0.5 部署）。

#### 5.E.4 后端 API

**新端点**：

```
GET    /api/v1/provider_keys             → list (api_key 返回末 4 位掩码)
POST   /api/v1/provider_keys             → create
PATCH  /api/v1/provider_keys/{id}        → update (label / model / base_url; api_key 可选)
DELETE /api/v1/provider_keys/{id}        → delete (若被 active 引用则先解绑或拒绝)

GET    /api/v1/settings/active_provider_key   → 当前 active key 的 id + 摘要
PUT    /api/v1/settings/active_provider_key   → body: { provider_key_id } 设为 active
```

掩码规则：`api_key` 列表返回时仅显示 `****xxxx`（末 4 位），完整 key 仅在创建/更新请求体里传输，**永远不在响应里回传**。

#### 5.E.5 LLM Client 改造（OpenAI-compatible 单实现）

- `Backend/app/llm/base.py` 保持 Protocol 不变（`complete` / `complete_json` / `complete_stream`）
- **将 `Backend/app/llm/grok.py` 重命名为 `Backend/app/llm/openai_compatible.py`**，类名 `GrokClient` → `OpenAICompatibleClient`
  - 构造函数签名改为接收 `provider_key: ProviderKey` 实例（取代当前的 `settings: Settings`）
  - 内部 `self.api_key` / `self.base_url` / `self.model_name` 字段保持，但全部从 `provider_key` 读
  - 错误消息里"xAI server error"等措辞改为通用"LLM upstream"
- **不**新增 ClaudeClient / OpenAIClient 单独类。Claude / OpenAI / OpenRouter 等都通过同一个 `OpenAICompatibleClient` 调用，区别只在 `base_url` 与 `model_name`
- `pyproject.toml` **不需要**新增 `anthropic` / `openai` SDK 依赖（仍只用 `httpx`）
- 新增 `Backend/app/llm/factory.py`（极简）：
  ```python
  def build_llm_client(db: Session) -> LLMClient:
      active_key = load_active_provider_key(db)
      if active_key is None:
          raise UpstreamError("no_active_llm_key")
      return OpenAICompatibleClient(active_key)
  ```
- 调用方改造：原来 `request.app.state.llm_client`（startup 单例）改成 **per-request 实例化**。每个需要 LLM 的 router (`chapters/expand`、`chapters/write`、`chapters/finalize`、`chapters/import`) 注入 `db` session 后调用 `build_llm_client(db)`
- SSE 路径需要把 LLM client 提前实例化，避免流式响应中途读 DB

**关于 Claude**：Anthropic 原生 API 不是 OpenAI compatible（用 `/v1/messages` + 自己的 schema），但 OpenRouter / Together / Anthropic 自己的兼容代理都提供 `/chat/completions` 入口。用户若想用 Claude，填 OpenRouter base_url + `anthropic/claude-sonnet-4.5` 这种 model_name 即可。v0.6 不为 Anthropic 原生协议单独适配。

#### 5.E.6 前端变更

- `App/LinoWriting/Models/ProviderKey.swift` 新增 Codable DTO
- `App/LinoWriting/Services/APIClient.swift` 新增 6 个端点方法
- `App/LinoWriting/Stores/AppStore.swift` 或新增 `ProviderKeysStore` 管理列表与 active 状态
- `SettingsView.swift` 重构为 **TabView**（macOS）/ Form sections（iOS）：
  - **Connection** tab：保留 backend URL + API token（即 v0.5 现有内容）
  - **LLM Providers** tab：列出已有 keys（label / provider / model / 末 4 位） + 添加 / 编辑 / 删除 / 设为 active（单选 radio）
- 新增 `ProviderKeyEditSheet` 字段：
  - **label** 输入（必填）
  - **provider_hint** 下拉（可选，作用仅是预填 base_url 和 model_name 模板）：`xai` / `openai` / `openrouter` / `deepseek` / `custom`
  - **base_url** 输入（必填，根据 provider_hint 自动预填，可改）
  - **api_key** SecureField（必填）
  - **model_name** 输入（必填，根据 provider_hint 自动预填一个推荐值，可改）

#### 5.E.7 Phase 拆分

**Phase E-1：后端数据层**
1. Alembic 迁移 `provider_keys` + `system_settings`
2. SQLAlchemy 模型 + Pydantic schemas
3. CRUD endpoints + active key 端点
4. `.env` 兼容性迁移（首次启动自动导入 `GROK_API_KEY`）
5. pytest 覆盖：CRUD / 掩码 / 删除 active 行为 / .env 迁移

**Phase E-2：后端 LLM 工厂 + OpenAI-compatible 统一 client**
1. `llm/grok.py` 重命名为 `llm/openai_compatible.py`，类名改 `OpenAICompatibleClient`
2. 构造签名改为接收 `ProviderKey`；删除对 `Settings` 的依赖；错误消息通用化
3. 新增 `llm/factory.py` 与 per-request 实例化（极简，不分支）
4. 所有调用方（routers/chapters.py 等）从 `request.app.state.llm_client` 切换到 `build_llm_client(db)`
5. SSE 路径预实例化 client，避免流式中途读 DB
6. **不**新增 anthropic / openai SDK 依赖（仍只用 httpx）
7. pytest 覆盖：MockLLMClient 走 factory 路径、active key 为空时返回正确错误、SSE 路径预实例化正常

**Phase E-3：前端 UI**
1. APIClient + Store + Models
2. SettingsView 重构为 Tab
3. ProviderKeyEditSheet + 列表 UI
4. XCTest 覆盖：store 层 CRUD + active 切换

---

### 5.K 响应式布局 + 苹果风美学升级 🟢

#### 5.K.1 动机

v0.5 baseline 审计结论：
- 窗口最小 1000×640，缩到 1100-1300 区间挤得难看
- 全栈零 Material，无景深，纯不透明色
- 全 app 仅 2 处动画，状态切换硬切
- Toolbar 是裸 ToolbarItem，无编辑器风格
- 字体全 system 默认，没有"写作工具"调性

试运营前必须让 app 在不同窗口尺寸下都美观，并具备同类专业写作工具（Pages / Bear / Ulysses）的视觉品质。

#### 5.K.2 设计清单（已拍板）

| 维度 | v0.5 | v0.6 目标 |
|---|---|---|
| 窗口最小尺寸 | 1000×640 | **880×580** |
| 三栏列宽 | 固定 sidebar 320 / detail 480 | 弹性区间 + 断点折叠 |
| Material | 无 | Sidebar `.regularMaterial`、RightPanel `.thinMaterial` |
| Toolbar | 裸 ToolbarItem | `.toolbarRole(.editor)` + `.toolbarBackground(.automatic, .visible)` |
| 动画 | 2 处 | 全局 `.animation(.smooth, value:)` + 视图切换 `.transition` |
| 字体 | 全 system sans | 章节正文可在 Settings 切 sans/serif（默认 serif） |
| Window style | 默认 | `.windowToolbarStyle(.unifiedCompact(showsTitle: false))` |
| Hover | 无 | macOS pointer hover 抬升 + shadow 加深 |
| ErrorBanner | 整条红色横幅 | 右下角 Toast + `.thinMaterial` 圆角胶囊 |

#### 5.K.3 响应式断点

```
窗口宽度        Sidebar      Editor       RightPanel
≥ 1100         展开          展开          展开
800 ~ 1099     展开          展开          折叠成右抽屉（toolbar 按钮唤起 sheet）
< 800          折叠成菜单     展开          折叠成右抽屉
```

实现要点：
- `WorkspaceView` 使用 `GeometryReader` 监听容器宽度（或 `@Environment(\.horizontalSizeClass)` 在 iOS 上）
- 折叠后保留状态：用户再放大窗口时自动展开
- iOS 已有的 sheet 模式可直接复用（`RightPanel` 抽屉化）
- 列宽改为 `.navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)` 给 Sidebar 更宽容；Editor 不设 max；RightPanel `min: 300, ideal: 340, max: 460`

#### 5.K.4 美学具体改动

**Material 层化**
- `Sidebar` (`ChapterListView`)：`.background(.regularMaterial)`
- `RightPanel` (`RightPanelView`)：`.background(.thinMaterial)`
- 主编辑区：保持窗口默认背景（让 Material 形成对比）
- 章节卡 / 角色卡：`.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))`

**Toolbar**
- `WorkspaceView`：`.toolbarRole(.editor)` + `.toolbarBackground(.automatic)` 让 toolbar 随滚动渐变出实底
- 章节编辑器内的"展开提纲"、"导入文本"、"finalize"按钮统一改 `.buttonStyle(.bordered)` + SF Symbol prefix

**Window style**（macOS only）
- `LinoWritingApp.swift`：`.windowToolbarStyle(.unifiedCompact(showsTitle: false))` 让标题栏与 toolbar 融合
- `.windowResizability(.contentMinSize)` 配合 `.frame(minWidth: 880, minHeight: 580)`

**全局动画**
- ChapterEditor 状态切换：`.animation(.smooth(duration: 0.35), value: chapter.status)`
- 章节切换：`.transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))`
- StatusBadge：`.contentTransition(.numericText())` 让状态文字过渡平滑

**字体**
- `Settings` 加 `editorFontDesign: 'sans' | 'serif'`（默认 serif）
- Step3_DraftView 与正文区域用 `.font(.system(.body, design: editorFontDesign == .serif ? .serif : .default))`
- 标题保持 sans

**Toast 错误条**
- 新建 `Views/Components/Toast.swift`：右下角浮窗，`.thinMaterial` + RoundedRectangle 16pt 圆角
- ErrorBanner 重构为 Toast 形态（保留 3s 自动消失 / 401 长留逻辑）

**Hover / Press**
- BookCard / ChapterListView 行：`.onHover { isHovered = $0 }` + 抬升 + shadow
- `.pointerStyle(.link)` 让光标变指针手势（macOS 14+）

#### 5.K.5 Phase 拆分

**Phase K-1：响应式断点**
1. 降窗口最小到 880×580，列宽改弹性
2. WorkspaceView 加 width-based 折叠逻辑（< 1100 RightPanel 抽屉、< 800 Sidebar 菜单）
3. 复用 iOS sheet 实现做 macOS 抽屉
4. XCTest 不强求（UI 改动），但人工验证 6 个窗口尺寸点：880 / 1000 / 1100 / 1280 / 1440 / 1920

**Phase K-2：Material + Toolbar + Window**
1. Sidebar / RightPanel / 卡片 Material 层化
2. `.toolbarRole(.editor)` + `.toolbarBackground` 全面套
3. `.windowToolbarStyle(.unifiedCompact)` + `.windowResizability(.contentMinSize)`
4. Hover / Press 微交互
5. ErrorBanner 重构为 Toast

**Phase K-3：动画 + 字体**
1. 全局 `.animation(.smooth, value:)` 套关键状态字段
2. 章节切换 transition
3. Settings 加 `editorFontDesign` 选项 + Step3_DraftView / 正文区切换实现
4. StatusBadge contentTransition

---

## 6. 历史文档索引

| 文件 | 用途 | 状态 |
|---|---|---|
| `PLAN_FRONTEND.md` | v0.5 前端契约定稿 | 存档，不再更新 |
| `PLAN_BACKEND.md` | v0.5 后端契约定稿 | 存档，不再更新 |
| `App/README.md` | 前端开发/运行说明 | 持续维护 |
| `Backend/README.md` | 后端开发/运行说明 | 持续维护 |
| `Backend/IMPLEMENTATION_STATUS.md` | v0.5 后端实施记录 | 存档 |

---

## 7. 变更日志

| 日期 | 文档版本 | 变更摘要 |
|---|---|---|
| 2026-05-23 | v0.6-draft | 初版。从双契约工作流收口为 PROJECT_PLAN 单一行动依据；导入 + 文风学习方案落 §5.A；候选池建立。 |
| 2026-05-23 | v0.6-draft | 追加 §5.E（多 LLM Key + 多 provider，App 内管理）与 §5.K（响应式布局 + 苹果风美学）详案。v0.6 迭代清单定型为 A + E + K，Phase 排序 + 并行关系落 §4.1。 |
| 2026-05-23 | v0.6-draft | §5.E 简化：放弃多 provider 各自适配，统一走 OpenAI-compatible 协议。`grok.py` 重命名为 `openai_compatible.py`；删除 ClaudeClient/OpenAIClient 计划；`provider_keys.provider` 字段降级为 `provider_hint`（仅 UI 提示，不影响后端分支）；`base_url` 改必填。pyproject 不再引入 anthropic/openai SDK。 |

### [2026-05-23] Phase K-2 实施小偏离说明
- 变更内容：`.pointerStyle(.link)` 改用 `NSCursor.pointingHand.push()/pop()`（在 `BookCardView` 的 `onHover` 中）。
- 变更原因：`.pointerStyle` 是 macOS 15.0+ API，而 `project.yml` 的部署目标是 macOS 14.0。`NSCursor` 等价方案在 macOS 14 上即可用。
- 影响范围：Phase K-2 / `BookCardView.swift`；无契约变化。

### [2026-05-23] Phase K-2 K-1 🟡 5 处理结论
- 变更内容：`.frame(minWidth: 880, minHeight: 580)` 仍保留在 `LinoWritingApp` 的 `WindowGroup` 上（未挪至 `WorkspaceView`），并在源码中加注释说明原因。
- 变更原因：`.windowResizability(.contentMinSize)` 是从 SwiftUI view minimum size 读取窗口最小尺寸的；如果把 frame 挪到 `WorkspaceView`，书架时窗口的最小尺寸就无人约束，属于 macOS window 行为变更，超出 K-2 视觉打磨范围。
- 影响范围：Phase K-2；后续若要做"书架窗口可更窄"需独立讨论 `.windowResizability` 取值与首选 minimum 来源。

| 2026-05-23 | **v0.6 发布** | A + E + K 三块全部落地。8 个 Phase 一次跑通(E-1 → E-2 → K-1 → A-1 → K-2 → K-3 → E-3 → A-2),每个 Phase 都走完 planner-builder-reviewer 三步。版本号 5 处同步到 `0.6.0`(`App/project.yml MARKETING_VERSION` + `Backend/pyproject.toml` + `app/main.py` + `routers/health.py` + `tests/test_auth.py`)。测试基线 v0.5 末:12 pytest + 17 XCTest → v0.6 末:57 pytest + 34 XCTest。一个跨 phase 的契约修复值得记录:E-3 reviewer 发现 `GET /api/v1/settings/active_provider_key` 后端实际返回的嵌套 shape 与前端预期的 flat shape 不一致(plan §5.E.4 明文要 flat),修后端 router 让其对齐 plan。 |

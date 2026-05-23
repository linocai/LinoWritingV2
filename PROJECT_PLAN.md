# Lino Writing v2 · PROJECT PLAN

> 本文档是 v0.6 起的**单一项目行动依据**。前端、后端、契约层全部合并在此。
> v0.1–v0.5 期间使用 `PLAN_FRONTEND.md` / `PLAN_BACKEND.md` 双契约工作流，作为 v0.5 契约存档保留，不再更新。
>
> 文档版本：v0.6-draft
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

## 1. 当前版本状态 (v0.5 — 已发布)

### 1.1 已实现能力

**前端（SwiftUI macOS 14+ / iOS 17+）**
- 书架（多书隔离，封面色、最近打开排序）
- 3 栏 Workspace（macOS NavigationSplitView / iOS 抽屉式 RightPanel）
- 5 步章节编辑器（idea → 展开提纲 → 写作 → 审阅 → finalize）
- SSE 流式写作（started/token/progress/done/error）
- 角色卡 inline 文档式编辑（frozen/live 双区 + 卡片级 dot indicator）
- 右栏 4 tab：角色卡 / 时间线 / 摘要 / 世界设定
- ErrorBanner（3s 自动消失，401 长留）
- Keychain 存储 backend URL + API token
- 测试：17 个（APIClient / SSEClient / Stores）

**后端（FastAPI + SQLAlchemy 2.0 + Postgres + Alembic）**
- 5 张业务表 + 1 张调试表（books / characters / chapters / timeline_events / agent_logs）
- 23 个 API 端点，全部 `/api/v1` Bearer auth
- 3 个 Agent：PromptExpander / Writer (SSE 流式) / Extractor (JSON)
- Grok LLM 客户端（OpenAI 兼容协议，retry + timeout）
- Context Pack 装配（按章节出场角色筛选 / 最近 2 章摘要 / 全部时间线）
- Extractor → live_fields/timeline/summary 事务性写入
- 测试：12 个（in-memory SQLite + MockLLMClient）

### 1.2 v0.5 已知残留 todo（移入升级候选池）

- 字段级 dot indicator（当前是卡片级简化版） → §3 B
- TimelineEvent 编辑（当前只读） → §3 C
- Admin Log Panel UI（APIClient 已暴露 `listAgentLogs`，UI 缺） → §3 D
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
| **E** | 多模型支持（Grok 之外加 Claude / GPT 等） | 🔵 待讨论 | — |
| **F** | 章节/全书导出（markdown / txt） | 🔵 待讨论 | — |
| **J** | 全文搜索 | 🔵 待讨论 | — |

剔除项（不进路线图）：
- ⚫ G. 卷/章节分组
- ⚫ H. 写作统计面板
- ⚫ I. 章节历史版本/diff

---

## 4. 当前迭代

### 4.1 v0.6 — 规划中

**目标**：待定。

**清单**：（待用户从 §3 候选池勾选）

```
[ ] A
[ ] B
[ ] C
[ ] D
[ ] E
[ ] F
[ ] J
```

**Phase 拆分**：迭代清单定型后，由 planner 在此补充每个候选项的 Phase。

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
- 章节当前 `status` ∈ {`idea_only`, `prompt_expanded`, `writing`}（即未 finalized）
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

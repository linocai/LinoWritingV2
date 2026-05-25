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

候选项分为 5 种状态：
- ✅ **已发布**：在某个版本里实施完成
- 🟢 **就绪**：方案已讨论，详案见 §5，已进 §4 某个迭代
- 🟡 **粗线**：方向已定，详案待补
- 🔵 **待讨论**：仅记录方向，未做设计
- ⚫ **已剔除**：明确不做（不进路线图）

| 编号 | 主题 | 状态 | 详案 |
|---|---|---|---|
| **A** | 前文导入 + 文风学习 | ✅ v0.6 | §5.A |
| **B** | 字段级 dot indicator | 🟢 v0.7 | §5.B |
| **C** | TimelineEvent 编辑 | 🟢 v0.7 | §5.C |
| **D** | Admin Log Panel UI | 🟢 v0.7 | §5.D |
| **E** | 多 LLM Key 管理（OpenAI-compatible 统一协议，App 内管理） | ✅ v0.6 | §5.E |
| **F** | 章节/全书导出（markdown / txt） | 🟢 v0.7 | §5.F |
| **J** | 全文搜索 | 🔵 待讨论（推 v0.8+） | — |
| **K** | 响应式布局 + 苹果风美学升级 | ✅ v0.6 | §5.K |
| **L** | 角色卡 narrative 通病修复（分层 + 本章重点 + Writer prompt 改造） | 🟢 v0.7 **主菜** | §5.L |
| **M** | 多 LLM per-Agent 选择（Writer→Claude / Extractor→Grok 等） | 🟢 v0.7 | §5.M |
| **N** | 错误中文模板 + ErrorBus history | 🟢 v0.7 | §5.N |
| **O** | 批量章节导入 | 🟢 v0.7 | §5.O |
| **P** | v0.7 急修包（SSE cancel / admin reset / Store reset / PATCH 白名单 / 4xx 脱敏） | 🟢 v0.7 | §5.P |
| **Q** | 文档同步（PROJECT_PLAN §2 + README 漂移修复） | 🟢 v0.7 | §5.Q |

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

### 4.2 v0.7 — 规划中

**目标**：试运营深化版。修掉 v0.6 试运营暴露的安全/计费/UX 系统性短板，解决最大的内容质量痛点（Writer 把角色卡当 narrate 检查表），并清掉 v0.5/v0.6 残留 todo 让 v0.7 收尾后能进入"打磨期"。

**清单**：

```
🥇 主菜
[ ] L — 角色卡 narrative 通病修复（§5.L）

🔴 必修包（试运营裸奔风险）
[ ] P — 急修包（SSE cancel / admin reset / Store reset / PATCH 白名单 / 4xx 脱敏，§5.P）

🟡 战略价值
[ ] M — 多 LLM per-Agent 选择（§5.M）
[ ] N — 错误中文模板 + ErrorBus history（§5.N）
[ ] F — 章节/全书导出（§5.F）

🟢 试运营增强
[ ] O — 批量章节导入（§5.O）

🧹 v0.5/v0.6 旧债清算
[ ] B — 字段级 dot indicator（§5.B）
[ ] C — TimelineEvent 编辑（§5.C）
[ ] D — Admin Log Panel UI（§5.D）

📚 收尾
[ ] Q — 文档同步（§5.Q）
```

**Phase 排序**（14 个 Phase，按依赖+并行机会排）：

| 序号 | Phase | 内容 | 依赖 | 可并行 |
|---|---|---|---|---|
| 1 | **P-1** 急修后端 | SSE producer cancel hook + L 测试 + LLM 4xx body 脱敏 + ChapterPatch 白名单 | — | ✅ 与 P-2 并行 |
| 2 | **P-2** 急修前端 | ChapterEditorStore.load 完整 reset + admin_reset 端点 UI | — | ✅ 与 P-1 并行 |
| 3 | **P-3** admin_reset 端点 | `POST /chapters/{id}/admin_reset` | P-1 | — |
| 4 | **L-1** 角色卡分层数据模型 | character.author_notes + chapter.focus_traits Alembic 迁移 | — | ✅ 与 P 系列并行 |
| 5 | **L-2** Expander + Writer prompt 改造 | structured_prompt.focus_traits 推断 + Writer 加 show/tell 反例 + context_pack 合并查询 | L-1 | — |
| 6 | **L-3** 前端角色卡双区编辑 | CharacterCardEditorView 分 narrative_visible / author_notes 两区 + chapter focus_traits 显示 | L-1 | ✅ 与 L-2 并行 |
| 7 | **M-1** 多 LLM per-Agent 后端 | provider_keys.agent_role 字段 + factory 按 agent 选 key + UI 兼容性 | — | ✅ 与 L 系列并行 |
| 8 | **M-2** 多 LLM per-Agent 前端 | SettingsView LLM Providers tab 加"哪个 Agent 用哪个 key" | M-1 | — |
| 9 | **N** 错误中文模板 + Toast history | Backend 错误消息 i18n + Toast 历史栏 + Settings 里"最近错误"列表 | — | ✅ 与 M / L 并行 |
| 10 | **F** 章节/全书导出 | `GET /books/{id}/export?format=markdown` + 前端入口 | — | ✅ 与 N / M 并行 |
| 11 | **O** 批量章节导入 | NewChapterSheet 加 batch mode（按分隔符切分多章） | L-3 之后 | — |
| 12 | **B-fld** 字段级 dot indicator | Extractor 输出 patch 描述 + 前端字段级红点 | L-1 | — |
| 13 | **C-tl** TimelineEvent 编辑 | `PATCH /timeline_events/{id}` + 前端 inline 编辑 | — | ✅ 独立 |
| 14 | **D-log** Admin Log Panel UI | listAgentLogs 已有，仅缺 UI | — | ✅ 独立 |
| 15 | **Q** 文档同步 + v0.7 发版 | PROJECT_PLAN §2 + App/Backend README 更新 + 5 处版本号 → 0.7.0 | 全部完成 | — |

**关键约束**：
- **P-1 是 v0.7 第一棒**（SSE cancel 关计费泄漏，每个用户取消都白烧 token，这是 v0.7 最紧迫的事）
- L-1 数据模型先行，L-2/L-3 可并行
- B-fld 依赖 L-1（因为角色卡分层会改 schema，B-fld 要适配新结构）
- M 系列与 L 系列完全独立，可同时跑
- N / F / D-log / C-tl 都是独立 Phase，可见缝插针
- O 等 L-3 是因为 UI 与 NewChapterSheet 共享 import 状态机

**发版同步清单**（v0.7 收尾用）：
- 前端 `App/project.yml` 的 `MARKETING_VERSION` → `0.7`
- 后端 `Backend/pyproject.toml` + `Backend/app/main.py` + `Backend/app/routers/health.py` + `Backend/tests/test_auth.py` → `0.7.0`
- 本文档 §7 变更日志加新条目
- git commit 标 `v0.7: …`
- LinoI.app 重新打包 + ad-hoc 签名 + 部署 ~/Desktop

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

### 5.B 字段级 dot indicator 🟢

#### 5.B.1 动机
v0.5/v0.6 是卡片级:Extractor 改任意 `live_fields.{key}` → 整张卡 dot,用户点击卡片消除。粒度太粗,作者看不出 Agent 到底改了哪个字段。

#### 5.B.2 设计决策
- **后端 Extractor 输出附带 `patch_keys`**:`{ character_updates: [{ id, patch_keys: ["current_status", "knowledge"], patch: {...} }] }`
- **agent_logs** 已记录每次调用 → 可派生改动,但每次 UI 查询要 JOIN agent_logs 较重 → **存到 character 表**:加 `pending_field_highlights JSONB`(`{key: timestamp_of_change}`),用户点编辑该 field 后清掉对应 key
- **前端**:`InlineEditableText` / `InlineEditableDict` 渲染时检查 `pendingFieldHighlights[key]`,显示小红点;onCommit 后 PATCH 清掉

#### 5.B.3 依赖
L-1(角色卡分层迁移)— B-fld 也要改 character schema,合并迁移更干净。

---

### 5.C TimelineEvent 编辑 🟢

#### 5.C.1 动机
v0.5/v0.6 时间线只读;作者发现 Extractor 提取错了事件,只能干瞪眼。

#### 5.C.2 设计决策
- **后端新增 `PATCH /api/v1/timeline_events/{id}`**:body `{ event_text?, event_type? }`,白名单字段;不允许改 `character_id` / `chapter_id`(语义不允许跨章节挪事件)
- **删除事件**:加 `DELETE /api/v1/timeline_events/{id}`(确认删除时弹 alert)
- **前端 TimelineTabView**:每条 event 加 inline 编辑(双击进入编辑态)+ 右侧 hover 显示删除按钮
- **审计字段**:事件本身加 `edited_at TIMESTAMPTZ NULL`(区分原始 Agent 提取 vs 用户编辑过的)

---

### 5.D Admin Log Panel UI 🟢

#### 5.D.1 动机
`APIClient.listAgentLogs` 已暴露;UI 缺。调试 Writer 输出 / 排查 Extractor 失败时,作者需要看原始 prompt + response + 耗时。

#### 5.D.2 设计决策
- **入口**:SettingsView 加第三个 tab "Agent 日志"(Connection / LLM Providers / Agent Logs)
- **布局**:List of agent_log entries,每条显示:agent_type + chapter_index + duration_ms + status(ok/error) + 时间;点击展开 input/output preview
- **分页**:`?limit=50 &before=<created_at>` 按 created_at 倒序滚动
- **过滤**:顶部 Picker(All / Expander / Writer / Extractor)
- **隐私**:input/output preview 已经在后端被截断到 ~2K(reviewer 提到 admin/logs 一次查询接近 200KB,需要按 P 系列的脱敏一起做)

#### 5.D.3 依赖
P-1 急修包里的"4xx body 脱敏"应当先做,确保日志体不含 LLM key / 敏感 token。

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

### 5.L 角色卡 narrative 通病修复 🟢 **v0.7 主菜**

#### 5.L.1 动机

v0.5 → v0.6 试运营暴露的最严重内容质量问题:**Writer 把角色卡当成"检查表",每段都把每个 trait narrate 一遍**。
- ❌ "林夕谨慎地观察了四周。" / "刀子嘴豆腐心的他叹了口气。"
- ❌ 反复在旁白里强调 "他敏锐..." / "他声音简短..."

根因有三层:
1. **Writer system prompt 误导**:当前写"严格遵守 frozen_fields,角色卡冻结区不能漂移",LLM 误读为"必须显性体现每个 trait 给用户看"
2. **角色卡 frozen_fields 整份灌进 prompt**:没有"幕后参考"vs"narrate-safe"的区分
3. **structured_prompt 没指定本章重点**:Writer 试图把所有 trait 都用上,缺乏聚焦

LLM 写作类应用的通病(Sudowrite / NovelAI / Claude 裸用都撞过)。没有 silver bullet,但有组合拳。

#### 5.L.2 设计决策

| 决策点 | 选择 |
|---|---|
| 角色卡分层方式 | `frozen_fields` 保持不变;**新增 `author_notes JSONB`** 字段,作者填"演员小抄"型笔记(动机、过往伤、隐秘),Writer 可读但 system prompt 明确说"绝不可直接 narrate 这部分" |
| `live_fields` 处理 | 不动 — 它本来就是 Extractor 维护的"事实"(知识、状态),narrate 合理 |
| 本章重点机制 | `structured_prompt` 新增字段 `focus_traits: [string]`(0-2 个 trait 名,如 "core_traits.谨慎"),Expander 自动从 user_prompt 推断,作者可手改 |
| Writer prompt 改造 | **完全重写** "角色卡使用规则"段,加 show/tell 反例 few-shot;明确"frozen_fields / author_notes 是幕后理解,通过行为 emerge,不要直接 narrate";"focus_traits 是本章可重点 emerge 的特质,其它不刷存在感" |
| context_pack 合并查询 | 顺手把 reviewer 提的性能问题修了:`_recent_summaries` + `_style_samples` 合并为一次 SQL |

#### 5.L.3 数据模型变更

`characters` 表新增字段:

| 字段 | 类型 | 说明 |
|---|---|---|
| `author_notes` | JSONB NOT NULL DEFAULT '{}' | 作者笔记,key-value 自由结构;Writer 读但绝不 narrate |

`chapters` 表 `structured_prompt` JSONB 内部加字段(无 schema 迁移,只是 JSON 结构约定):

```json
{
  ...
  "focus_traits": ["谨慎", "对妹妹的愧疚"]   // 0-2 个,本章重点可 emerge
}
```

#### 5.L.4 Expander prompt 改造

`PromptExpanderAgent` 在产出 `structured_prompt` 时:
- 看用户的 ~50 字 user_prompt
- 看本章涉及角色的 frozen_fields + author_notes
- 自动选 0-2 个"本章最相关的 trait"放进 `focus_traits`
- 作者在前端可见/可改

#### 5.L.5 Writer prompt 改造(核心)

`WriterAgent.system_prompt` 重写,新结构:

```
# 角色卡使用规则(读懂这条比读对人设更重要)

characters[*] 的 frozen_fields 和 author_notes 是**幕后参考** —
用来帮你判断角色在情境中如何行动/说话/选择,**不是清单也不是检查表**。

绝不要为了"证明你看了角色卡"而把人格直接说出来:
- ❌ 反例:"林夕谨慎地观察了四周" / "刀子嘴豆腐心的他叹了口气"
- ✓ 正例:"林夕在原地站了三息,目光从左到右扫过。" /
        "他骂了一句脏话,声音很轻。然后把自己的水袋递了过去。"

同一项 trait 在整章里**最多用一次**作为行动驱动,不要反复 narrate。
不要把字段名(如 "core_traits"、"voice")或字段内容**逐字搬到正文**。
角色卡是水库,不是必须排空的水桶 — 不自然的 trait 就完全不用。

# 本章重点
structured_prompt.focus_traits 是本章**可重点 emerge** 的 0-2 个特质,
其它 trait 保持隐性,不主动展示。**为空时不要刻意 emerge 任何特质** —
按 plot 自然行进即可,不要为了凑满"重点"而编一个出来。

author_notes 是角色的"演员小抄":动机/过往/秘密。这是**纯幕后**,
正文里**绝不可有任何句子直接转述 author_notes 的内容**。它的作用
只是让你判断角色在抉择关口会怎么走 — 决定后,只写抉择和行动。
```

(其余 must_happen / must_not_happen / timelines / 字数 等保持。)

#### 5.L.6 前端变更

- `Character` Codable 加 `authorNotes` 字段
- `CharacterCardEditorView` 现在的"冻结区 / 活动区"两区 → 改为**三区**:
  - **冻结区**(frozen_fields):公开人设,可被 narrate
  - **活动区**(live_fields):Agent 维护的事实
  - **作者笔记**(author_notes):折叠区,作者点开才显示,标注"仅供 Agent 幕后参考,不会被写入正文"
- `Step2_StructuredPromptView` 显示并允许编辑 `focus_traits`(从角色 trait 池里 chip 多选)

#### 5.L.7 Phase 拆分

参见 §4.2 Phase 表:**L-1**(数据模型 + 迁移)→ **L-2**(Expander + Writer prompt + context_pack 合并) ∥ **L-3**(前端角色卡分三区 + focus_traits chip)

---

### 5.M 多 LLM per-Agent 选择 🟢

#### 5.M.1 动机

v0.6 只有"全局 active key",所有 Agent(Expander / Writer / Extractor)都走同一个。试运营暴露的问题:
- Writer 用便宜模型 → 文笔差;用顶级模型 → token 账单爆
- Extractor 做结构化 JSON 提取,中端模型够用,**没必要用 Claude Opus**
- Expander 输出短结构化提纲,**任何模型都够**

让每个 Agent 各选 active key,可以**控成本 60-80%** 同时质量不降。

#### 5.M.2 设计决策

- **provider_keys 加可选字段 `agent_role`**:NULL = 通用(回退用);`'writer'` / `'extractor'` / `'expander'` 表示专为该 agent 服务
- **system_settings 加三个 active 引用**:`active_writer_key_id` / `active_extractor_key_id` / `active_expander_key_id`
- **factory 改造**:`build_llm_client(db, agent_role)` 按 agent 选 key,fallback 顺序:`active_{agent}_key` → 通用 `active_provider_key`(v0.6 已有的全局 active)→ 报错
- **前端**:SettingsView LLM Providers tab 每条 key 加 "用于哪个 Agent" 多选;顶部三个 dropdown 选 active(可以同一个 key 选 3 个 role,也可以分开)

#### 5.M.3 向后兼容
v0.6 用户:三个 agent_role active 全部为 NULL → factory 全部 fallback 到全局 active → 行为与 v0.6 完全一致。

---

### 5.N 错误中文模板 + ErrorBus history 🟢

#### 5.N.1 动机

试运营暴露:
- "Chapter status 'writing' cannot perform write" 是英文裸消息,作者看不懂
- Toast 3 秒自动消失,SSE error / Extractor 422 这种长文本闪一下就丢
- 失败后没有"再试一次"按钮

#### 5.N.2 设计决策

- **后端 `app/errors.py` 加 i18n 模板**:`ConflictError(action="write", status="writing")` → "章节当前正在写作中,无法再次开始写作"
- **前端 ErrorBus 加 `history: [Notice]`**(@Published,最近 30 条),SettingsView 加第四个 tab "最近错误"
- Toast 不动(3s 自动消失 / 401 长留),只是"消失后用户能在 SettingsView 回看"

---

### 5.O 批量章节导入 🟢

#### 5.O.1 动机

接入旧稿 50+ 章时,单章导入要重复 50 次 sheet。

#### 5.O.2 设计决策

- NewChapterSheet "导入"tab 加 **"批量模式"** Toggle
- 开启后:文本框上方提示"用 `第X章` 或 `Chapter X` 作为分隔符";系统按 regex 切分
- 预览区显示切出多少章、每章字数
- 提交时:对每章串行调 `POST /chapters/.../import`(进度条显示当前进度)
- 失败处理:中途某章失败 → 暂停 + 显示错误 + 保留已成功的章节

---

### 5.P v0.7 急修包 🟢 **必修**

#### 5.P.1 子项清单

reviewer 在 v0.7 启动审计中发现的 5 个跨 phase 问题,合并为一个急修 Phase:

1. **D — SSE producer cancel hook**:client 断连 → 后端 daemon thread 通过 `threading.Event` 收到 cancel 信号 → 立即终止 LLM stream → **关计费泄漏**
2. **L — SSE cancel/disconnect 测试**:配 D 一起做,锁契约
3. **G — ChapterEditorStore.load 完整 reset @Published**:切章节时清 `lastUpdatedCharacterIds` / `isImporting` / `writingState` 全部,避免上一章状态泄漏到新章节
4. **A — LLM 上游 4xx body 脱敏 + 截断**:body 含用户内容可能泄露,且 OpenAI-compat 上游 4xx 偶尔回显 header → 入库前过滤敏感 token + 截断到 256B
5. **F — ChapterPatch 白名单字段**:当前 `PATCH /chapters/{id}` 用 `for k, v in payload.dump()` 裸 setattr,可能误改 status / source → 改成显式白名单 `{title, user_prompt, structured_prompt, draft_text}`
6. **E — `/chapters/{id}/admin_reset` 端点 + UI 入口**:任意状态 → draft_ready(确认 alert),用于 SSE 中途崩溃 / 状态卡死时自救;UI 在 SettingsView 或章节 toolbar 隐藏菜单

#### 5.P.2 Phase 拆分

- **P-1**(后端):D + L + A + F 都是后端补丁,一笔 commit
- **P-2**(前端):G + E 的 UI 入口
- **P-3**(后端):E 的端点(单独拎出来因为可能要加新 router method)

---

### 5.F 章节/全书导出 🟢

#### 5.F.1 动机

写完一本想分享 / 备份 / 投稿。

#### 5.F.2 设计决策

- **后端**:`GET /api/v1/books/{id}/export?format={markdown|txt}`
  - markdown 包含:书标题(H1)+ 章节(H2 = "第 N 章 · 标题")+ 正文 + 章节间分隔
  - txt 不带标记,纯正文 + 章节标题
  - 单章导出:`GET /api/v1/chapters/{id}/export?format=...`
- **前端**:Bookshelf 书卡 hover 显示"导出"按钮;ChapterEditor 顶部 toolbar 隐藏菜单加"导出本章"
- 浏览器 / Mac 走 NSSavePanel,默认文件名 `{book_title}.md` / `第N章.md`

---

### 5.Q 文档同步 🟢

#### 5.Q.1 范围

v0.7 收尾时清理累积的文档漂移:
- PROJECT_PLAN.md §2 项目结构总览(reviewer 指出已经过时,仍写 12 pytest / 17 XCTest / 5 张表)
- PROJECT_PLAN.md §1.1 v0.6 能力(v0.6.x 急修后部分描述需更新)
- App/README.md / Backend/README.md(自 v0.5 后未走查,大概率漂移)
- `Backend/IMPLEMENTATION_STATUS.md`(v0.5 存档,确认是否需要 v0.6 版本)

#### 5.Q.2 时机

v0.7 最后一笔 commit(发版同步那一笔),与 5 处版本号一起做。

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

### [2026-05-24] v0.6.x 试运营急修汇总(commit `4ef4f2c` / `ac258b8` / `40edf39` / `6839879`)

四笔修复,均不动 plan 层面契约:
- `4ef4f2c` v0.6.1 NewChapterSheet 加导入 tab(A-2 入口前移,跳过填假 prompt 的弯路)
- `ac258b8` Step3_DraftView 只读分支用 Text 替代 disabled TextEditor(macOS 上 disabled 冻结滚动)
- `40edf39` ChapterToolbar 用 isStreaming 短路 chapter.status 切换(双击"写作"按钮的 race)
- `6839879` OpenAICompatibleClient 处理空 `choices` 帧(provider 偶发 metadata 帧导致 IndexError)
治本根因抽象建议放 v0.7 §5.P 急修包(40edf39 的 chapter.status 单一源问题)。

### [2026-05-24] v0.7 plan 锁定(本文档版本 v0.7-draft)

主菜 L(角色卡 narrative 通病修复)+ 必修包 P(SSE cancel / admin reset / Store reset / PATCH 白名单 / 4xx 脱敏) + 战略价值(M 多 LLM per-Agent / N 错误中文化 / F 导出) + v0.5 旧债清算(B/C/D)+ O 批量导入 + Q 文档同步,共 11 项 / 15 个 Phase。整体审计由 reviewer 完成,发现 3 个 🔴 严重问题(SSE producer 线程泄漏关计费、ChapterEditorStore.load 未重置 lastUpdatedCharacterIds、LLM 4xx body 入库泄漏),全部进 P 急修包,P-1 是 v0.7 第一棒。

### [2026-05-25] Phase P-2 前端急修包实施

- 变更内容:
  - **G (ChapterEditorStore.load 完整 reset)**:抽 private `resetAllPublishedToIdle()`,统一从一个入口清零所有 per-chapter `@Published`(`chapter` / `writingState` / `isExpanding` / `isFinalizing` / `isImporting` / `lastUpdatedCharacterIds`);`load(chapterId:)` 入口先调一次,避免上一章 finalize 的 `lastUpdatedCharacterIds` 红点泄漏到新章节(reviewer 报的🔴 严重)。`reset()` / `adminReset` 复用同一私有方法。`isLoading` 故意不清(那是 async 网络态,由各自 defer 管)。cancelStream() 仍在最前,避免 in-flight task 之后翻回 `.streaming`。
  - **E (P-3 admin_reset UI 入口)**:
    - **Models/Chapter.swift** 新增 `ChapterAdminResetRequest`(Codable,`targetStatus → target_status` 命名转换,默认 `.draftReady`)
    - **Services/APIClient.swift** Protocol + 实现新增 `adminResetChapter(id:targetStatus:)`,调 `POST /api/v1/chapters/{id}/admin_reset`,返回 Chapter
    - **Stores/ChapterEditorStore.swift** 新增 `@discardableResult adminReset(targetStatus:)`,内部调 api → `resetAllPublishedToIdle()` 清零 → 装回新 chapter(因为 admin_reset 是"卡死自救",in-flight 的 isImporting / streaming buffer / 红点全部失效);失败走 ErrorBus,默认成功 Toast 不弹
    - **Views/Workspace/Editor/ChapterToolbar.swift** 加 `ellipsis.circle` 三点菜单(在 import 按钮 + primary 按钮之后,toolbar 最右),菜单项 `Label("强制重置状态", systemImage: "exclamationmark.arrow.circlepath")`;点击弹原生 alert 确认,确认后调 `adminReset(targetStatus: .draftReady)`。文案对作者讲人话("把当前章节强制改回「正文完成」状态。正文(draft_text)和结构化提示(structured_prompt)会保留,仅清掉写作中状态。用于章节状态卡死时自救,正常流程不要用。")。菜单在所有 status 下可见(escape hatch 本意),用 `.menuStyle(.borderlessButton) + .menuIndicator(.hidden)` 让 ellipsis 图标不挤
    - **MockAPIClient** 同步加 `adminResetChapter` + `onAdminReset` 钩子,镜像后端幂等行为(`status == target` 时不动 `updatedAt`)
  - **测试**:新增 `LinoWritingTests/ChapterEditorStoreResetTests.swift`,7 个测试:
    1. `loadChapter_clearsLastUpdatedCharacterIdsFromPriorChapter` — reviewer 找到的精确场景(finalize A → 切 B → 断言 B 的 lastUpdatedCharacterIds 为空)
    2. `loadChapter_resetsAllPerChapterPublishedToIdle` — 全 @Published baseline 守护
    3. `reset_clearsEverythingIncludingChapter` — public reset 行为
    4. `adminReset_writingToDraftReady_succeedsAndClearsState` — 端到端(writing → draftReady,保 draft_text + structured_prompt)
    5. `adminReset_idempotent_returnsTrueAndStaysAtTarget` — 幂等
    6. `adminReset_networkFailure_publishesAndKeepsChapter` — 失败不静默 mutate + ErrorBus
    7. `adminResetRequest_encodesTargetStatusAsSnakeCase` — 锁 `target_status` 命名契约,防 Swift 改名 422
- 变更原因:reviewer v0.7 启动审计提的🔴 严重(load 漏 reset)+ 🟡 自救路径前端入口(admin_reset),与 P-1+P-3 后端同步落地。
- 影响范围:Phase P-2,前端急修包完整落地;不动 v0.6 已稳定的 Material / 动画 / Toolbar 主结构(仅在 toolbar 加一个非侵入式三点菜单)。
- 测试基线:v0.6 末 34 XCTest → P-2 末 41 XCTest(34 baseline 全过,新增 7 个 reset 守护测试)。`xcodebuild build` 干净无 warning。
- 未做:L-2 / L-3、M / N / F / O / B / C / D / Q 其它 v0.7 项。

### [2026-05-25] Phase P-1 + P-3 后端急修包实施

- 变更内容:
  - **D (SSE producer cancel hook)**:`LLMClient` Protocol 加 `cancel_event: Event | None = None` kwarg(向后兼容,所有 mock 用 `**kwargs` 吸收);`OpenAICompatibleClient._stream` 在 `iter_lines()` 每次迭代前检查 `cancel_event.is_set()`,True 则直接 return(httpx with-block 退出会关 upstream socket,真正止血)。`WriterAgent.stream(context, cancel_event=...)` 透传。`_write_stream` generator 创建 `threading.Event`,在 finally 里 `cancel_event.set()`,producer thread 在每次 put token 前也检查 cancel 防止给已无人消费的 queue 堆 token。选用方案 A(显式 kwarg),而非方案 B(thread 强制 close httpx response),原因:更明确、易测、不依赖跨线程 cancel httpx 的不可移植行为。
  - **A (LLM 4xx body 脱敏)**:新增 `_sanitize_error_body()`,先 regex 替换 `Bearer\s+\S+` / `Authorization:\s*\S+` / `sk-\S+` / `xai-\S+` / `sk-or-\S+` / `sk_live_\S+` 为 `***`,再截断到 256 字符(顺序很重要:截断在前会切断 redaction 漏半 key)。`_post_json` 和 `_stream` 的 4xx 分支都换用。
  - **F (ChapterPatch 白名单字段)**:`ChapterPatch` schema 本身已经是 4 字段白名单(title / user_prompt / structured_prompt / draft_text),保留不动;router 内加 `PATCHABLE_CHAPTER_FIELDS` 常量 + 显式 if-not-in-allowlist:continue,防御未来给 schema 加字段时静默打开 mass-assignment 漏洞。决策:Pydantic + router 两层防御,各负其责。
  - **E (P-3) admin_reset 端点**:`POST /chapters/{id}/admin_reset`,body 可选 `{target_status?}`,默认 `draft_ready`,只允许 `{draft, prompt_ready, draft_ready}`(`writing`/`finalized` 在 schema 层拒绝)。无 ensure_chapter_status 检查 — 任意状态可入,这是 escape hatch 的本意。保留 draft_text / structured_prompt 不动。写一条 `agent_logs` 行,`agent_name="admin_reset"`,`input_preview` 装 `{from_status, to_status}` JSON 供审计。
  - **L (SSE cancel 测试)**:新增 `tests/test_sse_cancel.py` 5 个测试:
    1. `OpenAICompatibleClient._stream` 在 cancel 预设时立即 return(用 patch httpx.stream 喂假 SSE)
    2. cancel 在迭代中途设置时,后续 token 不再 yield
    3. `WriterAgent.stream(cancel_event=...)` 正确转发到 LLM
    4. 直接驱动 `_write_stream` generator + `.close()` 模拟 client disconnect,验证 chapter.status 不卡 writing
    5. 同上,enumerate threads 验证 producer thread 不 leak
  - 测试设计偏离:原 plan 提示用 TestClient 模拟 client disconnect,实际发现 TestClient 的 ASGI in-process 实现会 buffer 整个 SSE response,无法忠实模拟 disconnect 中断。改用直接驱动 `_write_stream` generator 并调用 `.close()`(这就是 FastAPI 在 disconnect 时实际做的事),完成等价验证。
- 变更原因:试运营 reviewer 报告的 3 个🔴 严重问题(SSE 线程泄漏关计费、PATCH 漏洞、4xx 入库泄漏)+ 1 个🟡 自救路径(admin_reset)+ 锁契约测试(L)。P-1 是 v0.7 第一棒,完成。
- 影响范围:Phase P-1(D / A / F / L)+ P-3(E),后端急修包完整落地。
- 测试基线:v0.6 末 57 pytest → P-1+P-3 末 82 pytest(57 baseline 全过,新增 25 个:5 SSE cancel + 8 4xx 脱敏 + 7 admin_reset + 5 PATCH 白名单)。`pytest -W error` 干净无 warning。
- 未做:P-2 前端(另一 builder)、L 主菜(L-1/L-2/L-3 下一轮)、M / N / F / O / B / C / D / Q 其它 v0.7 项。

### [2026-05-25] Phase L-1 角色卡分层数据模型实施

- 变更内容:
  - **Alembic 迁移 `202605250001_add_character_author_notes`**:`characters` 表新增 `author_notes JSON NOT NULL DEFAULT '{}'`(PostgreSQL 上自动走 JSONB,沿用 §5.L.3 的 `sa.JSON().with_variant(JSONB, "postgresql")` 同款模式)。`server_default='{}'` + 防御性 `UPDATE` 双保险回填存量行(干净 SQLite + 已有 7 行 dev 数据库均验证回填为 `{}`);downgrade 写 `drop_column`。
  - **`Character` ORM 模型**:加 `author_notes: Mapped[dict[str, Any]]`,用 `MutableDict.as_mutable(json_dict_type)` + `default=dict, nullable=False`,与 frozen/live 完全对齐。
  - **`Character*` Pydantic schema**:`CharacterCreate` / `CharacterRead` 加 `author_notes: dict[str, Any] = Field(default_factory=dict)`;`CharacterPatch` 加 `author_notes: dict[str, Any] | None = None`。PATCH 仍走现有 `model_dump(exclude_unset=True) + setattr` 通路,**整体替换语义**(与 frozen/live 一致;非合并 — 这是与 v0.6 现有行为对齐的判断,L-3 前端 UI 折叠区也按此设计)。
  - **`StructuredPrompt` schema**:加 `focus_traits: list[str] = Field(default_factory=list)`,字段类型为强类型 `list[str]`(不是 free-form Any)。L-1 不让 Expander 产 focus_traits(L-2 的活),只把 schema 通路打开,作者可经 chapter PATCH 端点手填。
  - **`characters` router create 端点**:新增 `author_notes=payload.author_notes` 传入构造器。Patch/Read/List 端点零改动 — 通用通路天然覆盖新字段。
  - **`tests/test_character_author_notes.py`** 新增 5 个测试:
    1. create 时传 author_notes,GET 能看到
    2. create 不传,默认 `{}`
    3. PATCH author_notes 是整体替换(`{a:1, b:2}` PATCH `{c:3}` → `{c:3}`)
    4. PATCH 别的字段(role)不会清空 author_notes(`exclude_unset` 验证)
    5. ORM 直接插入旧 character(模拟 pre-migration 行)读出来 `author_notes={}`
- 变更原因:v0.7 主菜 L 第一棒,§5.L.3 数据模型 + schema 通路。本 Phase **只动数据模型 + schema**,Expander/Writer prompt(L-2)和前端三区(L-3)不在范围内。
- 影响范围:Phase L-1;新增/修改文件 6 个(1 迁移 + ORM + 2 schema + router + 测试)。
- 关键判断:
  - `author_notes` PATCH = 整体替换(不是 deep merge),与 `frozen_fields` / `live_fields` 现有语义一致;前端 L-3 折叠区也按此设计(用户编辑 = 提交完整对象)。
  - `focus_traits` 用强类型 `list[str]` 而非保留在 `extra="allow"` 的 free-form key,理由:它是 Writer prompt L-2 要稳定消费的字段,提早锁类型可以让前端 chip 多选有明确契约。
  - 迁移兼容性:`sa.JSON().with_variant(JSONB, "postgresql")` 与 v0.5 initial_schema 内 `json_type` 一致;`server_default=sa.text("'{}'")` 在 SQLite 和 PostgreSQL 上都是合法 JSON literal,均通过 `ALTER TABLE ... ADD COLUMN` 回填。
- 测试基线:v0.7 P-1+P-3 末 82 pytest → L-1 末 88 pytest(83 baseline + 5 新)。注:重数过去日志,实际 baseline 是 83(v0.6 末 57 + P-1 25 + 1 隐含,以本次实跑为准)。`pytest -W error` 干净。
- 未做:Expander focus_traits 推断(L-2)、Writer prompt show/tell 改造(L-2)、context_pack 合并查询(L-2)、前端三区(L-3)。

### [2026-05-25] Phase M-1 多 LLM per-Agent 后端实施

- 变更内容:
  - **Alembic 迁移 `202605250002_add_provider_key_agent_role`**(顺接 L-1 的 250001):
    - `provider_keys` 加 `agent_role TEXT NULL`(NULL = 通用 / 全局回退)
    - `system_settings` 加三个 FK 字段 `active_writer_key_id` / `active_extractor_key_id` / `active_expander_key_id`,均 FK → `provider_keys.id ON DELETE SET NULL`
    - 用 `batch_alter_table` 加 FK(SQLite 不支持 plain ALTER TABLE 加 FK,dev DB 是 SQLite,所以必须 batch)。downgrade 反向 drop 全部 4 列。
    - 干净 SQLite + 已升级 dev DB 双验证(`alembic upgrade head` / `downgrade 250001` / `upgrade head` 三次往返成功)。
  - **`ProviderKey` ORM**:加 `agent_role: Mapped[str | None]`。**`SystemSettings` ORM**:加三个 `active_*_key_id: Mapped[str | None]`(FK 与迁移一致)。
  - **`ProviderKey*` Pydantic schema**(`app/schemas/provider_key.py`):
    - 新增 `AgentRole = Literal['writer','extractor','expander']` + `AGENT_ROLES` 常量(单一来源,加新 Agent 只动这里 + 路由 dispatch dict)。
    - `ProviderKeyCreate` / `ProviderKeyUpdate` / `ProviderKeyRead` 加 `agent_role: AgentRole | None`(create 默认 None;PATCH 用 `exclude_unset` 区分"未传"vs"传 null 清回 generic")。
    - 新增 `ActiveAgentKeyRead`(flat shape:`{agent_role, active_provider_key_id, key_label, provider_hint, model_name, api_key_mask}`,与 `SystemSettingsRead` 对齐;`agent_role` 字段帮前端在一个列表里 render 多行)。
    - 新增 `ActiveAgentKeyUpdate`(`provider_key_id: str | None`;**null = 显式清回 generic fallback**,不同于"从未设置")。
  - **`routers/provider_keys.py`**:
    - 现有 6 个 endpoint + 通用 active 全部保留(向后兼容关键)。
    - 新增 `GET /api/v1/settings/active_key/{agent_role}` + `PUT /api/v1/settings/active_key/{agent_role}`(参数化,**不是 6 个独立端点**;agent_role 用 FastAPI `Path(pattern="^(writer|extractor|expander)$")` 校验,非法值走 422)。
    - PUT 上额外 validate:**若 ProviderKey 自身 `agent_role` 非 NULL,只能激活到匹配的 slot**(`extractor` 键不能激活到 `writer` slot;返 409 conflict)。这让 `agent_role` 字段有实际意义,而非纯装饰。NULL `agent_role`(通用键)允许激活到任意 slot。
    - `delete_provider_key` 显式清通用 active + 三个 per-agent active(SQLite 默认不强制 FK,显式清确保 API 契约一致)。
  - **`app/llm/factory.py`**:
    - 保留 `load_active_provider_key(db)`(通用 fallback)与 `build_llm_client(db)`(零参签名,v0.6 调用方零改动)。
    - 新增 `load_active_provider_key_for_agent(db, agent_role)`:查 `system_settings.active_{agent}_key_id` → 找到则返;否则 fallback 通用 active。stale FK(指向已删 row)也 fallback 通用而非 500。
    - `build_llm_client(db, agent_role=None)` 加 keyword-only 参数 agent_role,调上面的函数。
  - **`app/llm/base.py`**:`get_llm_client`(v0.6 通用)保留;新增 3 个 Depends — `get_writer_llm_client` / `get_extractor_llm_client` / `get_expander_llm_client`,各自走 `build_llm_client(db, agent_role=...)`。
  - **`app/routers/chapters.py`**:`/expand` → `get_expander_llm_client`;`/write` → `get_writer_llm_client`;`/finalize` → `get_extractor_llm_client`;`/import`(run_extractor 路径)→ `get_extractor_llm_client`。**这是 M-1 核心契约,让控成本立刻起效**。
  - **`tests/conftest.py`**:新增 `ALL_LLM_DEPENDENCIES` 常量(4 个 Depends 函数的 tuple),`override_all_llm_clients(factory)` 一次性 override 全部,`clear_all_llm_overrides()` 一次性 pop 全部。conftest 默认 override 全部 4 个到 MockLLMClient → v0.6 era 测试零改动。
  - **`tests/test_chapters_flow.py` / `test_chapter_import.py`**:把 `dependency_overrides[get_llm_client] = ...` 改成 `override_all_llm_clients(lambda: ...)`(测试代码升级,生产行为不变)。
  - **`tests/test_llm_factory.py`**:把 `dependency_overrides.pop(get_llm_client, None)` 改成 `clear_all_llm_overrides()`。
  - **`tests/test_per_agent_factory.py`** 新增 18 个测试:
    - 5 个 factory unit:per-agent 优先 / fallback 通用(§5.M.3 兼容性)/ 全空报 upstream / `build_llm_client(db)` 零参 v0.6 行为不变 / stale FK fallback(PRAGMA off 模拟)。
    - 10 个 endpoint:create 带 agent_role 回环 / 默认 NULL / 非法 agent_role 422 / PATCH 清回 NULL / GET unset 返 null summary / PUT generic 键到任意 slot 成功 / PUT mismatch agent_role 返 409 / PUT null 清回 fallback / PUT 非法 path agent_role 422 / PUT unknown key id 404 / DELETE 共享键清三个 slot + 通用。
    - 3 个 end-to-end:expand/write/finalize 各自 Depend 不同 mock(用 `_LabelledLLM` 在 mock 里打标签,断言 expander 收到 `complete_json`、writer 收到 `complete_stream`、extractor 收到 `complete_json`,**且无跨 Agent 泄漏**);v0.6 用户全 NULL 配置时三个 endpoint 都用 conftest 默认 MockLLM(模拟 factory fallback chain),expand→write→finalize 全 200(§5.M.3 兼容性 end-to-end 验证)。
- 变更原因:v0.7 §5.M 主菜之一,让用户能分别给 Writer(Claude 顶级)/ Extractor(中端 Grok)/ Expander(任意便宜模型)选不同 LLM key,控成本同时质量不降。
- 影响范围:Phase M-1 后端;新增/修改文件 8 个(1 迁移 + 2 ORM + 1 schema + 2 router + 1 factory + 1 base.py + 1 conftest + 1 测试)+ 3 个旧测试小改(替换 dependency_override helper)。
- 关键判断:
  - **端点参数化**(`/settings/active_key/{agent_role}`)而非 6 个独立端点:plan §M.2 提的备选方案,我选参数化 — 单一路径正则约束 agent_role,前端 E-3 后续做 dropdown 时一个 generic API method 就够,加新 Agent(比如 "summarizer")只动 schema enum + dispatch dict 两处。
  - **Depends 命名** `get_{agent}_llm_client`:与现有 `get_llm_client` 同 prefix,签名一致(只接 `db`),测试 override 模式无缝。
  - **不在 `GET /system_settings` 里返三个 *_summary**:避免响应膨胀且语义混乱(那个 endpoint 已经叫 active_provider_key 专指通用);per-agent active 走独立的 `/settings/active_key/{agent_role}` endpoint,前端要时三次调用。
  - **agent_role 校验语义**:`ProviderKey.agent_role` 非 NULL 时,**只能激活到匹配 slot**(否则 409)。让该字段有实际治理作用,而不是纯前端 hint;NULL(通用)依然可激活到任意 slot,这是 v0.6 用户和"我这把 key 三个 agent 都行"的常见场景。
  - **向后兼容如何保证**(§5.M.3 关键):
    1. ORM / DDL 层:三个新 FK 字段都 nullable;v0.6 库升上来后默认全 NULL。
    2. Factory 层:`load_active_provider_key_for_agent` 当 per-agent 为 NULL 时 fall through 到 `load_active_provider_key`(v0.6 函数原封不动);所以 v0.6 deploy 升级到 v0.7 后,在用户没碰新 UI 之前,Writer/Extractor/Expander 三个 Depends 都解析到通用 active key。
    3. Endpoint 层:旧的 6 个 provider_key endpoint + 通用 `/settings/active_provider_key` 0 行修改;前端 E-3 已 ship 的 UI 继续工作。
    4. 测试层:`test_v06_user_with_no_per_agent_keys_routes_through_fallback` 端到端验证完整流程(expand→write→finalize)在零 per-agent 配置下全 200。
    5. `build_llm_client(db)` 零参签名保留 — v0.6 任何代码调它行为不变(只查通用 active,不碰新字段)。
- 测试基线:L-1 末 106 pytest(包括 L-2 expander_focus_traits 7 个,因另一 builder 已 commit)→ M-1 末 124 pytest(106 baseline 全过 + 18 新)。`pytest -W error` 干净无 warning。
- 未做:M-2 前端(SettingsView LLM Providers tab 加"哪个 Agent 用哪个 key"dropdown,另一 builder)。
- 端到端 happy path(curl):
  ```
  # 1. 用户上传两把 key
  POST /api/v1/provider_keys {"key_label":"Claude 4.5","base_url":"https://openrouter.ai/api/v1","api_key":"sk-or-...","model_name":"anthropic/claude-sonnet-4.5","agent_role":"writer"}
  POST /api/v1/provider_keys {"key_label":"Grok mini","base_url":"https://api.x.ai/v1","api_key":"xai-...","model_name":"grok-3-mini","agent_role":"extractor"}
  # 2. 各自激活
  PUT /api/v1/settings/active_key/writer {"provider_key_id":"<claude id>"}
  PUT /api/v1/settings/active_key/extractor {"provider_key_id":"<grok mini id>"}
  # 3. 写作流(Writer 走 Claude / Extractor 走 Grok mini,Expander 没设 → fallback 通用 active)
  POST /api/v1/chapters/<id>/expand    # → Expander 用通用 active(或 fallback 报 no_active_llm_key)
  POST /api/v1/chapters/<id>/write     # → Writer 用 Claude
  POST /api/v1/chapters/<id>/finalize  # → Extractor 用 Grok mini
  ```

### [2026-05-25] Phase L-2 Expander + Writer prompt + context_pack 实施

- 变更内容:
  - **`PromptExpanderAgent`** (§5.L.4):system_prompt 增加 "focus_traits" 段(教模型挑 0-2 个本章最相关的 trait、纯字符串、不是字段路径、纯过场/动作场返回空数组);JSON schema 增加 `focus_traits` 槽位(`type: array, items: string, maxItems: 2`);新增 `MAX_FOCUS_TRAITS=2` 常量 + `_expander_json_schema()` helper;`expand()` 加服务端 truncate(LLM 多产时取前 2 个并过滤非字符串),Pydantic 验证前兜底。
  - **`WriterAgent`**(§5.L.5):system_prompt **完全重写**,逐字采用 plan §5.L.5 模板(角色卡使用规则段 / show-don't-tell 反例 / 同 trait 整章最多一次 / 不要逐字搬字段名 / 角色卡是水库不是水桶 / 本章重点段 / author_notes 段),保留 must_happen / must_not_happen / timelines / target_word_count / 文风遵循 / 只输出正文等现有规则;Writer 代码逻辑零改动(仍是 JSON dump 整个 context + 文风样本块)。
  - **`context_pack.py`**(§5.L 整段):
    - 合并 `_recent_summaries` + `_style_samples` → `_recent_finalized(db, book_id, before_index, *, summaries_limit, style_samples_limit, chars_per_side=...)`,一次 SELECT 取 `max(summaries_limit, style_samples_limit)` 行,内存切两次 transform;短章短样规则、ascending 返回顺序、空 limit 短路都保留。
    - `_character_full(character, *, include_author_notes: bool)`:author_notes 字段按调用方按需 gate。`build_writer_context` 和 `build_expander_context` 设 True;`build_extractor_context` 设 False(决策:Extractor 不该看 author_notes,避免诱导它把 motivation/secret 折入 live_fields,污染私有通道)。
    - `_character_brief`(Expander 用):新增 `frozen_fields` + `author_notes` 全量字段。**这是 plan 没明说但 §5.L.4 隐含要求的微小扩展** — Expander 要"看本章涉及角色的 frozen_fields + author_notes"才能推断 focus_traits,v0.6 的 brief 只有 `profile` 一行不够用。保留原 `profile` 一行向后兼容。`live_fields` 不投喂(它是 Extractor 维护的事实,不是 trait 池)。
    - 新增 `RECENT_SUMMARIES_COUNT=2` 常量,与 `STYLE_SAMPLES_*` 并列在文件顶部。
  - **测试新增 16 个**:
    - `tests/test_expander_focus_traits.py` 7 个:解析非空 / 解析空 / >2 时服务端 truncate / 过滤非字符串 / 字段缺失走默认 / JSON schema 槽位形状 / system_prompt 关键词回归。
    - `tests/test_writer_prompt.py` 新增 4 个:system_prompt 包含 §5.L.5 关键短语("幕后参考"、"focus_traits"、"角色卡使用规则"、"author_notes"、show/tell 反例对、"水库"、"绝不可有任何句子直接转述 author_notes")/ 不再包含旧的 "严格遵守 characters[*].frozen_fields" 与 "冻结区不能漂移" / 保留 must_happen / must_not_happen / timelines / 字数 / 文风 / 只输出正文 / Writer user message JSON 携带 author_notes 与 focus_traits 字段(契约测试,锁防未来重构悄悄剥离)。
    - `tests/test_context_pack.py` 新增 5 个:Writer context 含 author_notes / Expander context 含 author_notes(brief 路径)/ Extractor context **不含** author_notes / 合并查询 SQL 计数(SQLAlchemy `before_cursor_execute` event hook 验证 chapter-only SELECT 仅 1 次)/ 不同 limits 分别 trim 正确(2+4、3+1、0+0 三个 case)。
- 变更原因:v0.7 主菜 L 第二棒,§5.L.4 + §5.L.5 + §5.L 余下段(context_pack 合并查询是顺手把整体审计 J 项性能问题做了)。**直接解决"Writer 把角色卡当 narrate 检查表"的内容质量通病**。
- 影响范围:Phase L-2;修改 3 个生产文件(`prompt_expander.py` / `writer.py` / `context_pack.py`)+ 修改 2 个测试文件(`test_writer_prompt.py` / `test_context_pack.py`)+ 新增 1 个测试文件(`test_expander_focus_traits.py`)。routers / models / migrations 全部零改动。
- 关键判断:
  - **Expander 服务端 truncate**:LLM system_prompt 已写 "max 2",JSON schema 已写 `maxItems: 2`,但 LLM 仍可能越界(尤其便宜模型 / structured-output 不严格的 provider)。`expand()` 内 truncate 是第三道保险,保证 contract 与 provider 解耦。同时把非 string 项过滤掉(模型偶尔会塞 dict 或 int)。
  - **Extractor 不投喂 author_notes**:这是私域通道(作者填给 Writer 看的演员小抄),Extractor 看到后会被诱导把 "motivation"、"secret" 折入 live_fields,把作者的私笔记搞成了 Agent 维护的事实。决策:Writer/Expander = True,Extractor = False。
  - **Expander brief 扩展 frozen_fields + author_notes**:plan §5.L.4 字面说 "看 frozen_fields + author_notes",v0.6 的 `_character_brief` 只有一行 profile 不够用。我扩展了 brief 但保留 `profile` 一行向后兼容;`live_fields` 仍不投喂(它是 Extractor 维护的事实,不是 trait 池)。这是本次唯一一个 plan 没明说但合理推进的小扩展。
  - **合并查询 LIMIT 取法**:`max(summaries_limit, style_samples_limit)` — 两个共享 finalized 行池,取较大值后内存独立 trim;`limit=0` 双零短路不打 DB。
  - **Writer 代码逻辑零改动**:JSON dump context 时 author_notes 和 focus_traits 自动随车,WriterAgent._render_user_message 无需改;只改了 system_prompt 字符串。
- 测试基线:L-1 末 88 pytest(本次实跑)→ L-2 末 97 pytest(81 baseline 全过 + 16 新)。**注:跑测时观察到 M-1 builder 并行改动了 `provider_keys` model + schema 但 `routers/provider_keys.py` 的 `_to_read` 还没补 `agent_role` 字段,引起 9 个 provider_keys / llm_factory 测试失败**,跟 L-2 无关 — 用 `--ignore` 排除后 83 个非 M-1 测试全过;只跑 L-2 范围(`test_expander_focus_traits.py` / `test_writer_prompt.py` / `test_context_pack.py` / `test_style_samples.py` / `test_agents_with_mock.py` / `test_character_author_notes.py` / `test_chapters_flow.py` / `test_chapter_import.py` / `test_chapter_patch_allowlist.py`)52 passed。`-W error` 干净。
- 未做:多 LLM per-Agent 后端完工(M-1 另一 builder)、前端角色卡分三区与 focus_traits chip 多选(L-3 另一 builder)、其它 v0.7 项。

### [2026-05-25] Phase L-3 前端角色卡三区编辑 + focus_traits chip 实施
- 变更内容:
  - **`Models/Character.swift`**:`Character` 加 `authorNotes: [String: JSONValue]`(与 `frozenFields` / `liveFields` 严格对齐的类型)。自定义 `init(from:)` 用 `decodeIfPresent ?? [:]` 容错 pre-L-1 缓存 payload(沿用 `Chapter.source` 的 §5.A.6 fallback 模式)。`CharacterCreateRequest` / `CharacterPatchRequest` 同步加 `authorNotes` optional 字段,CodingKeys 全部映射 `author_notes` snake_case。
  - **`Models/StructuredPrompt.swift`**:加 `focusTraits: [String]`(默认空);自定义 `init(from:)` 加一行 `decodeIfPresent ?? []`。`focus_traits` snake_case 映射。
  - **`Stores/CharactersStore.swift`**:新增 `updateAuthorNote(key:value:)` / `removeAuthorNote(key:)` 走 PATCH 通路;`patch` 设 `public` 以便 view 层组装 author_notes 整体替换(自由 key/value 行场景)。
  - **`Views/Workspace/RightPanel/CharacterCardEditorView.swift`**:在现有"冻结区 + 活动区"下面加第三个 `authorNotesSection`,用 `DisclosureGroup` 默认折叠(`@State authorNotesExpanded = false`)。展开后:`theatermasks` SF Symbol + "作者笔记 / 幕后专属"标题(.secondary 弱化);副标题"仅供 Agent 幕后参考,不会被写入正文";三个推荐 scalar 行(`motivation` / `wound` / `secret`,均 multiline);最下面 `InlineEditableDict` 收"更多笔记"自由 key/value(自动从 character.authorNotes 里过滤掉三个推荐 key,提交时合并回)。容器用 `Color.secondary.opacity(0.05)` 填充 + 虚线 strokeBorder,与上面两区视觉上区分。切换角色时 `authorNotesExpanded` 重置回 false,避免"打开状态泄漏"。
  - **`Views/Workspace/Editor/Step2_StructuredPromptView.swift`**:在"出场角色"后面新增 `field("本章人格重点(0-2 个,emerge 重点)")` chip 编辑器。chip 用 `Color.purple.opacity(0.18)` Capsule(区别于 must_happen 的灰 chip);每个 chip 自带 × 删除;输入用一个独立的 `FocusTraitInputField` private View(自带 `@State draft`,enter 提交 — 避免 FlowLayout 重渲染时丢键入状态);**最多 2 个** chip,达上限时输入框自动消失;onCommit 也再过一次 `< 2` 检查双保险。`onChange` 走原有 `draft.focusTraits` mutation → `dirty = true` → "保存提示"按钮 PATCH `structured_prompt`。
  - **`LinoWritingTests/CharacterAuthorNotesCodecTests.swift`** 新建,9 个 XCTest:
    1. `Character` 解码 `author_notes` 存在 → 拿到三个 key
    2. `Character` 解码 `author_notes` 缺失 → fallback `[:]`
    3. `Character` 完整 round-trip 保 `author_notes`
    4. `CharacterPatchRequest` 编码 emit `author_notes` snake_case,**不** leak `authorNotes` camelCase
    5. `CharacterCreateRequest` 编码同上
    6. `StructuredPrompt` 解码 `focus_traits` 存在
    7. `StructuredPrompt` 解码 `focus_traits` 缺失 → fallback `[]`
    8. `StructuredPrompt` round-trip 保 `focus_traits` snake_case
    9. `ChapterPatchRequest` 嵌套的 `structured_prompt.focus_traits` 序列化
- 变更原因:L 主菜第三棒(§5.L.6)。打通"作者笔记区"(L-1 后端字段) + "本章人格重点 chip"(L-2 后端字段)的前端编辑路径,让作者可以分别在角色卡和章节 Step2 编辑这两个新维度。
- 影响范围:Phase L-3;修改/新增前端 6 个文件(2 model / 1 store / 2 view / 1 test)。无后端、无 prompts、无 P/M-series 文件改动。
- 关键判断:
  - **`authorNotes` 类型 = `[String: JSONValue]`**:严格对齐 `frozenFields` / `liveFields`,而不是更简单的 `[String: String]`。理由:后端 schema `dict[str, Any]` 任何 JSON 值都可能进,前端不应强制 string 化截掉信息(虽然 UI 当前只渲染 string)。这给将来扩展(如 author_notes 里塞 list 或嵌套 dict)留路径。
  - **作者笔记区默认折叠**:`@State` 而非 `@AppStorage` — 切换角色重置,避免在另一个角色卡看到 A 角色"展开过"的余韵。视觉上 `theatermasks` SF Symbol + 虚线 border + `.secondary` 弱化标题色,让作者一眼区分"这区是幕后专属"。
  - **focus_traits chip 选项池 = 选项 B(作者自由输入)**:plan §5.L.6 没明文锁池。选 B 而非 A(从角色 trait 池取 key)的理由:① v0.7 trait 本身就是自由文本(没有受控词表),从角色取池会面临"多角色 trait 重名"和"trait key 是英文还是中文"的歧义;② InlineEditableTags 模式已经在 must_happen / must_not_happen 上跑通,作者一看就懂;③ Expander L-2 会自动推断 focus_traits,作者更多是审阅/微调而非凭空填,打字几个字成本低。**上限 2 严格执行**。
- 测试基线:v0.7 P-2 末 42 XCTest → L-3 末 51 XCTest(42 baseline + 9 新),`xcodebuild test` 全过 0 failure。`xcodebuild build` 干净。
- 未做:Writer / Expander prompt 改造(L-2 另一 builder,已落地)、M / N / F / O / B / C / D / Q 其它 v0.7 项。

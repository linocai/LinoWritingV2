# Lino Writing v2 · PROJECT PLAN

> 本文档是 v0.6 起的**单一项目行动依据**。前端、后端、契约层全部合并在此。
> v0.1–v0.5 期间使用 `PLAN_FRONTEND.md` / `PLAN_BACKEND.md` 双契约工作流，作为 v0.5 契约存档保留，不再更新。
>
> 文档版本：v0.9.2（已发布；v0.9.1 已回退 rolled-back）
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

### 0.2.1 HZ 云端事实文件(v0.8 起)

`/Users/linotsai/hz_info.md` 是 HZ 杭州阿里云 ECS 的**单一事实文件**(域名 / 系统用户 / systemd / nginx site / postgres db 与 role / certbot 证书 / 端口监听 / 退役记录)。

**铁律**:任何在 HZ 上的运维动作(新建用户 / 改 nginx / 加 systemd unit / 改 UFW / 改证书 / 加端口监听 / 删旧资产),完成后**必须**同步更新 `hz_info.md`。该文件比 PROJECT_PLAN.md 优先级更高,因为它是**云端真相**。PROJECT_PLAN.md 写"我们准备怎么做",`hz_info.md` 写"现在云上实际是什么样"。

文件遵守的红线(摘自其顶部):**只写非敏感运维事实。不要把 root 密码 / SSH 私钥 / API key / token / `.env` 内容 / 证书私钥 / 数据库业务内容写进去**。

### 0.3 版本号约定

- **MAJOR.MINOR.PATCH** 三段式
- 前端：`App/project.yml` 的 `MARKETING_VERSION`
- 后端：`Backend/pyproject.toml` 的 `version` + `Backend/app/main.py` 的 FastAPI `version` + `Backend/app/routers/health.py` 的 health response
- 测试：`Backend/tests/test_auth.py` 的 assertion
- 发版时统一同步以上 5 处，并在 git commit message 标注

---

## 1. 当前版本状态 (v0.9.2 — 已发布)

> **v0.9.1 → v0.9.2 回退说明**:v0.9.1 用 `keychain-access-groups` entitlement 切数据保护 keychain 想消除 macOS 登录密码弹窗,结果 entitlement 让 Xcode 嵌入设备锁定的 development provisioning profile,与 Developer ID 证书重签冲突 → AMFI 拒绝启动(POSIX 163,**notarize/spctl 都过但 app 打不开**)。reviewer 体检定位根因后走 **Plan A 整体回退**:回文件型 keychain + 移除 entitlement,靠稳定 Developer ID 签名让 macOS "始终允许" 持久生效(ad-hoc 时永不持久,这才是当初"两次密码"的真根因)。详 §5.CC.6 / §7 [2026-05-28] v0.9.2。**v0.9.2 已真机 `open` 验证能启动**(PID 在 + 无 AMFI 拒绝),不再只看 notarize。

### 1.0 v0.9 新增能力(在 v0.8 之上)

**主菜:设备配对认证(W) -- 把双端登录体验做好**
- 后端 `device_tokens` 表(Fernet 加密 token_ciphertext)+ `pair_codes` 短码表(6 位数字 10 分钟 TTL)[§5.W.3]
- `/api/v1/auth/*` 4 端点:`pair_initiate`(要 Bearer)/ `pair_confirm`(白名单无 Bearer,5/min per IP 防爆破)/ `devices`(列)/ `devices/{id}`(revoke,不删行留审计)[§5.W.4]
- `require_bearer_token` 双路径:device-token 优先(`hmac.compare_digest` 防时序 + 命中 update last_used_at),失败 fallback static `api_token`(v0.8 兼容,留到 v1.0.x 删)[§5.W.4]
- macOS Settings 设备管理:列设备 + "添加新设备"生成 QR(CoreImage,JSON-base64 编 url/code/ip)+ 6 位短码 + 10 分钟倒计时 + 撤销 [§5.W.5]
- iOS 启动配对屏 `DevicePairView`:AVCaptureSession 扫码 → pairConfirm → 写 per-host Keychain → 进主界面;手输 6 位备选(Simulator 无相机路径)[§5.W.5]

**必修:TestFlight + Developer ID 分发(X,原 §5.V 重启)**
- 作者注册付费 Apple Developer Program(Team `HX73DFL88G`):iOS 7 天证书 → 1 年 + TestFlight OTA + macOS Developer ID notarize [§5.X.1]
- `project.yml` ad-hoc → Xcode Automatic signing + `DEVELOPMENT_TEAM` + `ENABLE_HARDENED_RUNTIME: YES` [§5.X.4]
- `scripts/release-macos.sh`:Release build → Developer ID 真签 → notarytool submit → stapler staple → spctl 验证 → Desktop。**X-4 实跑:notarytool Accepted,任何 Mac 双击直开** [§5.X.3]
- `scripts/release-ios.sh` + `ios-export.plist`:archive(`-allowProvisioningUpdates`)→ export → altool 上 TestFlight。**X-4 实战修正:altool keychain 在 Xcode 26.5 坏了(svce=NULL 查不到),改 App Store Connect API key 认证(`--apiKey`/`--apiIssuer` + ~/.appstoreconnect/private_keys/*.p8)** [§5.X.3 / X-4]
- `Info.plist` 加 `ITSAppUsesNonExemptEncryption=NO`(仅 HTTPS 豁免加密,免每次 build 的出口合规/法国声明)

**砍掉的候选(作者拍板不做)**
- ⚫ Y iOS DNS/TLS SNI override / ⚫ AA Siri Shortcuts / ⚫ BB Foundation Models -- 详 §5.Y/AA/BB 各节顶部戳记

### 1.0.1 v0.8 新增能力(在 v0.7.1 之上)

**必修包(云上线物理前置)**
- **PostgreSQL 切换**:`config.py` `set_sqlite_pragma` 加 dialect 网关(只 SQLite 跑 PRAGMA;PG 会 SyntaxError 触发 InFailedSqlTransaction)+ 9 条 Alembic 在 PG 16 上一次性 clean [§5.S / S-1]
- **ProviderKey Fernet 加密**:`api_key` 列改密文,`KEK_SECRET` 32-byte url-safe base64 从环境读 + 启动 fail-fast + Alembic `202605260003` data migration 加密回写历史明文 + read-side dual-fallback(v0.9 删) [§5.T / T-1]
- **Rate limit + HSTS + CORS 收窄 + access log 脱敏**:slowapi BaseHTTPMiddleware (per-token,write 30/min / read 600/min,429 + Retry-After + 中文 envelope) + HSTS 不带 includeSubDomains (作者 `*.linotsai.top` 兄弟子域多) + uvicorn access log redact 共享 8 条正则 [§5.T / T-2]

**部署(HZ 阿里云 ECS 一次性上线)**
- 跟邻居 `linofinance-api` / `100j-api` 一致:systemd unit + venv + Nginx + certbot + 现有 `postgresql@16-main`(**无 Docker**) [§5.S]
- 域名 `lw.linotsai.top`,certbot ECDSA 自动续期,Nginx site `proxy_buffering off` 适配 SSE
- 系统用户 `linowriting` + db/role `linowriting` + `/opt/linowriting/` (`deploy:linowriting 2770` setgid,`.env` 单独 600 隔离 secret)
- `Backend/deploy/deploy-hz.sh` rsync + venv + alembic + systemctl reload,实战加固 8 个坑(GNU rsync 强制 / 阿里云 PyPI 镜像 / 跨 user 权限 setgid / pip --no-cache-dir / eval-free / staging 中转去除) [§5.S.5 / S-3]

**iOS 三档响应式(主菜)**
- **WorkspaceView** iPad NavigationSplitView 三栏(sidebar=ChapterList / detail=Editor / inspector=RightPanel) + iPhone NavigationStack + 两 sheet(NavigationStack-wrapped + `.presentationDetents([.large])`) [§5.R.3 / §5.R.4 / R-1]
- **三档断点**:`horizontalSizeClass` 切 iPhone (compact) vs iPad (regular);iPad 内部 `GeometryReader` 检测 portrait/landscape 自动 `.doubleColumn` ↔ `.all`;iPad mini 多窗口 Split View 触发 compact 时切 iPhone 式 UI(预期行为) [§5.R.2 / R-2]
- **触控 affordances + 平台分支**:7 个文件 `#if os(iOS)` 从 stub 补到 production -- FileSaver UIDocumentPicker 真 await + BookCard 长按 ActionSheet + ChapterList swipeActions 删除 + Timeline 长按编辑/删 + SettingsView iOS Form 风格 + ProviderKeyEditSheet NavStack `.large` detents + RightPanelView 隔离巡查 [§5.R.5 / R-3]
- **38 个新 iOS XCTest**(LinoWritingTestsIOS 新 bundle,跑在 iOS Simulator) + `App/README_iOS.md` 7 天 re-sign 自用直装工作流 [§5.R.8 / §5.R.9 / R-4]

**客户端连云**
- **默认 BACKEND_URL** `https://lw.linotsai.top`(可在 Settings 改回 localhost dev) + Keychain per-host 拆分 + 启动 banner 提示填新 token [§5.U.2 / §5.U.3 / U-1]
- **macOS DNS 自检引导**(关键):Settings → Connection 加 NetworkSelfTestSection,`getaddrinfo()` async 检测当前 host IP 是否在 trustedBackendIPs;不命中时红警告 + 一行 sudo `tee /etc/hosts` 命令 + NSPasteboard 一键复制(解作者本机被 WARP/路由器全局劫持到 `198.18.16.246` 的边界 -- /etc/hosts 是 libc 层 override,跟 DNS / WARP 无关) [§5.U / U-1]
- **SSE 长连接 timeout** `timeoutIntervalForRequest=120 / forResource=600`,SSE 独立 URLSessionConfiguration 不再共享 `.shared`;ATS 默认 strict HTTPS-only 不加 exception domains [§5.U.2 / U-2]

### 1.1 v0.7.1 微调(在 v0.7 之上)

- **辅助面板**改用 macOS 14+ 原生 `.inspector(isPresented:)` modifier:
  - 不再是窄屏弹出 sheet,而是真正的右侧滑入栏,可拖动宽度
  - 工具栏图标 `sidebar.right` → `rectangle.righthalf.inset.filled`(Pages/Numbers 同款 inspector 标准符号),与左侧 `sidebar.left` 视觉拉开
  - 跟随窗口宽度自动隐藏/展开,跨阈值时切换,阈值内保留用户手动 toggle
  - `threeColumnLayout` / `twoColumnLayout` / `rightPanelSheet` 三套并行代码合并为单一 `macOSLayout` [§4.3]
- **角色卡删除 `voice`(说话方式)字段**:
  - 前端 `frozenScalarFields` 移除 `voice` 行;后端 Writer prompt 与 context_pack 不再引用
  - Alembic `202605260002_drop_character_frozen_voice` 清掉历史数据 `frozen_fields.voice`
  - 该字段的存在反而引诱 Writer 把"口头禅「啧」"逐字搬到正文,与 §5.L 主菜目标冲突 [§4.3]

### 1.2 v0.7 新增能力(在 v0.6 基础上)

**主菜:角色卡 narrative 通病修复(L)**
- `characters.author_notes JSONB`:作者笔记区(动机/过往伤/秘密),Writer / Expander 看得到但**绝不可 narrate**;Extractor 隔离不看 [§5.L.3 / §5.L.5]
- `structured_prompt.focus_traits: list[str]`(0-2 个):本章重点 emerge 的特质,Expander 推断 + 作者可改;空时 Writer 不刻意 emerge [§5.L.4 / §5.L.5]
- Writer system_prompt 重写:show/tell 反例 few-shot + "角色卡是水库不是必须排空的水桶" + author_notes 纯幕后规则 [§5.L.5]
- context_pack `_recent_summaries` + `_style_samples` 合并为一次 SQL [§5.L.5]
- 前端角色卡分**三区**(冻结 / 活动 / 作者笔记,默认折叠),Step2 加 focus_traits chip 多选 [§5.L.6]

**必修包(系统级 bug 清扫,P 系列 + 后续修订)**
- SSE producer cancel hook:用户取消写作时 cancel_event 透传到 httpx socket close,**关计费泄漏** [§5.P.1 D]
- LLM 上游 4xx body 脱敏:Bearer / sk- / sk-ant- / xai- / AIza 等 6+ 模式 redact + 256 字符截断 [§5.P.1 A]
- ChapterPatch + CharacterPatch 双层白名单字段:schema + router setattr 防 mass-assignment [§5.P.1 F + L-1 reviewer 🟡 #2]
- `POST /chapters/{id}/admin_reset` 端点 + UI 三点菜单"强制重置状态"+ 幂等(同状态 no-op,不写 log) [§5.P.1 E]
- ChapterEditorStore.load 全清 @Published(红点 leak 跨章节修复) [§5.P.1 G]

**控成本(多 LLM per-Agent,M)**
- `provider_keys.agent_role` + `system_settings.active_{writer,extractor,expander}_key_id`:每个 Agent 各自 active key,fallback 通用 [§5.M.2]
- `GET / PUT /api/v1/settings/active_key/{agent_role}` 参数化端点 [§5.M.4]
- LLM factory `build_llm_client(db, agent_role=)`:per-agent dispatch + 三态 fallback [§5.M.5]
- Routers 各 endpoint 注入对应 Agent 的 LLMClient(write→writer, finalize+import→extractor, expand→expander)
- 前端 SettingsView LLM Providers tab 加 per-agent picker + ProviderKeyEditSheet 加"用途"选择(三态 AgentRoleUpdate enum)+ 兼容性 capsule [§5.M.6]

**UX 改善(N + B-fld + C-tl + D-log)**
- 后端错误中文模板 + i18n_conflict / i18n_not_found / i18n_upstream helpers,14 处 raise 中文化(no_active_llm_key 等 sentinel 搬到 `details.code`) [§5.N]
- 前端 ErrorBus 加 30 条 FIFO history + SettingsView 新 tab "最近错误"(时间戳 + level + 完整 message + textSelection) [§5.N]
- 字段级 dot indicator:`character.pending_field_highlights JSONB` + Extractor 写 keys + PATCH live_fields 自动清 + InlineEditableText/Dict/Tags 加 showHighlight [§5.B]
- TimelineEvent 编辑 / 删除:`PATCH/DELETE /api/v1/timeline_events/{id}` + edited_at 字段 + TimelineTabView 双击 inline 编辑 + hover × 删除 [§5.C]
- SettingsView 第 4 tab "Agent 日志":listAgentLogs UI,按 agent_name 过滤 + cursor 分页 + 折叠展开看 input/output preview [§5.D]

**章节生命周期(A 系列扩展 + F + O)**
- 章节/全书导出 markdown / txt:`GET /books/{id}/export?format=` + `GET /chapters/{id}/export`,RFC 5987 中文 filename;Bookshelf 卡 hover 导出 + ChapterToolbar 三点菜单"导出本章"+ macOS NSSavePanel [§5.F]
- 批量章节导入:NewChapterSheet "批量模式" toggle + ChapterSplitter(5 regex 优先级 + minChapters 防误判)+ 串行 createAndImport + 进度 / 失败汇总 sheet [§5.O]

### 1.3 测试基线

- **后端 pytest** SQLite:**222 个**(v0.8 末 200 → v0.9 末 +22 W-1 配对认证:pair_initiate / pair_confirm 三态失败 / device-token 双路径 / revoke / rate limit)`-W error` 干净
- **后端 pytest PG 16**:v0.8 末 199+1 skipped(W-1 新表 PG path 未单独跑,HZ deploy 时 `alembic upgrade head` 一条龙加 device_tokens + pair_codes)
- **macOS XCTest**:**132 个**(v0.8 末 124 → v0.9 末 +8 DevicePairingTests:PairingPayload round-trip / QR / DTO Codable)
- **iOS Simulator XCTest**:**50 个**(v0.8 末 38 → v0.9 末 +12 DevicePairViewModelIOSTests:sanitize / gating / happy / 401 / scan-decode)
- HZ prod smoke:`{"status":"ok","version":"0.9.0"}` ✅
- **X-4 双端分发实跑**:macOS notarytool Accepted + spctl accepted(Notarized Developer ID);iOS altool UPLOAD SUCCEEDED → TestFlight

### 1.4 v0.9 已知残留(留 v0.9.x / v1.0+)

- **TestFlight 新账号 warm-up**:作者 2026-05-28 当天注册付费 Developer + 首个 App/build,TestFlight 后端传播延迟(几小时~24-48h),首个 build "App 不可用"是预期;本地 build 验过 100% 可装(arm64 iphoneos / bundle id 正确 / min iOS 17)。自用可直接 Xcode → Run 装真机(1 年证书)绕开 TestFlight
- **iOS ipOverride inert**(W-3):QR 的 `ip` 字段捕获但不持久化(codebase 无运行时 IP override 机制);真正消费要等 Y(已砍)。作者真机若不撞 DNS 劫持则无需
- **static api_token fallback**:W-1 双路径保留到 v1.0.x;删除时同步删 `Settings.api_token` + conftest `auth_headers` fixture
- **pair_codes 无自动清理**:HZ cron 加 `DELETE FROM pair_codes WHERE expires_at < now()`(backlog)
- v0.8 残留继续推:U-2 ATS simulator 抽验 / R-4 Keychain 真机抽验 / T-1 v1.0 删 Fernet dual-fallback 同步改 fixture / R-2 手动 toggle 冻结状态机
- v0.7 未做项:M-2 灰显视觉 / N 老英文 helper / D-log MockAPIClient 排序 / O batch cancel(留 v1.0+)

### 1.5 v0.7 / v0.8 历史能力(继承)

**v0.8**:PostgreSQL 切换 + HZ 阿里云 ECS 上线(systemd + Nginx + certbot + 现有 PG 16,无 Docker)+ ProviderKey Fernet 加密 + rate limit/HSTS/CORS/access log 脱敏 + iOS 三档响应式(NavSplit iPad / NavStack iPhone + 触控 affordance)+ 客户端连云 + macOS DNS 自检引导 + SSE 长连接调优。详 §1.0.1 / §5.R-U。

### 1.6 v0.5 / v0.6 历史能力(继承)

**v0.5**:书架、3 栏 Workspace、5 步章节编辑器、SSE 流式写作、角色卡 inline 编辑、右栏 4 tab、Keychain;5 张业务表 + 1 张调试表 + 23 个端点、3 个 Agent、Context Pack 装配、Extractor 事务性写入。

**v0.6 新增(已发布)**:响应式三档窗口断点、苹果风美学(Material / `.toolbarRole(.editor)` / `.windowToolbarStyle(.unifiedCompact)`)、全局动画、serif/sans 字体切换、Toast 错误条、Provider Key App 内管理(单 active)、章节"导入文本"入口 [详见 §5.A / §5.E / §5.K]

---

## 2. 项目结构总览

```
LinoWritingV2/
├── PROJECT_PLAN.md            ← 本文档（v0.6+ 单一行动依据）
├── PLAN_FRONTEND.md           ← v0.5 前端契约存档
├── PLAN_BACKEND.md            ← v0.5 后端契约存档
│
├── App/                       ← SwiftUI 前端
│   ├── project.yml            ← xcodegen 配置，版本号在此(0.7)
│   ├── LinoWriting.xcodeproj  ← 生成产物
│   ├── LinoWriting/
│   │   ├── App/               ← @main, AppEnvironment (DI),11 个 Store 注入
│   │   ├── Models/            ← 14 个 Codable DTO(Book/Chapter/Character/TimelineEvent/StructuredPrompt/ProviderKey/AgentLog/ExportFormat 等)
│   │   ├── Services/          ← APIClient(35+ 端点)、SSEClient、Keychain、ErrorMapping、Settings、CodecFactory、ChapterSplitter、FileSaver
│   │   ├── Stores/            ← 11 个 ObservableObject(AppStore/Bookshelf/Book/Characters/Chapters/ChapterEditor/Timeline/ProviderKeys/AgentLog/ErrorBus + 占位)
│   │   ├── Views/             ← Root(Settings 4 tab)/Bookshelf/Workspace/Components
│   │   ├── Platform/          ← #if os(macOS) 隔离
│   │   └── Resources/         ← Assets, AppIcon(v0.5 rounded-i), Localizable.xcstrings
│   ├── LinoWritingTests/      ← XCTest 120 个(v0.7 末)
│   └── README.md
│
└── Backend/                   ← FastAPI 后端
    ├── pyproject.toml         ← 版本号 & 依赖(0.7.0)
    ├── uv.lock                ← uv 依赖锁定(v0.7 新增)
    ├── app/
    │   ├── main.py            ← FastAPI app(版本字符串同步处)
    │   ├── config.py          ← Pydantic Settings
    │   ├── auth.py / errors.py(i18n_*) / db.py
    │   ├── models/            ← 7 张表 SQLAlchemy 模型(books / characters / chapters / timeline_events / agent_logs / provider_keys / system_settings)
    │   ├── schemas/           ← Pydantic DTOs(含 ChapterImport / ProviderKey AgentRole / TimelineEventPatch / ActiveAgentKey 等)
    │   ├── routers/           ← health / books / characters / chapters(含 export+import+admin_reset) / timeline_events / admin(logs) / provider_keys(含 per-agent active)
    │   ├── services/          ← context_pack / chapter_state / extractor_apply / env_provider_migration / exporter
    │   ├── agents/            ← base / prompt_expander / writer / extractor(均带 cancel_event)
    │   └── llm/               ← openai_compatible(单实现) / factory(per-agent dispatch) / base / errors
    ├── alembic/               ← 迁移脚本(v0.5 initial / 0001 provider_keys / 0002 chapter.source / 0001 author_notes / 0002 agent_role+per-agent active / 0003 timeline edited_at / 0001 pending_field_highlights)
    ├── tests/                 ← pytest 175 个(v0.7 末)
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
| **B** | 字段级 dot indicator | ✅ v0.7 | §5.B |
| **C** | TimelineEvent 编辑 | ✅ v0.7 | §5.C |
| **D** | Admin Log Panel UI | ✅ v0.7 | §5.D |
| **E** | 多 LLM Key 管理（OpenAI-compatible 统一协议，App 内管理） | ✅ v0.6 | §5.E |
| **F** | 章节/全书导出（markdown / txt） | ✅ v0.7 | §5.F |
| **J** | 全文搜索 | 🔵 待讨论（推 v0.8+） | — |
| **K** | 响应式布局 + 苹果风美学升级 | ✅ v0.6 | §5.K |
| **L** | 角色卡 narrative 通病修复（分层 + 本章重点 + Writer prompt 改造） | ✅ v0.7 **主菜** | §5.L |
| **M** | 多 LLM per-Agent 选择（Writer→Claude / Extractor→Grok 等） | ✅ v0.7 | §5.M |
| **N** | 错误中文模板 + ErrorBus history | ✅ v0.7 | §5.N |
| **O** | 批量章节导入 | ✅ v0.7 | §5.O |
| **P** | v0.7 急修包（SSE cancel / admin reset / Store reset / PATCH 白名单 / 4xx 脱敏） | ✅ v0.7 | §5.P |
| **Q** | 文档同步（PROJECT_PLAN §2 + README 漂移修复） | ✅ v0.7 | §5.Q |
| **R** | iOS 三档响应式 + 触控适配（K 的 iOS 版） | ✅ v0.8 **主菜** | §5.R |
| **S** | 后端 PostgreSQL 切换 + HZ 阿里云 ECS 部署（systemd + Nginx + 现有 PG 16） | ✅ v0.8 **必修** | §5.S |
| **T** | 安全硬化（ProviderKey 加密 / rate limit / HTTPS / secret manager） | ✅ v0.8 **必修** | §5.T |
| **U** | 客户端 → 云后端切换（BACKEND_URL / ATS / SSE 长连接调优 / DNS 自检引导） | ✅ v0.8 | §5.U |
| **V** | iOS Provisioning + TestFlight 上架（v0.9 并入 X 重启） | ✅ v0.9（并入 X） | §5.X |
| **W** | 设备配对认证（device_tokens 表 + QR + 6 位短码，双端首次启动免手填 token） | ✅ v0.9 **主菜** | §5.W |
| **X** | TestFlight + macOS Developer ID + notarize 自动化 | ✅ v0.9 **必修** | §5.X |
| **Y** | iOS DNS override / TLS SNI override | ⚫ 不做（作者拍板，真机未撞 DNS 劫持） | §5.Y |
| **AA** | App Intents / Siri Shortcuts | ⚫ 不做（作者拍板） | §5.AA |
| **BB** | Foundation Models 端侧 LLM 接管 Extractor | ⚫ 不做（作者拍板） | §5.BB |
| **CC** | Keychain 数据保护迁移（macOS 登录零弹窗，付费 Developer entitlement） | 🎯 v0.9.1 **主菜** | §5.CC |
| **DI** | 导入/提取解耦（导入只落正文→finalized；提取改手动 `/extract` 端点 + 工具栏按钮）+ 导入 sheet 布局急修 | 🚧 v0.9.3 **进行中** | §5.DI |

剔除项（不进路线图）：
- ⚫ G. 卷/章节分组
- ⚫ H. 写作统计面板
- ⚫ I. 章节历史版本/diff
- ~~⚫ V. TestFlight 上架~~ → **v0.9 重新启用**：作者付费 Developer Program 后，§5.X 接手 TestFlight + Developer ID + notarize 自动化
- ⚫ 多租户 / 多用户（作者自用永久 out of scope，单用户认证即可；W 引入 device-token 也是 per-device 不是 per-tenant）

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

### 4.3 v0.7.1 — ✅ 已发布

**目标**:v0.7 发布后用户试用马上反馈两个体验问题,做最小 patch release。

**清单**:
```
🪟 UI 收纸
[x] 辅助面板改 macOS 14+ 原生 .inspector(isPresented:) — 真正的右侧滑入栏,
    可拖宽度,工具栏图标换成 rectangle.righthalf.inset.filled(Pages/Numbers
    标准 inspector 符号),三套并行布局代码(three/two column + sheet)合并
    为单一 macOSLayout。跨 wideBreakpoint 自动 toggle,阈值内保留手动状态。

📋 角色卡精简
[x] 删除 frozen 区 voice("说话方式")字段 — 字段名直接邀请 Writer 把
    "口头禅「啧」"原样塞进正文,与 §5.L 主菜"角色卡是水库不是水桶"反向。
    前端 frozenScalarFields 删行 + 后端 writer.py / context_pack.py 去引用 +
    Alembic 202605260002 scrub frozen_fields.voice + 测试 fixture 替换为
    background。
```

**Phase 排序**(两条全独立):

| 序号 | Phase | 内容 | 测试基线 |
|---|---|---|---|
| 1 | **A-voice** | 删 voice 字段 + 数据迁移 + writer prompt / context_pack 去引用 + 测试 fixture | pytest 175 ✅ |
| 2 | **B-inspector** | macOS WorkspaceView 改 `.inspector` + 图标换 `rectangle.righthalf.inset.filled` + 合并 layout 分支 | XCTest 120 ✅ + macOS/iOS build clean |

**实际 commit**:
- `<this commit>` v0.7.1 inspector + drop voice field

**发版同步**:5 处版本号 `0.7.0 → 0.7.1` + LinoI.app v0.7.1 重新打包(ad-hoc 签名)。

---

### 4.2 v0.7 — ✅ 已发布

**目标**：试运营深化版。修掉 v0.6 试运营暴露的安全/计费/UX 系统性短板，解决最大的内容质量痛点（Writer 把角色卡当 narrate 检查表），并清掉 v0.5/v0.6 残留 todo 让 v0.7 收尾后能进入"打磨期"。**目标达成**。

**实际 commit 时间线**:
- `4b69bfa` Phase P-1+P-3 后端急修包(SSE cancel / 4xx 脱敏 / PATCH 白名单 / admin_reset)
- `53af6f8` Phase L-1 后端 character.author_notes + structured_prompt.focus_traits
- `5e12d40` Phase P-2 前端 ChapterEditorStore reset 加固 + admin_reset UI
- `80b5129` Phase L-2 后端 Expander/Writer prompt 改造 + context_pack 合并查询
- `5127460` Phase L-3 前端角色卡三区 + focus_traits chip
- `d4eef00` Phase M-1 后端 provider_keys.agent_role + per-Agent factory
- `a8a2a91` Phase M-2 + C-tl 前端 per-Agent picker + TimelineEvent 编辑/删除
- `a934732` Phase N + B-fld 错误中文模板 + ErrorBus history + 字段级 dot
- `e5bf01f` Phase F + O markdown/txt 导出 + 批量章节导入
- `b1c096e` Phase D-log Admin Log Panel UI
- `<this commit>` Phase Q v0.7 发版同步 + LinoI.app 重新打包

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

### 4.4 v0.8 — ✅ 已发布

**实际 commit 时间线**(2026-05-26 发版):
- `54a354f` Phase S-1 本地 PG 16 dialect 验证 + 2 dialect bug fix
- `445a548` Phase T-1 ProviderKey Fernet 加密 + KEK + Alembic data migration
- `1c97f75` Phase S-2 HZ 部署三件套草稿 (systemd + Nginx + deploy-hz.sh)
- `e6af8bc` Phase T-2 rate limit + HSTS + security headers + access log 脱敏
- `a99087d` Phase R-1 iOS WorkspaceView 重写 (NavSplit iPad / NavStack iPhone)
- `07a337f` Phase R-2 iOS 三档响应式 (size class + 方向检测)
- `1df4937` Phase R-3 iOS 触控 affordances + 平台分支补齐
- `744992a` Phase S-3 HZ 首次上线完成 + deploy-hz.sh 实战加固
- `b5e9ae0` Phase U-1 LinoI 默认 URL 切 lw.linotsai.top + macOS DNS 自检引导
- `3ff1eca` Phase U-2 SSE 长连接 timeout 调优 + ATS 默认 HTTPS-only 确认
- `8b02c95` Phase R-4 iOS XCTest 矩阵 (38 tests) + 7 天 re-sign 自用直装文档
- `<this commit>` Phase Z 发版同步 + LinoI.app v0.8 重新打包 + 清理中间产物

**目标达成**:iOS UI 全套打通(iPhone NavStack + iPad NavSplit + 触控 affordance) + 后端从单机 SQLite 上线到 HZ 阿里云 ECS HTTPS 服务 + ProviderKey 加密 + rate limit + 全套客户端连云能力(含 DNS 拦截 macOS 自检引导)。



**目标**:把 LinoWriting 从"单机 macOS 试运营"升级为"iOS + 云后端"双形态。用户原话:**"我准备做 iOS + 把后端搬到云上;这也是 v0.8 的目标"**。

v0.6 / v0.7 都是 macOS 单机 + 本地 backend,iOS 在 Simulator 能编过但 UI 大量是 stub,backend 在 `lino_writing.db` SQLite 文件里只能服务一个人。v0.8 要交付的是:**iPhone / iPad 能像 macOS app 一样写作 + LinoI 启动直接连上 HTTPS 云后端 + ProviderKey 不再裸奔**。多租户 / Web 客户端 / 付费墙留 v0.9+。

**清单**:

```
🔴 必修(云上线前不做就出事)
[ ] S — 后端 PostgreSQL 切换 + 容器化(§5.S)
[ ] T — 安全硬化:ProviderKey 加密 + rate limit + HTTPS + secret manager(§5.T)

🥇 主菜
[ ] R — iOS 三档响应式 + 触控适配 + 免费 Apple Dev 自用安装工作流(§5.R)
[ ] U — 客户端 → 云后端切换(BACKEND_URL / ATS / SSE 长连接调优,§5.U)

🧹 v0.7 旧债清算
[ ] 老英文 errors helper(conflict / not_found / upstream)收回 — N 计划内未做
[ ] M-2 灰显视觉(per-Agent picker 选项级 disable)
[ ] F iOS UIDocumentPicker 真正 await(目前 stub)— 并入 R
[ ] O 批量导入 cancel 按钮 + failure skeleton 文档化
[ ] D-log MockAPIClient 排序 / infinite-scroll 防抖 / setFilter 竞态
```

**Phase 排序**(12 个 Phase,按依赖+并行机会排):

| 序号 | Phase | 内容 | 类型 | 依赖 | 可并行 |
|---|---|---|---|---|---|
| 1 | **S-1** PG dialect 验证(dev) | 本地 `docker run -d -p 5432:5432 postgres:16` 起一个 PG 容器(纯 dev 工具,不进 prod 栈)+ `DATABASE_URL=postgresql+psycopg://... alembic upgrade head` 一次性跑通 9 条迁移 + `DATABASE_URL=... pytest -W error` 175 全过 + 抓任何 SQLite-only 查询/写法的 bug。**`config.py` default 保持 SQLite**(详 §5.S.2);prod 由 systemd EnvironmentFile 注入 PG URL | 后端 | — | ✅ 与 R-1 并行 |
| 2 | **T-1** ProviderKey 加密 | `ProviderKey.api_key` Fernet 加密 + KEK 从环境读 + Alembic data migration 把现有明文加密回写 + 兼容老明文行(read-side dual,写一律加密) | 后端 | S-1 | — |
| 3 | **T-2** Rate limit + 脱敏强化 | `slowapi` 或自写 in-memory middleware(per-token + per-endpoint 写限速,防 LLM key 烧钱)+ access log 脱敏 + HSTS header + CORS 收窄 | 后端 | T-1 | ✅ 与 S-2 并行 |
| 4 | **S-2** HZ 部署三件套草稿 | 写 `linowriting-api.service` systemd unit + Nginx site `linowriting` + `Backend/deploy/deploy-hz.sh` 脚本(rsync + alembic + systemctl reload);本地 dry-run 不实际推 HZ | 后端 | S-1 | ✅ 与 T-2 并行 |
| 5 | **S-3** HZ 首次上线 | SSH 进 HZ:创建 `linowriting` 用户 + PG DB/role + DNS A 记录 + certbot 签证 + `.env`(600)+ systemd enable + Nginx reload + 从作者 mac 跑 deploy-hz.sh + production smoke test(`https://<sub>.linotsai.top/api/v1/health` + write 端到端 + 邻居 100j/lf 不受影响) | 部署 | S-2 + T-1 + T-2 | — |
| 6 | **R-1** iOS WorkspaceView 重写 | iPad 用 `NavigationSplitView(sidebar=ChapterList, detail=Editor, inspector=RightPanel)`;iPhone 用 `NavigationStack` + 两 sheet(章节列表 + 右栏);删除现 `iOSLayout` 的"右上角弹 sheet"过渡实现 | 前端 | — | ✅ 与 S 系列并行 |
| 7 | **R-2** iOS 三档响应式 | iPhone (compact width) / iPad portrait / iPad landscape 三档断点(`horizontalSizeClass` + `verticalSizeClass`);列宽 / inspector 默认可见性 / sheet vs split 切换 | 前端 | R-1 | — |
| 8 | **R-3** iOS 触控 affordances + 平台分支补齐 | 长按代替 hover、swipe 代替 `.contextMenu`、`.topBarLeading/.topBarTrailing/.bottomBar` 全梳理 + FileSaver / BookCardView / ChapterListView / TimelineTabView / SettingsView / ProviderKeyEditSheet 的 `#if os(iOS)` 分支全部从 stub 补到 production | 前端 | R-1 + R-2 | — |
| 9 | **R-4** iOS XCTest 矩阵 + 自用直装工作流 | XCTest 在 iPhone 14 / iPad Pro 11" simulator 双跑;现有 120 个 baseline 维持,新增至少 20 个 iOS 路径覆盖(NavigationSplitView 切栏、sheet 唤起、UIDocumentPicker mock);README 写 7 天 re-sign 工作流(详 §5.R.9) | 前端 | R-3 | — |
| 10 | **U-1** BACKEND_URL 生产默认 + Settings | LinoI 启动首屏 / `SettingsView` Connection tab:默认 URL 从 `http://localhost:8787` 换成 `https://<prod-domain>` + 可改输入框 + Keychain 旧 localhost 数据迁移策略(留 vs 清,详见 §5.U.3) | 全栈 | S-3 | — |
| 11 | **U-2** SSE 长连接调优 + ATS | systemd unit `ExecStart=` 加 `--timeout-keep-alive 75`(§5.S.3 已写入)+ Nginx site `proxy_buffering off` + `proxy_read_timeout 120s`(§5.S.3 已写入)+ iOS Info.plist `NSAppTransportSecurity` 不显式 disable(默认仅 HTTPS)+ 真机 SSE write 流连续 1 分钟不断 | 全栈 | U-1 + S-3 | — |
| 12 | **Z** 文档同步 + v0.8 发版 | PROJECT_PLAN §1 / §2 / §3 更新 + App/Backend README + 5 处版本号 → 0.8.0 + LinoI v0.8 打包 + 云部署 cutover 步骤 | 全栈 | 全部完成 | — |

**关键约束**(依赖顺序的物理原因):
- **S-3 必须先于一切 R 真机测试**:iPhone / iPad 真机连不上 `localhost`(只有 Simulator 同机才行)。R 阶段开发期可用 Simulator + localhost,但**真机验收**必须先有 S-3 上线的云域名,否则 R-4 / U-2 走不通。
- **T-1 必须先于 S-3**:云上 ProviderKey 明文存 Postgres 等于把 OpenAI/xAI/Anthropic 的钱包贴公网。任何 secret leak 都会立刻烧钱。
- **T-2 必须先于 S-3**:无 rate limit 上公网 + 单租户静态 token = 任何泄漏的 token 都是无限刷 LLM 的肉鸡。
- **S-2 与 T-2 可并行**:systemd unit / Nginx site / deploy 脚本草稿 与后端 middleware 添加正交,改的文件不冲突。
- **R-1 与 S 系列可并行**:iOS UI 重写不碰后端契约,Simulator + localhost backend 全程可开发。
- **U 系列必须等 S-3**:客户端切生产域名前,生产域名必须先 up。
- **V 已剔除**(2026-05-26 用户拍板):作者自用 + 免费 Apple Developer 账号,Xcode → device 直装 + 7 天 re-sign 工作流即可,无需 TestFlight。详 §5.R.9 / §5.V。

**发版同步清单**(v0.8 收尾用):
- 前端 `App/project.yml` 的 `MARKETING_VERSION` → `0.8`
- 后端 `Backend/pyproject.toml` + `Backend/app/main.py` + `Backend/app/routers/health.py` + `Backend/tests/test_auth.py` → `0.8.0`
- 本文档 §7 变更日志加新条目
- git commit 标 `v0.8: iOS + HZ cloud backend`
- **LinoI macOS 打包**:仍 ad-hoc(单机自用)`codesign --force --deep --sign -` + 部署 `~/Desktop/LinoI.app`(沿用 v0.7/v0.7.1 流程)
- **LinoI iOS 打包**:Xcode → device 直装(详 §5.R.9 自用直装工作流),不走 TestFlight
- **HZ 部署 cutover**(详 §5.S.5 runbook):首次部署一次性配置 + 日常发版 `./Backend/deploy/deploy-hz.sh`
- **域名最终拍板**:`lw.linotsai.top` vs `lino.linotsai.top` vs `linowriting.linotsai.top`(S-3 启动前必须先定)
- 老本地 `lino_writing.db` 留作者本机不删,作 dev 沿用

**范围控制**(明确**不**在 v0.8 内):

🚫 永久 out of scope(作者自用项目,不进任何路线图):
- ❌ **多租户 / 多用户**(JWT、user_id 列、tenant scoping)— 单用户静态 Bearer 永远够用;§5.T.4 的 AuthContext plumbing **已撤销**,保持当前 `require_bearer_token` 简洁
- ❌ **TestFlight / Apple Developer Program 付费版** — 免费 Dev 账号 + Xcode→device 直装 + 每周 re-sign,详 §5.R.9

⏳ 推 v0.9+(看后续优先级):
- ❌ Web 客户端(浏览器写作 UI)
- ❌ 付费墙 / billing / 计量(无意义,自用)
- ❌ Anthropic 原生 API 适配(OpenRouter 路径已够)
- ❌ Android 客户端
- ❌ 离线模式(iOS 无网时本地缓存写作)
- ❌ 章节实时协作(WebSocket)

---

### 4.5 v0.9 — ✅ 已发布(v1 之前最后一个大版本)

**实际 commit 时间线**(2026-05-28 发版):
- `9d9be32` PROJECT_PLAN v0.9 plan 锁定
- `9efb2e6` Phase X-1 project.yml 切 Automatic signing + Team ID
- `f15159e` Phase W-1 后端 device_tokens 配对认证
- `ba35963` Phase W-2 macOS 设备管理 UI + QR 生成 + APIClient auth 方法
- `5617942` Phase X-2 scripts/release-macos.sh (Developer ID 真签 + notarize)
- `bddc485` Phase X-3 scripts/release-ios.sh + ios-export.plist (TestFlight)
- `1d5fe80` Phase W-3 iOS 启动配对屏 + 扫码(W 系列收口)
- `80a8cdb` X-4 实战修正:release-ios.sh altool → App Store Connect API key
- `<this commit>` Phase Z v0.9 发版同步 + Info.plist 免合规 + HZ deploy + 双端重打包

**目标达成**:双端登录体验从"SSH grep .env 手填 token"升级为"老设备出二维码 / 新设备扫码即用"(device_tokens + pair_codes + 4 端点 + macOS QR 生成 + iOS 扫码屏)。付费 Apple Developer 后 iOS 7 天证书 → 1 年 + TestFlight OTA + macOS Developer ID notarize 全套自动化脚本就位并 X-4 实跑验证。Y/AA/BB 候选作者拍板不做。

**X-4 实战教训(已固化进脚本 + §5.X)**:Xcode 26.5 的 altool 在两处偏离文档 ——(1) `--store-password-in-keychain-item` 要显式 `--item` flag;(2) 即便存进 keychain,`@keychain:` 查找因 svce=NULL 失败。最终弃用 app-specific-password keychain 路径,改 App Store Connect API key(`--apiKey`/`--apiIssuer` + `.p8`),Apple 现代推荐且 notarytool 可复用。macOS notarytool 路径(`LinoI-deploy` profile)本身没问题,轨道 A 一次过。

---

### 4.5-archived v0.9 — 原 🚧 进行中段(发版后归档)

**目标**:把双端登录体验做好。作者原话:**"v1 上线前的最后一个大版本,目标:把双端的登录体验都做好,现在其实不太舒服,而我整好 developer 之后,应该舒服多了"**。

v0.7 / v0.8 把功能 / 后端 / iOS UI 全跑通了,但**首次启动 + 凭据流**对作者本人都不太舒服:每个新设备启动都要(1)知道 BACKEND_URL (2)SSH HZ + sudo grep `.env` 拿 token (3)复制到 LinoI Settings (4)触发 keychain。iOS 真机第一次装尤其麻烦。v0.9 主菜就是把这条流改成"老设备显示二维码,新设备扫码即用"。

同时作者付费 Apple Developer Program 后,V phase(原 v0.8 剔除)重新启用,iOS 7 天 re-sign 痛点消失 + TestFlight OTA + macOS Developer ID 真签 + notarize 全套到位。

**清单**:

```
🥇 主菜(v1 之前必须)
[ ] W — 设备配对认证(device_tokens 表 + QR + 6 位短码,§5.W)
[ ] X — TestFlight + macOS Developer ID + notarize 全自动化(§5.X,原 §5.V 重启)

🟢 扩展(看作者付费后实际体验决定)
[ ] Y — iOS DNS / TLS SNI override(仅 iPhone 真机撞 DNS 拦截才入,§5.Y)
[ ] AA — App Intents / Siri Shortcuts(§5.AA)
[ ] BB — Foundation Models 端侧 LLM 接管 Extractor(§5.BB,降云 LLM 账单)

📚 收尾
[ ] Z — 文档同步 + v0.9 发版 + LinoI macOS/iOS 双端上 TestFlight 第一笔
```

**Phase 排序**(预计 8-10 个 Phase,按依赖+并行排):

| 序号 | Phase | 内容 | 类型 | 依赖 | 可并行 |
|---|---|---|---|---|---|
| 1 | **W-1** device_tokens 后端 | `device_tokens` 表(id / device_name / token_ciphertext / created_at / last_used_at / revoked_at)+ Alembic 迁移 + `auth.py` 双路径(device-token first, static api_token fallback) + 端点 `POST /auth/pair_initiate` `POST /auth/pair_confirm` `GET /auth/devices` `DELETE /auth/devices/{id}` + 配对码 6 位数字 10 分钟 TTL | 后端 | — | ✅ 与 X-1 并行 |
| 2 | **X-1** Signing 切 Automatic | `project.yml`:iOS `CODE_SIGN_STYLE: Automatic` + `DEVELOPMENT_TEAM=<Team ID>`,macOS 加 Developer ID Application 路径(保留 ad-hoc dev path)。Apple ID + App-Specific Password keychain 配置。**作者拿到 Apple Team ID 才能动** | 配置 | 作者付费 + Team ID | — |
| 3 | **W-2** macOS Settings → 添加设备 | Settings → Connection 加 "设备管理" 子区域:列出当前 device tokens(name / 创建时间 / 上次使用)+ "添加新设备" 按钮 → 显示 QR code(编码 BACKEND_URL + pair_code + optional IP override)+ 6 位短码备选 + 倒计时(10 分钟)+ "撤销设备" 按钮 per row | 前端 macOS | W-1 | ✅ 与 W-3 并行 |
| 4 | **W-3** iOS 启动配对屏 + 扫码 | iOS 首次启动(无任何 device token)显示"扫码配对"屏 → `AVCaptureSession` 扫 QR → 解析 BACKEND_URL + pair_code → 调 `/auth/pair_confirm` → 写 Keychain → ready;**手输 6 位短码** 备选(扫码不行时) | 前端 iOS | W-1 | ✅ 与 W-2 并行 |
| 5 | **X-2** macOS Developer ID 真签 + notarize 脚本 | `scripts/release-macos.sh`:Release build → `codesign --sign "Developer ID Application: <作者名>"` → `xcrun notarytool submit --apple-id ... --team-id ... --wait` → `xcrun stapler staple` → 部署 `~/Desktop/LinoI.app`(取代 v0.8 的 ad-hoc 签名) | 配置/脚本 | X-1 | ✅ 与 X-3 并行 |
| 6 | **X-3** iOS TestFlight archive + 上传脚本 | `scripts/release-ios.sh`:`xcodebuild -archivePath ... archive` → `xcodebuild -exportArchive -exportOptionsPlist ios-export.plist` → `xcrun altool --upload-app -f LinoI.ipa --apple-id ... --apple-id-password ...` → TestFlight processing 后 internal tester 收到 OTA | 配置/脚本 | X-1 | ✅ 与 X-2 并行 |
| 7 | **Y**(可选)| iOS DNS override / TLS SNI override:LinoI Settings 加 "服务器 IP override" 可选字段;NWConnection-based HTTPS client(自管 TLS SNI = `lw.linotsai.top` + cert verify)。**仅作者 iPhone 真机第一次连 lw.linotsai.top 撞 DNS 拦截才入** | 前端 iOS | W-3(扫码携带 IP override) | — |
| 8 | **AA**(可选)| App Intents:3 个意图(开始写下一章 / 今天写了多少字 / 继续上次章节)注册到 Shortcuts.app + Siri | 前端 iOS | X-1 | ✅ 与 BB 并行 |
| 9 | **BB**(可选)| Foundation Models 端侧 LLM:iOS deployment target 18.1+;前端在 finalize 后用 `FoundationModels` framework 跑章节摘要(取代云 Extractor 摘要部分);keep timeline_events / character_updates 仍走云 Extractor;监控 LLM 月账单变化看是否值得 | 前端 iOS | X-1 + iOS 18.1+ target | ✅ 与 AA 并行 |
| 10 | **Z** 文档 + 发版 | PROJECT_PLAN §1 / §3 / §4.5 / §7 更新 + App/Backend README + 5 处版本号 → 0.9.0 + LinoI macOS Developer ID 真签 + 部署 Desktop + iOS TestFlight 上传 + `hz_info.md` 同步 | 全栈 | 全部完成 | — |

**关键约束**:
- **X-1 必须等作者付费 Developer Program 注册完 + 拿到 Team ID** —— 这是物理依赖
- **W-1 后端可在 X-1 之前并行** —— device_tokens 表与 Signing 无关
- **W-3 iOS 扫码屏在 Simulator 跑不了**(无真相机) → 测试用手输 6 位码路径 + 真机 OTA 后扫码 verify
- **X-3 首次 TestFlight 上传** Apple processing 1-2 天;processing 期间 internal testers 收不到 OTA。**作者本人也算 internal tester**(配自己 Apple ID 即可)
- **Y 强烈建议先观望**:作者付费 + iOS 真机走 TestFlight 后,网络环境跟开发机不一样(蜂窝 / 公司 Wi-Fi),DNS 拦截不一定撞。撞了再入 Y 不晚
- **BB 是最大 ROI 但工作量也最大**:Foundation Models 跑端侧,iOS 18.1+ 才有(macOS 15.x 等价 framework 待验证)。先要把 iOS deployment target 从 17 升 18.1。**等 W + X 落地后再评估**

**作者付费 Developer 后需提供给 builder 的 5 个值**(X-1 启动前必收齐):

1. **Apple Team ID**(10 位字母数字大写)
   - 拿法:登录 https://developer.apple.com/ → Membership → Team ID
   - 用途:`project.yml` `DEVELOPMENT_TEAM=<值>` + notarytool / altool 命令行
   - 敏感度:**不是 secret**,可以入 git;但散在 project.yml 里有点丑,可外置 `App/dev.xcconfig`(gitignore)
2. **Apple ID 邮箱**(作者 Apple 账号登录邮箱)
   - 用途:altool / notarytool `--apple-id <邮箱>`
   - 敏感度:不是 secret 但属个人隐私,**只放本地 `~/.netrc` 或 keychain**,**不入 git**
3. **App-Specific Password**(给 altool / notarytool 用,**不是** Apple ID 真密码)
   - 拿法:登录 https://appleid.apple.com/ → Sign-In and Security → App-Specific Passwords → Generate(给一个标识如 "LinoI deploy" 命名)
   - 16 位 `xxxx-xxxx-xxxx-xxxx` 格式
   - **敏感度:secret**,**绝不入 git**。放本机 Keychain (`xcrun notarytool store-credentials` 帮你存)或 `~/.netrc` 600 perms
4. **bundle ID 决策**(open question)
   - 推荐:**沿用 `com.lino.linowriting.LinoWriting`** 与 v0.8 ad-hoc 一致 → Keychain item 连续,旧 token / 设置不丢
   - 风险:此 ID 是 Apple 全球唯一,作者注册时若发现已被占用,需换。**X-1 第一步:登录 App Store Connect → Identifiers → 试注册此 ID** 看是否能拿到
5. **Apple Developer Program 入会确认 + iOS 真机 UDID**(若 X-4 archive 直装到自己 iPhone 调试)
   - UDID 拿法:iPhone 连 mac → Finder 侧栏点 iPhone → 点设备名下方信息 → UDID 自动显示 → Cmd+C 复制
   - **入 Apple Provisioning Profile 名单后才能 archive 给自己设备装**(TestFlight 路径不要 UDID,因为 internal testers 走的是 TF beta,不是 enterprise/ad-hoc profile)

**范围控制**(明确**不**在 v0.9 内,推 v1.0+):
- ❌ 多租户 / JWT / OAuth flow(单用户自用永久 out)
- ❌ Sign in with Apple(等价于多租户,作者不需要)
- ❌ CloudKit 数据同步(HZ backend 已经是 central authority)
- ❌ APNs Push 通知(写作流程不主动推)
- ❌ Universal Links(无 web 客户端)
- ❌ 真正的 App Store 公开发布(自用,TestFlight internal 即可)

**发版同步清单**(v0.9 收尾用):
- 前端 `App/project.yml` `MARKETING_VERSION` → `0.9`
- 后端 `Backend/pyproject.toml` + `app/main.py` + `routers/health.py` + `tests/test_auth.py` → `0.9.0`
- 本文档 §7 变更日志加 [2026-??-??] v0.9 发版 entry
- git commit 标 `v0.9: device pairing + TestFlight + Developer ID`
- **LinoI macOS 打包**:走 X-2 的 Developer ID Application 真签 + notarize + 部署 `~/Desktop/LinoI.app`(取代 v0.8 ad-hoc)
- **LinoI iOS 打包**:走 X-3 archive + altool 上 TestFlight,internal testers(作者本人)收到 OTA;**告别 7 天 re-sign**
- **HZ 部署**:`./Backend/deploy/deploy-hz.sh` 推 0.9.0,`hz_info.md` 同步 device_tokens 新表 + 任何新增端点

---

### 4.6 v0.9.1 — ✅ 已发布(Keychain 零弹窗登录)

**实际 commit**:`<this commit>` v0.9.1: Keychain 数据保护迁移(macOS 登录零弹窗)。

**目标达成**:macOS LinoI 登录"输两次密码"根治。切数据保护 keychain(entitlement 门控,非交互弹窗)。X-4 验证:**keychain-access-groups entitlement 熬过 Developer ID 重签 + notarize Accepted**,Desktop 0.9.1 已部署。

**Z' 实战教训(已固化进 release-macos.sh + §5.CC.4)**:加 entitlement 后第一次 notarize **被拒**(`status: Invalid`,`com.apple.security.get-task-allow` critical error)。根因:X-1 切 Automatic 后 Release build 用 "Apple Development" cert 签,自带 debug 用的 `get-task-allow=true`;v0.9.1 前 release-macos.sh 重签**不带 `--entitlements` 全剥**所以连 get-task-allow 一起没了 → notarize 过;现在为保 keychain-access-groups 而保留 entitlement,把 get-task-allow 也带上了 → 被拒。修:提取 entitlement 后 `PlistBuddy -c "Delete :com.apple.security.get-task-allow"` 精确剥掉,只留分发安全的 keychain-access-groups / application-identifier。

---

### 4.6-archived v0.9.1 — 原 🚧 段(发版后归档)

**目标**:彻底干掉 macOS LinoI 登录时"输两次密码"的恶心体验。作者原话:**"我付费 Developer 有一个目的,就是要彻底解决这个登录的那么恶心的一个情况"**。

**根因**(读 `KeychainStore.swift` 确诊):
1. 当前 SecItem 查询用**文件型 login keychain**(无 `kSecUseDataProtectionKeychain`)→ macOS **交互式 ACL 弹窗**(输登录密码授权)
2. 存两个 item(`api_base_url` + `api_token.<host>`)→ 启动读两个 → **两次弹窗**
3. v0.9 之前 ad-hoc 签名:每次 rebuild 签名变 → macOS 当"新 app" → "始终允许"永不生效,每次都问

**解法**(付费 Developer 后才能做):切**数据保护 keychain**(data protection keychain,iOS 那套),访问由 `keychain-access-groups` entitlement **门控而非交互弹窗** → macOS 零弹窗,与 iOS 行为统一。详 §5.CC。

**清单**:
```
🥇 主菜
[ ] CC — Keychain 数据保护迁移(entitlement + kSecUseDataProtectionKeychain + 一次性迁移,§5.CC)

📚 收尾
[ ] Z' — 版本号 → 0.9.1 + release-macos.sh 保留 entitlement 重 notarize + 双端重打包
```

**Phase 排序**:

| 序号 | Phase | 内容 | 类型 | 依赖 |
|---|---|---|---|---|
| 1 | **CC-1** | 新 `LinoWriting.entitlements`(`keychain-access-groups = $(AppIdentifierPrefix)com.lino.linowriting.LinoWriting`)+ `project.yml` `CODE_SIGN_ENTITLEMENTS` + `KeychainStore` 所有查询加 `kSecUseDataProtectionKeychain: true` + `kSecAttrAccessGroup` + 一次性 `migrateFromLegacyKeychainIfNeeded()`(读老文件型 item → 写数据保护 → 删老) | 前端 | — |
| 2 | **Z'** | `release-macos.sh` codesign 加 `--entitlements`(`--force` 默认剥 entitlement,要从 Xcode 产物 `codesign -d --entitlements` 抽出再重签)+ 5 处版本号 → 0.9.1 + macOS 重 notarize + iOS 重上 TestFlight + 文档同步 | 全栈/部署 | CC-1 |

**关键约束 / 风险**:
- **release-macos.sh `--force` 重签会剥 entitlement** —— 必须 `codesign -d --entitlements :- <xcode 产物>` 抽出已签的 entitlement,重签时 `--entitlements <抽出文件>` 带上,否则数据保护 keychain 访问失败(entitlement 没了)
- **macOS Developer ID(无 provisioning profile)+ keychain-access-groups**:access group 用 Team ID 前缀(`HX73DFL88G.com.lino.linowriting.LinoWriting`,`$(AppIdentifierPrefix)` 解析为 `<TeamID>.`)。macOS 10.15+ 支持 Developer ID app 用数据保护 keychain
- **迁移弹窗**:首次启动 0.9.1 从老 login keychain 读 token 那一下,可能弹**最后一次**(因为老 item 还在文件型 keychain,ACL 交互);读到后写进数据保护 keychain,之后永远零弹窗。若读不到(老 item 被点过"拒绝")则走 banner 让作者重填一次
- **数据丢失风险**:迁移只读不删原 item 直到确认新写成功;失败保留老 item + ErrorBus 提示
- **iOS 侧**:iOS 本来就是数据保护 keychain(无文件型),改动对 iOS 是 no-op 行为(加 access group 后仍正常),但 entitlement 要确保 iOS Automatic signing 也带上

**发版同步**:5 处版本号 → 0.9.1 + LinoI macOS notarized 重打包 + iOS TestFlight 重传 + `hz_info.md`(后端无变化,backend 不用重 deploy —— **CC 纯前端 Keychain,后端零改动**)。

**范围控制**:v0.9.1 只做 Keychain 零弹窗,不碰别的。

---

### 4.6 v0.9.3 — 🚧 进行中（导入/提取解耦 + 导入 sheet 布局急修）

**触发**：作者试用反馈两个 bug。
1. **导入按钮被裁切**：新建章节 sheet 切到「导入」模式后，底部「取消 / 导入」整行被挤出 sheet 可视区。根因：`NewChapterSheet` body 是普通 `VStack`，frame 只设 `minHeight/idealHeight`、**无 maxHeight**，而「正文」`TextEditor` 是 `maxHeight:.infinity`（贪婪占高）；macOS 的 sheet 高度**不能超过父窗口**（K-1 最小窗口 880×580），字段总高 > 窗口可视高时 footer 被裁到底边外。
2. **导入后被晾在空白草稿 SOP、正文丢失**：`NewChapterSheet` 导入走「① 先建空骨架章节（`user_prompt=""`，立刻选中+载入编辑器）→ ② 调 `/import`」两步，且 `/import` 默认 `run_extractor=true` 会跑 ExtractorAgent→LLM。LLM 一旦失败，后端 `db.rollback()` 把第②步刚写的 `draft_text` 一起回滚 → 正文没保存，只剩第①步那个空骨架章节载入编辑器 = 作者看到的「跳到新建 SOP 起点」。

**作者拍板的目标流**：**导入 = 先把正文完整落地成 `finalized` 章节（不依赖 LLM，永远成功）；提取角色/时间线 = 之后作者手点工具栏按钮再单独跑。** 把「导入」与「提取」彻底解耦。详案见 §5.DI。

**Phase 排序**（4 个 Phase，契约已在 §5.DI 定死，DI-1/DI-2/DI-3 可并行）：

| 序号 | Phase | 内容 | 类型 | 依赖 | 可并行 |
|---|---|---|---|---|---|
| 1 | **DI-1** 后端 extract 端点 | `POST /api/v1/chapters/{id}/extract`：对 `finalized` 且有 `draft_text` 的章节跑 ExtractorAgent，**先删本章旧 timeline_events** 保证可重复提取；返回与 finalize 同款 `{chapter, updated_character_ids, added_event_ids}`；新增 `no_draft_to_extract` 中文错误码；提取失败 `db.rollback()` 不动正文/状态。pytest 5+ | 后端 | — | ✅ 与 DI-2/DI-3 并行 |
| 2 | **DI-2** 前端 sheet 布局 + 导入解耦 | `NewChapterSheet` / `ImportChapterSheet` 改「ScrollView 表单区 + 钉死底部 footer」修按钮裁切；导入路径一律 `run_extractor=false`（只落正文→finalized），去掉「导入后让 Agent 提取」开关换提示文案；`submitImport` trim 正文 + **失败回滚删空骨架 + 清编辑器**。XCTest | 前端 | — | ✅ 与 DI-1/DI-3 并行 |
| 3 | **DI-3** 前端手动提取按钮 | `APIClient.extractChapter` + `MockAPIClient` 钩子 + `ChapterEditorStore.extract()`（`isExtracting` 标志 + 复用 `lastUpdatedCharacterIds` 高亮）+ `ChapterToolbar` 加「提取角色/时间线」按钮（`status == .finalized` 才显示，跑完刷新 charactersStore）。XCTest | 前端 | DI-1 契约（可对 mock 先行） | ✅ 与 DI-1/DI-2 并行 |
| 4 | **DI-4** 收尾发版 | 5 处版本号 0.9.2 → 0.9.3 + §7 变更日志 + HZ `deploy-hz.sh`（**无新迁移**，仅代码 + 版本）+ smoke `{"version":"0.9.3"}` + LinoI macOS Developer ID 重打包（`release-macos.sh`）+ iOS 重上 TestFlight | 全栈/部署 | DI-1+DI-2+DI-3 | — |

**关键约束**：
- DI-1 **无 Alembic 迁移**（不加表/列，纯新增端点 + 错误码）。
- DI-3「提取」按钮对**任意** `finalized` 章节可见 = 可重复提取（DI-1 先删本章旧 timeline 保证不堆重复事件）；Agent 写完 finalize 已提取过的章节再点 = 重新提取，幂等。
- 导入失败（DI-2）现在只剩传输/网络层（`run_extractor=false` 不碰 LLM），失败必须删掉第①步空骨架，不得把作者晾在空 SOP。
- `static api_token` / device-token 双路径、§5.A 其余契约不动；`ChapterImportRequest.run_extractor` 字段保留（后端仍支持，前端只是改为始终传 false）。

**发版同步清单**（DI-4）：5 处版本号 → `0.9.3`；§7 变更日志；HZ redeploy（无迁移）；LinoI 双端重打包。

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

### 5.R iOS 三档响应式 + 触控适配 🎯 **v0.8 主菜**

#### 5.R.1 动机

v0.7 iOS 处于"编译过 / UI 是 stub"状态:
- `WorkspaceView.iOSLayout` 只有 editor + 右上角按钮弹一个 sheet 显示 RightPanel,**没有章节侧栏**,作者切章节要回到根视图
- 没有 `NavigationSplitView`,iPad 上的 split-view 优势完全没用上
- `FileSaver.swift` iOS 分支是 `// TODO` 级 stub(F 已知残留),无法真正保存
- v0.6 K-1 的"响应式三档断点"是 macOS 专属(窗口宽度判定),iOS 完全不适用 — iPhone / iPad / iPad landscape 是 size class + orientation 联合判定
- 多处 hover 微交互(BookCard / ChapterListView 行)在 iOS 上无意义,需要换 swipe / 长按
- Keychain ACL 在 iOS 上没有"始终允许"勾选,行为与 macOS 不同 — 当前代码若有依赖弹框确认会卡

v0.8 主菜:让 iPhone / iPad 都能跑出 macOS 同等质量的写作体验。

#### 5.R.2 设计决策

| 决策点 | 选择 |
|---|---|
| 三档断点 | **iPhone (compact width)** / **iPad portrait (regular width + portrait)** / **iPad landscape (regular width + landscape)** |
| iPad layout | `NavigationSplitView(sidebar=ChapterListView, detail=EditorView, inspector=RightPanelView)`,iPad portrait 默认折 inspector,landscape 默认展 |
| iPhone layout | `NavigationStack`,根视图 = EditorView,toolbar 两个按钮:左 = "章节" sheet(ChapterList),右 = "辅助" sheet(RightPanel) |
| 触控 affordance | 长按代替 hover(BookCard / ChapterListView 显选项菜单);swipe-to-action(ChapterListView 行左滑显删除 / 右滑显导出) |
| 工具栏 placement | iPhone 主要按钮 `.topBarTrailing` + 写作 primary CTA `.bottomBar`;iPad 全部 `.topBarTrailing` |
| FileSaver | `UIDocumentPickerViewController` (export mode) 真正 await;via `UIViewControllerRepresentable` wrapper |
| Keychain | iOS 无 ACL 弹框,直接 read/write 即可;Keychain wrapper 内 `kSecAttrAccessible = .afterFirstUnlockThisDeviceOnly`,不跨设备同步 |
| 字体 | serif 设定保留;iOS 上 dynamic type 跟系统(`.font(.system(.body, design: serif ? .serif : .default))` 自动响应) |

#### 5.R.3 NavigationSplitView 契约(iPad)

```swift
NavigationSplitView(columnVisibility: $columnVisibility) {
    ChapterListView()                          // sidebar
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
} content: {
    EditorView()                               // detail
} detail: {
    RightPanelView()                           // inspector
        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
}
.navigationSplitViewStyle(.balanced)
```

- `columnVisibility` 默认值:
  - iPad portrait: `.doubleColumn`(sidebar + detail,inspector 折叠;toolbar 按钮可唤出)
  - iPad landscape: `.all`(三栏全开)
- 通过 `@Environment(\.horizontalSizeClass)` + `@Environment(\.verticalSizeClass)` 检测当前档位,onChange 更新 `columnVisibility`
- 用户手动 toggle 后保留状态(同 macOS inspector 行为)

#### 5.R.4 iPhone NavigationStack 契约

```swift
NavigationStack {
    EditorView()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: { showChaptersSheet = true }) {
                    Image(systemName: "list.bullet")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { showRightPanelSheet = true }) {
                    Image(systemName: "info.circle")
                }
            }
        }
}
.sheet(isPresented: $showChaptersSheet) { ChapterListView() }
.sheet(isPresented: $showRightPanelSheet) { RightPanelView() }
```

写作 primary CTA(展开提纲 / 写作 / finalize)放在 `.bottomBar`,大手指可达。

#### 5.R.5 每个 `#if os(iOS)` 文件补齐清单

| 文件 | 当前状态 | v0.8 要做 |
|---|---|---|
| `Platform/FileSaver.swift` | iOS 分支 `// TODO`,直接返回 nil | 改为 `UIDocumentPickerViewController(.export)` wrapper,真正 await user 选目录;返回选中的 URL |
| `Views/Workspace/WorkspaceView.swift` `iOSLayout` | editor + 右上角 sheet | R-1 重写为 size-class-aware:iPhone NavigationStack,iPad NavigationSplitView |
| `Views/Components/BookCardView.swift` | hover 抬升(macOS) | iOS 加 `.onLongPressGesture` 显选项菜单(打开 / 导出 / 删除);hover 分支 `#if os(macOS)` 包住 |
| `Views/Workspace/Editor/ChapterListView.swift` | macOS `.contextMenu` 右键 | iOS 加 `.swipeActions(edge: .trailing)` 删除 / `.swipeActions(edge: .leading)` 导出 |
| `Views/Workspace/Editor/TimelineTabView.swift` | macOS hover × 删除 | iOS 改长按弹 ActionSheet 选删除 / 编辑 |
| `Views/Root/SettingsView.swift` | macOS 4-tab TabView | iOS 改 `Form` + `Section`(原生 iOS Settings 风格);macOS 保 TabView 不动 |
| `Views/Components/ProviderKeyEditSheet.swift` | macOS sheet 380×500 | iOS 改 `NavigationStack` + `.presentationDetents([.large])`,Done / Cancel 在 navigationBar |
| `Views/Workspace/Editor/RightPanelView.swift` | 当前 iOS 已经能渲染 | 配合 R-1 嵌进 NavigationSplitView inspector,sheet wrapper 改为 R-1 内 sheet 一致 wrap |

#### 5.R.6 接口契约

**不**新增 / 不修改后端 API。纯前端 R 阶段。

新增 / 修改的 Swift 类型:

```swift
// Models/UI/PlatformLayout.swift (新)
enum iOSLayoutMode {
    case iPhone           // compact width
    case iPadPortrait     // regular + portrait
    case iPadLandscape    // regular + landscape
}

extension EnvironmentValues {
    var iOSLayoutMode: iOSLayoutMode { ... }
}
```

#### 5.R.7 风险与 open question

- **iPad mini 多窗口(Split View)**:多任务时 iPad 也可能进入 compact width — R-2 必须按 size class 而不是 device idiom 判定,否则 iPad split-view 用户体验崩
- **iOS 26+ 与 iOS 18 行为差异**:`.inspector` modifier 在 iOS 17+ 才有;`NavigationSplitView` iOS 16+。`project.yml` 当前 iOS deployment target = ?(open question:builder 启动 R-1 时先 grep `project.yml`,如低于 iOS 17 需要升)
- **Keychain ACL**:iOS Keychain 没有 macOS 的"始终允许"弹框,但**首次 read 会在 lock screen 后触发解锁**;若用户 BACKEND_URL 改到云域名后立即触发 SSE,可能撞 keychain access denied。需在 `KeychainStore` 加 retry 一次的兜底
- **iOS Simulator 不支持 keychain `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 的某些边界条件**:R-4 测试要在真机抽 1 次

#### 5.R.8 验收标准

- iPhone 14 simulator:全流程(创建书 → 创建章 → 写作 → finalize → 导出)能跑通,无卡死,无 stub 提示
- iPad Pro 11" portrait simulator:三栏 split-view 默认 double-column,toolbar 按钮唤出 inspector
- iPad Pro 11" landscape simulator:三栏全开
- 真机(作者本人 iPhone)抽 1 次:Keychain + UIDocumentPicker + SSE 跑通
- XCTest 120 baseline 全过 + 新增 ≥ 20 个 iOS 路径测试
- `xcodebuild -destination 'platform=iOS Simulator,name=iPhone 14'` build clean

#### 5.R.9 自用直装工作流(免费 Apple Developer 账号)

**2026-05-26 作者拍板**:此项目永久作者自用,免费 Apple Dev 账号 + Xcode → device 直装,不走 TestFlight(详 §5.V 已剔除)。

**约束(免费账号特性)**:
- Personal Team **签名证书 7 天有效**;第 8 天起 app 启动会被 iOS 拒(unable to verify app)
- Apple ID 绑定设备数上限 **3 台**(iPhone / iPad / iPod touch 合计)
- Bundle ID 任意,无需 Apple 注册(沿用 `com.lino.linowriting.LinoWriting`,与 macOS Keychain 连续性一致)
- 不能上 TestFlight、不能上 App Store、不能邀别人测

**周复用工作流**:
1. iPhone / iPad 连 USB 或同 Wi-Fi(Xcode 15+ 支持 wireless debug)
2. Xcode Project → Signing & Capabilities → Team 选作者 Personal Team
3. `xcodegen generate` → 打开 `LinoWriting.xcodeproj` → 顶部 destination 选自己 iPhone → Product → Run
4. app 安装到 device,有效期 7 天
5. 第 8 天起 app 启动会失败 → 重复步骤 3(15 秒搞定)
6. **Keychain 数据连续性**:7 天 re-sign 后 bundle ID + device 不变 → Keychain item 保留,不需要重新填 backend URL / token

**`project.yml` 配置切换(R-3 阶段做)**:

当前(ad-hoc,仅 macOS):
```yaml
CODE_SIGN_STYLE: Manual
CODE_SIGNING_ALLOWED: NO
CODE_SIGN_IDENTITY: ""
```

iOS 自用打开后(R-3):
```yaml
# macOS 配置仍 ad-hoc(本地 codesign --sign - 不需要 team)
# iOS 配置走 Automatic + Personal Team
CODE_SIGN_STYLE: Automatic
CODE_SIGNING_ALLOWED: YES        # iOS 必须签
DEVELOPMENT_TEAM: <作者 Personal Team ID>
```

**R-4 收尾时**:README 加一段"iOS 自用安装步骤"(给作者自己以后忘了对照用)。

#### 5.R.10 风险与 open question(R.9 新增)

- ~~**iOS deployment target**~~:**已答**(2026-05-26 作者拍板):作者 iPhone iOS 26.5,远高于 `project.yml` 当前 deployment target 17.0;`.inspector` modifier(iOS 17+)/ `NavigationSplitView`(iOS 16+)全部兼容,**保留 deployment target 17.0** 不调
- **`DEVELOPMENT_TEAM` 在 git 仓库**:Personal Team ID 不算 secret,但散在 `project.yml` 里会污染 git diff — 改 `xcconfig` 外置,或 `.env.local`(open question)
- **7 天 re-sign 自动化**:Xcode 命令行 `xcodebuild -destination 'platform=iOS,id=<udid>'` build + install,可写脚本一键,但需 device UDID 配在脚本里。R-4 可选交付 `scripts/install-ios.sh`

---

### 5.S 后端 PostgreSQL 切换 + HZ 阿里云部署 🎯 **v0.8 必修**

> **2026-05-26 部署目标实锚**:作者已有阿里云 ECS(代号 `hz`,杭州,`118.178.122.194`),其上已跑成熟 `linofinance-api` / `100j-api` / 个人主页三业务,**邻居约定**是 systemd unit + venv + Nginx + certbot + 现有 `postgresql@16-main`(**不是 Docker**)。LinoWriting 跟邻居一致接入,不另起容器栈。详见 `/Users/linotsai/hz_info.md`。
>
> ⚠️ 原 §5.S 写的"Dockerfile 多阶段构建 + docker-compose.prod.yml + Caddy + Fly.io/Render/Hetzner 三候选评估"**整段作废**。
>
> **2026-05-26 实施**:旧 `Backend/Dockerfile` / `Backend/docker-compose.yml` / `Backend/deploy/Caddyfile` / `Backend/deploy/docker-compose.prod.yml` / `Backend/deploy/backup.sh` **已 git rm 删除**。HZ 单一部署路径,YAGNI。`Backend/deploy/` 目录在 S-2 阶段重建,放新的 `deploy-hz.sh`。`Backend/README.md` 部署段同步重写。

#### 5.S.1 动机

v0.7 后端的现状:
- `config.py` 默认 `database_url: sqlite+pysqlite:///./lino_writing.db`,**数据库文件在仓库根目录**,云上不能依赖
- `.env.example` 已经写 `postgresql+psycopg`,SQLAlchemy + Alembic 已经 dual-dialect(`with_variant(postgresql.JSONB)`),Postgres 切换**数据层是 ready 的**
- 没有 process manager(开发用 uvicorn 直接跑)
- 现有 9 条 Alembic 迁移(v0.7 末 8 条 + v0.7.1 voice cleanup 1 条)从未在 Postgres 上一次性 `upgrade head` 全跑过

HZ 杭州云的现状(参 `/Users/linotsai/hz_info.md`):
- Ubuntu 24.04.4 LTS / 1.6GiB RAM / 30GB 可用磁盘 / Swap 2.0GiB
- `postgresql@16-main.service` active,本机 5432,已有 `100j` / `linofinance` 两库 + `postgres` 系统库
- Nginx active,80/443,已 reverse_proxy 三个站点
- certbot ECDSA 证书 + 自动续期,已有 3 个站点证书
- SSH 22 公钥登录,UFW 入站只 `22/80/443`
- 日常用户 `deploy`,业务系统用户依业务命名(如 `linofinance`)

LinoWriting 接入策略:跟邻居一致,不引入异类(Docker 会让单 ECS 内存压力陡增 + 与现有 systemd 监控/日志体系断层)。

#### 5.S.2 设计决策

| 决策点 | 选择 |
|---|---|
| **部署目标** | HZ 阿里云 ECS(`118.178.122.194`),复用现有 OS / Nginx / Postgres / certbot 栈 |
| **域名** | **`lw.linotsai.top`**(2026-05-26 作者拍板,DNS A 记录已解析到 `118.178.122.194`)。沿用作者域名,certbot 自动签 ECDSA。 |
| **dev 数据库** | SQLite 保留(本地快开发,跟 v0.7 一致);**S-1 阶段必须** 至少跑一次 `docker run postgres:16` 本地 pytest 抓 dialect-only bug |
| **测试数据库** | pytest 本地默认 SQLite in-memory(快);S-1 / Z 阶段切 `DATABASE_URL=postgresql+psycopg://...` 走 PG 全跑一遍 |
| **`config.py` 默认** | **保持 SQLite**(dev 友好);prod 由 systemd unit `EnvironmentFile=` 注入 `DATABASE_URL=postgresql+psycopg://...` |
| **仓库根 `lino_writing.db`** | gitignore(已是),不删 |
| **process manager** | **systemd unit + uvicorn 单 worker**(SSE 友好,HZ 1.6GiB RAM 紧张,单用户场景够用);**不用 gunicorn**(单 worker 不需要 master + worker 双进程开销) |
| **业务系统用户** | 创建 `linowriting`(跟邻居 `linofinance` 命名一致),`/opt/linowriting/` 目录所有者,venv + `.env` 在内 |
| **反向代理** | 沿用 HZ 现有 Nginx,新加 `/etc/nginx/sites-available/linowriting` 一份配置,反代 `127.0.0.1:8787`,**SSE 必须 `proxy_buffering off`** |
| **HTTPS** | `sudo certbot --nginx -d <sub>.linotsai.top --key-type ecdsa`(沿用邻居约定),自动续期 |
| **secret 存储** | `/opt/linowriting/.env`,owner `linowriting:linowriting`,mode `600`;systemd `EnvironmentFile=` 加载;**不进 git**。包含 `API_TOKEN` / `DATABASE_URL` / `KEK_SECRET`(T-1) / `CORS_ORIGINS` 等 |
| **alembic 时机** | **手动 cutover**(deploy 脚本里调用,SSH 进 HZ 跑 `sudo -u linowriting bash -c "cd /opt/linowriting && .venv/bin/alembic upgrade head"`);**不在 systemd ExecStartPre 自动跑**(失败 → service 起不来,排错路径不清晰) |
| **容量预算** | uvicorn 单 worker idle ~80MB;HZ 已 1.6GB,linofinance + 100j + nginx + PG 估占 ~700MB,LinoWriting 加 ~100MB,剩 ~800MB swap 余量;**单用户场景够用**,超 70% 内存时考虑 ECS 扩容 |

#### 5.S.3 部署落地三件套

**(1) systemd unit `/etc/systemd/system/linowriting-api.service`** — 跟邻居 `linofinance-api.service` 一致风格:

```ini
[Unit]
Description=Lino Writing v2 backend (FastAPI)
After=network-online.target postgresql@16-main.service
Wants=network-online.target

[Service]
Type=simple
User=linowriting
Group=linowriting
WorkingDirectory=/opt/linowriting
EnvironmentFile=/opt/linowriting/.env
ExecStart=/opt/linowriting/.venv/bin/uvicorn app.main:app \
    --host 127.0.0.1 --port 8787 \
    --timeout-keep-alive 75 \
    --log-level info
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/linowriting

[Install]
WantedBy=multi-user.target
```

**(2) Nginx site `/etc/nginx/sites-available/linowriting`**:

```nginx
server {
    listen 80;
    server_name lw.linotsai.top;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name lw.linotsai.top;

    ssl_certificate     /etc/letsencrypt/live/lw.linotsai.top/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/lw.linotsai.top/privkey.pem;

    # SSE 长连接必须关 buffer + 拉长 timeout
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 120s;
    proxy_send_timeout 120s;

    # 防 LinoI 客户端 large body(批量导入章节)
    client_max_body_size 8m;

    # HSTS 由 T-2 后端 middleware 添加;Nginx 不重复加

    location / {
        proxy_pass http://127.0.0.1:8787;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

**(3) Deploy 脚本 `Backend/deploy/deploy-hz.sh`(新文件,本地 → HZ rsync + remote alembic + reload)**:

```bash
#!/usr/bin/env bash
# 本地 push 一份代码到 HZ 并完成 deploy/迁移/重启,幂等。
set -euo pipefail

HZ=deploy@118.178.122.194
REMOTE=/opt/linowriting

# 1. rsync 代码到 HZ staging,排除本地脏文件
rsync -avz --delete \
    --exclude='.venv' --exclude='.env' --exclude='__pycache__' \
    --exclude='*.db' --exclude='*.db-journal' \
    Backend/ "$HZ:$REMOTE/staging/"

# 2. 在 HZ 上做原子切换 + 装依赖 + 跑迁移
ssh "$HZ" "sudo -u linowriting bash -lc '
    cd /opt/linowriting
    rsync -a --delete staging/ ./
    [ -d .venv ] || python3 -m venv .venv
    .venv/bin/pip install -e .
    .venv/bin/alembic upgrade head
'"

# 3. reload service
ssh "$HZ" "sudo systemctl reload-or-restart linowriting-api"

# 4. smoke check
sleep 2
ssh "$HZ" "curl -fsS http://127.0.0.1:8787/api/v1/health -H 'Authorization: Bearer \$API_TOKEN'" || echo "(token 用 \$API_TOKEN 占位,实际验证用 https://lw.linotsai.top + 真 token)"
```

(脚本是骨架。S-3 builder 完善:保留 N 份回滚目录 / 失败 abort / 干净退出码 / 不打印 .env 行。)

#### 5.S.4 接口契约变化

**API 端点**:零变化(纯部署 / 数据层)。

**env 变量新增 / 修改**(写进 `/opt/linowriting/.env`,**不进 git**):
- `DATABASE_URL=postgresql+psycopg://linowriting:<password>@127.0.0.1:5432/linowriting`
- `API_TOKEN=<32+ 字节随机字符串>`(prod 与作者本地 dev token 隔开,不复用)
- `KEK_SECRET=<32-byte base64 url-safe>`(T-1 用)
- `CORS_ORIGINS=https://lw.linotsai.top`(收窄,T-2 用;若用其它子域换)
- `LOG_LEVEL=INFO`
- `GROK_API_KEY` / `MODEL_NAME` 仅在仍走 env 注入路径时保留;v0.6 已有 ProviderKey 表,**prod 推全部走 ProviderKey**,env 路径仅作 fallback

**`config.py` 改动**:不动默认值(保留 SQLite 给 dev),prod 由 EnvironmentFile 注入 `DATABASE_URL`。

**Alembic 迁移**:零新增(仅验证现有 9 条在 PG 上 `upgrade head` 干净;data migration 留 T-1)。

#### 5.S.5 部署 runbook(HZ 上线 + 日常发版)

**首次部署一次性配置**:

```bash
ssh deploy@118.178.122.194
# === 以下在 HZ 上 ===

# 1. 创建业务系统用户 + 目录
sudo adduser --system --group --home /opt/linowriting linowriting
sudo mkdir -p /opt/linowriting
sudo chown linowriting:linowriting /opt/linowriting

# 2. 创建 Postgres DB + role
sudo -u postgres psql <<'SQL'
CREATE ROLE linowriting WITH LOGIN PASSWORD '<32+ bytes random>';
CREATE DATABASE linowriting OWNER linowriting;
SQL

# 3. DNS:作者域名提供商加 A 记录 lw.linotsai.top → 118.178.122.194
#    (TTL 5 分钟,等 dig 出新 IP 再继续)

# 4. certbot 签 ECDSA 证书
sudo certbot --nginx -d lw.linotsai.top --key-type ecdsa

# 5. /opt/linowriting/.env (mode 600)
sudo -u linowriting tee /opt/linowriting/.env > /dev/null <<'ENV'
DATABASE_URL=postgresql+psycopg://linowriting:<password>@127.0.0.1:5432/linowriting
API_TOKEN=<32+ bytes random>
KEK_SECRET=<32-byte base64 url-safe>
CORS_ORIGINS=https://lw.linotsai.top
LOG_LEVEL=INFO
ENV
sudo chmod 600 /opt/linowriting/.env

# 6. 写 systemd unit + Nginx site(内容见 §5.S.3)
sudo systemctl daemon-reload
sudo systemctl enable linowriting-api
sudo cp /etc/nginx/sites-available/linowriting /etc/nginx/sites-available/linowriting.bak.$(date +%Y%m%d-%H%M%S)
sudo nginx -t && sudo systemctl reload nginx

# 7. 从作者 mac 跑第一次 deploy
./Backend/deploy/deploy-hz.sh

# 8. 启动 + 验证
sudo systemctl start linowriting-api
curl -fsS https://lw.linotsai.top/api/v1/health -H "Authorization: Bearer <API_TOKEN>"
# → {"status":"ok","version":"0.8.0"}
```

**日常发版**:

1. 本地 `git commit` 完成后
2. `./Backend/deploy/deploy-hz.sh` — rsync + alembic + systemctl reload 一气呵成
3. `curl -fsS https://lw.linotsai.top/api/v1/health -H "Authorization: Bearer ..."` 确认 200 + 版本号
4. LinoI 客户端连云端跑一次 write 流确认

**回滚**:deploy 脚本未来若加"保留 N 份历史目录",回滚 = `sudo -u linowriting ln -sfn /opt/linowriting/releases/<旧 commit> /opt/linowriting/current && sudo systemctl restart linowriting-api`。MVP 阶段先靠 `git checkout <旧 commit> && ./deploy-hz.sh`。

#### 5.S.6 风险与 open question

- **HZ 1.6GiB RAM 压力**:已跑 nginx + PG + 2 个 FastAPI + 静态站点;再加 LinoWriting 单 uvicorn worker。**S-3 启动前先 `ssh deploy@... 'free -h'` 看实际余量**;若紧张:(a) 升级 ECS 配额(成本) / (b) 加 swap / (c) 砍 PG `shared_buffers`。v0.8.x 视情况
- **PG buffer cache 共享**:`100j` + `linofinance` 已在同一 `postgresql@16-main`;LinoWriting 加入后内存抢资源。**S-1 / Z 跑 pytest 全套时观察 query 耗时是否回归 dev 基线**
- **Nginx 配置错连带挂邻居**:`sudo nginx -t` 必跑,改 sites-available 前先 `cp ... .bak.$(date +%Y%m%d-%H%M%S)`(沿用 `hz_info.md §7` 流程)
- **PG JSONB vs SQLite JSON 差异**:已有 `with_variant`,但 query-side(如 `.contains()` / `->'key'`)若有 SQLite-only 写法会爆 — S-1 跑 pytest 抓
- **alembic upgrade 失败半中**:Postgres 默认事务 DDL,单笔迁移失败会回滚;**多笔迁移之间是分别 commit 的**,中间失败会停在 partial state。**S-1 验收里强制要求"先在 dev local PG 上 `alembic upgrade head` 干净"才能 HZ cutover**
- ~~**域名拍板**~~:**已答**(2026-05-26):`lw.linotsai.top`,DNS A 记录已解析,certbot 可直接签
- **UFW**:HZ 入站只 22/80/443;LinoWriting backend 走 `127.0.0.1:8787` 本机回环,**不需要开 8787 公网端口**
- ~~**现有 `Backend/Dockerfile` / `Backend/docker-compose*.yml` / `Backend/deploy/`**~~:**已答**(2026-05-26):5 个文件 `git rm` 删除,`Backend/README.md` 同步重写。`Backend/deploy/` 目录在 S-2 阶段重建放 `deploy-hz.sh`

#### 5.S.7 验收标准

- **dev 本地 PG smoke**:S-1 阶段 `docker run -d postgres:16` + `DATABASE_URL=postgresql+psycopg://... pytest` 全 175 + 新增 PG dialect 测试通过,`-W error` 干净
- **HZ 部署落地**:`ssh deploy@... 'systemctl status linowriting-api'` active + `journalctl -u linowriting-api -n 50` 无 error
- **HTTPS 健康检查**:`curl -fsS https://lw.linotsai.top/api/v1/health -H "Authorization: Bearer ..."` 返回 200 + `{"status":"ok","version":"0.8.0"}`
- **邻居不受影响**:`curl -fsS https://100j.linotsai.top/health` + `curl -fsS https://lf.linotsai.top/api/v1/health` 仍 200
- **`systemctl --failed` 为 0**(沿用 `hz_info.md §11` 退役验收准则)
- **`free -h`** 剩余可用 > 200MB
- **LinoI macOS 客户端连云后端**,完整 write 流(expand → write → finalize)跑通
- **PG `pg_dump` 备份脚本** cron 示例写进 Backend README(对照邻居 `linofinance` 备份风格 — 若已有则照搬;若无则新建 `/opt/linowriting/backup.sh` + 每日 cron)

---

### 5.T 安全硬化 🎯 **v0.8 必修**

#### 5.T.1 动机

本地单用户裸奔可以,云上裸奔出事。v0.7 的安全态势:
- ProviderKey 明文存数据库(OpenAI / xAI / Anthropic 的钱包)
- 无 rate limit(任何泄漏的 api_token 是无限刷 LLM 的肉鸡)
- `cors_origins: str = Field(default="*")` 完全敞开
- LLM 4xx body 已脱敏(v0.7 P-1 A),但**access log 还未脱敏**
- `.env` 在仓库 / 本地文件系统;云上必须改 secret manager
- 单租户静态 Bearer `api_token` v0.8 保留;**多租户永久 out of scope**(2026-05-26 作者拍板,§5.T.4)

#### 5.T.2 设计决策

| 决策点 | 选择 |
|---|---|
| ProviderKey 加密 | **Fernet (AES-128-CBC + HMAC-SHA256)**(`cryptography` 包,Python 标准)— `api_key` 列存 base64 ciphertext;KEK 从 `KEK_SECRET` 环境变量读 |
| KEK 长度 | 32 字节 base64 url-safe(Fernet 标准) |
| 老明文行迁移 | Alembic data migration:遍历 `provider_keys`,检测**不是** Fernet 格式(`gAAAAA` 开头)则视为明文,加密回写 |
| Read-side dual | 读 row 时先尝试 Fernet decrypt;`InvalidToken` 则当明文返回(向后兼容,迁移完成后下个版本删 fallback) |
| Rate limit | `slowapi` middleware(基于 `limits` 包);per-token + per-endpoint;write 系列(`/chapters/*/expand|write|import|finalize`)限 30/min;其它读端点 600/min |
| HTTPS-only | HZ Nginx 已通过 certbot 自动 HTTPS(§5.S);backend middleware 额外加 HSTS header(`Strict-Transport-Security: max-age=31536000; includeSubDomains`) |
| CORS | `CORS_ORIGINS` 从 `*` 收窄为 `https://<prod-domain>`(LinoI 是 native app,无 Origin header 不卡 CORS,不需要 `linowriting://` 自定义 scheme) |
| Access log 脱敏 | uvicorn `access_log_handler` 自定义 filter,re-apply `_sanitize_error_body` 同款 regex(防 query string / body 含 sk-/Bearer) |
| ~~Multi-tenant hook~~ | **已撤销**(2026-05-26):沿用现 `require_bearer_token`,不加 `AuthContext` plumbing。详 §5.T.4 |

#### 5.T.3 接口契约变化

**Alembic 迁移**:`202605270001_encrypt_provider_keys`(data-only,无 schema 变更):
- upgrade:遍历所有 `provider_keys` 行,api_key 不是 Fernet 格式则加密 + 回写
- downgrade:遍历所有 `provider_keys` 行,Fernet 格式则解密 + 回写明文

**新 env 变量**:
- `KEK_SECRET`(32-byte url-safe base64;启动时验证格式,无效 → fail-fast)

**新 endpoint 行为**:
- 所有 write 路径加 rate limit;超限返回 `429 Too Many Requests` + `Retry-After` header + `details.code = "rate_limited"`(中文 i18n 模板:"请求过于频繁,请稍候再试")

**前端影响**:
- ErrorMapping 加 429 处理,Toast 显中文 + 倒计时
- 其它端点 / DTO 零变化

#### 5.T.4 ~~multi-tenant hook~~ — **已撤销**(2026-05-26)

作者拍板:此项目永久单用户自用,多租户**永远**不做。当前 `require_bearer_token` 静态 Bearer 是最简也是最终方案,不需要 `AuthContext` plumbing。

理由:YAGNI — plumbing 本身有维护成本(每个 router endpoint 加 `Depends`),而开关永远不会被打开。如未来真要做多租户(极不可能),`require_bearer_token` → `get_current_auth(AuthContext)` 的重构是机械替换,完全等到那天再说。

T-2 仍按原计划做 rate limit / HSTS / CORS 收窄 / access log 脱敏 — 这些**与租户数无关**,云上线必须项。

#### 5.T.5 风险与 open question

- **Fernet 还是 AES-GCM**:Fernet 简单但 IV 处理黑盒;AES-GCM 性能略好但要自己管 nonce。**Planner 选 Fernet**(简单 + Python 标准);如作者有性能要求(单 row 加密耗时 < 0.1ms,影响微乎其微),改 AES-GCM 也可
- **KEK 轮换**:v0.8 不做 multi-key rotation(单 KEK)。轮换时需要先解密老 row 用旧 KEK 再加密新 KEK,留 v0.8.x
- **rate limit 在 multi-worker 下**:HZ 决策已落单 uvicorn worker(§5.S.2),in-memory limiter 直接干净。单用户场景永久足够,不需要 Redis-backed
- **HSTS includeSubDomains**:HZ 域名是 `<sub>.linotsai.top`,作者已有多个兄弟子域(`100j` / `lf` / `linotsai.top` 根域),**`includeSubDomains` 会影响所有 `*.linotsai.top` 站点强制 HTTPS**。当前邻居都已经 HTTPS-only,加 `includeSubDomains` 安全;但若未来作者临时起个 `http://dev.linotsai.top` 试什么会被 HSTS pin 锁住。**T-2 启动前 verify**:作者本机 keychain 是否曾访问过 `linotsai.top` 任何子域的 http → 若 yes,`includeSubDomains` 加上后作者本机浏览器历史会强制升 HTTPS(通常无害)。**Planner 推荐**:不加 `includeSubDomains`,仅当前域名 HSTS;保险且无功能损失

#### 5.T.6 验收标准

- pytest 新增 ≥ 15 个测试:
  - Fernet round-trip(encrypt → store → read → decrypt 匹配)
  - 老明文 row read fallback(模拟 pre-migration row)
  - Alembic 迁移 idempotent(跑两次不重复加密)
  - rate limit 命中 → 429 + Retry-After + 中文 message
  - rate limit 未命中正常 200
- `bandit -r app/` 安全静态检查 0 high severity
- 启动时 `KEK_SECRET` 无效 → fail-fast(进程退出码 1)
- prod cutover 后 `psql -c "SELECT api_key FROM provider_keys"` 全是 `gAAAAA...` ciphertext

---

### 5.U 客户端 → 云后端切换 🎯 **v0.8**

#### 5.U.1 动机

云后端 up 之后,客户端要能"开箱直连":
- LinoI 首次启动时 BACKEND_URL 默认值是 `http://localhost:8787` — 云上线后这个默认对作者新装时毫无意义
- iOS 真机连 `http://localhost:8787` 直接超时(没人在那监听);连 `http://` 任意地址会被 ATS 拒
- SSE 在公网长连接(write 流可能跑 1-3 分钟)需要调 uvicorn keep-alive + Nginx buffer 关
- 老 v0.7 macOS Keychain 里已经有 `lino.localhost:8787.token` — 切到 `lw.linotsai.top` 要不要清?

#### 5.U.2 设计决策

| 决策点 | 选择 |
|---|---|
| 默认 BACKEND_URL | `https://lw.linotsai.top`(S-3 域名拍板后写死;现指 §5.S 推荐子域,作者拍板可换);保留 `Settings → Connection → BACKEND_URL` 输入框允许作者切回 localhost 自测 |
| Keychain key | 当前是 `lino.{host}.token`;切域名后 host 部分自动变,新旧 row 共存。**不自动迁移 token**(详 §5.U.3) |
| SSE keep-alive | uvicorn `--timeout-keep-alive 75` + Nginx `proxy_buffering off` + `proxy_read_timeout 120s`(§5.S.3) + 客户端 URLSession `timeoutIntervalForRequest = 120, timeoutIntervalForResource = 600` |
| iOS ATS | Info.plist `NSAppTransportSecurity` 不显式 disable;默认仅 HTTPS;不加 exception domains(强制 HTTPS,`lw.linotsai.top` 用 Let's Encrypt cert) |
| iOS Simulator localhost dev | Apple 允许 `http://localhost` 是 ATS 默认例外(macOS host loopback);**Simulator dev 不撞墙**,不需要 ATS exception |
| iOS 真机 dev | 真机不能用 http,作者真机调试时必须连云后端 `https://lw.linotsai.top`,或本地起 backend + ngrok/cloudflared tunnel 加 HTTPS |
| macOS dev | 不受 ATS 限制(macOS NSURLSession 默认 ATS 不强制),保留 localhost dev 流畅 |

#### 5.U.3 Keychain 迁移决策

**open question**:切到生产域名时,老 `lino.localhost:8787.token` 怎么办?

**选 A(planner 推荐)**:**两不动,提示一次**
- 不删旧 row(作者改回 localhost 还能用)
- 不自动 migrate token 到新 host(token 在云上可能不同)
- 启动时若新 host 无 token → SettingsView Connection tab 顶部红 banner "请填入云后端 API token"

**选 B**:自动 migrate
- 旧 token 直接复制到新 host key — 风险:作者云后端 token 未必和本地一样,导致一上来就 401

**选 C**:清掉旧的
- 反预期,作者本机 dev 时还要重填,体验差

→ 落 A。

#### 5.U.4 接口契约变化

**前端代码改动**:
- `Services/Settings.swift`(or `AppEnvironment`):`defaultBackendURL` 改为生产域名(S-3 后填)
- `Stores/AppStore.swift` 启动时 token 检测逻辑加 banner trigger
- `Services/SSEClient.swift`:URLSession config `timeoutIntervalForRequest = 120, timeoutIntervalForResource = 600`(若当前不是)
- `App/project.yml` iOS Info.plist 不加 `NSAppTransportSecurity`(空对象 = 默认 HTTPS only)

**后端代码改动**:
- uvicorn startup args 由 HZ systemd unit `ExecStart=` 控制(`--timeout-keep-alive 75`,§5.S.3)
- Nginx site 关 buffer + 拉长 timeout 已在 §5.S.3 写定

#### 5.U.5 风险与 open question

- **iOS Simulator localhost dev**:Apple 历史上对 simulator `localhost` ATS 是宽松的(host loopback 例外),但偶有 Xcode 版本回归;**R-4 启动前 verify**;若撞墙,project.yml 加 dev-only Info.plist 变体豁免 `localhost`
- **HTTPS cert pinning**:暂不做(用 Let's Encrypt 即可);v0.9+ 若需要可加 NSPinnedDomains
- **SSE 在弱网下断流**:URLSession 自动 retry 不适用 SSE(会丢已收的 token)— 客户端需要"流断了 → 提示 + Stop 状态;不自动重连"(其实当前已是这行为,确认即可)

#### 5.U.6 验收标准

- iPhone 14 真机连 `https://<prod-domain>`:create book → expand → write(SSE 跑满 60+ 秒不断)→ finalize → export 全跑通
- macOS 上 LinoI 设 BACKEND_URL = `http://localhost:8787` 仍可工作(dev backwards compat)
- 401 token 错误时 Settings 顶部 banner 提示
- iOS XCTest 加 1 个测试:启动时若 host 无 token,AppStore 触发 `pendingTokenSetupBanner = true`

---

### 5.V iOS Provisioning + TestFlight 上架 ⚫ **已剔除**

> **2026-05-26 作者拍板:此项**永久**不做。** 作者自用项目 + 免费 Apple Developer 账号,Xcode → device 直装 + 7 天 re-sign 工作流即可,无任何邀测 / 上架需求。本节保留作历史决策记录,但 §4.4 Phase 表已删除 V,候选池 §3 已标 ⚫。日后真要做时再重新评估。详 §5.R.9。

---

#### 5.V.1 动机(也是 v0.8 范围 open question)

当前 `project.yml` 设 `CODE_SIGNING_ALLOWED: NO`,ad-hoc 签名 — **能在自己设备本机自测,但**:
- 不能上 TestFlight(Apple 必须真签)
- 不能给别人邀测(provision profile 限制)
- 不能上 App Store

**v0.8 决策点**(留作者):
- (a) **仅自用** → V 不做,v0.8 收尾时 R/S/T/U 完成即可发版,LinoI iOS 通过 Xcode → device 直接安装
- (b) **邀请 1-3 个朋友 beta** → V 做,但只发 internal testers(无需 Apple Review,但需 Developer Program $99/yr)
- (c) **公开 TestFlight** → V 做,需 Apple Review(2-3 天),正式 store 还需更长

**Planner 推荐**:**先 (a)**,v0.8 内不做 V;R/S/T/U 完成 + 真机自测即可发 0.8.0;TestFlight 留 v0.8.x。理由:
- Apple Developer Program 注册要时间(账号验证 1-7 天,国内开发者发票 / 银行卡审查更长)
- TestFlight build 走 archive + upload + processing,首次配 1-2 天打磨
- v0.8 主菜是 iOS + 云后端跑通,先让这两件事 ship,beta 用户分发独立推进

#### 5.V.2 设计决策(若 V 入 v0.8)

| 决策点 | 选择 |
|---|---|
| Apple Developer Program | $99/yr,个人 account(作者邮箱注册);企业账号($299/yr)不需要 |
| Bundle ID | **生产 / dev 分开**:`com.lino.linowriting`(prod,App Store + TestFlight)/ `com.lino.linowriting.dev`(local dev) — 避免 dev sandbox 污染 prod TestFlight 用户数据 |
| Code signing | `project.yml`:`CODE_SIGNING_ALLOWED: YES`,`CODE_SIGN_STYLE: Automatic`,`DEVELOPMENT_TEAM: <team ID>`,prod target 用 prod bundle ID |
| Provisioning profile | Xcode 自动管(Automatic signing) |
| TestFlight metadata | App name `LinoI`,short description "LLM-assisted novel writing",test instructions 简单写"先在 Settings 里填 LLM provider key 再写章节" |
| Build 流程 | `xcodebuild archive` → `xcodebuild -exportArchive -exportOptionsPlist` → `xcrun altool --upload-app`(或 Xcode Organizer 上传) |

#### 5.V.3 接口契约

零后端契约变化。仅前端 `project.yml` + Apple developer portal 配置。

#### 5.V.4 风险与 open question

- **国内 Apple ID 注册周期**:作者 Apple ID 是否已经是 Developer? open question
- **Bundle ID `com.lino.linowriting` 已被占用风险**:Apple 全球唯一性,需注册时检查;若被占用,换 `app.lino.linowriting` 或类似
- **Keychain 数据迁移**:若 bundle ID 从 `com.lino.linowriting.LinoWriting`(v0.7 ad-hoc) 改为 `com.lino.linowriting`(v0.8 prod) **不一致 → keychain access group 不同 → 老 token 丢**。**决策**:沿用 `com.lino.linowriting.LinoWriting`(v0.6/v0.7 Q phase 已锁的),保 Keychain 连续性 — 但 prod TestFlight bundle ID 必须和 ad-hoc 一致才行,即 v0.6 锁的就是 prod bundle ID,这点 v0.7 Q phase log 已经记下

#### 5.V.5 验收标准(若入)

- TestFlight build processed + 至少 1 个 internal tester 安装并跑通 write 流
- archive 流程文档化进 `App/README.md`
- `xcodebuild archive -scheme LinoWriting -destination 'generic/platform=iOS'` 干净 + 上传成功

---

### 5.W 设备配对认证 🎯 **v0.9 主菜**

#### 5.W.1 动机

v0.7 / v0.8 使用单一 static `API_TOKEN`(`/opt/linowriting/.env` 中,32 字节十六进制随机)。每个新设备首次启动:
1. 知道 BACKEND_URL(默认现在是 `https://lw.linotsai.top`)
2. SSH HZ 跑 `sudo grep ^API_TOKEN= /opt/linowriting/.env | cut -d= -f2-` 拿明文 token
3. 复制 token 到 LinoI Settings → Connection → API Token 字段
4. 保存,触发 Keychain 存储

对作者本人(单用户自用)都不舒服。iOS 真机第一次装尤其麻烦(SSH 在 iPhone 上没有,得另开 mac SSH 然后手动 retype 32 字节 hex)。**v0.9 主菜:把这条流改成"老设备显示 QR 码 + 6 位短码,新设备扫码 / 输码即用"**。

#### 5.W.2 设计决策

| 决策点 | 选择 |
|---|---|
| 认证机制 | **device-token**:每个设备独立 token,可单独 revoke。**不引入** OAuth / JWT / Sign-in-with-Apple(那等于多租户,作者永久 out) |
| token 存储 | DB `device_tokens` 表,`token_ciphertext` 用 v0.8 T-1 Fernet 加密(`KEK_SECRET` 已就位) |
| 与 static api_token 兼容 | **保留至少 v0.9.x 一个版本**:`auth.py` 先按 device-token 验,失败 fallback static `api_token`。v1.0 / v1.0.x 删除 fallback,只保 device-token |
| 配对码格式 | **6 位数字**(0-999999),好记好输;**10 分钟 TTL**;每码一次性,confirm 后失效 |
| 配对码生成位置 | **macOS LinoI**(已配好的设备主动生成)→ 显示码 + 编码 QR 码 |
| QR 码内容 | JSON-base64:`{"u": "https://lw.linotsai.top", "c": "123456", "ip": "118.178.122.194"}`(`ip` 可选,作者 macOS 调用时已知 `trustedBackendIPs` 直接含) |
| iOS 扫码 | `AVCaptureSession` + `AVCaptureMetadataOutput`(iOS 17+ 标准 API),不需要新依赖 |
| 不能扫码时备选 | iOS 启动屏的"手动配对"路径:输 BACKEND_URL + 6 位短码 + (可选)IP override → 调 `/auth/pair_confirm` |
| 设备名 | 作者可填(macOS / iPhone / iPad),默认用 `UIDevice.current.name` 或 `Host.current().localizedName` |
| 撤销路径 | macOS Settings → "设备管理" 列表 → 每行 trash icon → 调 `DELETE /auth/devices/{id}` |

#### 5.W.3 后端数据模型变更

新表 `device_tokens`:

| 字段 | 类型 | 备注 |
|---|---|---|
| `id` | UUID PK | |
| `device_name` | TEXT NOT NULL | 作者可读 |
| `token_ciphertext` | TEXT NOT NULL | Fernet 密文(同 ProviderKey.api_key 模式) |
| `created_at` | TIMESTAMPTZ NOT NULL | |
| `last_used_at` | TIMESTAMPTZ NULL | 每次成功认证更新 |
| `revoked_at` | TIMESTAMPTZ NULL | revoke 后 set,认证时拒 |

Alembic 迁移 `<YYYYMMDD>0001_add_device_tokens.py`,9 → 10 条迁移链。

新表 `pair_codes`(短码临时表):

| 字段 | 类型 | 备注 |
|---|---|---|
| `code` | TEXT(6) PK | 0-999999 zero-padded |
| `created_at` | TIMESTAMPTZ NOT NULL | TTL 10 分钟,定时清理 |
| `consumed_at` | TIMESTAMPTZ NULL | confirm 后 set |
| `device_name` | TEXT NULL | confirm 时 client 填 |

Alembic 同笔迁移加。

#### 5.W.4 后端 API

新端点全在 `/api/v1/auth/*` 路径下:

**`POST /api/v1/auth/pair_initiate`** — macOS 老设备调,先验自己的 token(走现有 `require_bearer_token`)
- 入参:无
- 出参:`{"code": "123456", "expires_at": "<ISO>"}`(后端生成 6 位随机数字 0-padded,插 pair_codes 表)
- rate limit:30/min per token

**`POST /api/v1/auth/pair_confirm`** — 新设备调,**不需要现有 token**(白名单端点,仅靠 pair_code 验证)
- 入参:`{"code": "123456", "device_name": "linotsai's iPhone"}`
- 出参:`{"device_id": "<UUID>", "token": "<明文 32-byte hex,只这一次返回>"}`
- 后端:验 code 存在 + 未消费 + 未过期 → 生成新 32 byte token → encrypt + insert `device_tokens` → mark `pair_codes.consumed_at` → 返回明文 token 一次
- rate limit:更严,5/min per IP(防爆破 6 位码)

**`GET /api/v1/auth/devices`** — 列出当前所有 device_tokens(自己看)
- 出参:`[{"device_id", "device_name", "created_at", "last_used_at"}]`(不返回 token 密文)

**`DELETE /api/v1/auth/devices/{device_id}`** — revoke
- 后端:set `revoked_at = now()`;**不删行**(留审计痕)

**`auth.py::require_bearer_token`** 改造:
1. 收到 `Authorization: Bearer <token>` 后,先在 `device_tokens` 表里找匹配的 Fernet decrypt → 若找到且未 revoked,update `last_used_at` → 通过
2. 找不到 → fallback to `settings.api_token`(static)兼容 v0.8 路径
3. 都不通 → `401 unauthorized`

#### 5.W.5 前端 UI

**macOS Settings → Connection → "设备管理" 子区域**(在现有 BACKEND_URL / Token / DNS 自检之下):

- 列出当前 device_tokens(`GET /api/v1/auth/devices`)
- 每行:device_name + 创建时间 + 上次使用 + 撤销按钮
- "添加新设备" 按钮 → 调 `pair_initiate` → 弹出对话框:
  - 显示 6 位短码大字体
  - QR 码占主要篇幅
  - "复制 URL + 码" 按钮(给作者 iMessage / 隔空投送到 iPhone)
  - 倒计时(10 分钟)

**iOS 启动屏(无 token 时,替换现有 SettingsView Connection 红 banner)**:
- "扫描 macOS 上的配对码" 主按钮 → 调相机权限 → 扫 QR → 解析 + 自动 `pair_confirm` → ready
- "手动输入" 备选 → 表单:BACKEND_URL(默认填好)+ 6 位短码 + 可选 IP override
- 提交 → 调 `pair_confirm` → 写 Keychain → ready

**iOS Settings → Connection 同样有 "设备管理" 区域**(但 iOS 只能显示自己 + 调撤销;"添加新设备" 仅 macOS 才有,iPhone 不当配对源,简化 UX)

#### 5.W.6 接口契约改动总结

| 文件 | 改动 |
|---|---|
| `Backend/app/models/device_token.py`(新) | SQLAlchemy model |
| `Backend/app/models/pair_code.py`(新) | 同上 |
| `Backend/alembic/versions/<新>` | 加表 |
| `Backend/app/routers/auth.py`(新) | 4 个端点 + cleanup pair_codes 的后台 task / cron(开始可手动 SQL DELETE WHERE expires_at < now()) |
| `Backend/app/auth.py` | `require_bearer_token` 双路径 |
| `App/LinoWriting/Services/APIClient.swift` | pairInitiate / pairConfirm / listDevices / revokeDevice |
| `App/LinoWriting/Services/KeychainStore.swift` | 已 v0.8 per-host;v0.9 token 改 device_token 但 keychain key 仍 `api_token.<host>`(语义不变) |
| `App/LinoWriting/Views/Root/SettingsView.swift` | "设备管理" 子区域 + 添加设备对话框 + QR 显示 |
| `App/LinoWriting/Views/Root/DevicePairView.swift`(新) | iOS 启动配对屏(扫码 + 手输) |
| `App/LinoWriting/Stores/AppStore.swift` | 启动时 token 缺失走 DevicePairView 而非现有 banner |

#### 5.W.7 风险与 open question

- **配对码爆破**:6 位数字暴力 = 1M 组合。10 分钟 TTL + 5/min per IP rate limit = 攻击者每 10 分钟最多 50 次尝试;期望命中需要 ~20000 个 10 分钟窗口(1.3 年)。**够安全**。若想再加固,加配对码失败 5 次后整条 IP 锁 30 分钟
- **QR 码内嵌 short code 信任问题**:配对码本身有效期 10 分钟。QR 截图被 leak 也只在窗口内有效。**风险可接受**
- **`pair_confirm` 是白名单端点(无 Bearer)** 会不会成为 DoS / 信息泄漏入口:返回信息少(只 "code valid" 或 "code invalid"),且 rate limit per IP 控住。OK
- **多设备同时配对**:`pair_initiate` 可生成多个并存(每个 10 分钟独立 TTL)。无冲突
- **`device_name` 来源**:iOS `UIDevice.current.name` 在 iOS 16+ 默认返回 "iPhone"(privacy 改),拿不到真名 "linotsai's iPhone"。用户手输 fallback 必须存在
- **Keychain access group**:bundle ID 不变 → keychain access group 不变 → 与 v0.8 兼容

#### 5.W.8 验收标准

- pytest 新增 ≥ 12 测试:
  - pair_initiate → 短码 6 位数字
  - pair_confirm valid code → 返回 token + 表里新 row
  - pair_confirm wrong code → 401
  - pair_confirm consumed code → 401
  - pair_confirm expired code → 401
  - device-token Bearer 路径通过 require_bearer_token
  - revoked device token 拒
  - static api_token fallback 仍工作(向后兼容)
  - rate limit 命中 → 429
- macOS:Settings 显示自己 device,生成配对码,撤销自己后立即 401(自废,作者要重启 LinoI 走 pair_confirm)
- iOS Simulator(无相机)走手输短码路径全程跑通
- iOS 真机扫 macOS 的 QR(作者本人验)

---

### 5.X TestFlight + macOS Developer ID + notarize 🎯 **v0.9 必修**(原 §5.V 重启)

#### 5.X.1 动机

作者 2026-05-26 决定注册 Apple Developer Program($99/年个人版),解锁:
- iOS 签名证书 7 天 → 1 年(告别每周 Xcode→Run re-sign)
- TestFlight 内测分发(自己 iPhone + iPad 自动 OTA,无需 USB 连)
- macOS Developer ID Application cert + notarize(取代 v0.8 ad-hoc,带去任何 Mac / 朋友机器都直接打开)
- App Intents / Siri Shortcuts 在真机长期稳定(7 天 re-sign 限制消失)

§5.V 历史决策(永久不做 TestFlight)**正式 supersede** -- v0.9 X phase 接管。

#### 5.X.2 设计决策

| 决策点 | 选择 |
|---|---|
| Developer Program 类型 | $99/年 Individual(作者邮箱注册)。**不要** Enterprise $299/yr(那是给企业内分发,App Store + TestFlight 都不通) |
| Bundle ID | **沿用 `com.lino.linowriting.LinoWriting`**(v0.6 / v0.7 / v0.8 ad-hoc 一致,Keychain 数据连续不丢) |
| Code signing iOS | `project.yml`:`CODE_SIGN_STYLE: Automatic` + `DEVELOPMENT_TEAM=<10 位 Team ID>`,Xcode 自动管 provisioning profile |
| Code signing macOS | 两路并存:**dev path** 保留 `CODE_SIGNING_ALLOWED: NO` ad-hoc(作者本机快速 iter);**release path** 新加 Developer ID Application cert + notarize(`./scripts/release-macos.sh`) |
| Apple credentials 存储 | Apple ID + App-Specific Password 走 `xcrun notarytool store-credentials` 入 mac Keychain(profile name = `LinoI-deploy`);release 脚本调 `--keychain-profile LinoI-deploy`,不读 env var 不入 git |
| TestFlight build 上传 | `xcodebuild archive` → `xcodebuild -exportArchive` → `xcrun altool --upload-app -t ios` (新 API 是 `xcrun notarytool` for Mac,`xcrun altool` 仍是 iOS path) |
| TestFlight metadata | App name `LinoI` / short description "LLM-assisted novel writing" / test notes "登录用 macOS 生成的配对码"(自用 + 配对认证流程) |
| iOS deployment target | 暂保 17.0(v0.8 验证过 iPhone iOS 26.5 兼容);BB phase 若入则升 18.1 |
| 真机直装 UDID | TestFlight 路径 **不需要 UDID**(internal testers 走 TF beta channel,Apple 自管 profile)。**作者若想 archive 直装到自己 iPhone 不走 TF**(快迭代用)才需 UDID;X-3 完成后 TF OTA 即可 |

#### 5.X.3 自动化脚本

**`App/scripts/release-macos.sh`**(新文件):
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project LinoWriting.xcodeproj -scheme LinoWriting-macOS \
    -destination 'platform=macOS' -configuration Release clean build
BUILT=/Users/linotsai/Library/Developer/Xcode/DerivedData/LinoWriting-*/Build/Products/Release/LinoI.app
codesign --force --deep --options runtime --timestamp \
    --sign "Developer ID Application: <作者注册名>" "$BUILT"
xcrun notarytool submit "$BUILT.zip" --keychain-profile LinoI-deploy --wait
xcrun stapler staple "$BUILT"
rm -rf ~/Desktop/LinoI.app && cp -R "$BUILT" ~/Desktop/LinoI.app
echo "deployed $(plutil -p ~/Desktop/LinoI.app/Contents/Info.plist | grep ShortVersion)"
```

**`App/scripts/release-ios.sh`**(新文件):
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
ARCHIVE=$(mktemp -d)/LinoI.xcarchive
xcodebuild -project LinoWriting.xcodeproj -scheme LinoWriting-iOS \
    -destination 'generic/platform=iOS' -configuration Release \
    -archivePath "$ARCHIVE" archive
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportPath "$(dirname "$ARCHIVE")/export" \
    -exportOptionsPlist scripts/ios-export.plist
xcrun altool --upload-app \
    -f "$(dirname "$ARCHIVE")/export/LinoI.ipa" \
    -t ios \
    --apple-id <作者 Apple ID 邮箱> \
    --password "@keychain:LinoI-altool-password" \
    --team-id <Team ID>
echo "uploaded to TestFlight, processing 5-30 min"
```

**`App/scripts/ios-export.plist`**(新文件):TestFlight 用的 `ExportOptions.plist`,`method=app-store`,`signingStyle=automatic`,team ID,bundle ID,uploadSymbols=true。

#### 5.X.4 project.yml 改动

```yaml
# 顶层 settings 之外加 conditional signing(只 iOS target 启用 Automatic;
# macOS target 仍可用 ad-hoc 走 dev path,release 用真签由 release-macos.sh 接管)
targets:
  LinoWriting:
    ...
    settings:
      base:
        # ... 现有的 PRODUCT_BUNDLE_IDENTIFIER 等保留
      configs:
        Debug:
          # macOS dev 仍 ad-hoc 快速 iter
          CODE_SIGNING_ALLOWED: NO
        Release:
          # iOS Release 走 Automatic;macOS Release 由 release-macos.sh 后处理
          CODE_SIGN_STYLE: Automatic
          DEVELOPMENT_TEAM: <作者 Team ID>
          CODE_SIGNING_ALLOWED: YES
```

(具体 yaml syntax 由 builder 在 X-1 phase 选;§5.X.4 仅示意。)

#### 5.X.5 接口契约

零后端契约变化。仅 `project.yml` + 新 `App/scripts/` 目录。

#### 5.X.6 风险与 open question

- **Apple Developer 注册周期**:Individual $99/年,国内开发者 1-7 天审核(账号 / 银行卡 / 发票)。**作者声明已决定注册** → X 启动等审核通过即可
- **Bundle ID 已被占用**:`com.lino.linowriting.LinoWriting` 全球唯一。**X-1 第一步**:登录 App Store Connect → Identifiers → 试注册。若占用,换 `app.lino.LinoWriting` 等,**但要在 v0.9 Z 发版前一次性切完**(中途换 bundle ID = Keychain access group 变 = 老 token 丢)
- **notarize 失败 hardening**:`--options runtime` 强制 hardened runtime,有时与某些 SwiftUI 私有 API 冲突。出 issue 时按 notarize 报告调整 entitlements
- **App-Specific Password 不入 git**:用 `xcrun notarytool store-credentials` 存 mac Keychain,profile name = `LinoI-deploy`;脚本里只引 profile name,不见明文
- **TestFlight processing 时间**:首次上传 1-2 天,后续每次 5-30 分钟。**X-4 算独立 phase** 因为 processing 期间 internal testers 收不到 OTA,但本地脚本已完成

#### 5.X.7 验收标准

- `./App/scripts/release-macos.sh` 跑通:Developer ID 签 + notarize success + stapler staple ok + `~/Desktop/LinoI.app` 在任意一台未登录作者 Apple ID 的 Mac 上双击直接打开(无 Gatekeeper "无法验证开发者" 弹框)
- `./App/scripts/release-ios.sh` 跑通:archive + export + altool upload 成功 + App Store Connect Activity 标签里看到 build 进入 "processing"
- 1-2 天后 internal tester(作者本人 Apple ID 加入 TestFlight Internal Testing 组)收到 TestFlight 推送 + 装 + 启动 LinoI iOS 跑通 W 配对流
- `project.yml` Debug + Release 两 config 各跑 `xcodebuild` clean,无 cert / profile error

---

### 5.Y iOS DNS / TLS SNI override 🎯 **v0.9 候选**(仅真机撞墙才入)

#### 5.Y.1 动机

v0.8 macOS 通过 `/etc/hosts` override 解了作者本机 DNS 被路由器 / WARP 拦截到 `198.18.16.246` 的问题。**iOS 没有 `/etc/hosts` 等价物**。

如果作者付费 + iOS 真机走 TestFlight 后,**iPhone 网络环境与开发机不同**(蜂窝 / 公司 Wi-Fi / 家用 Wi-Fi),DNS 拦截不一定撞。**Y 仅当 iOS 真机第一次连 lw.linotsai.top 撞墙才入 v0.9**;不撞就推 v1.0.x 永远不入也行。

#### 5.Y.2 设计决策(若 Y 入)

| 决策点 | 选择 |
|---|---|
| 方案选型 | **客户端层 SNI override**(NWConnection + NWProtocolTLS,手设 SNI)。不要 NetworkExtension(NEAppProxyProvider 要 Apple 审批,门槛太高) |
| Settings UI | LinoI Settings → Connection 加可选字段 "服务器 IP override"(默认空,空 = 走标准 URLSession);W 配对码 QR 也可携带 |
| 实现细节 | 写 `Services/HostOverrideURLSession.swift`:URLProtocol 子类拦截 `lw.linotsai.top` host 请求 → 在 NWConnection 上跑 HTTP/1.1(rest)或 HTTP/2(SSE);TLS SNI 显式设 `lw.linotsai.top` 即使 URL host 是 IP;cert verify policy 同样用 `SecPolicyCreateSSL(true, "lw.linotsai.top")` |
| SSE 支持 | 复杂度高:NWConnection 上的 HTTP/2 streaming 需要自己 implement event-stream 解析。**先做 REST 路径,SSE 留 v0.9.x** |
| macOS 也用? | macOS 走 hosts override 简单,Y 仅 iOS;macOS 不动 |

#### 5.Y.3 验收标准(若入)

- iPhone 真机蜂窝 / 公司 Wi-Fi 连 `https://lw.linotsai.top` 全流程 ok(健康检查 + provider keys + book CRUD + write 流)
- SSE 流(write 一章)在 host override 路径下不丢 token(可能需要 v0.9.x 才完整)

#### 5.Y.4 风险与 open question

- **NWConnection HTTP/2 SSE 自实现工作量大** -- 不在 v0.9 主菜则等 v0.9.x
- **TLS cert pinning 暂不做**:Let's Encrypt cert 即可验,无需 pin
- **可能根本不需要**:作者真机网络若不撞,Y 永远不动

---

### 5.AA App Intents / Siri Shortcuts 🎯 **v0.9 候选**

#### 5.AA.1 动机

付费 Developer 后 iPhone 真机走 TestFlight 长期稳定,App Intents API 暴露的 Siri 命令成为日常生产力可能:
- "Hey Siri,用 LinoI 开始写第 5 章"
- "Hey Siri,LinoI 今天写了多少字"
- "Hey Siri,继续上次没写完的章节"

iPhone 上手机随手喊一句就触发,比解锁找 app 快得多。

#### 5.AA.2 设计决策

| 决策点 | 选择 |
|---|---|
| 暴露的 Intent 数 | 3 个起步(write next / today stats / continue last) |
| 实现 | `App/LinoWriting/Intents/<XYZ>Intent.swift`,`struct: AppIntent` + `IntentDescription` |
| Shortcuts 集成 | 自动登记到 Shortcuts.app(`AppShortcutsProvider`) |
| 数据访问 | Intent 内调 LinoI 的 APIClient(已有,跑在 main process);无独立 sandbox |
| Siri 中文支持 | iOS 18+ Siri 支持中文 App Intents,Intent metadata 写中文 |

#### 5.AA.3 接口契约

零后端变化。前端新增 3 个 .swift 文件 + project.yml 新加 `INFOPLIST_KEY_NSAppIntentsUsageDescription` 等若需要。

#### 5.AA.4 验收标准

- iPhone 真机 TestFlight build:Shortcuts.app 列出 3 个 LinoI 意图
- "Hey Siri 开始写下一章" 触发 → LinoI 启动 + 自动选 next 章 + 开 expand
- 跑通无中文识别问题

---

### 5.BB Foundation Models 端侧 LLM 接管 🎯 **v0.9 候选**(最大 ROI 也最大改造)

#### 5.BB.1 动机

iOS 18.1+ 提供 `FoundationModels` framework(macOS 15+ 等价待 X 启动时 verify),**Apple 自家 LLM 跑设备 NPU,免费,离线**。当前 LinoI 全部 LLM 调用(Writer / Extractor / Expander)走云后端,云后端调 OpenAI-compatible API(Grok / Claude / etc),每条 prompt token 都收费。

**BB 把 Extractor 部分活搬到端侧**(章节摘要 / 关系字段简单提取 / 角色 trait 推断),云 LLM 只跑 Writer(创造性) + Expander(结构化提示)。**预计降低 LLM 月账单 30-60%**。

#### 5.BB.2 设计决策

| 决策点 | 选择 |
|---|---|
| 接管哪些 Agent 任务 | **仅 Extractor**(章节摘要 + timeline_events 简单提取 + character_updates simple cases)。Writer + Expander **不动**(创造性 + 结构化推理仍走云) |
| iOS deployment target | **升 18.1**(作者 iPhone iOS 26.5 兼容;但 v0.8 的 simulator 矩阵需 update) |
| macOS deployment target | macOS 15+ 等价 FM API 待 X-1 启动时 verify;若不存在,**macOS 仍走云 Extractor**,BB 仅 iOS |
| Fallback 策略 | 端侧失败 / iOS < 18.1 / macOS → fallback 到云 Extractor。客户端 try-catch 包好 |
| 性能 | Apple FM 在 iPhone Pro 16+ A18 上速度 ok;iPhone 普通版 / 老 iPad 略慢但不阻断 -- 设个 30s timeout,超时 fallback 云 |
| 隐私 | 端侧跑 = 章节内容不离开设备进 Apple model(虽然 finalize 后摘要也只用于内部 timeline,不算敏感) |

#### 5.BB.3 接口契约改动

| 文件 | 改动 |
|---|---|
| `App/LinoWriting/Services/FoundationModelsClient.swift`(新) | 包 FM framework,接口跟现有 cloud Extractor 一致 |
| `App/LinoWriting/Services/APIClient.swift` | `finalize()` 增加 try-Apple-FM-first / fall-cloud 路径 |
| `Backend/app/routers/chapters.py` | 加端点 `POST /chapters/{id}/finalize_with_summary`(客户端已端侧跑完摘要,只让后端持久化 + 验) -- 或保留旧 `finalize` 端点不动,客户端跳过云 Extractor 直接 commit summary |
| iOS Info.plist | `NSPrivacyAccessedAPITypes` 等 -- iOS 18.1+ FM 需要的 privacy manifests 待 X 启动时 verify |
| Backend tests | finalize 路径加 "client-side summary provided" 分支测试 |

#### 5.BB.4 风险与 open question

- **FM API 稳定性**:iOS 18.1 才刚 GA,可能 18.2 / 18.3 API breaking change。BB 启动前 verify API 稳定承诺
- **macOS 等价 framework**:macOS 15.x 是否有 `FoundationModels`,X 启动时 grep Apple Developer doc verify。若没有,LinoI macOS 这条路 fallback 云,**只有 iOS 真机享受 BB 红利**
- **节省到底多少**:取决于作者写章节频率。每章 finalize 大约 ~1500 token in / ~500 out 走云 Extractor(以 grok-4-mini $0.20/M input + $1.20/M output 估算)= 每章约 $0.001。一月 30 章 ≈ $0.03。**节省幅度小**于我之前估计的 30-60%。除非作者已切用 Claude Opus / GPT-4o 等 premium model,否则 BB ROI 一般。**X 完成后看作者实际月账单决定**
- **工作量大**:FM API 自身学曲线 + finalize 路径改造 + fallback 路径 + 测试矩阵。**1-2 周**专注工作。**v0.9 候选最末位**

#### 5.BB.5 验收标准

- iPhone 真机(iOS 18.1+)finalize 一章:Console 看到 "Used Foundation Models" 日志,云端 agent_logs 表无对应 Extractor 记录(因为没调云)
- iOS Simulator(iOS 18.1+)同样
- macOS / iOS < 18.1 / iPad 老款:走 fallback,云端 agent_logs 有 Extractor 记录(回归测试)
- finalize 后 summary 内容质量与云 Extractor 相当(主观,作者验)

---

### 5.CC Keychain 数据保护迁移(零弹窗登录) 🎯 **v0.9.1 主菜**

#### 5.CC.1 动机

macOS LinoI 登录要"输两次密码"。`KeychainStore.swift` 用文件型 login keychain(`SecItemCopyMatching` 未设 `kSecUseDataProtectionKeychain`),macOS 对它是**交互式 ACL**;两个 item(`api_base_url` + `api_token.<host>`)各弹一次 = 两次密码。v0.9 前 ad-hoc 签名让"始终允许"永不生效(每次 rebuild 签名变 = 新 app)。付费 Developer 给了稳定签名 + `keychain-access-groups` entitlement,可切数据保护 keychain(entitlement 门控,零弹窗)。

#### 5.CC.2 设计决策

| 决策点 | 选择 |
|---|---|
| keychain 类型 | 文件型 login keychain → **数据保护 keychain**(`kSecUseDataProtectionKeychain: true` 全查询)|
| entitlement | `keychain-access-groups = $(AppIdentifierPrefix)com.lino.linowriting.LinoWriting`(`$(AppIdentifierPrefix)` 解析为 `<TeamID>.` = `HX73DFL88G.`)|
| access group | `kSecAttrAccessGroup` 显式设同上 group |
| accessible | 保持 `kSecAttrAccessibleAfterFirstUnlock`(解锁后可读,不需密码)|
| 迁移 | 一次性 `migrateFromLegacyKeychainIfNeeded()`:数据保护 keychain 没值但文件型有 → 读出(可能弹最后一次)→ 写数据保护 → **确认写成功后再删文件型**;失败保留老 item + ErrorBus |
| iOS | 本就是数据保护 keychain;加 access group 后 no-op 行为,但 entitlement 要随 Automatic signing 带上 |

#### 5.CC.3 接口契约

- 新 `App/LinoWriting/Resources/LinoWriting.entitlements`
- `App/project.yml`:LinoWriting target 加 `CODE_SIGN_ENTITLEMENTS: LinoWriting/Resources/LinoWriting.entitlements`
- `KeychainStore.swift`:`read` / `write` / `clear` 的 SecItem 字典统一加 `kSecUseDataProtectionKeychain: true` + `kSecAttrAccessGroup`;新增 migration 方法 + 在 `AppStore` 启动或 KeychainStore init 调一次
- **`Backend/`零改动**(纯前端 Keychain)
- `scripts/release-macos.sh`:codesign 重签保留 entitlement(见 §5.CC.4 风险)

#### 5.CC.4 风险与 open question

- **codesign `--force` 剥 entitlement**(本 phase 第一坑):release-macos.sh 把 Xcode 签的 "Apple Development" 重签成 "Developer ID",`codesign --force --sign X` **不带 `--entitlements` 会丢掉 entitlement**。修法:重签前 `codesign -d --entitlements - --xml <xcode 产物> > ent.plist` 抽出已签 entitlement,重签 `codesign --force --options runtime --timestamp --entitlements ent.plist --sign "Developer ID..."`。重签后 `codesign -d --entitlements - app | grep keychain-access-groups` 硬验证 entitlement 还在,再 notarize
- **get-task-allow 致 notarize Invalid**(本 phase 第二坑,X-4 实战撞到):保留 entitlement 后第一次 notarize **被拒**(`statusCode 4000`,`The executable requests the com.apple.security.get-task-allow entitlement`)。根因:X-1 Automatic signing 下 Release build 用 "Apple Development" cert 签,自带 debug 用的 `get-task-allow=true`;v0.9.1 之前 release-macos.sh 重签全剥 entitlement 顺带把它也去了 → notarize 过;现在为保 keychain-access-groups 而保留 → get-task-allow 一起留下 → 拒。修:提取后 `/usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" ent.plist` 精确剥掉,只留 keychain-access-groups / application-identifier / team-identifier(分发安全)。**通用教训:从 Apple Development 签名抽 entitlement 给 Developer ID 重签时,必须剥 get-task-allow**
- **macOS Developer ID + 数据保护 keychain**:无 provisioning profile 的 Developer ID app,access group 必须用 Team ID 前缀;macOS 10.15+ 支持。若实测数据保护 keychain 在 Developer ID 下不工作(极少数边界),fallback 是保留文件型 keychain 但靠稳定签名让"始终允许"生效(一次点击后永久,因为签名稳定了)
- **迁移读不到老 token**:若作者历史上点过"拒绝",老 item 读不出 → migration 静默跳过 → AppStore banner 让作者在 Settings 重填一次 token(写直接进数据保护 keychain)
- **notarize hardened runtime + keychain-access-groups**:两者兼容,无冲突

#### 5.CC.5 验收标准

- macOS:`release-macos.sh` 出的 notarized 0.9.1,`codesign -d --entitlements - ~/Desktop/LinoI.app` 能看到 `keychain-access-groups`;首次启动迁移(最多一弹)后,**退出重开 0 弹窗**;`spctl --assess` 仍 accepted
- iOS Simulator + 真机:配对 / 读 token 正常,无回归
- macOS XCTest 132 + iOS XCTest 50 不回归(KeychainStore 改动若破坏现有测试需修)
- 作者主观:macOS LinoI 冷启动不再要密码

#### 5.CC.6 v0.9.2 回退(Plan A)——CC 方案整体撤销

> v0.9.1 上线后 **app 直接打不开**(macOS Finder「应用程序"LinoI"无法打开」),reviewer 体检定位根因,作者拍板走 **Plan A 整体回退**,以 v0.9.2 发布。

**根因链**:`keychain-access-groups` entitlement → Xcode Automatic signing 为带 entitlement 的 target **嵌入一个设备锁定的 development provisioning profile**(`embedded.provisionprofile`)→ release-macos.sh 用 **Developer ID** 证书重签,证书类型与嵌入的 development profile **不匹配** → 运行时 **AMFI 拒绝 launchd 启动进程**(`open` 报 `RBSRequestErrorDomain Code=5` / `NSPOSIXErrorDomain Code=163`)。**致命陷阱:notarize Accepted + `spctl --assess` accepted 都过,但 app 仍打不开** —— 公证只验签名/notary 票据,不验 provisioning profile 与证书的类型一致性,所以全程没有任何红灯,直到双击。

**为什么 v0.9.1 全部测试 + 公证都没拦住**:XCTest / notarize / spctl 没有一个会真正 `open` 这个 app。**通用教训(已固化进 CLAUDE.md):Developer ID 分发的 app 必须以真机 `open` 验证能启动,绝不能只看 notarize/spctl 结论。**

**Plan A 回退内容**:
| 撤销项 | 回退到 |
|---|---|
| `KeychainStore.swift` | `git checkout 371f9e4` 回 v0.9 文件型 login keychain(无 `kSecUseDataProtectionKeychain` / 无 access group / 无 migration)|
| `AppEnvironment.swift` | 移除 `migrateFromLegacyKeychainIfNeeded()` 调用 |
| `LinoWriting.entitlements` | 回 v0.9 内容(sandbox + network.client + files.user-selected),且 **project.yml 不再引用它**(休眠文件)|
| `project.yml` | 删 `CODE_SIGN_ENTITLEMENTS` 行(profile 嵌入的根源);保留 Automatic signing + DEVELOPMENT_TEAM + ENABLE_HARDENED_RUNTIME |
| `release-macos.sh` | codesign 段:① 重签前 strip `Contents/embedded.provisionprofile`(防御)② 重签 **不带 `--entitlements`**(Plan A 无自定义 entitlement)③ 重签后硬验证「无 get-task-allow + 无 embedded.provisionprofile」|
| `KeychainStoreMigrationTests.swift` | 删除(v0.9.1 产物)|

**"两次密码"真根因再认识**:不是文件型 keychain 本身的错 —— 是 **ad-hoc 签名让 macOS「始终允许」永不持久**(每次 rebuild 签名变 = 新 app 身份 = ACL 重置)。付费 Developer 的**稳定 Developer ID 签名**已让「始终允许」点一次就永久生效,所以文件型 keychain + 稳定签名 = 一次点击后零弹窗,**无需** entitlement / 数据保护 keychain。CC 方案是用错了工具解对的问题。

**验证**:macOS 132 + iOS 50 XCTest 过;macOS 0.9.2 notarize Accepted + stapler OK + **无 embedded profile + 无 get-task-allow**;**`open ~/Desktop/LinoI.app` exit 0 + 进程真起来(无 AMFI/POSIX 163)= 启动回归已修**;HZ `{"status":"ok","version":"0.9.2"}`;iOS 0.9.2 上 TestFlight(`No errors uploading archive`)。

---

### 5.DI 导入/提取解耦 🚧（v0.9.3）

#### 5.DI.1 设计原则

- **导入只负责落地正文**：把作者贴入的整章正文存成 `finalized` 章节，**不触碰任何 LLM**，因此永远成功（只可能传输层失败）。
- **提取是独立的、手动触发的二次动作**：章节落地后，作者在工具栏点「提取角色/时间线」才跑 ExtractorAgent。提取失败只提示，**绝不动已落地的正文 / 章节状态**。
- 这条取代 §5.A 里「import 默认 run_extractor=true、一步到位」的旧行为。`ChapterImportRequest.run_extractor` 字段**保留**（后端仍支持），前端改为**始终传 `false`**。

#### 5.DI.2 后端契约：`POST /api/v1/chapters/{chapter_id}/extract`

- **认证**：`require_bearer_token`（同其余端点）。
- **依赖**：`llm = Depends(get_extractor_llm_client)`（与 `/import`、`/finalize` 同一 extractor key 路由）。
- **请求体**：无（空）。
- **前置校验**：
  - `_get_chapter`（缺则 404）。
  - `ensure_chapter_status(chapter, {"finalized"}, "extract")` —— 只对**已落地**章节提取；非 finalized → 409 i18n_conflict。
  - `(chapter.draft_text or "").strip() == ""` → 抛新错误码 `no_draft_to_extract`（409，中文「本章没有正文可提取」）。
- **行为**（顺序）：
  1. `db.execute(delete(TimelineEvent).where(TimelineEvent.chapter_id == chapter.id))` + `db.flush()` —— **先清本章旧时间线事件**，保证重复点「提取」不堆重复事件（镜像 `/reopen` 的清理；live_fields 由新 extractor 输出覆盖即可）。
  2. `book = _get_book(...)`；`context = build_extractor_context(db, book, chapter)`。
  3. `try`: `ExtractorAgent(llm).extract(context)` → `apply_extractor_output(db, chapter, output)` → `log_agent_call(agent_name="extractor", ...)` → `db.commit()`。
  4. `except (LLMError, AppError, ValueError)`: `db.rollback()`（**正文/状态本就没改，安全**）→ 记一条 error 的 `agent_logs` → `db.commit()` → 是 AppError 直接 raise，否则 `raise i18n_upstream("llm_generic", retryable=..., detail=...)`。
- **响应**：`{ "chapter": ChapterRead, "updated_character_ids": [...], "added_event_ids": [...] }`，与 `/finalize`、`/import` 同款 envelope。
- **状态**：成功后章节仍是 `finalized`（不改状态，只回写角色卡 live_fields + 时间线）。
- **无 Alembic 迁移**。

#### 5.DI.3 前端改动（文件级）

- **`Services/APIClient.swift`**：Protocol + 实现加 `func extractChapter(id:) async throws -> ChapterImportResponse`（POST `/api/v1/chapters/{id}/extract`，无 body，复用 `ChapterImportResponse` 解码——shape 一致）。镜像 `finalize` / `reopen` 的无 body POST 写法。
- **`Services/MockAPIClient.swift`**：加 `extractChapter` + `onExtract` 钩子。
- **`Stores/ChapterEditorStore.swift`**：加 `@Published private(set) var isExtracting`（并入 `resetAllPublishedToIdle()` 清零）；加 `func extract() async -> ChapterImportResponse?`，镜像 `finalize()`：置 `isExtracting`、调 `api.extractChapter`、成功写 `self.chapter` + `self.lastUpdatedCharacterIds`、失败 → ErrorBus。
- **`Views/Workspace/Editor/ChapterToolbar.swift`**：`chapter.status == .finalized` 时显示「提取角色/时间线」按钮（与「重新打开」并列），点击 → `extract()` → 成功后 `chaptersStore.upsert` + `charactersStore.markUpdated` + 非空则 `charactersStore.load(bookId:)`；`isExtracting` 时 disable + spinner。
- **`Views/Workspace/Sidebar/NewChapterSheet.swift`**：
  - **布局**：body 拆成「固定头部（标题 + 模式 Picker）+ ScrollView（模式字段）+ 固定底部 footer（取消 / 提交）」；footer 在 ScrollView 外，任何窗口高度恒可见。给 sheet 设合理 `maxHeight`（或让 footer 钉死）。
  - **导入解耦**：删掉 import 模式的「导入后让 Agent 提取」Toggle 与相关 `runExtractor` 状态，换成提示「导入只保存正文；之后可在工具栏点「提取」更新角色卡 / 时间线」。`submitImport` / `submitBatch` 一律 `runExtractor: false`。
  - **健壮性**：`submitImport` trim `draftText`；`importChapter` 返回 nil（失败）时 `await chaptersStore.delete(id: new.id)` 删掉第①步空骨架 + `chapterEditorStore.reset()` 清编辑器，sheet 保持打开供重试。
- **`Views/Workspace/Editor/ImportChapterSheet.swift`**（工具栏进入既有章节的导入）：同样的 footer/scroll 布局修复；删 `runExtractor` Toggle，导入一律 `run_extractor=false`。

#### 5.DI.4 测试

- 后端 pytest（DI-1）：① finalized + draft_text + mock extractor → 200，返回 ids、建 timeline；② 连点两次提取 → 时间线不重复（先删后建）；③ 非 finalized（draft/draft_ready/writing）→ 409；④ finalized 但空 draft_text → 409 `no_draft_to_extract`；⑤ extractor LLM 抛错 → 错误透出 + 正文/状态保留。
- 前端 XCTest（DI-2/DI-3）：`ChapterEditorStore.extract()` happy + failure（MockAPIClient `onExtract`）；`submitImport` 失败删空骨架（store mock 验证）；现有 `ChaptersStoreImportTests` 改成 `run_extractor=false` 期望。

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

### [2026-05-25] Phase C-tl 实施(TimelineEvent 编辑 + 删除)

- 变更内容:
  - **后端**
    - **alembic `202605250003_add_timeline_event_edited_at.py`**:`timeline_events` 加 `edited_at TIMESTAMPTZ NULL`(无 server_default,故意保留 NULL 区分 Agent 原始行)。downgrade drop。
    - **`Backend/app/models/timeline_event.py`**:`Mapped[datetime | None] edited_at`。
    - **`Backend/app/schemas/timeline.py`**:`TimelineEventRead.edited_at: UtcDatetime | None = None`;新增 `TimelineEventPatch`(`event_text` 可选 + `event_type` 可选 + `@model_validator(mode='after')` 强制至少一个 → 否则 ValueError → 422)。
    - **`Backend/app/routers/timeline_events.py`**(新建):`PATCH /api/v1/timeline_events/{id}` + `DELETE /api/v1/timeline_events/{id}`。沿用 chapters/characters 的二层白名单模式(`PATCHABLE_TIMELINE_EVENT_FIELDS = frozenset({"event_text", "event_type"})`)。PATCH 写 `edited_at = utc_now()`、不允许改 character_id / chapter_id。返回 `TimelineEventRead` 时 JOIN `chapter.index` 拿 `chapter_index`(同 characters timeline 路径)。DELETE 物理删除返 204。
    - **`Backend/app/routers/characters.py`**:`GET /characters/{id}/timeline` 输出加 `edited_at` 字段(列表 read-back 一致性)。
    - **`Backend/app/main.py`**:挂载 `timeline_events.router`。
  - **前端**
    - **`Models/TimelineEvent.swift`**:`editedAt: Date?`(`edited_at` snake_case)+ 自定义 `init(from:)` 用 `decodeIfPresent` 兜底 pre-v0.7 缓存(同 `Chapter.source` / `Character.authorNotes` 套路);新增 `TimelineEventPatchRequest`(eventText / eventType 可选 + snake_case CodingKeys)。
    - **`Services/APIClient.swift`**:Protocol + 实现新增 `updateTimelineEvent(id:eventText:eventType:)` + `deleteTimelineEvent(id:)`。错误走 ErrorMapping。
    - **`LinoWritingTests/MockAPIClient.swift`**:同步 mock,update 时本地 `editedAt = Date()`,delete 时移除并清理 timelineEvents。
    - **`Stores/TimelineStore.swift`**:`@discardableResult updateEvent(id:eventText:eventType:)` + `deleteEvent(id:)`。成功时把服务器返回的 row 原地 swap(`editedAt` 立即可见,不用 reload);失败 publish 到 ErrorBus,本地不优化乐观。
    - **`Views/Workspace/RightPanel/TimelineTabView.swift`** 整体改写:`TimelineEventRow` 子 View 持有 `@State isHovered` + `@FocusState editorFocused` + `@State draft`。双击 eventText → 进入 `TextEditor` inline 编辑(只单条,父 View 持 `editingEventId`);Enter(onSubmit)保存;失焦(onChange editorFocused → false)自动保存;**macOS** Esc(`.onExitCommand`)取消。`editedAt != nil` 时在 caption 行加灰色 "已编辑" 胶囊。**macOS** hover 显示右侧 `xmark.circle.fill` 删除按钮(`.transition(.opacity)`);**iOS** 用 `.swipeActions(.trailing)`。点删除 → 父级 alert "删除这条事件?\n该操作不可撤销。",确认走 `timelineStore.deleteEvent`。
  - **测试**:
    - 后端 `tests/test_timeline_events.py` 新增 12 个(PATCH text/type/empty 422/disallowed-fields/404/401/invalid-type 422 + 白名单常量守护 + DELETE 成功+消失/404/401 + 列表回读 edited_at)。
    - 前端 `LinoWritingTests/TimelineEventEditTests.swift` 新增 7 个(updateEvent 成功 swap / 失败保原 + deleteEvent 成功 / 失败保原 + Codable edited_at 解码 + 缺失 fallback + PatchRequest snake_case)。
- 变更原因:v0.6 已知残留 todo #2(§3 C)— TimelineEvent 此前只读,Extractor 出错或细节不准时作者只能干瞪眼。本次按 §5.C 详案给出最小可用编辑/删除能力 + edited_at 审计标记。
- 影响范围:Phase C-tl 全部落地;新增 2 后端文件(1 migration + 1 router)+ 3 修改(model / schema / characters timeline 输出 / main.py);前端新增/修改 5 个文件(TimelineEvent.swift / APIClient.swift / MockAPIClient.swift / TimelineStore.swift / TimelineTabView.swift)+ 1 新增测试文件。不动 M-2 / L-2 / L-3 / P 系列已 commit 内容。
- 关键判断:
  - **未引入 `updated_at` 列**:plan §5.C.2 只提 `edited_at`;子项清单顺手提的 "event.updated_at 同步" 在 TimelineEvent 模型上没有对应列(原 schema 只有 created_at)。新增 `updated_at` 会变成 schema 层 churn 且不在 §5.C.2 设计决策里,故只加 `edited_at` 单字段。如有需要,后续 phase 显式加。
  - **inline 编辑触发 = 双击**:沿用 macOS 文本表格惯例(对比 InlineEditableText 是单击 — 但 TimelineEvent 行还要承担"双击进入编辑 vs 单击选行"的语义,而且 hover 已经有视觉响应,单击编辑会被误触)。
  - **"已编辑" 标记位置**:与第 N 章 / 事件类型同行的 caption 区,小灰胶囊 + `.help("这条事件被用户改过")`。不放在事件文本下方避免行变高、错位 hover 删除按钮。
  - **删除确认 alert 文案**:"删除这条事件?" / "该操作不可撤销。"(对齐 CharacterCardListView 删除角色的语气,但更短 — timeline 事件粒度比角色卡更细,文案不需要列副作用)。
  - **失败不优化乐观**:PATCH/DELETE 失败时本地 list 保持原样,inline 编辑 view 由 `editingEventId` 在 onCommit 时主动复位(若需要重试,作者重新双击即可);删除若失败,行仍在,作者可重试。这是为了让 ErrorBus 的 toast 与 UI 状态一致,而不是"看到没了但其实没删"。
  - **iOS 兼容性**:`onExitCommand` / `onHover` macOS-only。inline 编辑器抽到 `private var editor: some View` `@ViewBuilder` 内做平台分支,iOS 走 swipe action;两个平台都靠 onChange(editorFocused) 的失焦兜底保存。`xcodebuild build -destination 'generic/platform=iOS'` 通过。
- 测试基线:v0.7 L-3 末 51 XCTest → C-tl 末 68 XCTest(51 baseline + 7 TimelineEventEdit + 10 之前 M-2 已加但记账漏掉的 per-agent active slot 测试)。后端 124 pytest → 136 pytest(124 baseline + 12 timeline_events 新)。`pytest -W error` 干净,`xcodebuild build`(macOS + iOS)+ `xcodebuild test`(macOS)全过。
- 未做:v0.6 旧债 B(字段级 dot indicator) / D(Admin Log Panel UI);M-2 / N / F / O / Q 等其它 v0.7 项。

### [2026-05-25] Phase M-2 多 LLM per-Agent 前端实施

- 变更内容:
  - **`Models/ProviderKey.swift`**:
    - 新增 `enum AgentRole: String, Codable, CaseIterable, Sendable, Hashable { case writer, extractor, expander }`,自带 `displayName`(中文 UI 文案)。
    - `ProviderKey` 加 `agentRole: AgentRole?`(nil = 通用键 / v0.6 行为);自定义 `init(from:)` 用 `decodeIfPresent ?? nil` 兜底 pre-M-1 缓存 / 老后端 payload,沿用 §5.A.6 `Chapter.source` fallback 模式。
    - `ProviderKeyCreate` 加 `agentRole: AgentRole? = nil`(默认通用)。
    - `ProviderKeyUpdate.agentRole` 用**三态 enum `AgentRoleUpdate`**(`.untouched` / `.set(AgentRole)` / `.clear`)而非裸 `Optional<AgentRole>`,自定义 `encode(to:)` 把三态映射到 "省略键 / emit value / emit JSON null",对齐后端 `exclude_unset` 区分"未传"vs"传 null 清回 generic" 的语义。改 `ProviderKeyUpdate` 从 `Codable` 降为 `Encodable`(代码里只 encode,decoding 不需要)。
    - 新增 `ActiveAgentKeyRead`(`agent_role / active_provider_key_id / key_label / provider_hint / model_name / api_key_mask`,与后端 flat shape 对齐)。
    - 新增 `ActiveAgentKeyUpdate(providerKeyId: String?)`,自定义 `encode(to:)` 把 nil emit 成 explicit `"provider_key_id": null` 而非省略(`null = 清回 generic` 是后端约定信号,绝不能让 JSONEncoder 默认行为吞掉)。
  - **`Services/APIClient.swift`**:`APIClientProtocol` 新增 2 方法 `getActiveAgentKey(agentRole:)` / `setActiveAgentKey(agentRole:, providerKeyId:)`;`APIClient` 实现 path `/api/v1/settings/active_key/{role.rawValue}`(GET + PUT),错误走既有 `ErrorMapping`(后端 409 mismatch → `AppError.conflict`)。说明:此次另一 builder 在同一文件加了 C-tl 的 `updateTimelineEvent` / `deleteTimelineEvent`,两组方法在 protocol/类内共存,无冲突。
  - **`Stores/ProviderKeysStore.swift`**:加 `@Published activeAgents: [AgentRole: ActiveAgentKeyRead]`(三个 slot 各自的 active);`reloadBoth()` 从 2 个 `async let` 扩成 5 个(list + 通用 active + 三个 per-agent);新增 `fetchActiveAgent(_:)` 私有 helper + 公开 `setActiveAgentKey(agentRole:, providerKeyId:)` mutator,后者乐观更新仅当前 slot(其它两 slot 不重渲),错误透传 ErrorBus。
  - **`Views/Root/SettingsView.swift`**:在 "LLM Providers" tab 的 keys 列表**上方**插入新 section `PerAgentActiveSection`(标题"按 Agent 分别选择(可选)"+ 副标题解释控成本场景),三行 `PerAgentRow`(Writer / Extractor / Expander),每行一个 `Picker(.menu)`,选项首项"沿用通用 active"(`tag(Optional<String>.none)`)+ 所有 `store.sortedItems` 平铺。选不兼容 key(自身 agent_role 非 nil 且与 slot 不匹配)在 label 上加 "·非 {role} 专用" 后缀提示;真正提交后后端 409 会走 ErrorBus toast。底部 keys 行加 "{role} 专用" 紫色 capsule,让用户看见 key 自身的绑定。
  - **`Views/Root/ProviderKeyEditSheet.swift`**:Form 末尾加新 Section "用途",一个 `Picker(.menu)` 4 项("通用(任何 Agent 都可用)" / Writer / Extractor / Expander 专用),帮助文字解释"绑定到某 Agent 后,该 key 只能激活到对应 slot;通用 key 可激活到任意 slot"。prefill 把 `existing.agentRole` 同步进 `@State agentRole`;submit 时与原值对比生成 `AgentRoleUpdate` 三态(未变 → `.untouched`、改某 Agent → `.set(...)`、改"通用" → `.clear`)。
  - **`LinoWritingTests/MockAPIClient.swift`**:
    - 加 `activeAgentKeyIds: [AgentRole: String?]`(三 key 都 present,nil 表示未绑);`createProviderKey` / `updateProviderKey` 接受 `agentRole`(三态 update 同样实现);`deleteProviderKey` 同步清三个 slot(对齐后端 §5.M / M-1 行为)。
    - 实现 `getActiveAgentKey` / `setActiveAgentKey`,后者复刻后端 409(key.agentRole 非 nil 且 ≠ slot → `AppError.conflict`)+ `lastSetActiveAgentPayload` 捕获 hook 给契约测试断言"nil 是否真的发到后端而不是被 JSONEncoder 吞掉"。
    - 关键修复:`reloadBoth` 现并发触发 5 个 mock 调用(2 → 5),`calls.append` / state 读没加锁会偶发触发 Swift 测试进程 "Restarting after unexpected exit"。加 `NSLock` + `locked(_:)` helper,把 list / getActive* / setActive* 五个方法包起来,真实后端"单事务串行"语义在 mock 里也成立。其它 mock 方法暂不加锁(测试里没有并发场景触发)。
  - **`LinoWritingTests/ProviderKeysStoreTests.swift` 新增 9 个测试**(在 baseline 12 上扩到 21):
    1. `test_setActiveAgentKey_writerKey_toWriterSlot_succeeds` — happy path,且 `activeAgents[.extractor/.expander]` 不被误动。
    2. `test_setActiveAgentKey_writerKey_toExtractorSlot_publishesConflict` — 后端 409 路径,断 ErrorBus 收到,slot 不被写入。
    3. `test_setActiveAgentKey_nil_clearsBackToGeneric` — 设了再清,断 store 反映 + `lastSetActiveAgentPayload.providerKeyId == nil`(契约)。
    4. `test_load_populatesAllThreeAgentSlots` — `load()` 并发 fetch 三个 slot,store.activeAgents 三 key 都 present(即便 slot 空)。
    5. `test_activeAgentKeyUpdate_nil_emitsExplicitJsonNull` — `ActiveAgentKeyUpdate(providerKeyId: nil)` 必须 emit `{"provider_key_id": null}`,绝不能省略字段(否则后端把当成"未传"保持现状,UI 与后端脱节)。
    6. `test_providerKeyCreate_agentRole_serializesAsSnakeCase` — `.writer` → `"agent_role": "writer"` snake_case round-trip,不 leak camelCase。
    7. `test_providerKeyUpdate_agentRole_triState_serialization` — 三态分别 assertion:`.untouched` 省略键 / `.set(.expander)` emit `"expander"` / `.clear` emit `null`。
    8. `test_providerKey_decoding_missingAgentRole_fallbacksToNil` — 老 payload 无 `agent_role` 字段不炸,fallback nil。
    9. `test_providerKey_decoding_withAgentRole_roundTrips` — 完整 payload round-trip。
    + 1 个 `test_activeAgentKeyRead_decoding_emptySlot` 解码契约(空 slot 仍带 agent_role)。
- 变更原因:v0.7 §5.M 主菜下半场,把 M-1 后端契约暴露给用户在 LinoI 内可视化操作。用户立即能控成本:在 Settings → LLM Providers tab 创建一把 Claude key(用途选 Writer 专用),再创建一把 Grok mini key(用途选 Extractor 专用),分别在"按 Agent 分别选择"区里激活到对应 slot,Expander 留"沿用通用"(用最便宜那把);写作流走的就是各自配的 key,后端 §5.M / M-1 端到端测试已验证此组合。
- 影响范围:Phase M-2;修改/新增前端 6 个文件(1 model / 1 service / 1 store / 2 view / 1 mock)+ 测试扩 9 个。后端、其它 stores / views、L 系列、P 系列、C-tl 全部零改动。
- 关键判断:
  - **"通用 active picker"沿用既有 radio 行内 UX,不在顶部加新 picker**:plan §5.M.2 ASCII 草图把通用 active 画成一个独立顶部 picker,但 v0.6 E-3 已落地的实现是"每个 key 行有一个 radio 圈 + ACTIVE 徽章"。保留现有 radio,只把"按 Agent 分别选择"section 作为新插入块加在 keys 列表上方。理由:① 不破坏 v0.6 用户的肌肉记忆;② radio 行内交互更接近 macOS Settings 风格;③ plan ASCII 是概念示意,不是逐字 spec。
  - **不兼容 key 在 per-agent picker 里"列出 + 加后缀提示"而非"灰显隐藏"**:plan §M-2 写"推荐:列出所有 key,但视觉上对'不兼容'key 灰显并标'非 {role} 专用'"。SwiftUI `Picker(.menu)` 没法对单个选项加 `disabled` 状态(`Menu` 才能;`Picker.menu` 渲染成系统 menu,选项一律可选)。所以选"全部列出 + 文字提示 + 让后端 409 兜底"。优点:用户能看见所有 key,误选会立刻收到中文 toast;缺点:对老练用户多走一次往返。Trade-off 取后者(代码简单 + UX 不藏选项 + 后端校验权威)。
  - **per-agent picker 默认显示"沿用通用 active"**:文案选这个而非"未选择" / "默认" / "空",理由:① 直接说明 fallback 行为(用户立刻知道这一格"沿用"上方设的通用 active);② 与后端 §5.M.3 兼容性"v0.6 用户全 NULL → fallback 通用 active"语义对齐;③ 比"未设置"更友好(后者听起来像"必须选")。
  - **`ProviderKeyUpdate.agentRole` 用 `AgentRoleUpdate` 三态 enum 而非 `Optional<AgentRole>?` 双重可选**:双重可选解释力差(外层 nil = 未传 / 内层 nil = clear 这种约定纯靠注释撑),三态 enum 自带 case name 自解释。代价:`ProviderKeyUpdate` 自己写一份 `encode(to:)`,但其它字段反正也要走 `encodeIfPresent`,负担可控。`ProviderKeyUpdate` 不再 `Decodable`(从未需要)。
  - **`ActiveAgentKeyUpdate.providerKeyId == nil` 必须 emit explicit JSON null**:这是后端 §5.M / M-1 的关键约定 — null 表示"清回 generic fallback",字段缺失表示"未传(无效请求)"。Swift `JSONEncoder` 默认对 `Optional.none` 字段会省略键(实测:走 `encodeIfPresent` 路径),所以必须自己 `encode(to:)` 调 `encodeNil(forKey:)`。这是本 Phase 最容易踩错的点,专门加了 `test_activeAgentKeyUpdate_nil_emitsExplicitJsonNull` 契约测试锁死。
  - **MockAPIClient 加 `NSLock`**:`reloadBoth` 并发数从 2 涨到 5 后,无锁的 `calls.append` / state 读写偶发触发 Swift Concurrency runtime 崩 test 进程("Restarting after unexpected exit, crash, or test timeout")。隔离运行不复现,只有完整 suite 跑才暴露 — 典型并发 bug。解法:per-call `NSLock`(只在新 / 改的 5 个 provider key 方法上加),不一刀切 mock 全文,保持对其它测试零干扰。这同时把 v0.6 隐藏的"两个 async let"潜在 race 也修了。
  - **C-tl 上条记账"10 之前 M-2 已加但记账漏掉的 per-agent active slot 测试"是误记**:M-2 此次落地才把这 9 个测试加进 ProviderKeysStoreTests(此前 baseline 是 12,不含 per-agent)。以本次实跑为准:**59 baseline → 68 末**(C-tl 写 68 实际是把 M-2 工作提前计入了)。不改 C-tl 那条 entry,只在本条里说明。
- 测试基线:M-1 后端 + L-3 前端 + C-tl 末实际 ProviderKeysStoreTests baseline 12 → M-2 末 21(其它 suite 不变,合计 **59 → 68 XCTest**,59 baseline 全过 + 9 新)。`xcodebuild build` 干净 0 error 0 warning;`xcodebuild test` 全过 0 failure(完整 suite 与单文件单跑都验证过)。
- 未做:N(错误中文模板)/ F(导出)/ O(批量导入)/ B(字段级 dot)/ D(Agent Log Panel UI)/ Q(发版同步)等 v0.7 其它项。本 Phase 只做 §5.M.2 决策中"前端"那一行(SettingsView 内"哪个 Agent 用哪个 key"的可视化操作)。
- 端到端 happy path(用户操作):
  1. Settings → LLM Providers tab → "添加" → 别名"Claude 4.5"、Provider"OpenRouter"、Model `anthropic/claude-sonnet-4.5`、API Key 粘贴 + **用途 = Writer 专用** → 添加。
  2. 再点"添加" → 别名"Grok mini"、Provider"xAI"、Model `grok-3-mini`、API Key 粘贴 + **用途 = Extractor 专用** → 添加。
  3. 列表两行 keys,各自带紫色 "Writer 专用" / "Extractor 专用" capsule。
  4. 上方"按 Agent 分别选择(可选)" section → Writer 行 picker 改为 "Claude 4.5 · anthropic/claude-sonnet-4.5";Extractor 行改为 "Grok mini · grok-3-mini";Expander 保留"沿用通用 active"(走任意一把通用 key 兜底)。
  5. 之后写章节 expand / write / finalize 时,后端 §5.M / M-1 的 Depends 各自解析到对应 key:Writer → Claude(写得好),Extractor → Grok mini(便宜),Expander → 通用 active(默认任意便宜模型)。控成本立刻起效。

### [2026-05-25] Phase B-fld 字段级 dot indicator 实施

- 变更内容:
  - **后端**
    - **`app/agents/extractor.py`** (§5.B.2):`EXTRACTOR_SCHEMA` 在 `character_updates.items.properties` 加 `patch_keys: {type: array, items: {type: string}}` 槽位;system_prompt 新增一句"对每个 character_update,请在 patch_keys 数组里列出本次 patch 修改的 live_fields 顶层 key 名"。**注意**:patch_keys 是 LLM 自报告,服务端**不信任**,以下游 `live_fields_patch.keys()` 为权威(plan §5.B 兜底)。
    - **Alembic 迁移 `202605260001_add_character_pending_field_highlights.py`**(顺接 C-tl 的 250003):`characters` 加 `pending_field_highlights JSON NOT NULL DEFAULT '{}'`(PostgreSQL JSONB,SQLite plain JSON,沿用 L-1 同款 `sa.JSON().with_variant(JSONB)` 模式)。`server_default '{}'` + 防御性 `UPDATE ... WHERE IS NULL` 双保险回填存量行。downgrade 写 `drop_column`。
    - **`app/models/character.py`**:加 `pending_field_highlights: Mapped[dict[str, Any]]`,`MutableDict.as_mutable(json_dict_type)` + `default=dict, nullable=False`,与 frozen/live/author_notes 完全对齐。
    - **`app/schemas/character.py`**:`CharacterRead` 加 `pending_field_highlights: dict[str, Any] = Field(default_factory=dict)`。**`CharacterPatch` 不暴露此字段** — 清除是 PATCH live_fields 的服务端 side-effect,不是单独 PATCH 路径(plan §5.B 选了"通过现有 PATCH 自动清除"而非加专用端点 — 自然语义更优)。
    - **`app/services/extractor_apply.py`**:在 `apply_extractor_output` 的 `character_updates` 循环中,**合并(不覆盖)**写入 `pending_field_highlights`:`existing_highlights = dict(character.pending_field_highlights or {}); for key in patch.keys(): existing_highlights[key] = utc_now().isoformat(); character.pending_field_highlights = existing_highlights`。**关键判断**:用 `patch.keys()` 而非 `output.get("patch_keys")` 作为 source of truth(plan §5.B 兜底:"LLM 撒谎时以 patch.keys() 为权威")。合并而非覆盖,让多章未看的红点累积保留。
    - **`app/routers/characters.py`** PATCH 端点:在原 `for key, value in dumped.items(): setattr(...)` 后追加 highlights 自动清除块:`if "live_fields" in dumped and isinstance(dumped["live_fields"], dict): existing_highlights = dict(character.pending_field_highlights or {}); for key in dumped["live_fields"].keys(): existing_highlights.pop(key, None); character.pending_field_highlights = existing_highlights`。**关键判断**:只在 PATCH live_fields 时清除;PATCH frozen_fields / author_notes 不动 highlights(Extractor 只写 live_fields,所以 frozen/author 永远不会有 highlight)。语义自然(plan §5.B.2 "用户编辑该 field 后 PATCH 清掉")。
    - **`tests/test_field_highlights.py`** 新增 10 个测试:
      1. Extractor 跑完 → character.pending_field_highlights 有对应 key 与 ISO 时间戳(端到端)
      2. 旧 highlights 与新 highlights 合并(seed 旧 + 跑 Extractor → 两个 key 都在)
      3. PATCH live_fields 清除所有现有 highlights(全 keys 在 payload 里)
      4. PATCH live_fields 部分 keys 只清除被 patch 的,未提及的 key 仍 highlighted
      5. PATCH frozen_fields 不动 highlights
      6. PATCH author_notes 不动 highlights
      7. LLM 自报告 patch_keys 与 actual patch.keys() 不一致 → 服务端以 patch.keys() 为权威(直接驱动 `apply_extractor_output`,bypass LLM mock)
      8. 老 character(ORM 默认 + 迁移 server_default)pending_field_highlights 读出来 `{}`
      9. schema lock:`EXTRACTOR_SCHEMA["properties"]["character_updates"]["items"]["properties"]` 含 `patch_keys`
      10. CharacterPatch 不暴露 `pending_field_highlights`(防未来契约漂移)
  - **前端**
    - **`Models/Character.swift`**:`Character` 加 `pendingFieldHighlights: [String: String]`(key→ISO 时间戳字符串);CodingKeys `pendingFieldHighlights = "pending_field_highlights"`;自定义 `init(from:)` 用 `decodeIfPresent ?? [:]` 容错 pre-B-fld 缓存(沿用 §5.A.6 `Chapter.source` / §5.L.1 `Character.authorNotes` 模式)。`CharacterCreateRequest` / `CharacterPatchRequest` **不**暴露此字段(契约:服务端 only,清除是 PATCH live_fields 的 side-effect)。
    - **`Views/Components/InlineEditableText.swift`** + **`InlineEditableDict.swift`** + **`InlineEditableTags.swift`**:加 `showHighlight: Bool = false` init 参数;label HStack 内 `if showHighlight { DotIndicator().help("Agent 在最近一次完成时改动过这个字段") }`。tags 也加上是因为 goals / secrets_known / abilities / relationships 都是 live_fields 子键,Extractor 可改这些。
    - **`Views/Workspace/RightPanel/CharacterCardEditorView.swift`**:`liveTextRow` / `tagsRow` / `relationshipsRow` 渲染时检查 `character.pendingFieldHighlights[spec.key] != nil` 并通过 `showHighlight:` 传入。新增私有 helper `isLiveFieldHighlighted(_ key: String) -> Bool`。**frozen 区与 author_notes 区不显示**(plan 明文,Extractor 不动这两区)。卡片顶部红条文案保留为"卡片级 legacy 提示",但只看 `pendingHighlightIds`(immediate post-finalize)— 不与字段级红点视觉重复。
    - **`Stores/CharactersStore.swift`**:**保留** `pendingHighlightIds` 作为 fallback;新增 helper `cardHasPendingHighlight(_ character) -> Bool` 综合两个信号(legacy id set OR 字段级 dict 非空)。
    - **`Views/Workspace/RightPanel/CharacterCardListView.swift`**:Picker 菜单内角色名旁的小红点改用 `charactersStore.cardHasPendingHighlight(c)`,使字段级 highlights 也驱动选择列表的卡片级红点。
    - **`LinoWritingTests/CharacterFieldHighlightsTests.swift`** 新增 7 个测试:
      1. `Character` 解码 `pending_field_highlights` 存在 → 拿到 keys 与时间戳
      2. `Character` 解码 `pending_field_highlights` 缺失 → fallback `[:]`(legacy payload)
      3. `Character` 完整 round-trip 保 `pending_field_highlights` snake_case
      4. `CharacterPatchRequest` **不** emit `pending_field_highlights`(契约 lock,防未来误加)
      5. `CharactersStore.cardHasPendingHighlight` 字段级非空 → true
      6. `CharactersStore.cardHasPendingHighlight` 仅 legacy `pendingHighlightIds` 含 id → true
      7. `CharactersStore.cardHasPendingHighlight` 两信号都空 → false
- 变更原因:v0.6 残留 todo #1(§3 B)— v0.5/v0.6 是"卡片级红点",粒度太粗,作者看不出 Agent 改了哪个字段。本 Phase 按 §5.B 详案做到字段级,与 L-1 author_notes 私域边界严格隔离(Extractor 仍不投喂 author_notes 给上下文,B-fld 也只针对 live_fields)。
- 影响范围:Phase B-fld 全部落地;后端新增/修改文件 6 个(1 migration + 1 agent + 1 model + 1 schema + 1 service + 1 router + 1 test);前端新增/修改文件 6 个(1 model + 3 component + 1 store + 2 view + 1 test)。不动 L-1/L-2/L-3/M/P/C-tl/N 已 commit / WIP 内容。
- 关键判断:
  - **服务端兜底 patch.keys() vs LLM 自报告 patch_keys**:plan §5.B 明文要求,选 `patch.keys()` 为权威。这避免 LLM 在 patch_keys 撒谎(列了但 patch 没改 / 改了但 patch_keys 漏报)而污染 highlights。schema 槽位仍保留,允许未来 LLM 自描述并扩展到"嵌套 key 路径"而无契约变更。专门加测试 #7 锁这条不变量。
  - **自动清除 vs 专用端点**:plan §5.B.2 文字提了两种方案("用户编辑该 field 后 PATCH 清掉" / "专用清除端点")。**选自动清除**:① 用户编辑 live_fields 时已经走 PATCH,自然语义;② 不增加新端点降低契约面;③ 前端 InlineEditable 行的 onCommit 不必额外发请求,服务端 round-trip 后 Character.pendingFieldHighlights 已无该 key,UI 红点自然消失。**判断点**:只有 live_fields PATCH 触发清除(frozen/author_notes 不触发) — Extractor 只写 live_fields,这是闭环对称。专门加测试 #5/#6 锁 frozen/author_notes PATCH 不动 highlights。
  - **合并 vs 覆盖 highlights**:plan 明文"合并旧 highlights,让用户多章未看的红点累积保留"。决策点是当 chapter A 让 `current_status` 亮,chapter B 让 `knowledge` 亮,用户都没编辑过 → 应同时看到两个红点。专门加测试 #2 锁这条。
  - **卡片级 legacy 机制保留 + 综合 helper**:plan 提"保留作为 fallback"。我没有删除 `pendingHighlightIds`(否则会破坏 finalize 后"刚刚改了哪几个角色"的即时信号 — 该信号来自 `FinalizeResult.updatedCharacterIds`,后端 list reload 之前 view 已经响应)。同时新增 `cardHasPendingHighlight` helper 让 list/picker 一处调用 OR 两信号,字段级 dict 非空也能让卡片级红点亮。这让 v0.6 行为与 v0.7 字段级行为**叠加不冲突**:legacy 在 user 点开卡片后(`select` clear `pendingHighlightIds`)消失,字段级在 user 编辑该字段后(server 自动清除)消失。
  - **三个 InlineEditable 组件都加 showHighlight**:`InlineEditableTags` 也加上,理由是 live_fields 里 goals / secrets_known / abilities / relationships 都是数组/字典型 — Extractor 一旦碰这些就需要 dot。这避免"只在 string 字段亮红点,数组字段沉默"的不一致。
  - **author_notes 区与 frozen 区显式不显示红点**:plan 严禁动 author_notes 私域边界。CharacterCardEditorView 内 `frozenTextRow` / `authorNoteTextRow` 不接 `showHighlight`(走 default false),确保即便用户绕开 schema 强塞个 highlight 也不会渲染 — 双保险。
  - **`pendingFieldHighlights` 类型 = `[String: String]`** 而非 `[String: Date]`:JSONDecoder 已为 Date 配 ISO 处理,但选 String 是因为这字段从未被前端做"时间运算"(我们只关心 key 存在与否),后端发什么字符串前端就保什么。Round-trip 安全,wire format 透明。
- 测试基线:
  - 后端 v0.7 C-tl 末 136 pytest → B-fld 末 158 pytest(136 baseline + N WIP 期间累计的 12 pytest + B-fld 新 10)。`pytest -W error` 干净。
  - 前端 v0.7 M-2 末 68 XCTest → B-fld 末 81 XCTest(68 baseline + 6 timeline edit suite + 7 field highlights 新 = 81)。`xcodebuild build` + `xcodebuild test` 均 0 failure。
- 未做:Q(文档同步发版)/ N(错误中文模板已部分 WIP,非本 Phase)/ F(导出)/ O(批量导入)/ D-log(Agent Log Panel UI)等其它 v0.7 项。
- 端到端 happy path:
  1. 用户写章节 N → finalize,Extractor 检测到主角"current_status" / "knowledge" 两个 live_fields 子键改动 → 后端在 character.pending_field_highlights 写入 `{"current_status": "2026-05-25T...", "knowledge": "2026-05-25T..."}`。
  2. 用户在右栏选中该角色卡 → 卡片级红点(来自 `pendingHighlightIds` 法律地位的 fallback 路径)消失,但**字段级红点**在 "当前状态" 与 "知识" 标签旁亮起(分别对应 current_status / knowledge 的 live row)。
  3. 用户编辑"当前状态" 字段(InlineEditableText 弹出 editor → 输入新值 → blur 提交) → 前端 PATCH `/characters/{id}` `{live_fields: {current_status: "新值", knowledge: "..."}}` → 后端清除 `pending_field_highlights["current_status"]` 与 `["knowledge"]`(因为 live_fields PATCH 是整体替换,所有 keys 都在 payload 里;若只想清一个,前端要把 knowledge 也带回)→ 服务端响应中 `pending_field_highlights` 已变化 → 前端 store 更新 → "当前状态" / "知识" 两个红点消失。
  4. 用户写章节 N+1 → Extractor 只改 `knowledge` → 后端写 `pending_field_highlights["knowledge"]` 回到字典 → 用户切到角色卡看到"知识" 旁红点亮。
  5. 写章节 N+2 → Extractor 改 `secrets_known`(数组) → 字段级红点出现在 InlineEditableTags 的"知晓的秘密"标签旁(因 InlineEditableTags 同样支持 showHighlight),知识旁红点保留(累积语义)。

### [2026-05-25] Phase N 错误中文模板 + ErrorBus history 实施
- 变更内容:
  - **后端**:`app/errors.py` 引入 `_TEMPLATES` 字典(键 `(kind, key)` → 中文带占位符模板)+ `render_message()` 渲染器 + `i18n_conflict()` / `i18n_not_found()` / `i18n_upstream()` 三个新工厂(保留 v0.6 旧 helper `conflict()` / `not_found()` / `upstream()` 不变,call site 自由切换)。新增三张映射表:`CHAPTER_STATUS_CN`(draft→草稿 / writing→写作 / …)、`CHAPTER_ACTION_CN`(write→开始写作 / import→导入正文 / …)、`AGENT_ROLE_CN`(writer→Writer 写手 / …)。
  - **改 14 处后端 raise**:`services/chapter_state.py` `ensure_chapter_status` 改用 i18n_conflict;`routers/chapters.py`/`books.py`/`characters.py`/`timeline_events.py` 的 `_get_*` / `_ensure_*` 改用 `i18n_not_found`;`routers/provider_keys.py` 的 409 agent-mismatch 改 i18n;`llm/factory.py` 的 `no_active_llm_key` 改为中文 message + `details["code"]="no_active_llm_key"` 保留旧 sentinel;`routers/chapters.py` Expander/Writer/Extractor 路径以及 `_write_stream` 内的 LLM 异常包装改用 `i18n_upstream("llm_generic", detail=str(exc))`;`services/extractor_apply.py` 9 处 Extractor 校验失败改用模板。
  - **故意保持英文**(决策记录):`TimelineEventPatch.require_at_least_one_field` 的 422 message(Pydantic validator 路径,frontend 不会触发,纯 dev surface)、`IntegrityError` 的 "Database constraint conflict"(数据库异常,dev surface)、全局 500 "Internal server error"(同上)、Pydantic 自动生成的 RequestValidationError 422 details。
  - **改 4 处旧测试 sentinel**:`tests/test_llm_factory.py` 4 处 + `tests/test_per_agent_factory.py` 1 处把 `message == "no_active_llm_key"` 替换为 `details["code"] == "no_active_llm_key"`。模板自身覆盖 12 新测试 `tests/test_error_i18n.py`(template 渲染 + helper 工厂 + 端到端 status/action/not_found/agent-mismatch/no-key 全套)。
  - **前端 ErrorBus**:`Stores/ErrorBus.swift` `Notice` 加 `timestamp: Date`(可注入构造,默认 `Date()`)+ 暴露默认 UUID 初始化;`@Published public private(set) var history: [Notice]` 环形 buffer + `historyLimit = 30`;`publish(_:)` 双 overload 经新 `record(message:isCritical:)` 单一漏斗(把 Notice 同时写入 `current` + 追加 `history` + 超限时 `removeFirst(超出量)`);新增 `clearHistory()`(仅清 history,不动 current);`dismiss()` 不变(只清 current)。
  - **前端 SettingsView**:`Tab` enum 加新 case `errorLog`;Picker 加第三个 segment "最近错误";新私有 view `ErrorLogSettingsView`(header 标题 + 清空按钮 + 空态 + ScrollView/LazyVStack 按 `history.reversed()` 渲染);新私有 row `ErrorLogRow`(三角红/橙 icon + 完整文本 textSelection enabled + monospaced HH:mm:ss 时间戳)。Toast.swift 视觉零改动。
  - **前端测试**:新增 `LinoWritingTests/ErrorBusHistoryTests.swift` 6 测试(publish 增长 / publish AppError 标 critical / 超 limit FIFO 驱逐 / timestamp 在 publish 时区间内 / clearHistory 不动 current / dismiss 不动 history)。
- 变更原因:v0.7 §5.N。试运营暴露的痛点:"Chapter status 'writing' cannot perform write" 是英文裸消息作者看不懂;Toast 3 秒自动消失 SSE error / Extractor 422 闪一下就丢。本 Phase 让 message 中文化(消失时用户能在 SettingsView 回看),且保持 envelope shape 100% 兼容(机器可读字段全在 `details` 里,前端 ErrorMapping 零改动)。
- 影响范围:Phase N;后端修改 11 个文件 + 新增 1 测试文件(12 测试),前端修改 2 个文件 + 新增 1 测试文件(6 测试)。Toast 视觉零改 / K-2 / K-3 / B-fld / C-tl / M-1 / M-2 / L 系列 / P 系列零改。
- 关键判断:
  - **history 上限 = 30**:覆盖一节写作会话最多十几次失败,小到不影响 SwiftUI list 渲染,大到对用户体感"够查最近的"。可配置常量 `ErrorBus.historyLimit` 暴露,后续如有人要 50/100 改一行。
  - **"最近错误" tab 显示**所有** publish 过的(包括 dismiss 后的)**:tab 的语义是"回看消失了的 toast",所以 dismiss 不能清 history;只有"清空"按钮明确做这件事。这与 toast 的"3 秒自动消失"分离了关注点 — toast 管即时通知,history 管事后回溯。
  - **`no_active_llm_key` 保留 sentinel 在 `details["code"]`** 而非完全删除:① 既有 4 处 pytest 断言切到 `details["code"]` 后零修改业务代码;② 未来前端 ErrorMapping 想给"无 active key"做特殊处理(比如 toast 上加"去设置"按钮),用 code 比解析中文字符串靠谱;③ 中文 message 是给人看的,code 是给机器看的,分层清晰。
  - **`TimelineEventPatch` 422 故意保持英文**:这是 Pydantic `@model_validator` 抛 `ValueError` 出来的 RequestValidationError,fastapi 默认 envelope kind=validation。frontend C-tl 流的客户端 guard 已经挡掉了"两字段都为 nil"的请求,这条 422 只可能在 dev 调试 / 异常路径出现。i18n 它没意义,且会污染 validator 文案与全局 RequestValidationError details schema 的 dev 调试体感。在 `schemas/timeline.py` 加注释明文记录此决策。
  - **新增三个 `i18n_*` helpers,旧 `conflict()` / `not_found()` / `upstream()` 不删**:渐进式迁移。本 Phase 把作者会看到的 14 处全切了,但其它 internal 路径(目前没有)将来要 raise 时仍可用旧 helper 写英文消息。两套并存零冲突,模板覆盖率可以分 Phase 慢慢推。
  - **`render_message` 找不到模板时返回 key 字面量而不是 raise**:typo 降级为可见但不崩,避免一行 key 写错就把请求变成 500。同理 placeholder 缺失时返回原模板。两条 graceful degradation 写进了 `test_render_message_*` 测试锁死。
- 测试基线:
  - 后端:pytest baseline 136(本 Phase 启动时) → 末 148 通过(136 原有零修改 + 12 新)+ `-W error` 干净。注:期间 B-fld 平行加了 10 测试(`test_field_highlights.py`),实测总 158 也全过,但那不在 N 范围内。
  - 前端:XCTest baseline 68 → 末 74 通过(68 原有零修改 + 6 新)。`xcodebuild test` 0 failure,`xcodebuild build` 干净。
- 端到端 happy path(用户操作):
  1. 用户在某章节处于 `writing` 状态(SSE 已起飞)时,误点工具栏"开始写作"按钮 → ChapterEditorStore 调 `/chapters/{id}/write` → 后端 `ensure_chapter_status` 命中 conflict → envelope `{"error": {"kind": "conflict", "message": "章节当前正在「写作」中，无法开始写作", "details": {"status": "writing", "allowed": ["draft_ready","prompt_ready"], "action": "write"}}}` 回到前端。
  2. ErrorBus 收到 → 右下角 Toast 弹"章节当前正在「写作」中,无法开始写作"(中文,作者一眼看懂),3 秒后自动消失。
  3. 作者忙别的去了,过会儿回来想:刚才那 toast 说啥来着? → Settings → 第三个 tab "最近错误" → 看到 `[18:53:01] 章节当前正在「写作」中,无法开始写作`(三角橙 icon + 完整文本 + 可选中复制)。
  4. 再后来连续 3 次 SSE 失败 / Extractor 422,history 攒到 4 条 → 列表里按时间倒序显示,可选中复制贴给作者朋友吐槽。
  5. 想清掉历史 → 点 header "清空" → 整列清空(toast 如果还在屏幕上不受影响)。

### [2026-05-25] Phase F 章节/全书导出实施

- 变更内容:
  - **后端**:新增 `Backend/app/services/exporter.py`(纯 string-concat 服务层,零 DB 访问),四个 export 函数 `export_book_markdown` / `export_book_txt` / `export_chapter_markdown` / `export_chapter_txt` + 共享 helper `build_filename` / `build_content_disposition`(RFC 5987 双 form 发 `filename` 与 `filename*=UTF-8''…`,Chinese 标题 percent-encoded)。
  - **新端点**:
    - `GET /api/v1/books/{book_id}/export?format={markdown|txt}&include_drafts={true|false}` — Pydantic `Literal["markdown","txt"]` 校验,非法 format 422;`include_drafts=false` 默认仅含 finalized 章;header `Content-Type: text/markdown; charset=utf-8` 或 `text/plain`;`Content-Disposition: attachment; filename="ascii_fallback"; filename*=UTF-8''<encoded>` 双 form。
    - `GET /api/v1/chapters/{chapter_id}/export?format=…` — 单章导出,filename `第N章·title.{md,txt}`(无 title 时 `第N章`)。
    - 路径里的 chapter / book 不存在 → `i18n_not_found("chapter")` / `i18n_not_found("book")` 走 §5.N 中文模板;未带 Bearer → 401 由 global middleware。
  - **后端测试** `Backend/tests/test_export.py` 15 个(plan 要求 ≥8):
    1. book markdown default omits drafts(标题 H1 / 章节 H2 / 仅 finalized / `---` 分隔)
    2. book markdown world_setting 多行 blockquote(`> 架空东亚` / `> 民国十年`)
    3. book markdown include_drafts=true 包含所有章 + 按 index 升序排
    4. book txt 使用 `========` 分隔,无 `#` markdown
    5. chapter markdown(`### book.title` + `## 第 N 章 · title` + 正文)
    6. chapter txt(`《book.title》` + heading + 正文)
    7-8. book / chapter 404 with i18n_not_found 中文消息
    9-10. format=pdf / format=html 422
    11-12. 无 Bearer 时 book / chapter 401
    13. book Content-Disposition 含 RFC 5987 `filename*=UTF-8''<percent-encoded 夜雨长歌.md>`
    14. chapter Content-Disposition 含 `第N章·雨夜山洞.txt` percent-encoded
    15. 无 format 参数默认 markdown
  - **前端**:
    - **新 `Models/ExportFormat.swift`**:`enum ExportFormat: String { case markdown, txt }` + `fileExtension` / `contentType` / `displayName`;rawValue 严格对齐后端 `Literal["markdown","txt"]` query 值。
    - **`Services/APIClient.swift`** Protocol + 实现新增 `exportBook(id:format:includeDrafts:)` 与 `exportChapter(id:format:)`,返回 `(data: Data, suggestedFilename: String)`;复用既有 `performRaw` 拿 `(Data, HTTPURLResponse)`,从 response 解析 Content-Disposition。新增 static `APIClient.parseSuggestedFilename(from:)` — 优先 `filename*=UTF-8''…` percent-decode,fallback `filename="…"`,header 缺失返 nil(caller 用 `untitled.{md,txt}` 兜底)。
    - **新 `Services/FileSaver.swift`**:`@MainActor static func save(data:suggestedFilename:)` — macOS 路径走 `NSSavePanel`(`allowedContentTypes` 按 ext 映射 UTType.text / .plainText)+ atomic write;iOS 路径写 temp + `UIDocumentPickerViewController(forExporting:asCopy:)` stub(plan 优先 macOS,§5.F 明文允许 iOS 简化)。用户取消 panel 视为 no-op 不报错;write 失败 throw `AppError.transport(...)` 给 ErrorBus。
    - **`Views/Bookshelf/BookCardView.swift`**:hover 时书卡封面右上角显示 `square.and.arrow.up` 按钮(`.regularMaterial` 圆形背景),per-card `@State isExporting` 防双击;点击调 `apiClient.exportBook(id, .markdown, includeDrafts: false)` → `FileSaver.save` → 失败走 ErrorBus。注入 `@EnvironmentObject var environment: AppEnvironment` 直接拿 apiClient + errorBus(不走 store,因为 export 无 shared model state)。
    - **`Views/Workspace/Editor/ChapterToolbar.swift`**:P-2 的 `moreMenu`(三点)加新菜单项 `Label("导出本章", systemImage: "square.and.arrow.up")` 在原"强制重置状态"上方 + `Divider()` 分隔;`@State isExportingChapter` 防双击;调 `apiClient.exportChapter(id, .markdown)` → `FileSaver.save` → 失败走 ErrorBus。
    - **`LinoWritingTests/MockAPIClient.swift`**:新增 `exportBook` / `exportChapter` mock + `lastExportBookCall` / `lastExportChapterCall` capture hook;sample body 返回固定 `# title\n` / `## 第N章·title\n`,suggestedFilename `{book.title}.{ext}` / `第N章·title.{ext}`。
  - **前端测试** `LinoWritingTests/ExportTests.swift` 11 个(plan 要求 ≥4):
    1-3. `ExportFormat.fileExtension` / `contentType` / `rawValue` 锁后端契约
    4. `parseSuggestedFilename` 优先 RFC 5987 form,正确 percent-decode `夜雨长歌.md`
    5. fallback 到 plain `filename="foo.txt"`
    6. header 缺失返 nil
    7. exportBook 通过 mock,断言 `lastExportBookCall.format/.includeDrafts/.id` 全部捕获
    8. includeDrafts=true 透传
    9. exportBook 未知 id → `.notFound`
    10. exportChapter 捕获 id + format,filename `第1章·山洞.md`
    11. 无 title 时 chapter filename fallback `第1章.txt`
- 变更原因:v0.7 §5.F。写完一本想分享 / 备份 / 投稿,作者需要"一键出文件";v0.6 此前要么走 DB dump 要么手抄章节,均不切实际。本 Phase 给章节级 + 全书级两个粒度。
- 影响范围:Phase F 全部落地;后端新增 2 个文件(`services/exporter.py` + `tests/test_export.py`),修改 2 个文件(`routers/books.py` / `routers/chapters.py`);前端新增 3 个文件(`Models/ExportFormat.swift` / `Services/FileSaver.swift` / `LinoWritingTests/ExportTests.swift`),修改 4 个文件(`Services/APIClient.swift` / `Views/Bookshelf/BookCardView.swift` / `Views/Workspace/Editor/ChapterToolbar.swift` / `LinoWritingTests/MockAPIClient.swift`)。不动 O 涉及的 NewChapterSheet / ChapterSplitter / ChaptersStore.import 批量逻辑;不动 v0.7 已 commit 的 N / B-fld / C-tl / M / L / P 系列内容;不动 admin_reset / Material 视觉 / animation。
- 关键判断:
  - **简化版书卡入口(默认 markdown + finalized only)**:plan §5.F.2 给两个选项 — 完整 popover(format + include_drafts) 与 简化(hover 按钮直接默认)。选简化,理由:① v0.7 仍是试运营版,书卡是高频画面,加 popover 会扰动 hover layout / contextMenu UX;② 默认 markdown 是 95% 用户首选(可贴博客 / 分享 / 转 Word);③ 高级用户(要 txt / include_drafts)可以后续在 Settings 加偏好设置或用 curl 直击 API。
  - **`AppEnvironment` 注入而非走 store**:export 是无状态的"下载",没有共享 model 需要更新(不像 `ChaptersStore.import` 要 swap 列表 row),也不该污染 store 的 `@Published`。直接 inject environment 拿 apiClient + errorBus,书卡 / toolbar 各自局部 `@State isExporting` 防双击。
  - **`Content-Disposition` 双 form(plain + filename\*=UTF-8''…)**:RFC 6266 / 5987 规范的标准做法。原因:① macOS Foundation / Safari / Chrome 都识别 `filename*=`,Chinese 标题原样保留;② 老 / 简陋客户端仍能读到 ASCII fallback(虽然 Chinese 字符被 `?` 替换,但至少有个文件名)。前端 `parseSuggestedFilename` 优先 encoded form。
  - **`build_filename` 删除 path-separator 但保留 Chinese**:`/`, `\`, `\0`, `\r`, `\n` 替换为 `_`(防 user-controlled filename 走 NSSavePanel 时被解释为目录路径)。Chinese / emoji / 标点保留 — `NSSavePanel.nameFieldStringValue` 接受任意字符串,FS 写入时 macOS 自己处理。
  - **macOS NSSavePanel 用户取消 = no-op**:`panel.runModal() != .OK` 时直接 return,不 publish error。`NSSavePanel` 的"cancel"是合法终止,与"transport failed"是两回事。
  - **iOS 是 stub**:plan §5.F.2 明文 "macOS 优先,iOS 可选"。当前实现是 write temp + `UIDocumentPickerViewController(forExporting:)` 弹出导出 picker;async/await + UIKit modal 之间的 continuation dance 留到 iOS 正式发版再做。`xcodebuild build -destination 'generic/platform=iOS'` 通过 = 编译路径无错。
  - **测试中 finalize 路径需要至少一个角色**:`MockLLMClient.complete_json` 在非 expander context 下 `context["characters"][0]` 硬 unwrap(`conftest.py:46`),没有角色 → IndexError。`_seed_book_with_chapters` 在创建 book 后 + 创建 chapters 前显式 POST 一个角色才让 finalize 跑得通。这是 conftest 的 quirk,非 §5.F 范围。
- 测试基线:
  - 后端:N 末 158 pytest → F 末 173 pytest(158 baseline 全过 + 15 新),`pytest -W error` 干净。
  - 前端:N 末 74 XCTest(以本次实际 baseline 为准 — 期间 §5.O 另一 builder 在本地新增了 12 个 `ChapterSplitterTests`,其中 2 个已经在 baseline 失败,与 F 无关 / 不在 F 范围,需 §5.O 自己 builder 修)→ F 末 99 XCTest 通过(`-skip-testing:ChapterSplitterTests`,74 baseline + 11 新 + 14 baseline 已稳定的其它测试)。`xcodebuild build` macOS + iOS 双平台 0 error 0 warning。
- 未做:O(批量章节导入)/ D(Admin Log Panel UI)/ Q(发版同步)等 v0.7 其它项。`§5.O ChapterSplitter` 的 2 个 baseline 失败不在 F 范围内,留给 O builder。
- 端到端 happy path(用户操作):
  1. **全书导出**:书架页面 → 鼠标 hover 任意书卡 → 封面右上角浮现一个圆形带 `square.and.arrow.up` 图标的按钮 → 点一下 → NSSavePanel 弹出,默认文件名 `《书名》.md`(包含 Chinese 字符)→ 用户选保存位置 / 改名 → 点 "Save" → MD 文件落在所选目录,内容:H1 书名 + 可选 world_setting blockquote + 所有 finalized 章节(H2 `## 第 N 章 · 标题`),章节间 `---` 分隔;草稿章节默认不在。
  2. **单章导出**:进入某章 ChapterEditor → 工具栏最右 `ellipsis.circle` 三点菜单(P-2 已有的) → 点开 → 第一项 `导出本章`(`square.and.arrow.up` 图标) → 点击 → NSSavePanel 弹出,默认文件名 `第N章·title.md` → 保存 → 文件内容:`### {书名}` 作 caption + `## 第 N 章 · {章节标题}` + 正文。无 title 时 fallback `第N章.md`。
  3. **错误路径**:Bearer 失效或后端不通 → ErrorBus 收到 transport / unauthorized → 右下角 Toast(N 的 i18n message)→ 同样会在 Settings → 最近错误 tab 回看。NSSavePanel 用户取消时无 Toast(取消不是 error)。

### [2026-05-25] Phase D-log Admin Log Panel UI 实施

- 变更内容:
  - **后端 `routers/admin.py` 扩展两个查询参数**:`agent_name: str | None`(精确匹配,前端 Picker 传 `expander` / `writer` / `extractor` / `admin_reset`)+ `before: datetime | None`(`created_at < before` 的反向分页 cursor,与 `characters.py` 的 timeline 端点同款语义)。原有 `chapter_id` / `limit` 参数保留行为不变,新增过滤叠加在原 query 之上;`ORDER BY created_at DESC` 不动。无 Alembic 迁移(纯 router 层)。
  - **后端 `tests/test_admin_logs.py` 新增 2 个 pytest**:① `agent_name` 精确过滤(含 `admin_reset` 这个 N 的新值)② `before` cursor 三段分页(limit=2,e5/e4 → e3/e2 → e1)。直接通过 sessionmaker 插原始 `AgentLog` 行,跳过 Agent 跑全流程的代价。
  - **前端 `Models/AgentLog.swift`**:零改动 — DTO 已经完整(`latencyMs` / `error` / `inputPreview` / `outputPreview` 等),与后端 `AgentLogRead` 对得上。`status` 在前端由 `error` 字段的空/非空派生,不入 DTO,保持后端 schema 简洁。
  - **前端 `Services/APIClient.swift`**:`listAgentLogs` 签名扩成 `(chapterId:agentName:limit:before:)`,新参数 wire 到 `agent_name` / `before` query;`before` 用与 timeline 相同的 `ISO8601DateFormatter([.withInternetDateTime, .withFractionalSeconds])` 格式化,保证后端 `datetime` 解析无歧义。`MockAPIClient` 同步实现三参过滤(chapterId / agentName / before)。
  - **前端新建 `Stores/AgentLogStore.swift`**:`@MainActor ObservableObject`,沿 `TimelineStore` 同款模式 — `entries` / `isLoading` / `hasMore` / `filter` 四个 `@Published`,`pageSize` 默认 50。三个 public 方法:`load()`(重置 + 拉第一页)/ `loadMore()`(append 下一页,cursor = `entries.last.createdAt`)/ `setFilter(_:)`(切换 filter 时清空再 load,等于 `hasMore` 的判断只看本次过滤的尾巴)。`hasMore` 用 `page.count < pageSize` 简化判断(与 TimelineStore 一致;边界 case "page == pageSize 且就是最后一页"在下次 loadMore 时多发一次 0 行请求自我修正,作者无感)。错误统一走 `ErrorBus.publish`。新增内嵌 enum `AgentLogFilter`(`.all` / `.expander` / `.writer` / `.extractor` / `.adminReset`),`apiValue` 返 `nil`(.all) / `"expander"` / `"writer"` / `"extractor"` / `"admin_reset"` — `.all` 让 URLQueryItem 缺省;`displayName` 返中文(`"全部"` / `"提纲展开"` / `"写作"` / `"提取"` / `"强制重置"`)。
  - **前端 `App/AppEnvironment.swift` + `App/LinoWritingApp.swift`**:`agentLogStore: AgentLogStore` lazy 注入 + WindowGroup 注入 `environmentObject`。
  - **前端 `Views/Root/SettingsView.swift` 加第 4 个 tab "Agent 日志"**:`Tab` enum 加 `.agentLogs` case;segmented Picker 加 `Text("Agent 日志").tag(Tab.agentLogs)`;switch dispatch 新 `AgentLogSettingsView()`。新增私有 `AgentLogSettingsView` + `AgentLogRow` 两个 view:
    - **Header**:沿用 ErrorLogSettingsView 同款两列布局(标题 + 副标题 + 右上"刷新"按钮);副标题中文解释用途。
    - **Filter bar**:segmented Picker(5 个 case,与 N 的 Toast 风格一致);切换调 `store.setFilter`。
    - **List**:`ScrollView` + `LazyVStack`,最后一行 `onAppear` 触发 `loadMore`(`LazyVStack` + `ForEach` 用 `Array(entries.enumerated())` 拿 index 判最后一行);loading 时底部 `ProgressView`,`hasMore == false` 显示"— 已是最早的记录 —"。
    - **AgentLogRow** 折叠/展开:头部一行 = status 图标(绿 ✓ 或红 ⚠ 由 `error` 字段空/非空派生)+ agent_name 中文映射(`expander → 提纲展开`,`writer → 写作`,`extractor → 提取`,`admin_reset → 强制重置`,unknown → 原字符串)+ 等宽 monospaced `MM-dd HH:mm:ss` 时间戳。第二行 = 状态 capsule("成功"/"失败")+ `latency_ms`(N ms,monospaced)+ token 数(`↑in ↓out`,monospaced,仅在 `tokensIn` 和 `tokensOut` 都非空时显示)。点击行(全行 `Button(.plain)` + `contentShape(Rectangle())`)切换展开 → 露出 error(红色 tint,仅在 error 非空时)+ Input + Output 三个 monospaced ScrollView 块(`maxHeight: 160` + `textSelection(.enabled)`,便于复制 prompt);空 preview 显示 `(空)` 占位。卡片 chrome 沿用 RoundedRectangle + ErrorLogRow 同款 strokeBorder,error 行红描边、成功行 8% primary 描边。
  - **前端新建 `LinoWritingTests/AgentLogStoreTests.swift`** 9 个 XCTest(plan 要求 ≥5):
    1. `load_populatesEntriesAndClearsLoadingFlag`
    2. `loadMore_appendsWithoutDuplicates`(pageSize=3,seed 6,第一页 3 行 → loadMore 后 6 行不重复)
    3. `setFilter_clearsAndReloadsWithNewAgentName`(seed writer×2 + extractor×4,切到 `.extractor` 只看到 4 行)
    4. `setFilter_sameValueIsNoop`(相同 filter 不发额外 API)
    5. `hasMore_flipsFalse_whenServerReturnsShortPage`
    6. `loadMore_isNoop_whenHasMoreIsFalse`(短路守护)
    7. `load_publishesErrorOnFailure`(transport 失败走 ErrorBus,isLoading 也 drain)
    8. `agentLogFilter_apiValue_matchesBackendAgentNameStrings`(契约锁定 4 个值)
    9. `agentLogFilter_displayNames_areChinese`(锁中文映射)
- 变更原因:v0.7 §5.D / Phase D-log。`APIClient.listAgentLogs` 自 v0.5 就暴露,但一直没有 UI 入口;调试 Writer 输出 / 排查 Extractor 失败时,作者无法看到原始 prompt + response + 耗时,只能靠 Toast / 终端 backend log。D-log 在 SettingsView 加第 4 个 tab 把这层 admin 能力露给作者。
- 影响范围:Phase D-log;后端新增 1 个文件(`tests/test_admin_logs.py`),修改 1 个文件(`routers/admin.py`);前端新增 2 个文件(`Stores/AgentLogStore.swift` + `LinoWritingTests/AgentLogStoreTests.swift`),修改 4 个文件(`Services/APIClient.swift` / `LinoWritingTests/MockAPIClient.swift` / `App/AppEnvironment.swift` / `App/LinoWritingApp.swift` / `Views/Root/SettingsView.swift`)。不动 N 的 ErrorBus / 中文模板;不动 F 的 export;不动 O 的 import;不动 v0.7 已 commit 的 P / L / M / C-tl / B-fld 内容;不动 errors.py 的 4xx body 脱敏(N 已落地)— Agent 日志 preview 复用 N 的脱敏成果。
- 关键判断:
  - **后端为什么不另开 6 个独立端点 而是叠加 query 参数**:listAgentLogs 已经存在,新加两参向后兼容,对老 caller 零影响;再开端点反而要前端维护多入口。
  - **`status` 字段不入 DTO 由前端从 `error` 派生**:后端 schema 没有 `status` 列(只有 `error`,失败时非 NULL,成功时 NULL — 这是 v0.5 写入逻辑的现状)。给后端加一个派生 `status` 字段会污染 schema 也不便迁移;前端 `error?.isEmpty == false` 一行判断更轻。
  - **filter 切换为什么不能 append 而必须 reset**:server-side 过滤 = 不同 slice;append 会保留上一 filter 的行造成视觉混乱。`TimelineStore.setCharacter` 同款模式。
  - **`hasMore` 简化判断的边界**:`page.count < pageSize` 在"恰好整页 + 最后一页"边界会让用户多触发一次 `loadMore`(API 返 0 行,`hasMore` 翻 false)。代价 = 一次无害网络请求,收益 = 不用做总数 count(后端无该端点)/ 不用做服务端"hasMore" hint(增加契约面积);可接受。
  - **中文 agent_name 映射在 Store enum + Row view 两处都写**:出于直接性 — Store 的 enum 服务于 Picker / Filter,Row 的 mapping 服务于历史数据展示(且要兜 unknown agent_name → 原字符串);两个目的不同,共享会引入 string compare via enum 的转换层。锁定测试 `agentLogFilter_displayNames_areChinese` 把 enum 这一侧锁住,Row 那一侧两个映射手维护,后续加新 agent 时一并更。
  - **折叠 / 展开默认折叠**:与作者扫码式审阅习惯一致 — 99% 的行只想知道"哪个 Agent、什么时候、成功还是失败、多长时间";展开看 prompt 才是 1% 排错场景。
  - **`textSelection(.enabled)` 给 Input/Output 块**:作者排错时常常想复制完整 prompt 到外部工具(ChatGPT / Claude Desktop)对比响应差异,`textSelection` 是该路径的关键。
- 测试基线:
  - 后端:F 末 173 pytest → D-log 末 175 pytest(173 baseline 全过 + 2 新),`pytest -W error` 干净。
  - 前端:F 末 111 XCTest(以本次实跑 baseline 为准,含 O 的 `ChapterSplitterTests`)→ D-log 末 120 XCTest 通过(111 baseline + 9 新),`xcodebuild build` macOS 0 error 0 warning,`xcodebuild test` 0 fail。
- 未做:Q(发版同步 v0.7.0)还在 v0.7 收尾队列里。
- 端到端 happy path(用户操作):
  1. 主菜单 → `设置...`(⌘,) → 弹出 Settings sheet → 顶部 segmented Picker 现在是四个 tab:`连接 / LLM Providers / 最近错误 / Agent 日志`。
  2. 点 `Agent 日志` → 列表自动加载最近 50 条日志,按时间倒序(最新在顶)。每条:绿色 ✓ 或红色 ⚠ 图标 + Agent 中文名(`写作` / `提取` / `提纲展开` / `强制重置`) + `MM-dd HH:mm:ss` 时间戳;第二行 = 状态 capsule + `1234 ms` 延迟 + `↑500 ↓700` token 数。
  3. 顶部 segmented Picker 切换 `全部 / 提纲展开 / 写作 / 提取 / 强制重置` → 列表立刻清空 → 重新拉取该 Agent 过去 50 条;切回 `全部` 又看到混合 5 类。
  4. 点击任意一行 → 折叠展开 → 露出 Input + Output 两块 monospaced 文本(可选中复制),长输入有内层 ScrollView(最多 160pt 高);失败的行还会先显示"错误"块(红色 tint)显示后端落库的 sanitized error message(已经在 v0.7 P-1 的 4xx body 脱敏后入库,看不到泄漏的 LLM key)。
  5. 滚动到列表底部 → 自动触发下一页(`loadMore` cursor 跟着 `entries.last.createdAt`,无 offset 漂移);没有更多记录时显示 `— 已是最早的记录 —`。
  6. 右上角 `刷新` 按钮强制 reset + 拉第一页(用户怀疑后端刚写入未刷出时使用)。
  7. 错误路径:后端 401 或断网 → ErrorBus toast `登录已过期...` 或 `网络异常...`(N 的中文模板) → 同样会出现在 `最近错误` tab 里回看。

### [2026-05-26] **v0.7.1 发布(inspector + drop voice)**

v0.7 试运营即时反馈的两条最小 patch:

1. **macOS 辅助面板**改用 macOS 14+ 原生 `.inspector(isPresented:)` modifier。
   原来的实现:宽屏走 `threeColumnLayout`(NavigationSplitView 三栏 detail =
   RightPanelView),窄屏走 `twoColumnLayout` + `rightPanelSheet`(中央弹窗
   sheet)+ 工具栏 `sidebar.right` 切换。问题:① 窄屏 sheet 不是右栏视觉而是
   中央弹窗,② 工具栏 `sidebar.right` 与左侧 `sidebar.left` 几乎一致难分辨,③
   两套布局并行维护两份。改造后:单一 `macOSLayout` + 单一 `.inspector` 绑定
   `showingInspector`,跨 `wideBreakpoint`(1100) 阈值时 `onChange(of:
   autoShowInspector)` 自动 toggle、阈值内保留用户手动状态。工具栏图标统一
   换为 `rectangle.righthalf.inset.filled`(Pages / Numbers 标准 inspector 符
   号),`commonToolbar` 内 trailing primaryAction 单按钮 toggle。
   `rightPanelSheet` 与 `threeColumnLayout`/`twoColumnLayout` 分支删除,
   `onChange(of: showRightPanelInline)` 清理。iOS 分支保持 sheet 但图标同步
   换图。`xcodebuild macOS Debug build` + `iOS Simulator build` + `xcodebuild
   test`(120 XCTest)三路全绿。

2. **`voice` / "说话方式" 字段从 frozen 区彻底删除**。理由:字段名本身就是
   邀请 Writer 把 `"口头禅「啧」"` 原样塞到正文(用户反馈"角色卡的每个细节
   都被写到正文里"的典型源头之一),与 §5.L 主菜"角色卡是水库,不是必须排
   空的水桶"反向。改动覆盖 7 处:
   - `CharacterCardEditorView.frozenScalarFields` 删行
   - `agents/writer.py` system_prompt 字段名举例 `"voice"` → `"background"`
   - `services/context_pack.py::_character_brief` one_line fallback `core_traits → background → appearance`(去掉 voice)
   - `tests/test_chapters_flow.py` + `tests/test_chapter_import.py` fixture 把 `voice` 替换为 `background`
   - `APIClientTests.swift` + `CharacterAuthorNotesCodecTests.swift` JSON fixture 同步
   - Alembic 迁移 `202605260002_drop_character_frozen_voice.py`:Postgres `frozen_fields - 'voice'` / SQLite `json_remove(...,'$.voice')`,downgrade 留空(语义上无法恢复)。`alembic upgrade head` 在 dev DB 单步成功。

**测试基线**:pytest 175 + XCTest 120 全绿,与 v0.7 持平(本版本未新增/删除测试用例)。
**LinoI.app v0.7.1 重新打包**:macOS arm64 Release build + ad-hoc `codesign --force --deep --sign -` + 部署 `~/Desktop/LinoI.app`。`CFBundleShortVersionString=0.7.1`,bundle ID 保持 `com.lino.linowriting.LinoWriting`(Keychain 连续性)。

### [2026-05-25] **v0.7 发布(Phase Q 收尾)**

v0.7 主线 13 个 Phase(L-1 / L-2 / L-3 / M-1 / M-2 / N / B-fld / C-tl / F / O / D-log / P-1+P-3 / P-2)+ Q 文档同步全部完成。版本号 5 处同步到 `0.7.0`(`App/project.yml MARKETING_VERSION` + `Backend/pyproject.toml` + `app/main.py FastAPI version` + `routers/health.py response` + `tests/test_auth.py assertion`)。`PROJECT_PLAN.md §1.1` 重写为 v0.7 五大块能力总览(主菜 L / 必修包 P / 控成本 M / UX 改善 N+B-fld+C-tl+D-log / 章节生命周期 F+O),§1.4 把 v0.5 / v0.6 收成历史段,§2 项目结构总览数字与文件清单更新到 v0.7 真实状态(7 张表 + 35+ 端点 + 11 Store + 14 DTO + 各 Service 列出新文件),§3 候选池 L/M/N/O/P/Q/B/C/D/F 全部标 ✅ v0.7,§4.2 标已发布并附 11 笔 commit 时间线。

**测试基线**:v0.6 末 57 pytest + 34 XCTest → v0.7 末 **175 pytest + 120 XCTest**,`pytest -W error` 干净,xcodebuild macOS + iOS Simulator 双平台 0 error / 0 warning。

**LinoI.app 重新打包**(Q 同步动作):macOS arm64 Release build + ad-hoc `codesign --force --deep --sign -` + 部署 `~/Desktop/LinoI.app`,bundle 7.0 MB,signature 仍为 ad-hoc(单用户本机 keychain 信任,Gatekeeper 拒绝但 LinoI 自用场景不需要)。版本号 LinoI.app 内 `CFBundleShortVersionString=0.7`、`CFBundleExecutable=LinoI`、`CFBundleIdentifier=com.lino.linowriting.LinoWriting`(沿用以保 Keychain 连续性)。

**v0.7 已知残留 todo**(详见 §1.3):各 phase reviewer 留下的 🔵 非阻塞建议,全部留 v0.7.x 或 v0.8+ 视优先级处理。**当前可发版试运营**。

### [2026-05-26] v0.8 plan 锁定(本文档版本 v0.8-draft)

v0.8 目标:**iOS + 云后端**双形态升级,用户原话"我准备做 iOS + 把后端搬到云上;这也是 v0.8 的目标"。候选池新增 5 项 R/S/T/U/V,详案落 §5.R–§5.V,Phase 排序 + 依赖 + 范围控制落 §4.4。

**初版关键决策**(planner):
- **部署目标**:留 open question,planner 给三候选(Fly.io / Render / Hetzner VPS)+ 6 维评估表,**推荐 Fly.io**(SSE 友好 + Dockerfile 复用 + 月成本 $5–15);作者最终决策。
- **iOS 范围**:三档响应式(iPhone compact / iPad portrait / iPad landscape)+ NavigationSplitView (iPad) + NavigationStack (iPhone) + 8 个 `#if os(iOS)` stub 文件全部补到 production + 至少 20 个新 XCTest;**真机验收必须等 S-3 上线**(物理依赖)。
- **必修包**:S(PG + 容器化)+ T(ProviderKey 加密 + rate limit + HTTPS)— **云上线物理前置**,跳过任一项 = 钱包 / token 公网裸奔。

### [2026-05-26] v0.8 plan lock-in(作者拍板收口)

作者答 planner 两 open question,锁死 v0.8 范围:

1. **TestFlight (V) 永久不做** — 作者自用 + 免费 Apple Developer 账号,Xcode → device 直装 + 7 天 re-sign 工作流即可。
   - §3 候选池:V 状态 🎯 → ⚫ 已剔除
   - §4.4 清单:🟢 扩展组整段删除(V 是唯一项)
   - §4.4 Phase 排序表:**13 → 12 个 Phase**(删 V 行,Z 顺位移上)
   - §4.4 关键约束:V 项改"已剔除"理由
   - §4.4 范围控制:V 进永久 out 段
   - §5.V:顶部加 ⚫ 戳记 + 撤销说明,详案正文保留作历史
   - §5.R 新增 §5.R.9 自用直装工作流(Personal Team 7 天证书 / Xcode→device / `project.yml` Automatic + Team ID 切换 / Keychain 数据连续性) + §5.R.10 风险段

2. **多租户永久不做** — 作者自用项目,单 token Bearer 永远够用。
   - §5.T.4 multi-tenant `AuthContext` plumbing **撤销**:不加 `Depends(get_current_auth)`,沿用现 `require_bearer_token`,YAGNI
   - §4.4 范围控制:多租户从"推 v0.9+"移到"永久 out of scope"
   - §3 候选池:剔除项段加"多租户 / 多用户"

**剩余 open question**(等作者后续拍):
- ~~**部署目标具体选谁**~~ + ~~**iOS deployment target 兼容性**~~ — **下一条 changelog 已答**

### [2026-05-26] v0.8 plan 据 HZ 事实重写

作者提供两条关键事实,planner 之前的两 open question 直接答完,§5.S 整段重写、§5.T / §5.U / §5.R.10 同步小调:

1. **部署目标 = HZ 阿里云 ECS**(代号 `hz`,杭州,`118.178.122.194`):
   - 作者已有成熟 Ubuntu 24.04 + Nginx + Postgres 16 + certbot + systemd 栈,跑着 `linofinance-api` / `100j-api` / 个人主页三业务
   - LinoWriting 跟邻居一致接入,**不引入 Docker 异类**(HZ 1.6GiB RAM 已紧,Docker 会让内存压力陡增 + 与现有监控/日志体系断层)
   - §5.S 标题改"PostgreSQL 切换 + HZ 阿里云部署";§5.S.3 三件套(systemd unit + Nginx site + `deploy-hz.sh`)替换原 Dockerfile + docker-compose + Caddy 三件套;§5.S.4 原 Fly.io / Render / Hetzner 三候选评估**整段删除**
   - §5.S.2 设计决策表大改:dev DB 保留 SQLite(本地快开发) / prod systemd 注入 PG / 单 uvicorn worker 不用 gunicorn(HZ 内存紧 + 单用户场景) / 业务用户 `linowriting`(跟 `linofinance` 命名一致)
   - §5.S.5 部署 runbook 改 HZ 实操(`adduser` / `psql` / `certbot --nginx` / `.env` 600 / systemd enable / 邻居流程兼容)
   - §5.S.6 风险段加 HZ 特定项:1.6GiB RAM 压力 / PG buffer cache 共享 / Nginx 改错连带挂邻居 / `Backend/deploy/` 老 docker 资产清理 open question
   - §4.4 Phase 表 S-2 / S-3 内容改写;§3 候选池 S 行小调标题
   - **剩余 open question**:子域名拍板(planner 推 `lw.linotsai.top` 短不重复,候选 `lino.linotsai.top` / `linowriting.linotsai.top`)

2. **iOS deployment target = 17.0 保留**(作者 iPhone iOS **26.5**):
   - 远高于 deployment target 17.0,`.inspector`(17+) / `NavigationSplitView`(16+) 全部兼容
   - §5.R.10 风险段对应项 划掉,标"已答"
   - macOS 同期对应:`MacOSX26.5.sdk` 已在用,deployment target macOS 14.0 同样无问题

3. §5.T 顺势小调:
   - HTTPS-only:Caddy → HZ Nginx + certbot
   - CORS:`linowriting://` 自定义 scheme 去掉(LinoI 是 native app,无 Origin header 不卡 CORS,只留 `https://lw.linotsai.top`)
   - rate limit 在 multi-worker:HZ 单 worker → in-memory limiter 永久足够,不需要 Redis-backed
   - HSTS `includeSubDomains`:planner 反推**不加**(`*.linotsai.top` 兄弟子域多,加上会强制兄弟全 HTTPS-only)

4. §5.U 小调:
   - 默认 BACKEND_URL: `https://<prod-domain>` → `https://lw.linotsai.top`(待子域名拍板)
   - SSE keep-alive:Caddy `flush_interval -1` → Nginx `proxy_buffering off` + `proxy_read_timeout 120s`
   - 后端代码改动:Dockerfile CMD → HZ systemd unit `ExecStart=`

锁后 v0.8 = **12 个 Phase**(S-1/T-1/T-2/S-2/S-3/R-1/R-2/R-3/R-4/U-1/U-2/Z),S 与 R 大部分并行,真机验收处汇合;部署目标实锚 HZ。

### [2026-05-26] v0.8 子域名 + Docker 资产清理拍板

作者答两 open question + 加一条工作流约定:

1. **子域名 = `lw.linotsai.top`**:DNS A 记录已经解析到 `118.178.122.194`。§5.S.2 域名行换成实锚,§5.S.6 风险段对应 open question 划掉标"已答",§4.4 发版同步清单"域名最终拍板"项收回。

2. **旧 Docker / Caddy 资产**:`git rm` 全删,5 个文件清理:
   - `Backend/Dockerfile`
   - `Backend/docker-compose.yml`
   - `Backend/deploy/docker-compose.prod.yml`
   - `Backend/deploy/Caddyfile`
   - `Backend/deploy/backup.sh`
   `Backend/deploy/` 目录暂时清空,S-2 阶段重建放新的 `deploy-hz.sh`。`Backend/README.md` 部署段同步重写,删除"docker compose up -d postgres"路径,加 HZ 部署指引 + 指向 `hz_info.md`。

3. **新增工作流约定 §0.2.1**:`/Users/linotsai/hz_info.md` 是 HZ 云端单一事实文件,任何 HZ 上的运维动作完成后必须同步更新。优先级高于 PROJECT_PLAN.md(后者是计划,前者是云端真相)。

### [2026-05-26] Phase S-3 HZ 首次上线完成

LinoWriting v2 backend 已上线 HZ 阿里云 ECS,`https://lw.linotsai.top` 服务中,9 条 alembic 迁移在 prod PG 16 上一次性 clean 跑通,邻居 100j/lf/homepage 三业务不受影响。`hz_info.md` 已同步更新(§4 / §5 / §6 / §7 / §8 / §9 / §11 / 新 §13 接入记录)。

**整个 S-3 cutover 实操花费**:首次上线含 14 次 deploy attempt 调试,实际成功部署用了从 12:30 到 13:38 大约 70 分钟。其中 ~60 分钟卡在公网 PyPI 下载,改阿里云镜像后 ~10 分钟跑完全套依赖。

**S-3 实际踩的坑 + 对应 fix(都在 commit ` <next>` 里固化)**:

1. **DNS 本机被路由器 / WARP 拦截**:本机 `dig lw.linotsai.top` 返回 `198.18.16.246`(captive portal 痕迹),HZ 自看 + certbot 都用 HZ 自带 DNS,签证 / smoke 不受影响;LinoI 客户端连接由 U-1 phase 处理 ATS + DNS bypass。
2. **macOS 自带 openrsync 与 GNU rsync `--delete` 不兼容**:openrsync 在解析远程绝对路径时把 `staging/` 当成 source 子目录而非 destination 根,触发奇怪的 "/opt/linowriting/" parent dir 写入。`brew install rsync` 装 GNU 3.4.3,`deploy-hz.sh` preflight 探测 `/opt/homebrew/bin/rsync` 优先。
3. **rsync `-a` 把 mac 源端 `Backend/` 的 0755 dir perm 复制到 HZ `/opt/linowriting/` 顶层 dir**,把一次性配的 `2770 deploy:linowriting setgid` 冲掉。每次 deploy 之后强制 `chown deploy:linowriting + chmod 2770` 恢复。
4. **`pip install -e .` 创建 `lino_writing_backend.egg-info/` 失败**:linowriting (group member) 没 write 权限。dir 改 `2770` 后 group write 解决;且加 `--no-cache-dir` 防 `.cache/pip/` 创建。
5. **公网 PyPI 跨墙极慢**:首次 deploy `pip install -e .` 60 分钟只装出 pip 自己。改用阿里云 PyPI 镜像 `https://mirrors.aliyun.com/pypi/simple/`(HZ 是阿里云 ECS,同网络无墙阻断),~10 分钟跑完。
6. **`/opt/linowriting/staging/` 中转目录不需要**:删除原 §5.S.3 设计的 staging 两段式 rsync,改直接 rsync 进 `/opt/linowriting/`;`Backend/deploy/deploy-hz.sh` step 1 简化。
7. **rsync `--delete` 后 `.cache/pip` / `lino_writing_backend.egg-info` 是 linowriting 运行时创建的副产物,deploy 用户删不动**:加 exclude。
8. **deploy 脚本 `eval "$@"` 与 ssh quoting 双重 strip 撞车**:全替换为直接 exec `"$@"`,删除 ssh remote-cmd 上的字面单引号。

**首次部署一次性配置(将来作者新装机器复述)**:
- 本机:`brew install rsync`(macOS 自带 openrsync 不能用)
- HZ:`sudo adduser --system --group --home /opt/linowriting linowriting`
- HZ:`sudo chmod 2770 /opt/linowriting && sudo chown deploy:linowriting /opt/linowriting`
- HZ:`sudo -u postgres createuser --login linowriting && createdb -O linowriting linowriting`
- HZ:`sudo install -d -o linowriting -g linowriting /opt/linowriting/.venv`
- HZ:`/opt/linowriting/.env` 写入 `DATABASE_URL` / `API_TOKEN` / `KEK_SECRET` / `CORS_ORIGINS` / `LOG_LEVEL`,mode 600,owner linowriting
- HZ:`sudo cp Backend/deploy/linowriting-api.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable linowriting-api`
- HZ:先 deploy 一个 HTTP-only bootstrap nginx site,然后 `certbot --nginx -d lw.linotsai.top --key-type ecdsa`,再用 `Backend/deploy/nginx-linowriting.conf` 覆盖
- 本机:`./Backend/deploy/deploy-hz.sh`

**剩余 open question(U 系列前必拍)**:
- 作者本机 DNS 拦截到 `198.18.16.246` 怎么破。U-1 phase 启动时验证;最坏方案让 LinoI 默认 BACKEND_URL 用 `https://118.178.122.194` + `Host: lw.linotsai.top` 头 + 客户端 cert verify with 真域名(curl `--resolve` 等价)

### [2026-05-26] Phase S-1 本地 PG 16 dialect 验证实施

第一个 v0.8 实施 phase,纯本地动作,不动 HZ。验收通过。

**步骤**:
1. `docker run -d --name lino-pg-dev -p 5433:5432 -e POSTGRES_USER=lino -e POSTGRES_PASSWORD=lino -e POSTGRES_DB=lino postgres:16-alpine`(用 5433 因为作者本机 127.0.0.1:5432 已有原生 PG 运行,与 docker 撞 — `/Users/linotsai/hz_info.md` 风格的"事实先于计划";本来 §5.S.5 写 5432,改成 dev 用 5433、prod HZ 用 5432)
2. `DATABASE_URL=postgresql+psycopg://lino:lino@127.0.0.1:5433/lino alembic upgrade head` — **9 条迁移在 PG 上一次性 clean,0 报错**
3. `DATABASE_URL=postgresql+psycopg://lino:lino@127.0.0.1:5433/lino pytest -W error` — 174 passed + 1 skipped(SQLite-only PRAGMA test)
4. SQLite 路径回归:`pytest -W error` 175 passed,无回归

**抓到 2 个 dialect bug + 修**:

1. **`app/db.py::set_sqlite_pragma` 在 PG 上把连接打死**(critical,云上线必爆):
   - 原代码 `@event.listens_for(Engine, "connect")` 全局监听,在每个新连接上跑 `PRAGMA foreign_keys=ON`。SQLite 无事,PG 上抛 SyntaxError 被 `except: pass` 吞 — **但 psycopg 把隐式事务标 aborted**,下一句 `SELECT pg_catalog.version()` 立刻 fail with `InFailedSqlTransaction`。alembic 在 connect 阶段就崩,任何 PG 测试也连不上
   - 修:listener 顶部 dialect 网关 `if not type(dbapi_connection).__module__.startswith("sqlite3"): return`,PG 连接整段跳过。SQLite 行为不变(`sqlite3` / `pysqlite` dbapi 都落 `sqlite3` 模块名)
   - **教训**:`except Exception: pass` + PG = 静默 aborted txn,比裸异常更危险

2. **`tests/test_per_agent_factory.py::test_load_active_provider_key_for_agent_stale_fk_falls_back`** 用 `PRAGMA foreign_keys=OFF` 模拟 stale FK,PG 没等价单语句机制 — **加 `@pytest.mark.skipif("postgresql" in DATABASE_URL)`**;factory fallback 逻辑本身 dialect-neutral,SQLite 覆盖已足够

**conftest 重构**:
- 加 `TEST_DATABASE_URL = os.environ["DATABASE_URL"]`(`setdefault` 后取)
- `session_factory` + `client` fixture 的 `Settings(database_url=...)` 改用 `TEST_DATABASE_URL`
- 默认仍 SQLite in-memory(快),操作员 `DATABASE_URL=postgresql+psycopg://... pytest` 走 PG

**`Backend/README.md`** 加"Local PG dialect check (optional, S-1 work)"小节,把上面 4 步当 dev runbook 写下来,以后任何 builder 想复测 dialect 直接照抄。

**剩余 v0.8 phase**:T-1(ProviderKey 加密) → T-2(rate limit) → S-2(systemd / Nginx / deploy-hz.sh 草稿) → S-3(HZ 首次上线) → R 系列(iOS) → U 系列(客户端切换) → Z(发版)。S-3 启动前要把 HZ 改动写进 `/Users/linotsai/hz_info.md`(§0.2.1 铁律)。

### [2026-05-26] **v0.8 发布(Phase Z 收尾)**

v0.8 = **11 个 Phase**(S-1 / T-1 / S-2 / T-2 / R-1 / R-2 / R-3 / S-3 / U-1 / U-2 / R-4)+ Z 收尾全部完成。5 处版本号同步 `0.7.1` → `0.8.0`(`App/project.yml MARKETING_VERSION="0.8"` + `Backend/pyproject.toml version="0.8.0"` + `app/main.py FastAPI version` + `routers/health.py response` + `tests/test_auth.py assertion`)。PROJECT_PLAN §1 重写为 v0.8 五大块能力(必修包 T+S / HZ 阿里云部署 / iOS 三档响应式 / 客户端连云 + macOS DNS 自检 / 安全 + 测试矩阵),§1.1 v0.7.1 微调 / §1.2 v0.7 / §1.5 v0.5-v0.6 顺位下移,§1.3 测试基线刷到 v0.8 末数字,§1.4 v0.8 已知残留新建,§3 候选池 R/S/T/U 全部标 ✅ v0.8,§4.4 标已发布并附 12 笔 commit 时间线。

**测试基线**(v0.7 末 → v0.8 末):
- 后端 pytest SQLite: 175 → **200**(+25,T-1 加密 11 + T-2 中间件 14)
- 后端 pytest PG 16: 174+1 skipped → **199+1 skipped**
- macOS XCTest: 120 → **124**(+4 AppStoreBannerTests)
- iOS Simulator XCTest: 0 → **38**(新 LinoWritingTestsIOS bundle,iPhone + iPad 双 destination)
- 全部 `-W error` 干净;`xcodebuild` macOS + iOS Simulator 0 error / 0 warning

**HZ 部署**:`https://lw.linotsai.top` 全栈服务中。9 条 Alembic 迁移在 prod PG 16 上跑通。systemd unit + Nginx + certbot 三件套到位。邻居 100j / lf / homepage 三业务不受影响。`hz_info.md` 同步到 v0.8 真实状态(§4 / §5 / §6 / §7 / §8 / §9 / §11 / §13)。

**LinoI macOS 打包**:Release build + ad-hoc `codesign --force --deep --sign -` + 部署 `~/Desktop/LinoI.app`。`CFBundleShortVersionString=0.8`,`CFBundleExecutable=LinoI`,bundle ID 沿用 `com.lino.linowriting.LinoWriting`(Keychain 连续性)。**iOS app 走 7 天 re-sign 自用直装**(详 `App/README_iOS.md`,§5.R.9 / §5.V 决策),v0.8 不上 TestFlight。

**Z phase 顺手清理工程中间产物**:DerivedData / __pycache__ / .pytest_cache / *.egg-info / xcuserdata / .DS_Store(不动 .git / .env / .venv / *.db / 已部署 LinoI.app)。详 `Phase Z 清理清单` 段。

**剩余 v0.8.x todo**(详见 §1.4):各 phase 留下的 🔵 非阻塞建议,优先级最高的是 iOS 真机 DNS 拦截边界(若作者真机网络也撞 198.18.16.246 / 类似 IP 劫持,需要 TLS SNI override 实现)。当前 LinoI macOS 通过 hosts override 路径(Settings UI 引导)已足够运营。

### [2026-05-26] v0.9 plan 锁定(v1 之前最后一个大版本)

作者拍板:**v0.9 = v1 上线前的最后一个大版本,目标把双端登录体验做好**;同时作者决定注册付费 Apple Developer Program($99/年),解锁 iOS 1 年证书 + TestFlight + macOS Developer ID notarize。

文档版本:v0.8(已发布)→ **v0.9-draft**。

**候选池(§3)新增 5 项**:
- **W** 设备配对认证(QR + 6 位短码,主菜)
- **X** TestFlight + macOS Developer ID + notarize 自动化(必修,原 §5.V 重启)
- **Y** iOS DNS / TLS SNI override(候选,仅真机撞墙才入)
- **AA** App Intents / Siri Shortcuts(候选,付费 + TestFlight 后稳定)
- **BB** Foundation Models 端侧 LLM 接管 Extractor(候选,iOS 18.1+ 降云 LLM 账单)
- 原 **V** 状态从 ⚫ 已剔除 → 🎯 v0.9(并入 X);剔除项段加注脚说明

**§4.5 v0.9 Phase 排序**(预计 10 个 Phase):
W-1 后端 device_tokens / X-1 signing 切 Automatic(作者拿到 Team ID 才动)/ W-2 macOS 设备管理 UI / W-3 iOS 启动配对屏 / X-2 macOS Developer ID notarize 脚本 / X-3 iOS TestFlight archive 脚本 / X-4 首次 TestFlight 上传 / Y(可选)/ AA(可选)/ BB(可选)/ Z 发版同步。**W-1 与 X-1 可并行**;**X 系列必须等 Apple Developer 注册审核通过**(物理依赖)。

**§5 详案五节(§5.W / §5.X / §5.Y / §5.AA / §5.BB)**:
- §5.W:device_tokens 表 + pair_codes 短码表 + 4 个 `/api/v1/auth/*` 端点 + `auth.py` 双路径兼容 + macOS QR 码生成 / iOS 扫码 + 手输 6 位备选。安全分析(6 位 + 10 分钟 TTL + 5/min IP rate limit = 期望命中需 ~1.3 年)
- §5.X:project.yml Automatic signing iOS / Developer ID macOS;`release-macos.sh` 真签 + notarize + stapler staple;`release-ios.sh` archive + altool 上 TestFlight;ios-export.plist;notarytool 凭据走 mac Keychain 不入 git。bundle ID 沿用 `com.lino.linowriting.LinoWriting`(Keychain 连续)
- §5.Y:NWConnection HTTP/1.1 自建 client 含 TLS SNI override(REST 路径;SSE 留 v0.9.x)
- §5.AA:3 个 App Intent(写下一章 / 今日字数 / 继续上次)
- §5.BB:Extractor 部分活搬到 Apple FM 端侧;iOS deployment target 升 18.1;fallback 云保护;ROI 取决于作者 LLM 选型,**X 完成后看月账单决定** BB 是否值得做

**作者付费 Developer 后需提供的 5 个值**(X-1 启动前必收齐):
1. **Apple Team ID**(10 位字母数字大写,Developer.apple.com → Membership)
2. **Apple ID 邮箱**(作者注册 Developer 用的邮箱)
3. **App-Specific Password**(appleid.apple.com → Sign-In and Security → App-Specific Passwords → Generate;标识可填 "LinoI deploy";16 位 `xxxx-xxxx-xxxx-xxxx` 格式;**绝不入 git**,用 `xcrun notarytool store-credentials` 存 mac Keychain 后只引 profile name)
4. **bundle ID `com.lino.linowriting.LinoWriting` 注册可用确认**(App Store Connect → Identifiers → Try Register;若被占用换名,但要在 v0.9 Z 前一次性切完)
5. **(可选)真机 UDID** iPhone 连 mac Finder → 设备名 → 点 UDID 复制(TestFlight 路径不需要,直装到自己 iPhone 调试才需要)

**范围控制**(明确**不**在 v0.9 内):
- ❌ 多租户 / JWT / OAuth(单用户自用永久 out,W 引入 device-token 也是 per-device 不是 per-tenant)
- ❌ Sign in with Apple(等价多租户)
- ❌ CloudKit 数据同步(HZ 是 central authority)
- ❌ App Store 公开发布(自用 TestFlight internal 即可)
- ❌ Universal Links(无 web 客户端)
- ❌ APNs Push 通知

锁后 v0.9 = **8-10 个 Phase**(W-1/X-1/W-2/W-3/X-2/X-3/X-4 必修 + Y/AA/BB 候选 + Z 收尾),W 与 X 系列大部分可并行,X 系列等 Apple Developer 注册审核通过。

### [2026-05-28] **v0.9 发布(Phase Z 收尾)**

v0.9 = **8 个实施 Phase**(W-1/W-2/W-3 设备配对 + X-1/X-2/X-3/X-4 签名分发)+ Z 收尾全部完成。Y/AA/BB 候选作者拍板不做。5 处版本号同步 `0.8` → `0.9.0`(`App/project.yml MARKETING_VERSION="0.9"` + `Backend/pyproject.toml="0.9.0"` + `app/main.py` + `routers/health.py` + `tests/test_auth.py`)。

**主菜达成(W)**:双端登录从"SSH HZ `sudo grep .env` 手填 32 字节 token"升级为"macOS 设备管理生成 QR + 6 位短码 → iOS 扫码/手输 → pairConfirm 拿 device-specific token 写 Keychain → 进主界面"。后端 `device_tokens`(Fernet 加密) + `pair_codes`(6 位数字 10 分钟 TTL,5/min per IP 防爆破) + 4 个 `/auth/*` 端点 + `require_bearer_token` 双路径(device-token 优先 hmac.compare_digest + static fallback v1.0.x 删)。

**必修达成(X)**:作者注册付费 Apple Developer(Team `HX73DFL88G`)。project.yml ad-hoc → Automatic signing + `ENABLE_HARDENED_RUNTIME`。`release-macos.sh`(Developer ID 真签 + notarytool + stapler)+ `release-ios.sh`(archive + export + altool API-key 上传)+ `ios-export.plist`。Info.plist 加 `ITSAppUsesNonExemptEncryption=NO` 免出口合规/法国声明。**X-4 实跑:macOS notarytool Accepted(任何 Mac 双击直开);iOS altool UPLOAD SUCCEEDED → TestFlight**。

**X-4 实战修正**:Xcode 26.5 altool 两处坑 ——`--store-password-in-keychain-item` 要 `--item` flag + `@keychain:` 查找 svce=NULL 失败,弃 app-specific-password keychain 改 App Store Connect API key(`.p8` in `~/.appstoreconnect/private_keys/`)。

**测试基线**(v0.8 末 → v0.9 末):pytest SQLite 200 → **222**(+22 W-1);macOS XCTest 124 → **132**(+8 DevicePairing);iOS XCTest 38 → **50**(+12 DevicePairViewModel)。全 `-W error` 干净,xcodebuild macOS + iOS Simulator 0/0。

**HZ 部署**:`./Backend/deploy/deploy-hz.sh` 推 0.9.0,`alembic upgrade head` 一条龙加 `device_tokens` + `pair_codes`(10 → 11 条迁移)。`https://lw.linotsai.top/api/v1/health` → `{"status":"ok","version":"0.9.0"}`。`hz_info.md` §9 同步新表 + §13 增补。

**LinoI 打包**:macOS 走 `release-macos.sh` Developer ID notarized 0.9 部署 `~/Desktop`;iOS 走 `release-ios.sh` 上 TestFlight 0.9。**TestFlight 新账号 warm-up**:作者当天注册首个 build,Apple 后端传播延迟,首装可走 Xcode → Run 真机(1 年证书)绕开。

**v0.9.x / v1.0 待办**(详 §1.4):TestFlight warm-up 完成后确认 OTA / iOS ipOverride(Y 已砍,真机不撞 DNS 即无需) / static api_token fallback v1.0.x 删 / pair_codes cron 清理。**v1.0 是下一个大版本**(打磨期)。

### [2026-05-28] **v0.9.1 发布(Keychain 零弹窗登录)** —— ⚠️ 已被 v0.9.2 整体回退

> **此版本有致命缺陷,macOS app 打不开,已于同日 v0.9.2 回退。下文保留作历史记录,实际生效方案见 v0.9.2。**

修掉 macOS LinoI 登录"输两次密码"的体验痛点。CC-1(KeychainStore 切数据保护 keychain + `keychain-access-groups` entitlement + 一次性迁移)+ Z'(release-macos.sh 保留 entitlement 重签 + 版本号 0.9.1 + 双端重打包)。**纯前端,后端零代码改动**(HZ redeploy 仅为版本 lockstep)。

**根因 → 解法**:`KeychainStore` 用文件型 login keychain(交互式 ACL)+ 存两个 item(`api_base_url` + `api_token.<host>`)→ 启动读两个 → 两次密码弹窗;ad-hoc 签名时"始终允许"永不生效(每 rebuild 签名变)。付费 Developer 给稳定签名 + `keychain-access-groups` entitlement → 切**数据保护 keychain**(iOS 那套,entitlement 门控非交互)→ macOS 零弹窗。一次性 `migrateFromLegacyKeychainIfNeeded()` 把老文件型 item 搬进数据保护 keychain(顶多迁移时弹最后一次)。

**X-4 两个签名管线坑(已固化 release-macos.sh)**:
1. `codesign --force` 不带 `--entitlements` 会剥掉 entitlement → 数据保护 keychain 失效。修:`codesign -d --entitlements - --xml` 抽出 + 重签 `--entitlements` 带回 + 硬验证。
2. 抽出的 entitlement 含 `get-task-allow=true`(Apple Development 签名注入的 debug entitlement)→ notarize **Invalid**(statusCode 4000)。修:`PlistBuddy -c "Delete :com.apple.security.get-task-allow"` 精确剥掉再重签。

**验证**:macOS 136 + iOS 50 XCTest 全过;macOS 0.9.1 **notarize Accepted** + `keychain-access-groups` 在最终签名里存活 + spctl accepted,部署 `~/Desktop/LinoI.app`(0.9.1);HZ `{"status":"ok","version":"0.9.1"}`;iOS 0.9.1 上 TestFlight。5 处版本号 → 0.9.1。

**子 agent 插曲**:CC-1 builder 跑 macOS keychain migration 测试时,headless `xcodebuild test` 在文件型 keychain 操作上挂死(ACL 弹窗无人应答);coordinator 杀掉挂住的 xcodebuild 子进程后 builder 恢复 + 自清 DIAG 诊断脚手架。最终 migration 测试靠 probe(`errSecMissingEntitlement` 探测)在无 entitlement 的 test host 优雅 XCTSkip,136 全过不挂。

### [2026-05-28] **v0.9.2 发布(回退 v0.9.1,Plan A)**

v0.9.1 上线即翻车:macOS app **直接打不开**(Finder「应用程序"LinoI"无法打开」)。作者一句"直接叫 review 出来做个体检",reviewer 独立体检定位根因,作者拍板 **Plan A 整体回退** → v0.9.2。详 §5.CC.6。

**根因**:`keychain-access-groups` entitlement 让 Xcode 给 target 嵌入设备锁定的 development provisioning profile → 与 release-macos.sh 的 Developer ID 重签证书类型不匹配 → **AMFI 拒绝 launchd 启动**(POSIX 163)。**最阴的点:notarize Accepted + spctl accepted 全过,公证根本不验 profile 与证书的类型一致性,所以一路绿灯直到双击才炸。**

**回退动作**:`KeychainStore.swift` `git checkout 371f9e4` 回 v0.9 文件型 keychain;`AppEnvironment.swift` 移除 migration 调用;`LinoWriting.entitlements` 回 v0.9 休眠内容;`project.yml` 删 `CODE_SIGN_ENTITLEMENTS` 行(profile 嵌入根源);`release-macos.sh` 改为重签前 strip `embedded.provisionprofile` + 重签不带 `--entitlements` + 硬验证「无 get-task-allow + 无 embedded profile」;删 `KeychainStoreMigrationTests.swift`。**纯前端 + 打包脚本,后端零代码改动**(HZ redeploy 仅版本 lockstep)。

**"两次密码"真根因再认识**:不是文件型 keychain 的错,是 **ad-hoc 签名让「始终允许」永不持久**(每 rebuild 签名变=新身份)。稳定 Developer ID 签名下,文件型 keychain「始终允许」点一次永久生效 —— 零弹窗**无需** entitlement / 数据保护 keychain,CC 方案是用错工具解对问题。

**验证**:macOS 132 + iOS 50 XCTest 过;macOS 0.9.2 notarize Accepted + stapler OK + **无 embedded profile + 无 get-task-allow**;**关键 —— `open ~/Desktop/LinoI.app` exit 0 + 进程真起来(无 AMFI/POSIX 163),启动回归已修**(吸取教训:不再只看 notarize 就宣布完成);HZ `{"status":"ok","version":"0.9.2"}`;iOS 0.9.2 上 TestFlight(`No errors uploading archive`)。5 处版本号 → 0.9.2。

**通用教训(已固化进 CLAUDE.md)**:① Developer ID 分发的 app 必须真机 `open` 验证能启动,notarize/spctl 全过 ≠ 能打开;② 给带 entitlement 的 target 做 Automatic signing 会嵌入 development profile,与 Developer ID 重签互斥 —— Developer ID 分发就别给 target 配 `CODE_SIGN_ENTITLEMENTS`(除非你确实需要,且重签时一并处理 profile)。

### [2026-05-31] v0.9.3 plan 锁定（导入/提取解耦 + 导入 sheet 布局急修）

接管者按三段式开 planner。作者试用反馈两个 bug:(1) 新建章节 sheet 切「导入」模式后底部「导入」按钮被挤出 sheet 可视区(macOS sheet 高度 ≤ 父窗口 + 正文 TextEditor `maxHeight:.infinity` + 无 maxHeight 约束);(2) 贴正文导入后被晾在空白草稿 SOP、正文丢失(根因:`NewChapterSheet` 走「先建空骨架 → 调 `/import`」两步,且 `/import` 默认 `run_extractor=true` 跑 LLM,LLM 失败 `db.rollback()` 把正文一起回滚,只剩第一步空骨架载入编辑器)。

作者拍板目标流:**导入只落正文(→finalized,不碰 LLM,永远成功);提取角色/时间线改为作者手点工具栏按钮单独跑**。详案落 §5.DI,Phase 落 §4.6。4 个 Phase:DI-1 后端新增 `POST /chapters/{id}/extract`(finalized + 有 draft_text 才跑,先删本章旧 timeline 保证可重复提取,失败 rollback 不动正文;新增 `no_draft_to_extract` 错误码;**无 Alembic 迁移**) / DI-2 前端两个 sheet 改 ScrollView+钉死 footer 修按钮裁切 + 导入一律 `run_extractor=false` + 失败回滚删空骨架 / DI-3 前端 `extractChapter` + `ChapterEditorStore.extract()` + 工具栏「提取」按钮 / DI-4 收尾发版(5 处版本号 → 0.9.3 + HZ redeploy 无迁移 + 双端重打包)。DI-1/DI-2/DI-3 契约定死后可并行。`ChapterImportRequest.run_extractor` 字段保留,前端只是改为始终传 false。

### [2026-05-31] DI-3 + DI-2 施工完成（前端）
- 变更内容：DI-3 提取通路落地 —— `APIClient.extractChapter(id:)`(无 body POST `/extract`,复用 `ChapterImportResponse`)+ `MockAPIClient.onExtract` 钩子 + `extractChapter` 默认实现 + `ChapterEditorStore.isExtracting`(并入 `resetAllPublishedToIdle`)+ `extract()`(镜像 `finalize()`,写 `chapter`/`lastUpdatedCharacterIds`,失败 → ErrorBus)+ `ChapterToolbar` 在 `.finalized` 分支加「提取角色/时间线」按钮(与「重新打开」并列,`isExtracting` 时禁用 + spinner,成功后 `upsert`/`markUpdated`/非空则 `charactersStore.load`)。DI-2 布局 + 导入解耦 —— `NewChapterSheet` / `ImportChapterSheet` 改「钉死 header + ScrollView 表单 + 钉死 footer」并加 `maxHeight:560` 修按钮裁切;删两个 sheet 的 `runExtractor` Toggle 换成「导入只保存正文…」提示文案,`submitImport`/`submitBatch`/`ImportChapterSheet.submit` 一律 `runExtractor:false`;`submitImport` trim 正文 + 失败回滚 `chaptersStore.delete(id:)` 删空骨架 + `chapterEditorStore.reset()`。
- 变更原因：执行 §5.DI.3 前端文件级改动。
- 影响范围：Phase DI-2、DI-3。
- 偏离说明(均为实现细节,不改契约):
  - 提取按钮 SF Symbol 选 `sparkles`(plan 给的候选之一)。
  - 顺手修了 `ChapterToolbar`「导入文本」按钮的 `.help` 文案(原文「并可选择让 Agent 提取…」描述的是已删除的 Toggle 行为)—— 属 DI-2「换提示文案」范畴。
  - `NewChapterSheet` / `ImportChapterSheet` 的 `charactersStore` `@EnvironmentObject` 解耦后不再被引用,保留未删(`@EnvironmentObject` 未用不产生编译告警,删它需动父级环境注入,超出本 Phase 范围)。
  - 新增前端测试文件 `LinoWritingTests/ChapterExtractTests.swift`(7 例:extract happy/failure/无章节短路/load 清 isExtracting/mock 默认 envelope + submitImport 失败删骨架/成功不回滚);`ChaptersStoreImportTests` 现有 `run_extractor=true` 断言均为 store/model 层显式传参的字段传递契约(非 sheet 驱动),plan 字段保留前提下不改。
- 验证:macOS `LinoWriting-macOS` 全 bundle 139 例 0 失败(基线 132 + 新增 7);App target build 成功无 warning。

### [2026-05-31] DI-1 后端 + reviewer 收口 + DI-4 版本号(v0.9.3 代码就绪,发版待真机)

- **DI-1 后端**:`Backend/app/routers/chapters.py` 新增 `POST /api/v1/chapters/{id}/extract`(镜像 `finalize_chapter`:`get_extractor_llm_client` 依赖 + `ensure_chapter_status({"finalized"})` + 空 `draft_text` 抛 409 + 提取前删本章 timeline + extractor 异常 `db.rollback()` 保正文/状态 + 返回 `{chapter, updated_character_ids, added_event_ids}`)。`Backend/app/errors.py` 加错误码 `("conflict","no_draft_to_extract")="本章没有正文可提取"` + `CHAPTER_ACTION_CN["extract"]="提取角色/时间线"`(后者为渲染 409 中文动词必需,plan 既有 i18n 规范的延伸)。**无 Alembic 迁移**。新增 `Backend/tests/test_chapter_extract.py` 覆盖 §5.DI.4 全部 5 条契约。
- **reviewer 收口**:独立审计无🔴致命,两个 bug 核心均修好。处理掉:🟡 `ChaptersStore.create()` 的 `showNewChapterSheet=false` 副作用让导入失败时 sheet 提前关、违反「保持打开供重试」→ 移除副作用改由调用方显式 dismiss(核对全部 `create()` 调用方);🟡 后端失败用例 ⑤ vacuous(原章节无 timeline)→ 改为先成功 extract 建 1 条 timeline 再失败,真断言 rollback 后旧 timeline 保留;🔵 端点预删 timeline 加注释说明真正去重点在 `apply_extractor_output`;🔵 删两个 sheet 解耦后未引用的 `charactersStore @EnvironmentObject`。🟡 xcodegen 把 3 个 xcscheme 从 `LinoI.app` 退回 `LinoWriting.app`(与本次无关的副作用)→ coordinator `git checkout` 还原。
- **DI-4 版本号**:5 处 `0.9.2 → 0.9.3`(`App/project.yml MARKETING_VERSION` + `Backend/pyproject.toml` + `app/main.py` + `routers/health.py` + `tests/test_auth.py`)。
- **测试基线**(v0.9.2 末 → v0.9.3):后端 pytest SQLite 222 → **229**(+7 extract);macOS XCTest 132 → **140**(+7 extract,1 keychain bundle 跑时跳过 → 实跑 136 非 keychain 绿);iOS XCTest **50**(extract 通路仅验编译,测试在 macOS bundle)。后端 `-W error` 干净。
- **⏳ 未做(发版操作,待作者驱动)**:① **真机 `open` 验证两个 bug 实修**(CLAUDE.md 铁律:notarize/测试过 ≠ 能用,必须真机跑一遍 SOP);② HZ `deploy-hz.sh` 推 0.9.3(**无迁移**,仅代码 + 版本)+ smoke `{"version":"0.9.3"}`;③ LinoI macOS `release-macos.sh`(Developer ID notarize)+ iOS `release-ios.sh`(TestFlight)双端重打包。**注意**:导入「只落正文」路径不依赖 `/extract`,连旧 HZ(0.9.2)也能验 Bug1/Bug2;但工具栏「提取」按钮需 HZ 部署 0.9.3 后才有 `/extract` 端点,否则 404。

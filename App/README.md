# LinoWriting (前端，v0.5)

SwiftUI 实现的 Mac/iOS 双平台原生 App，对接 `PLAN_FRONTEND.md` 描述的后端 API。

## 环境

- Xcode 16+ / 26.x
- macOS 14+，iOS 17+
- xcodegen（生成 `.xcodeproj`：`brew install xcodegen`）

## 构建与运行

```bash
cd LinoWritingV2/App
xcodegen generate          # 由 project.yml 生成 LinoWriting.xcodeproj
open LinoWriting.xcodeproj
# 选择 LinoWriting scheme + My Mac，Run。首启会弹 SettingsView 让你填后端 URL 和 Token。
```

CLI 一把构建：
```bash
xcodebuild -project LinoWriting.xcodeproj \
  -scheme LinoWriting \
  -destination 'platform=macOS,arch=arm64' \
  -configuration Debug build
```

iOS Simulator：
```bash
xcodebuild -project LinoWriting.xcodeproj \
  -scheme LinoWriting \
  -destination 'generic/platform=iOS Simulator' build
```

## 跑测试

```bash
xcodebuild -project LinoWriting.xcodeproj -scheme LinoWriting \
  -destination 'platform=macOS,arch=arm64' test
```

当前 17 个用例：
- `APIClientTests`：错误 envelope 映射、Chapter/Character/列表反序列化（8 个）。
- `SSEClientTests`：分包、CRLF、未知事件、错误事件（4 个）。
- `StoreTests`：建书 / 建章 / 扩写 / 写作 / 完成 全流程；inline 字段更新；ErrorBus 行为（5 个）。

## 项目结构

详见 `PLAN_FRONTEND.md` §5。简短版：

```
LinoWriting/
├── App/        @main + AppEnvironment（依赖注入）
├── Models/     Codable DTO，键名严格对齐后端
├── Services/   APIClient（含 SSE 流）/ KeychainStore / ErrorMapping / Settings
├── Stores/     ObservableObject，每个店铺一份职责
├── Views/      Root / Bookshelf / Workspace（三栏） / Components
└── Platform/   #if os(macOS) 收敛区
```

## 已实现 View 清单

- ✓ `RootView` / `SettingsView`（首启强制配置 + 「设置...」菜单）
- ✓ `BookshelfView` + `BookCardView` + `NewBookSheet`
- ✓ `WorkspaceView`（macOS：NavigationSplitView 三栏；iOS：抽屉式 RightPanel）
- ✓ `ChapterListView` + `NewChapterSheet`
- ✓ `ChapterEditorView` + `ChapterToolbar` + Step 1/2/3 卡片
- ✓ `RightPanelView` 4 tab：角色卡 / 时间线 / 摘要 / 世界设定
- ✓ `CharacterCardEditorView`（inline 文档式编辑，含冻结/活动分区与小红点）
- ✓ `TimelineTabView`（v0.5 只读）
- ✓ `SummariesTabView`（已完成章节摘要列表，点击跳转）
- ✓ `WorldSettingTabView`（双 markdown 文本框 + 失焦保存）
- ✓ `Toast` 右下角胶囊（`.thinMaterial`），3s 自动消失，401 长留

## 已对接端点（API contract §3.2）

| 端点 | 实现 | 备注 |
|---|---|---|
| `GET/POST/PATCH/DELETE /books` | ✓ | 含 `POST /books/{id}/touch` |
| `GET/POST/PATCH/DELETE /characters` | ✓ | 含时间线 `GET /characters/{id}/timeline` |
| `GET/POST/PATCH/DELETE /chapters` | ✓ | |
| `POST /chapters/{id}/expand` | ✓ | 含 `?force=true` 参数 |
| `POST /chapters/{id}/write`（SSE） | ✓ | started/token/progress/done/error |
| `POST /chapters/{id}/finalize` | ✓ | 返回 updated_character_ids |
| `POST /chapters/{id}/reopen` | ✓ | |
| `GET /admin/logs` | ✓ | APIClient 已暴露，UI 尚未做调试面板 |

## 已知偏差与后续待办

- **小红点：** 当前是「整卡级」标记（按 plan 的简化版方案），未做到字段级。`pendingHighlightIds` 在 finalize 后写入，用户点击该角色时清除。
- **Timeline 编辑：** v0.5 仍为只读列表，PATCH 端点尚未在 §3.2 出现，前端不实现编辑入口。
- **Summary 详情加载：** 摘要 tab 通过 `ChaptersStore.ensureSummary` 按需 `GET /chapters/{id}` 拉详细内容；正式后端如果 `ChapterSummary` 直接含 summary 字段，可去掉这层。
- **Admin Log Panel：** APIClient 已经把 `listAgentLogs` 暴露，但 UI 没做单独的调试视图（plan §6 未列）。需要时再叠一层。
- **代码签名：** project.yml 配置了 `CODE_SIGNING_ALLOWED: NO`，方便本机/CI 跑测试。云上分发前需要切回 Automatic 并提供 Team。

## 等待云上部署的环节

在真后端可用之前，本地可以：
1. 启动 mock 后端（FastAPI / Express 模拟 §3 端点）。
2. SettingsView 中填 `http://localhost:8787` + token。
3. 进入书架后建书 → 建章 → 扩写 → 写作（SSE）→ 完成。

正式部署时只需替换 baseURL。

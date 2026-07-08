# LinoWriting 前端（产物名 LinoI）

SwiftUI 双平台原生 App（macOS 26 / iOS 26，iPhone-only），对接 FastAPI 后端。项目唯一权威文件：仓库根 `PROJECT_PLAN.md`；工程坑单：仓库根 `CLAUDE.md`。

## 环境

- Xcode 26+，macOS 26+
- xcodegen（`brew install xcodegen`）

## 构建与测试

```bash
cd App
xcodegen generate   # 由 project.yml 生成 LinoWriting.xcodeproj
```

> ⚠️ **铁律**：每次 `xcodegen generate` 后必须修回 scheme 的产物名（详见根 CLAUDE.md）：
> ```bash
> sed -i '' 's/BuildableName = "LinoWriting.app"/BuildableName = "LinoI.app"/g' \
>   LinoWriting.xcodeproj/xcshareddata/xcschemes/*.xcscheme
> ```

```bash
# macOS 测试
xcodebuild -project LinoWriting.xcodeproj -scheme LinoWriting-macOS \
  -destination 'platform=macOS,arch=arm64' test

# iOS 测试（模拟器）
xcodebuild -project LinoWriting.xcodeproj -scheme LinoWriting-iOS \
  -destination 'platform=iOS Simulator,name=<你的模拟器>' test
```

门禁基线数字以 `PROJECT_PLAN.md §1 当前状态` 为准。

## 发布

- **macOS**：`scripts/release-macos.sh`（Developer ID 签名 + notarize；本地换包用 `--skip-notarize`）。发版后必须真机 `open /Applications/LinoI.app` + `pgrep` 验证能启动（CLAUDE.md 铁律：notarize 通过 ≠ 能启动）。
- **iOS**：付费 Developer 账号，Xcode 直装真机（dev 签名）；TestFlight 正式分发是长期欠账（见 PROJECT_PLAN §1）。`scripts/release-ios.sh` 为 TestFlight 链路备用。

## 结构

```
LinoWriting/
├── App/        @main + AppEnvironment（依赖注入）
├── Models/     Codable DTO，键名严格对齐后端 snake_case
├── Services/   APIClient / SSEClient / KeychainStore / ErrorMapping / Settings 等
├── Stores/     ObservableObject（每个一份职责）
├── Views/      Theme（玻璃主题层）/ Components / Bookshelf / Workspace / Reader / Root
│               macOS 用 Mac* 子目录、iOS 用 iOS 子目录，#if os() 隔离
└── Platform/   跨平台收敛区
```

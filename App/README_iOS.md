# LinoI iOS 自用安装（免费 Apple Developer 账号）

> 2026-05-26 拍板：本项目是作者自用 + 一台 Mac + 几台个人设备，**永远走 Xcode → device 直装 + 7 天 re-sign 工作流**，不上 TestFlight、不上 App Store、不邀别人测。
> 详 `PROJECT_PLAN.md` §5.R.9 / §5.V。

## 前提

- macOS 装好 Xcode 16+，命令行工具就位
- 免费 Apple Developer 账号（**Personal Team**，不需要 99 美元/年的 paid 账号）
- 作者本人 Apple ID（绑定自己的 iPhone / iPad）
- iPhone / iPad 跑 **iOS 17+**（`project.yml` 当前 deployment target 17.0）
- iPhone / iPad **打开开发者模式**：iOS 16+ 在「设置 → 隐私与安全性 → 开发者模式」开关，开后会要求重启
- iPhone / iPad 与 Mac 同 Wi-Fi（无线调试），或 USB 直连

## 约束（免费账号特性）

| 项 | 限制 |
|---|---|
| 签名证书 | **7 天有效**，第 8 天起 app 启动会被 iOS 拒绝（`Unable to verify app`） |
| 绑定设备数 | 同 Apple ID 最多 **3 台**（iPhone / iPad / iPod touch 合计） |
| Bundle ID | 任意，无需 Apple 注册。沿用 `com.lino.linowriting.LinoWriting` |
| TestFlight / App Store | **不可用** |
| 邀别人测 | **不可用** |

## 一次性配置（首次装机做一遍即可）

### 1. 改 `project.yml` 启用 iOS 自动签名

当前仓库的 `App/project.yml` 是 **macOS ad-hoc** 签名配置（builder 不预填 Team ID，避免把作者 Team ID 泄进 git diff）：

```yaml
settings:
  base:
    CODE_SIGN_STYLE: Manual
    CODE_SIGNING_REQUIRED: NO
    CODE_SIGNING_ALLOWED: NO
    CODE_SIGN_IDENTITY: ""
```

作者第一次往真机装时，**临时**改成 Automatic + Personal Team。两个落点选一：

**方案 A（最简单）**：直接在 Xcode UI 改 — 不动 `project.yml`，每次 `xcodegen generate` 后 Xcode UI 会保留作者 Team 选择吗？**会被覆盖**。所以方案 A 实际不可用。

**方案 B（推荐）**：在 `project.yml` 的 `LinoWriting` target 下加 iOS 专属签名段。本地 `.env.local` 存 Team ID，运行 `xcodegen` 前 export，xcodegen 不直接读 env 但 yaml 可被预处理 — **太复杂**。

**方案 C（实际做法）**：手动改 `project.yml`，把以下加到 `LinoWriting` target 的 `settings.base`：

```yaml
# iOS device 签名（self-deploy 时打开，git 提交前可以不还原 —
# Team ID 不算敏感信息，但散在仓库里碍眼）
CODE_SIGN_STYLE: Automatic
CODE_SIGNING_ALLOWED[sdk=iphoneos*]: YES
DEVELOPMENT_TEAM[sdk=iphoneos*]: <Personal Team ID, 10 字符大写字母数字>
```

> 用 `[sdk=iphoneos*]` 条件限定，让 macOS 的 ad-hoc 不受影响。
> Team ID 在 Apple Developer Portal 顶栏右侧能查到，免费账号也有。

然后 `xcodegen generate`，重新打开 `.xcodeproj`。

### 2. Xcode 第一次签名

1. 打开 `App/LinoWriting.xcodeproj`
2. 顶部 destination 选自己的 iPhone（连上 USB 或 wireless）
3. 左侧 Project Navigator 选 `LinoWriting` → 右侧 `Signing & Capabilities` 标签
4. 选自己的 Personal Team（应该会自动选）
5. Xcode 会自动创建一个 7 天 provisioning profile
6. iPhone 端首次跑会要求在「设置 → 通用 → VPN 与设备管理」里**信任**这个开发者证书（信任后才能启动 app）

### 3. Keychain 数据连续性

bundle ID = `com.lino.linowriting.LinoWriting` + device 不变 → iOS Keychain item 跨 7 天 re-sign 保留。**不需要每周重新填后端 URL 和 Token**。

## 周复用工作流（7 天 re-sign）

第 8 天起，app 在 iPhone 上启动会变灰 + 弹"Unable to verify app"。重跑一次 Xcode build 即可，**总耗时 ~15 秒**：

1. iPhone 连 Mac（USB 或同 Wi-Fi 自动配对）
2. `cd /Users/linotsai/Lino/LinoWritingV2/App && xcodegen generate`（如果改过 `project.yml`）
3. 打开 `LinoWriting.xcodeproj`
4. 顶部 destination 选自己的 iPhone
5. `Cmd + R`（或 `Product → Run`）
6. Xcode 重签 + 推到 device，约 15 秒
7. app 重新可用，再扛 7 天

## 命令行直装（可选 — `scripts/install-ios.sh`）

如果想跳过 Xcode UI，PROJECT_PLAN §5.R.10 建议过一个 shell 脚本一键装。当前 R-4 阶段不交付，需要时按下面模板补：

```bash
#!/usr/bin/env bash
# scripts/install-ios.sh — 7 天 re-sign 一键直装
set -euo pipefail

UDID="<在 Xcode → Window → Devices and Simulators 抄>"
cd "$(dirname "$0")/.."/App
xcodegen generate
xcodebuild \
  -project LinoWriting.xcodeproj \
  -scheme LinoWriting-iOS \
  -destination "platform=iOS,id=$UDID" \
  -configuration Debug \
  build install
```

需要 `DEVELOPMENT_TEAM` 已经配在 `project.yml` 里（见上文方案 C）。

## 测试矩阵

R-4 完工后，iOS Simulator 上跑 logic 测试：

```bash
cd /Users/linotsai/Lino/LinoWritingV2/App
xcodebuild -project LinoWriting.xcodeproj \
  -scheme LinoWriting-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test
```

iPad：

```bash
xcodebuild -project LinoWriting.xcodeproj \
  -scheme LinoWriting-iOS \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  test
```

macOS 基线（不动 iOS bundle）：

```bash
xcodebuild -project LinoWriting.xcodeproj \
  -scheme LinoWriting-macOS \
  -destination 'platform=macOS,arch=arm64' \
  test
```

§5.R.8 还要求人工 simulator 抽查（logic test 覆盖不到 SwiftUI view tree 真实渲染）：

- iPhone 17 Pro simulator：建书 → 建章 → 写作 → finalize → 导出 全跑一遍
- iPad Pro 13" portrait：三栏默认 double-column，toolbar 「辅助面板」按钮唤出第三栏
- iPad Pro 13" landscape：三栏全开
- 真机（作者本人 iPhone）抽一次：Keychain + UIDocumentPicker + SSE 跑通

## 不能做（拒绝候选池里的项）

- ❌ TestFlight 上架 — 邀人测、内测群、Apple Developer Program $99/年 这些**永久不做**
- ❌ App Store 上架 — 同上
- ❌ Enterprise 分发 — 同上
- ❌ Ad-hoc 分发链接 — 免费账号没有

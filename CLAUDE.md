# LinoWriting — 项目经验与约束

> 从全局 CLAUDE.md 抽出的项目级经验。放在 LinoWriting 项目根目录，重命名为 `CLAUDE.md`。

## macOS Developer ID 分发 + keychain entitlement 启动炸弹

**致命坑：** 给 Developer ID 分发的 macOS app 加 `keychain-access-groups` entitlement（想用 iOS 那套数据保护 keychain 消除密码弹窗），会让 Xcode Automatic signing 嵌入一个设备锁定的 **development** provisioning profile（`Mac Team Provisioning Profile`，带 `ProvisionedDevices`）。若 release 脚本随后用 `Developer ID Application` 证书 `codesign --force` 重签，证书类型（Developer ID）与 profile 类型（development）不兼容 → AMFI 在 launchd spawn 时拒绝 → 双击报「应用程序无法打开」。

* 指纹：`open` 报 `RBSRequestErrorDomain Code=5 / NSPOSIXErrorDomain Code=163 / Launchd job spawn failed`，但终端直跑二进制 exit 0；`codesign --verify` 过、`spctl --assess` accepted、**notarize 也 Accepted**（notary / Gatekeeper 都不查「证书 vs profile 类型」组合，只有启动期 AMFI 查）。
* 所以「notarize 过 = 没事」是误判：**必须真机 `open` 验证能启动 + `pgrep` 确认进程在，再宣布发版成功**。

**正解：** macOS 零 keychain 弹窗不该套 iOS 数据保护 keychain。稳定的 Developer ID 签名下，文件型 login keychain 的 ACL「始终允许」点一次就**永久持久**（ad-hoc 签名时永不持久，因为每次 rebuild 改变 designated requirement = 系统当新 app）。付费 Developer 拿到稳定签名后，文件型 keychain +「始终允许」本就是零弹窗正路，不需要 entitlement、不需要 profile。数据保护 keychain + team-prefix access group 是 App Store（有 provisioning）的玩法，Developer ID 上引狼入室。

## codesign 重签 & entitlement

* `codesign --force` 重签**默认剥 entitlement**；若要保留，`codesign -d --entitlements - --xml app > ent.plist` 抽出 + 重签 `--entitlements ent.plist`。
* 从「Apple Development」签名抽出的 entitlement **含 `com.apple.security.get-task-allow`**（debug，notarize statusCode 4000 拒），必须 `PlistBuddy -c "Delete :com.apple.security.get-task-allow"` 剥掉。
* 改 entitlements 文件**别整体替换**（会顺手丢掉 app-sandbox / network.client / files.user-selected）。

## keychain 存储迁移

* 改 keychain 存储/迁移时「先删老 → 后写新」会在写失败时丢数据：**必须确认新写成功才删老**（plan 契约也这么写），失败要把内存值写回，别只记 failed 列表让值蒸发。
* headless `xcodebuild test` 跑文件型 keychain 操作会触发 ACL 弹窗挂死；带 entitlement 的 test host 数据保护 keychain 才不挂——keychain 行为是发版前**真机 / 真签名人工 checklist** 项，单测全 XCTSkip 给不了保障。

## iOS 布局（macOS 尺寸漏套，v0.9.4/0.9.5 三连修的根因）

* **改 iOS View 后必须 `simctl launch` 真跑 + 截图看**，不能只 build/archive——build/archive 成功 ≠ 渲染正确。v0.8/v0.9 的 iOS UI 一路只 build 从没真 launch，攒出白屏 + 工具栏药丸 + sheet 溢出三类 bug。
* **给 macOS 窗口/sheet 用的 `.frame(minWidth:)` 必须 `#if os(macOS)` 包起来**，否则 iPhone（~393pt）被强制撑宽：居中内容看着没事，贴边的导航栏/工具栏/标题/Toast 全被顶出屏幕（白屏假象，极具迷惑性）。
* 宽屏 `HStack` + 带中文文字标签的按钮在 compact 宽度会竖排逐字换行撑成巨型药丸：compact 下整簇 `.labelStyle(.iconOnly)`，固定元素 `.fixedSize()`。
* 系统性扫屏法：`RootView` 临时加 DEBUG 截图画廊（`--args uiscreen=<name>` 渲染单屏），build 一次逐屏 `simctl launch` + 截图，用完 `git checkout` 还原。

## 长文档 HTML 收口 PDF（从全局 CLAUDE.md 移回，2026-05-30 经验）

* 长/复杂文档优先用 Chromium 原生 `page.pdf()`，别迷信 Paged.js：后者在整文档累积到一定规模时会同步死循环（页计数冻结、页面内 setTimeout 被节流），单区块却正常——排查极费时。看门狗必须放 Node 侧。
* 「目录带页码」用两遍渲染：第一遍出 PDF，用 PyMuPDF 读内链 GoTo 目标页回填，第二遍出最终稿。比 CSS target-counter 稳。
* 导出前必须把所有 JS 驱动的终态强制写死（计数终值、条形/雷达宽度、展开 hover/折叠），并 `print-color-adjust:exact` 保深色与强调色；逐页渲 PNG 拼总览图自查「数据不崩」。
* CJK 表格防溢出：`table-layout:fixed` + 单元格 `word-break:break-word;overflow-wrap:anywhere`；外部 URL 用 `[文字](链)` 短链文本，别贴裸长 URL（不可断字会撑破列）。
* 中文/PDF 工具链先确认「同一个 python 解释器同时有 markdown+fitz+PIL」再开工，别假设 `python3` 指向你想要的那个。写文件时若字符串里的空格被写成 `\x00`（SyntaxError: EOL/null bytes），换非空格哨兵重写整文件。

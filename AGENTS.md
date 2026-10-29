# AGENTS.md

> 本文件用于指导 AI 编码 Agent 在本仓库内编码、修改、自测、提交；以命令、约束、边界为主。
> 需求见 `docs/requirements.md`，设计见 `docs/technical-design.md`。两者与代码冲突时，以代码和本文件为准。

## 1. 项目概览

macOS 14 菜单栏应用，在本机记录剪切板历史，并粘贴回前台应用。技术栈：Swift 5、AppKit + SwiftUI、系统 `sqlite3`、Carbon `RegisterEventHotKey`。最低系统 macOS 14，`LSUIElement = YES`，无 Dock 图标，不开启 App Sandbox。

架构：`Domain` 做条目、哈希、搜索、保留，不碰剪切板；`Features` 做采集、面板、粘贴、隐私、设置；`Storage` 写 SQLite 与负载文件；`Platform` 提供热键、辅助功能、登录项、前台应用；`App` 把状态栏和面板装起来。

v1 只做本地历史：采集、搜索、预览、粘贴、隐私、保留、设置。不要加片段库、规则、同步、OCR、账号或 Sparkle。

不要破坏的行为：

- 采集只读需要的类型。超限内容先对原文哈希，再只存预览。不同的大文本不能并成一条。
- 跳过暂停、本应用、`org.nspasteboard.TransientType`、机密标记，以及钥匙串、密码、1Password、Bitwarden。安全输入结束后 1 秒内的变化也跳过。
- 日志和关于页诊断 JSON 不包含剪切板正文。
- 打开菜单时记下前台应用，不要等到点击菜单项。粘贴按键前先关闭面板。失败时重新打开面板，并保留「未能自动粘贴，已复制，请手动粘贴」。
- `plainCopy` 只写入剪切板。回车是完整粘贴，⌘回车只复制，⇧回车粘贴纯文本。⌘⌫ 清空全部并二次确认；历史为空时不弹窗。
- 搜索框处于编辑时，Delete、左右方向键和 ⌘Z 交给输入框。回车仍粘贴当前条目。⌘⌫ 仍清空，不交给输入框。
- ⌘⇧V 在光标所在屏幕正中打开面板。菜单里的「打开主面板」才跟随「面板位置」设置。
- 热键用 Carbon 修饰键保存。拒绝单独的 ⌘C、⌘V、⌘X、⌘Q。
- 删除先删数据库行，成功后再删文件。失败要提示，不能显示已删除。清空后再 `VACUUM`。置顶不参与条数、天数和 200MB 图片容量。
- `sqlite3_step` 失败必须抛错，不能把历史列表变成空的。
- 状态栏图标保持模板图，暂停画斜杠，未授权画圆点。

## 2. 构建 & 启动命令

本仓库没有包管理器安装步骤，也不使用 pnpm。用 Xcode 或下面的 `xcodebuild`。

```bash
# 构建
xcodebuild -project ClipboardAssistant.xcodeproj -scheme ClipboardAssistant -destination 'platform=macOS' -derivedDataPath /tmp/ClipboardAssistantDD build

# 本地运行。应用没有 Dock 图标，从菜单栏进入
open /tmp/ClipboardAssistantDD/Build/Products/Debug/ClipboardAssistant.app

# 清理产物
xcodebuild -project ClipboardAssistant.xcodeproj -scheme ClipboardAssistant -destination 'platform=macOS' -derivedDataPath /tmp/ClipboardAssistantDD clean
```

替换二进制前先结束旧进程：`kill $(pgrep -x ClipboardAssistant)`。本地 ad-hoc 签名即可。没有 Developer ID 时不要公证；步骤只写在 `Packaging/notarize.md`。不要打开 App Sandbox。

## 3. 校验 & 测试命令（最重要章节）

没有独立的 lint 或 `tsc`。校验就是编译并跑 `ClipboardAssistantTests`。

```bash
# 全量测试（同时完成编译检查）
xcodebuild -project ClipboardAssistant.xcodeproj -scheme ClipboardAssistant -destination 'platform=macOS' -derivedDataPath /tmp/ClipboardAssistantDD test

# 单文件测试
xcodebuild -project ClipboardAssistant.xcodeproj -scheme ClipboardAssistant -destination 'platform=macOS' -derivedDataPath /tmp/ClipboardAssistantDD test -only-testing:ClipboardAssistantTests/LogicTests
```

> 要求：所有修改完成后，**必须先跑全量测试，修复报错再输出最终代码**。改保留、哈希、隐私或粘贴模式时，补 `Tests/` 里的对应断言。测试不启动菜单栏。

## 4. 目录结构与职责

- `App/`：入口、状态栏、面板装配。可新增、修改。
- `Domain/`：条目、哈希、搜索、保留。可新增、修改。禁止读写剪切板。
- `Features/`：采集、历史面板、粘贴、隐私、设置。可新增、修改。
- `Storage/`：SQLite 与负载文件。可新增、修改。
- `Platform/`：热键、辅助功能、登录项、前台应用。可新增、修改。
- `Tests/`：单元测试。可新增断言。新文件必须加入 `ClipboardAssistantTests` 的编译列表。
- `docs/`：需求与设计。一般只做增量更新，不把未实现的能力写成已完成。
- `Packaging/`：签名与公证说明。没有证书时不要执行公证命令。
- `ClipboardAssistant.xcodeproj/`：源文件是显式登记的。新增 `.swift` 必须同时改工程，否则编译看不到它。
- `logs/`：运行日志。不要把剪切板正文写进去，也不要把它当源码改。

## 5. 代码规范 & 范式

目录和符号用英文。界面文案只用 `L10n.text(zh:en:)`，不要写死一种语言。

```swift
Text(L10n.text("清空全部历史？", "Clear all history?"))
```

隐私判定放在 `PrivacyGate`，调用方只填 `PrivacyDecision`。跳过条件是返回 `false`，不要在采集处再复制一套判断。

```swift
if decision.isPaused { return false }
if decision.hasTransientMarker { return false }
if decision.secureInputEnabled && !decision.recordDuringSecureInput { return false }
```

粘贴模式决定写什么、发不发 ⌘V。`plainCopy` 只写剪切板。

```swift
var sendsKeystroke: Bool {
    self == .automatic || self == .plainText
}
```

数据库错误用 `throw`，不要吞掉 `sqlite3_step` 的失败。删除先删行，成功后再删负载文件。

```swift
func delete(id: String) throws {
    try locked {
        try database.run("DELETE FROM items WHERE id = ?") { bindText($0, 1, id) }
        payloads.removeItem(id: id)
    }
}
```

## 6. 分支 & 提交说明

从最新的 `main` 拉分支。不要直接在 `main` 上改。一个分支只做一件事。

分支名是 `类型/短横线英文摘要`，全小写，不用空格、中文或票据号。类型与提交说明相同。

```text
feat/source-app-icons
fix/clear-all-confirm
docs/readme
```

提交说明用 Conventional Commits，英文祈使句，说明为什么改，不要罗列文件。主题一行，不超过 72 个字符，句末不加句号。需要时再空一行写正文。

```text
feat: show source app icons and confirm clearing history

docs: expand README with setup, privacy, and retention
```

| 类型 | 用途 |
|---|---|
| `feat` | 用户能感知的行为 |
| `fix` | 修复已有行为 |
| `docs` | 只改文档 |
| `test` | 只补测试 |
| `chore` | 构建、工程或忽略规则，不改产品行为 |

合进 `main` 用 squash merge，主题就是合并后的那条提交说明。不要提交密钥、剪切板正文或 `logs/`。用户没要求时不要 push，不要改 git 配置，不要 `--no-verify`，不要 force push。

# 剪切板助手

macOS 14 菜单栏应用，记录本机剪切板历史并粘贴回前台应用。需求见 `docs/requirements.md`，设计见 `docs/technical-design.md`。两者与代码冲突时，以代码和本文件为准。

v1 只做本地历史：采集、搜索、预览、粘贴、隐私、保留、设置。不要加片段库、规则、同步、OCR、账号或 Sparkle。

## 目录

| 目录 | 职责 |
|---|---|
| `App` | 入口、状态栏、面板装配 |
| `Domain` | 条目、哈希、搜索、保留，不碰剪切板 |
| `Features/Capture` | 400ms 轮询与入库判定 |
| `Features/History` | 主面板 |
| `Features/Paste` | 写回剪切板和 ⌘V |
| `Features/Privacy` | 暂停、机密、排除应用 |
| `Features/Settings` | 偏好与设置窗口 |
| `Storage` | SQLite 与负载文件 |
| `Platform` | 热键、辅助功能、登录项、前台应用 |
| `Tests` | 不启动菜单栏的单元测试 |

界面文案用 `L10n.text(zh:en:)`。目录和符号用英文。

## 构建与运行

```bash
xcodebuild -project ClipboardAssistant.xcodeproj -scheme ClipboardAssistant -destination 'platform=macOS' -derivedDataPath /tmp/ClipboardAssistantDD test
open /tmp/ClipboardAssistantDD/Build/Products/Debug/ClipboardAssistant.app
```

应用是 `LSUIElement`，没有 Dock 图标。替换二进制前先结束旧进程。本地 ad-hoc 签名即可。没有 Developer ID 时不要公证；步骤只写在 `Packaging/notarize.md`。不要打开 App Sandbox。

## 不要破坏的行为

- 采集只读需要的类型。超限内容先对原文哈希，再只存预览。不同的大文本不能并成一条。
- 跳过暂停、本应用、`org.nspasteboard.TransientType`、机密标记，以及钥匙串、密码、1Password、Bitwarden。安全输入结束后 1 秒内的变化也跳过。
- 日志和关于页诊断 JSON 不包含剪切板正文。
- 打开菜单时记下前台应用，不要等到点击菜单项。粘贴按键前先关闭面板。失败时重新打开面板，并保留「未能自动粘贴，已复制，请手动粘贴」。
- `plainCopy` 只写入剪切板。回车是完整粘贴，⌘回车只复制，⇧回车粘贴纯文本。
- 搜索框处于编辑时，Delete、左右方向键和 ⌘Z 交给输入框。回车仍粘贴当前条目。
- ⌘⇧V 在光标所在屏幕正中打开面板。菜单里的「打开主面板」才跟随「面板位置」设置。
- 热键用 Carbon 修饰键保存。拒绝单独的 ⌘C、⌘V、⌘X、⌘Q。
- 删除先删数据库行，成功后再删文件。失败要提示，不能显示已删除。清空后再 `VACUUM`。置顶不参与条数、天数和 200MB 图片容量。
- `sqlite3_step` 失败必须抛错，不能把历史列表变成空的。
- 状态栏图标保持模板图，暂停画斜杠，未授权画圆点。

改保留、哈希、隐私或粘贴模式时，补 `Tests/` 里的对应断言。

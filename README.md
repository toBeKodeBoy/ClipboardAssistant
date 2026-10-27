# 剪切板助手

macOS 菜单栏应用。系统剪切板只留最近一次复制，这个应用在本机记下文本、富文本、图片和文件，再用快捷键贴回当前应用。

需要 macOS 14 或更高版本。没有 Dock 图标，入口在屏幕右上角。

## 使用

1. 用 Xcode 打开 `ClipboardAssistant.xcodeproj` 并运行，或按下面的命令编译后启动。
2. 在系统设置的辅助功能里允许「剪切板助手」。没有这项权限时仍会记录历史，但不会自动按 ⌘V。
3. 在任意应用里复制。约半秒后出现在历史里。
4. 按 ⌘⇧V，主面板在光标所在屏幕的正中打开。选中一条后回车，内容写回剪切板并粘贴到刚才的应用。

| 操作 | 结果 |
|---|---|
| 回车 | 按原始类型粘贴 |
| ⌘回车 | 只复制，不粘贴 |
| ⇧回车 | 只粘贴纯文本 |
| 菜单栏图标 | 最近 10 条，以及暂停、设置 |

热键可以在设置里改。单独的 ⌘C、⌘V、⌘X、⌘Q 不能用作热键。

## 隐私

历史只存在这台 Mac 上，路径是 `~/Library/Application Support/ClipboardAssistant/`。

默认不记录：

- 钥匙串、系统「密码」、1Password、Bitwarden 里的复制
- 带机密标记或 `org.nspasteboard.TransientType` 的内容
- 密码框等安全输入期间，以及结束后 1 秒内的变化

可在设置里暂停记录、把某个应用加入排除列表。关于页导出的诊断文件不含剪切板正文。

## 保留

默认最多 500 条、30 天，图片合计 200MB。超出后删掉最久未使用的未置顶条目。置顶不参与这些限制。单条文本超过 1MB、图片超过 10MB 时只留预览。

## 开发

```bash
xcodebuild -project ClipboardAssistant.xcodeproj -scheme ClipboardAssistant -destination 'platform=macOS' -derivedDataPath /tmp/ClipboardAssistantDD test
open /tmp/ClipboardAssistantDD/Build/Products/Debug/ClipboardAssistant.app
```

v1 不进沙盒。本地调试使用 ad-hoc 签名。签名和公证步骤见 `Packaging/notarize.md`。

更细的产品和实现说明：

- [需求](docs/requirements.md)
- [技术方案](docs/technical-design.md)
- [给代理的约定](AGENTS.md)

v1 不做片段库、规则、同步、OCR 和账号。

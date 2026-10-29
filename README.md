# 剪切板助手

一款适用于 **macOS 14 及以上版本**的菜单栏应用，在本机记录剪切板历史，帮助你搜索、预览并将内容粘贴回前台应用。

应用没有 Dock 图标，启动后从屏幕顶部的菜单栏进入。当前 v1 聚焦本地历史，不包含片段库、规则、同步、OCR、账号或自动更新功能。

![![20261027215705](httpspersonallearningbed.oss-cn-beijing.aliyuncs.com20261027215705.png)](https://personallearningbed.oss-cn-beijing.aliyuncs.com/![20261027215705](httpspersonallearningbed.oss-cn-beijing.aliyuncs.com20261027215705.png).png)

## 主要功能

- 记录文本、富文本、图片和文件引用，约每 400ms 检查一次剪切板变化。
- 按内容、标题和来源应用名称搜索，按文本、图片、文件或置顶筛选。
- 预览历史、置顶常用条目、删除记录，并在访达中显示文件。每条历史显示来源应用图标、名称和相对时间；应用已卸掉或没有 bundle id 时显示通用应用符号。
- 按原始类型粘贴、粘贴纯文本，或仅复制到剪切板。
- 暂停采集、排除指定应用，按条数、天数和图片容量自动清理。
- 设置开机启动、全局快捷键、外观、粘贴行为和面板位置。

## 从源码运行

需要 macOS 14 或更高版本，以及支持 macOS 14 SDK 的 Xcode。可直接用 Xcode 打开 `ClipboardAssistant.xcodeproj`，选择 `ClipboardAssistant` scheme 运行。

也可以在项目根目录执行：

```bash
xcodebuild -project ClipboardAssistant.xcodeproj -scheme ClipboardAssistant -destination 'platform=macOS' -derivedDataPath /tmp/ClipboardAssistantDD build
open /tmp/ClipboardAssistantDD/Build/Products/Debug/ClipboardAssistant.app
```

本地调试使用 ad-hoc 签名，不启用 App Sandbox。重新构建并替换正在运行的应用前，先结束旧的 `ClipboardAssistant` 进程。分发签名与公证说明见 [Packaging/notarize.md](Packaging/notarize.md)。

## 首次使用

1. 启动应用，在菜单栏找到剪切板图标。
2. 若需要自动粘贴，在「系统设置 → 隐私与安全性 → 辅助功能」中允许「剪切板助手」。未授权时仍可记录历史和复制内容。
3. 在其他应用中复制内容，稍后即可在历史中看到。
4. 按 **⌘⇧V** 打开主面板，搜索或选择一条记录，按回车粘贴回刚才的应用。

菜单栏菜单提供最近 10 条记录，以及「打开主面板」「暂停记录」和「设置」入口。

### 粘贴与复制

- **回车**：按原始类型粘贴；如果通用设置选择了「只写入剪切板」，则仅复制。
- **⌘回车**：仅复制，不自动粘贴。
- **⇧回车**：粘贴纯文本。
- **右键菜单 → 纯文本复制**：仅把纯文本写入剪切板。
- **⌫**：删除当前条。置顶条目需要确认。单条删除可用 ⌘Z 撤销，直到面板关闭。
- **⌘⌫**：清空全部历史。确认说明写明条数，并包含已置顶条目。取消不删除。没有记录时不弹窗；搜索框正在编辑时，这个快捷键仍用于清空。

自动粘贴失败时，面板会显示「未能自动粘贴，已复制，请手动粘贴」，此时可切回目标应用按 ⌘V。

全局快捷键可在设置中修改，但不能使用单独的 ⌘C、⌘V、⌘X 或 ⌘Q。快捷键始终在鼠标光标所在屏幕的正中打开面板；菜单中的「打开主面板」遵循「面板位置」设置。

## 隐私与本地数据

历史保存在本机目录：

```text
~/Library/Application Support/ClipboardAssistant/
```

默认隐私设置会跳过：

- 钥匙串访问、系统「密码」、1Password、1Password 7 和 Bitwarden 中的复制。
- 带机密标记或 `org.nspasteboard.TransientType` 标记的内容。
- 安全输入期间，以及安全输入结束后 1 秒内的剪切板变化。
- 暂停期间的变化，以及本应用自身写回的内容。

「设置 → 隐私」可管理排除应用、机密标记和安全输入选项。菜单栏可暂停或恢复记录；暂停时长支持手动恢复、15 分钟和 1 小时。

日志及「设置 → 关于」导出的诊断 JSON 不包含剪切板正文。文件历史保存的是文件引用，不是文件内容备份。

## 保留策略与内容限制

默认最多保留 **500 条、30 天**，未置顶图片的容量上限为 **200MB**。

- 到期条目按创建时间清理；条数或图片容量超限时，优先清理最久未使用的未置顶条目。
- 置顶条目不参与条数、天数和图片容量限制。
- 设置中可调整条数与天数，也可选择不限制条数或永久保留；图片容量上限固定为 200MB。
- 单条文本超过 1MB 或图片超过 10MB 时，只保留预览信息，不能从该历史条目恢复复制或粘贴。
- 主面板 **⌘⌫** 和设置中的「清空全部历史」都会删除所有记录，**包括置顶条目**。

## 开发与测试

在项目根目录运行测试：

```bash
xcodebuild -project ClipboardAssistant.xcodeproj -scheme ClipboardAssistant -destination 'platform=macOS' -derivedDataPath /tmp/ClipboardAssistantDD test
```

单元测试位于 `Tests/`，不启动菜单栏应用。修改保留策略、哈希、隐私或粘贴模式时，需要补充对应断言。

### 目录导航

- `App/`：应用入口、菜单栏和面板装配。
- `Domain/`：条目模型、哈希、搜索和保留策略。
- `Features/`：采集、历史面板、粘贴、隐私和设置。
- `Storage/`：SQLite 数据库与负载文件。
- `Platform/`：全局热键、辅助功能、登录项和前台应用。
- `Tests/`：逻辑与存储测试。
- `Packaging/`：分发签名与公证说明。

界面文案统一通过 `L10n.text(zh:en:)` 提供，目录和符号使用英文。完整的修改约定见 [AGENTS.md](AGENTS.md)。

## 相关文档

- [产品需求](docs/requirements.md)
- [技术设计](docs/technical-design.md)
- [开发约定](AGENTS.md)
- [签名与公证](Packaging/notarize.md)

需求或设计文档与实现不一致时，以当前代码和 `AGENTS.md` 为准。

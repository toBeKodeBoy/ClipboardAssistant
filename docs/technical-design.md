# Mac 剪切板助手 · 技术方案

| 项 | 决定 |
|---|---|
| 对应需求 | `docs/requirements.md` v1.0 |
| 系统 | macOS 14 及以上，Apple Silicon 与 Intel 通用二进制 |
| 语言 | Swift 5.9 |
| 界面 | SwiftUI 面板与设置，AppKit 负责菜单栏、窗口和剪切板 |
| 形态 | `LSUIElement = YES` 的菜单栏应用，无 Dock 图标 |
| 分发 | Developer ID 签名、硬化运行时、公证后的直接下载 |
| 沙盒 | v1 不沙盒 |
| 数据 | 本机 SQLite，图片与原始负载落在应用支持目录 |

v1 只做本地历史的采集、搜索、预览和粘贴。片段库、规则和同步不进入本方案的实现范围，只在数据模型上留出版本号。

## 1. 技术选型

| 能力 | 选择 | 原因 |
|---|---|---|
| 菜单栏 | `NSStatusItem` | 系统状态栏常驻，模板图标可随浅色深色变色 |
| 主面板 | `NSPanel` + SwiftUI | 使用 `nonactivatingPanel`，呼出时原应用保持前台 |
| 设置窗口 | SwiftUI `Settings` 场景 | 与面板共用同一套偏好 |
| 剪切板 | `NSPasteboard.general` | 读写系统通用剪切板 |
| 采集触发 | 轮询 `changeCount` | 公开 API 没有稳定的剪切板变化通知 |
| 全局快捷键 | Carbon `RegisterEventHotKey` | 注册单个热键，不申请输入监控 |
| 来源应用 | `NSWorkspace.frontmostApplication` | 读取前台应用身份不需要辅助功能 |
| 自动粘贴 | 先激活原应用，再 `CGEvent` 发送 ⌘V | 辅助功能授权后才能送达其他应用 |
| 安全输入 | `IsSecureEventInputEnabled()` | 密码框场景停止采集 |
| 开机启动 | `SMAppService.mainApp` | macOS 13 以上的登录项 API |
| 存储 | 系统 `sqlite3` | 查询简单，不引入第三方数据库 |
| 更新 | Sparkle，只检查不自动下载 | 匹配直接分发；设置里可关闭 |
| 日志 | `os.Logger` | 正文不写入日志 |

不申请输入监控、屏幕录制、完全磁盘访问。辅助功能只用于自动粘贴。

## 2. 进程与窗口

应用是单个常驻进程。状态栏图标由 `App/MenuBar` 创建。主面板是浮动面板，设置是独立窗口。

面板属性：

- 样式包含 `nonactivatingPanel`、`titled`、`fullSizeContentView`、`resizable`
- `level = .floating`
- `collectionBehavior` 包含 `canJoinAllSpaces`、`fullScreenAuxiliary`
- `hidesOnDeactivate = false`，避免一切到其他桌面就消失
- 可以成为关键窗口，从而接收搜索和方向键
- 不把应用激活成普通前台应用，原应用的焦点得以保留

打开面板时记下当时的前台应用，作为本次粘贴目标。关闭面板不修改剪切板。

默认尺寸 640×480，最小约 420×360。宽度小于 720 时预览移到列表下方，否则在右侧。尺寸和位置模式写入偏好，下次沿用。出现位置默认在鼠标所在屏幕、靠近指针，并限制在该屏幕的 `visibleFrame` 内。

菜单栏图标使用模板图。暂停时叠加斜杠。辅助功能未授权时叠加圆点，点击后打开权限说明。

## 3. 模块与目录

| 目录 | 职责 |
|---|---|
| `App` | 入口、`AppDelegate`、状态栏、面板和设置窗口的装配 |
| `Features/Capture` | 轮询变化、判定是否入库、去重、超限 |
| `Features/History` | 列表分组、搜索、筛选、预览、置顶和删除 |
| `Features/Paste` | 按模式写回剪切板，并在需要时发送 ⌘V |
| `Features/Privacy` | 排除应用、机密标记、安全输入、暂停计时 |
| `Features/Settings` | 通用、隐私、存储、关于 |
| `Domain` | 历史条目、类型、去重键、保留规则 |
| `Storage` | SQLite、负载文件、缩略图、清空与回收 |
| `Platform` | 热键、辅助功能、登录项、前台应用 |
| `Resources` | 图标、`zh-Hans`、`en` |
| `Tests` | 去重、保留、搜索、粘贴载荷这些不依赖界面的测试 |
| `Packaging` | 签名、公证和发版说明 |

界面通过协议访问存储和粘贴，测试用内存实现替换剪切板与数据库。

## 4. 采集

### 4.1 监听

`CaptureMonitor` 在串行队列上每 400ms 读取一次 `NSPasteboard.general.changeCount`。数值变化时进入采集。睡眠唤醒后再读一次。这个间隔满足「复制后 2 秒内出现」的验收。

采集不在主线程解码图片或计算哈希。主线程只接收已经整理好的条目并刷新界面。

### 4.2 一次采集的顺序

1. 暂停中：跳过。
2. `IsSecureEventInputEnabled()` 为真，且「安全输入时仍记录」关闭：跳过。
3. 本次变化由本应用刚刚写入：跳过。
4. 条目带 `org.nspasteboard.ConcealedType`，且「忽略机密标记」开启：跳过。
5. 前台应用的 bundle id 在排除列表中：跳过。
6. 读取负载，计算去重键。
7. 哈希已存在：把该条移到顶部，更新 `last_used_at`，不新增行。
8. 新内容：写入数据库和负载文件，再按保留策略淘汰。

来源应用取变化发生时的 `frontmostApplication`。无法判断、或检测到通用剪贴板标记时，来源名称写「通用剪贴板」。不拦截、不关闭系统的接力剪贴板。

### 4.3 保存哪些类型

一条记录保存原始 `NSPasteboardItem` 上的全部 UTI，粘贴时按原类型写回，让目标应用自己选择最合适的表示。

同时抽出用于界面的归一化结果：

| 归一化类型 | 判定 |
|---|---|
| `text` | 只有纯文本或 URL |
| `rich` | 存在 RTF 或 HTML，并另外保存纯文本 |
| `image` | PNG、TIFF 或 JPEG |
| `file` | 一个或多个文件 URL |
| `mixed` | 同时具有上述多类实质内容 |

纯文本单条上限 1MB，图片单条上限默认 10MB。超出时仍插入一条可见记录，标记 `payload_oversize`，列表显示「内容过大未保存」。粘贴这条时提示未保存，不写入空载荷。

文件不复制文件本体，只记录 URL、文件名、大小和修改时间。粘贴时把这些 URL 放回剪切板，由目标应用执行复制语义。

### 4.4 去重键

| 类型 | 输入 |
|---|---|
| 文本、富文本 | NFC，换行统一为 `\n`，再做 SHA-256。不裁剪首尾空白 |
| 图片 | 解码后的像素字节 SHA-256 |
| 文件 | 路径按字典序拼接，加上每个文件的大小和修改时间 |
| 混合 | 上述各部分按固定顺序拼接后再哈希 |

富文本的搜索和列表使用纯文本，展示和原样粘贴仍用原始 RTF/HTML。

### 4.5 自身写入

写剪切板前生成一个递增记号，并记下即将写入的哈希。随后到来的第一次匹配 `changeCount`，若哈希相同，则丢弃。记号在写入完成后最多保留 1 秒，避免漏掉系统合并产生的第二次变化。

## 5. 粘贴

面板打开期间，粘贴目标固定为打开前的前台应用。

| 操作 | 剪切板内容 | 是否发送 ⌘V |
|---|---|---|
| 回车、双击、⌘1–⌘9 | 全部原始类型 | 是 |
| ⌘回车 | 全部原始类型 | 否 |
| ⇧回车 | 只有 `public.utf8-plain-text` | 是 |
| 菜单栏最近一条 | 全部原始类型 | 是 |

自动粘贴的顺序：

1. 若当前前台不是当初记下的目标应用，调用该应用的 `activate`。
2. 在抑制采集的状态下写回剪切板。
3. 用 `CGEventSource(stateID: .hidSystemState)` 发送 Command + V 的按下与抬起。
4. 关闭面板。

`AXIsProcessTrusted()` 为假时不发送按键。剪切板已经写好，面板底部显示「未能自动粘贴，已复制，请手动粘贴」。设置里的粘贴行为若是「只写入剪切板」，则所有粘贴路径都不发送 ⌘V。

发送按键后短时间内目标应用的剪切板内容被再次读出，用来确认写入成功。无法确认目标应用是否接受按键时，保留已写入的剪切板，并给出同一条失败提示。已知会忽略模拟按键的应用记入发版说明。

Esc 和点击面板外只关闭面板。

## 6. 快捷键、权限与登录项

热键放在 `Platform/Hotkey`。使用 `RegisterEventHotKey` 注册，用 `UnregisterEventHotKey` 注销。录制时先注销旧热键；新组合保存成功后再注册。注册返回热键已存在时，设置页把该快捷键标红。

允许修饰键加一个主键。单独的 ⌘C、⌘V、⌘X、⌘Q 拒绝保存。默认组合是 ⌘⇧V。暂停和恢复没有默认全局热键，用户可以另设一组。

辅助功能检测使用 `AXIsProcessTrustedWithOptions`。权限说明里的按钮用 `prompt` 选项打开系统提示，并提供前往「系统设置 › 隐私与安全性 › 辅助功能」的入口。未授权不影响采集，也不影响「只复制」。

开机启动默认关闭。打开时调用 `SMAppService.mainApp.register()`，关闭时 `unregister()`。登录项拉起的仍是同一个 `LSUIElement` 应用，不出现 Dock 图标。

## 7. 数据

目录：

```text
~/Library/Application Support/ClipboardAssistant/
├── history.db
├── payloads/<sha256>/<uti-encoded>
└── thumbs/<sha256>.jpg
```

`history.db` 使用 WAL。`user_version` 从 1 开始。偏好（热键、外观、保留档位、面板尺寸、排除应用、暂停截止时间）放在 `UserDefaults`。剪切板正文不进 `UserDefaults`。

### 7.1 表

```sql
CREATE TABLE items (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  plain_text TEXT,
  content_hash TEXT NOT NULL,
  source_bundle_id TEXT,
  source_name TEXT,
  created_at REAL NOT NULL,
  last_used_at REAL NOT NULL,
  pinned INTEGER NOT NULL DEFAULT 0,
  pin_order INTEGER,
  byte_size INTEGER NOT NULL,
  image_width INTEGER,
  image_height INTEGER,
  payload_oversize INTEGER NOT NULL DEFAULT 0
);

CREATE UNIQUE INDEX idx_items_hash ON items(content_hash);
CREATE INDEX idx_items_list ON items(pinned DESC, pin_order ASC, last_used_at DESC);

CREATE TABLE representations (
  item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  uti TEXT NOT NULL,
  storage TEXT NOT NULL,          -- file | inline
  relative_path TEXT,
  inline_value TEXT,
  PRIMARY KEY (item_id, uti)
);
```

`plain_text` 同时承担列表摘要和搜索。图片和文件的摘要是文件名。

### 7.2 删除与清空

删除一条时，先删除 `payloads` 与 `thumbs` 中的文件，再删除 `items` 行。`representations` 随外键级联删除。清空包在一个事务里：导出全部负载路径，删除所有行，提交后删除文件，再执行 `VACUUM`。清空后重启数据库为空。

面板内的单条删除支持一次 ⌘Z，撤销状态只留在内存里，面板关闭即丢弃。清空和删除置顶先确认，确认文案带上当前条数。

### 7.3 保留

每次成功插入后，以及应用启动时，按下面的顺序处理未置顶记录：

1. 删除超过保留天数的记录。默认 30 天，可选 7、30、90、永久。
2. 条数超过上限时，从最旧的未置顶记录开始删。默认 500，可选 200、500、1000、不限制。
3. 图片文件合计超过 200MB 时，删除最旧的未置顶图片，直到低于上限。

置顶记录不参与以上淘汰。

## 8. 列表、搜索与预览

启动时把元数据和缩略图路径读入内存。500 条摘要的体量远小于 80MB 的常驻目标。原始图片只在预览或粘贴时按需读取。

分组在界面层计算，不入库：

| 分组 | 条件 |
|---|---|
| 置顶 | `pinned = 1`，按 `pin_order` |
| 刚刚 | 未置顶，且最近使用在 5 分钟内 |
| 今天 | 未置顶，同一本地日，并且早于「刚刚」 |
| 昨天 | 未置顶，上一个本地日 |
| 更早 | 其余未置顶记录 |

搜索对当前内存列表做包含匹配。比较前把查询和文本都做 Unicode case fold，因此英文不区分大小写，中文按包含匹配。匹配范围是纯文本、来源应用名和文件名。筛选「文本 / 图片 / 文件 / 置顶」先于搜索执行。200 条纯文本的过滤在本地完成，目标低于 200ms。

预览：文本保留换行并可滚动；图片先显示缩略图，缩略图由 `CGImageSourceCreateThumbnailAtIndex` 在入库时异步生成，长边 360 像素；多个文件显示「N 个文件」以及图标和文件名。在访达中显示调用 `NSWorkspace.activateFileViewerSelecting`。路径已失效时提示无法显示。

来源应用图标用 `NSWorkspace.icon(forFile:)` 读取应用包路径，并做小型缓存。

## 9. 设置与诊断

| 设置 | 存储 | 生效 |
|---|---|---|
| 开机启动 | 系统登录项 | 切换时立即注册或注销 |
| 快捷键 | `UserDefaults` | 保存后重新注册 |
| 外观 | `UserDefaults` | 面板立刻切换 `NSAppearance` |
| 粘贴行为、面板位置 | `UserDefaults` | 下一次操作即生效 |
| 排除应用、忽略机密、暂停时长 | `UserDefaults` | 下一次采集即生效 |
| 保留档位 | `UserDefaults` | 保存后立即跑一次淘汰 |

暂停时长为手动、15 分钟或 1 小时。定时恢复使用一个保存了截止时间的计时器，进程重启后若截止时间已过，直接恢复。

关于页展示版本、辅助功能状态和条数。诊断导出一个 JSON，只含应用版本、系统版本、是否已授权辅助功能、各类型条数和数据库文件大小。

日志分类为 `capture`、`paste`、`store`。格式化参数使用隐私遮蔽，禁止输出 `plain_text`、载荷路径中的正文和文件名以外的内容。

直接分发包用 Sparkle 检查更新，`automaticallyDownloadsUpdates = false`。设置关闭后不再发起检查。应用不申请出站业务接口；更新检查是唯一的网络行为。

## 10. 并发与性能

- 采集、哈希、数据库和文件 IO 共用一个串行队列。
- SwiftUI 只在主 actor 上读已经发布的条目数组。
- 缩略图解码完成后一次性替换界面模型。
- 缩略图使用 `NSCache`，数量上限 50。
- 列表单元格绑定摘要和缩略图路径，不绑定原始图片。
- 目标：500 条文本加 50 张缩略图时，常驻内存低于 80MB。采集过程不在主线程做像素哈希。

崩溃恢复依赖 SQLite WAL。启动时执行一次完整性检查；失败则把损坏文件改名保留，并新建空库，同时在关于页说明历史需要重新积累。不尝试从损坏文件里还原正文。

## 11. 测试

自动化覆盖纯逻辑：

- 文本规范化与连续复制去重
- 图片像素哈希相同则合并
- 文件以路径、大小、修改时间区分
- 超限记录可见且粘贴被拒绝
- 自身写入被抑制
- 机密标记和排除应用被跳过
- 置顶不参与条数和天数淘汰
- 纯文本粘贴只含一种 UTI
- 清空后 `VACUUM`，重启查询为空
- 搜索对「错误」和文件名的包含匹配

发布前按需求文档第 11 节的 10 条用例做手工验收，应用范围覆盖 Safari、Chrome、微信、飞书、Terminal、iTerm、VS Code、Finder、文本编辑、备忘录和 Word。

## 12. 打包

- Xcode 生成通用二进制，最低系统 macOS 14。
- `Info.plist` 设置 `LSUIElement` 为真。
- 硬化运行时打开。不加入沙盒权利。
- `NSAccessibilityUsageDescription` 说明自动粘贴的用途。
- 使用 Developer ID Application 证书签名，再用 `notarytool` 公证并装订。
- 产物是可以拖入「应用程序」文件夹的 `.app`。

App Store 版本另行评估。若要上架，需要打开沙盒、增加辅助功能用途字符串，并复测文件 URL 粘贴和前台应用排除。那不是 v1 直接分发的配置。

## 13. 后续版本预留

数据库保留 `user_version`。v1.1 可新增片段表和规则表，不改现有 `items` 的主键。v2.0 若做 iCloud 同步，在条目上增加修改时间和同步状态，冲突以 `last_used_at` 较新者为准，并继续排除「排除应用」里产生的内容。这两项都不在 v1 实现。

## 14. 风险与实现对策

| 风险 | 对策 |
|---|---|
| 目标应用忽略模拟的 ⌘V | 保留已写好的剪切板，面板提示手动粘贴，并记录应用 bundle id |
| 安全输入误伤普通输入框 | 默认仍跳过；设置提供「安全输入时仍记录」，默认关闭 |
| 大图阻塞采集队列 | 原始文件异步写入，列表只读缩略图 |
| 热键被其他应用占用 | 注册失败即在设置页标红，允许重录 |
| 通用剪贴板带入手机内容 | 按普通新记录入库，来源显示为通用剪贴板或当时的前台应用 |
| 公证后的硬化运行时拦截事件 | 用非沙盒签名包在公证前验证辅助功能下的 ⌘V |

# v1.1 片段库技术方案

状态：本分支已实现主体流程，macOS 集成验收未完成。配套 [PRD](prd.md) 与 [原型](prototype.html)。以现有 Swift 5、AppKit + SwiftUI、sqlite3 架构为基础，不引入新依赖。

## 1. 模块边界

- Domain/Snippet.swift：独立模型，不复用 ClipboardItem 的历史身份和保留字段。
- Domain/SnippetTemplate.swift：纯函数解析、校验、展开；不接触剪切板和文件系统。
- Domain/SnippetQuery.swift：普通搜索与关键字精确查询。
- Storage/SnippetStore.swift：共享现有数据库与串行存储执行域，提供事务 CRUD。
- Features/Snippets/：列表、编辑器、分组管理、变量填写表单与会话状态。
- App/AppModel.swift：装配状态与动作；PanelController 继续负责窗口和粘贴目标。
- Features/Paste/PasteService.swift：增加瞬时纯文本负载入口，共用权限、激活、按键、失败反馈和自身写入抑制。不要把片段先插入历史以借用粘贴入口。

上述为模块职责；片段模型中的匹配方法承担 SnippetQuery 职责，片段界面合并在 SnippetPanelView.swift；新增 Swift 和 Tests 文件必须同步登记到 Xcode 工程。现有 PrivacyGate 不复制、不绕过。

## 2. 数据设计（拟议，不执行）

保留 items、representations 和既有主键不变，新增两张表。以下 SQL 描述新增结构。用户已授权落地开发；产品启动时执行事务迁移，本次测试只操作隔离临时库，没有打开用户真实历史库。

```sql
CREATE TABLE snippet_groups (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  normalized_name TEXT NOT NULL UNIQUE,
  created_at REAL NOT NULL
);
CREATE TABLE snippets (
  id TEXT PRIMARY KEY,
  group_id TEXT REFERENCES snippet_groups(id) ON DELETE SET NULL,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  keyword TEXT,
  keyword_key TEXT UNIQUE,
  variables_json TEXT NOT NULL,
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL
);
CREATE INDEX idx_snippets_group_updated ON snippets(group_id, updated_at DESC);
```

ID 使用 UUID 字符串，时间沿用项目时间表示。无分组使用 NULL；固定分组只存在于界面。空关键字同时写入 keyword/keyword_key 为 NULL，非空关键字按 ASCII 小写生成唯一键。分组规范化规则与 PRD 一致，由同一个函数生成。变量 JSON 带 schemaVersion=1，保存 name、label、required、multiline，不保存填写值；读到不支持版本时提示无法编辑，不能静默覆盖。

片段无文件负载、无正文哈希唯一约束，不受 RetentionPolicy 处理。历史清空只操作历史表；片段清空不进入本次范围。组删除的 SET NULL 与组行删除同事务提交。界面只在事务成功后更新。

## 3. 迁移与错误恢复

现有连接启用 foreign_keys 和 WAL。实施时先核实 user_version 的实际设置位置，把“每次打开固定写 1”改为只在首次建库设置；禁止新版本启动把版本降回 1。

v1→v2：在同一连接串行执行 BEGIN IMMEDIATE、新建表与索引、检查必要结构、PRAGMA user_version=2、COMMIT。任一步失败 ROLLBACK，保留原库并显示存储错误，禁止以空数组掩盖失败。版本大于当前支持值则拒绝写入并提示升级；版本 2 不重复建表。迁移测试对版本 1 样本验证原有历史、负载引用及置顶均未变化。发布前用临时库测试中途失败恢复和重启重试；不可用直接复制正在写入的 WAL 主文件作为可靠备份。

所有 SQL 数据绑定参数。错误信息映射为稳定错误码，不直接输出包含 SQL 参数或正文的数据库消息。唯一冲突显示关键字/组名冲突；不存在的组显示重新选择；数据库失败保留编辑草稿并支持重试。

## 4. 解析与展开协议

建议接口：parse(body) throws -> ParsedTemplate；render(parsed, values) throws -> String。ParsedTemplate 包含字面量与变量 token、首次出现顺序和错误范围。一次线性扫描处理反斜杠转义、双花括号和 ASCII 名称；不使用模板执行引擎，不支持递归、表达式、文件读取或网络访问。

校验 20 个唯一变量、100,000 字节模板、10,000 字节单值和 100,000 字节展开上限。拼接时增量检查字节数，避免生成过大临时字符串。错误范围记录 String.Index 并由界面转换到编辑器范围，不把字节偏移当作字符偏移。

正文变更后按变量 name 合并元数据，删除不再使用的定义，新变量采用必填/单行。保存时以重新解析结果为准，拒绝残留或缺失定义。所有变量替换单次完成，不再解释用户输入。展开纯函数与实际写剪切板分开，可在提交前完整校验。

## 5. 会话、并发与粘贴

界面状态在主线程，数据库与历史存储复用串行执行域。存储完成后返回最新快照；查询请求携带递增序号，丢弃迟到结果。编辑已有片段带 expectedUpdatedAt，更新使用条件 WHERE id=? AND updated_at=?；未命中提示内容已变化，保留草稿，不覆盖较新版本。每次成功修改时间须严格递增。

一次使用会话持有 snippetID、模板快照、变量定义快照、目标应用引用和所选 PasteMode。填写中片段被修改/删除时提交前校验修订值，提示重新载入，不静默使用新正文。只允许一个执行请求，按钮在执行中禁用，避免重复粘贴。

流程：捕获目标 → 选择片段 → 无变量直接展开/有变量收集输入 → 校验修订与字节限额 → 生成内存中的纯文本负载 → 关闭面板 → 走原有粘贴执行链。表单窗口不得更新原目标。写入成功后调用既有自身写入抑制机制；自动粘贴失败重新打开面板，保留当前会话与既有失败文案，关闭/取消则释放。不得承诺对 Swift String 的物理内存安全擦除。

## 6. 界面与键盘路由

新增片段页，不改历史列表的数据源。本次界面统一使用分组选单；宽度 ≥720 时列表与预览左右排列，窄窗预览在下方。编辑器和变量表单在面板内切换并可滚动，保留原应用目标，不另开 sheet。标题、提示、菜单及错误经 L10n.text 输出中英文。VoiceOver 标签、焦点顺序和高对比度使用原生控件。

键盘由当前场景路由：编辑器、填写表单、片段浏览、历史浏览。多行字段回车换行；片段表单 ⌘回车执行当前动作；浏览中的 ⌘回车设定为仅复制。只有历史浏览处理历史清空快捷键，防止在片段编辑时误清历史。

## 7. 测试与实施门槛

纯逻辑测试：语法合法/非法、重复变量、转义、大小写、中文与 emoji 边界、非递归替换、必填/选填、UTF-8 字节上限、关键字唯一键和查询范围。

临时 SQLite 测试：迁移幂等与回滚、未知版本保护、外键移组、唯一冲突、CRUD 持久化、并发修订冲突、历史清空隔离、数据库失败不假成功。粘贴协调测试使用替身验证只复制不发按键、关闭先于发送、目标不变、自身写入抑制和失败重开。

macOS 上完成 PRD P01–P12 手工验收和全量测试：

```sh
xcodebuild -project ClipboardAssistant.xcodeproj -scheme ClipboardAssistant -destination 'platform=macOS' -derivedDataPath /tmp/ClipboardAssistantDD test
```

本次实现已接入应用。Windows 环境无法运行 AppKit 和 xcodebuild；当前验证范围、已修复问题及 macOS 验收缺口见 implementation.md。

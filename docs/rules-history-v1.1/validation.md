# 历史导入导出验证记录（移除规则与标签后）

日期：2026-11-11。分支：`feat/rules-history-transfer`。没有执行 Git 提交、合并或 push。

## 当前功能范围

用户已明确确认移除“历史标签”和整个“规则设置”，保留历史导入导出。规则页、正则 worker、规则模型及专属测试已删除；采集不再读取已保存规则，也不再打标签。历史不显示标签，搜索和筛选均不使用标签。原有隐私保护、片段库、采集和粘贴保持。

数据库仍为 v4，不降级、不清空历史、不删除旧表。旧 `capture_rules` 即使有启用规则或损坏配置也不会被读取，新数据库不再创建该表。旧标签字段和 `item_labels` 仅供备份元数据兼容，不作为可使用的标签功能。

## 最终验证结果

- macOS 全量 `ClipboardAssistantTests`：127 项通过，0 失败，0 跳过，同时完成应用编译。
- 剩余 5 个归档模块文件 Xcode 行覆盖率：1185 / 1185，100%。精确范围和源码校验值见 [coverage.json](coverage.json)。这不是整个应用或分支覆盖率。
- 独立归档测试：4 项 XCTest 通过。
- 新增回归覆盖：旧规则完全不执行、新记录不打标签、旧标签不参与搜索、设置中没有规则页，以及旧元数据仍可归档往返。
- 原有 JSON/TXT 导出、JSON 导入、预览和去重、保留计划/失效重确认、置顶、取消、读取租约、事务回滚及真实子进程崩溃恢复测试继续通过。
- Shell 脚本语法检查和 `git diff --check` 通过。

环境：macOS 27.0.1、arm64、Swift 5 工程配置；最低部署版本仍为 macOS 14。

## 复现命令

使用尚不存在的结果目录：

```bash
xcodebuild -project ClipboardAssistant.xcodeproj -scheme ClipboardAssistant \
  -destination 'platform=macOS' -derivedDataPath /tmp/ClipboardAssistantDD \
  -resultBundlePath /tmp/ClipboardAssistantTransferValidation.xcresult \
  -enableCodeCoverage YES test

bash scripts/check-history-transfer-coverage.sh /tmp/ClipboardAssistantTransferValidation.xcresult
bash scripts/test-history-transfer.sh
```

本次实际结果：`/tmp/clipboard-transfer-only.fsI6mA/Validation.xcresult`；输出：`/tmp/clipboard-transfer-only-tests.log`。临时产物可能被系统回收，仓库保留必要计数和源码 SHA-256，无剪切板正文。

## 当前入口与边界

历史面板底部提供导入/导出，设置的存储页提供全部历史导出和导入。JSON 可恢复，TXT 仅供阅读。导入先预览，影响原历史时需要勾选保留策略淘汰确认。

解析逐条读取，预览解码负载驻内存，上限 256 MiB，确认后写 staging；尚未实现校验阶段全部负载落临时区的更低常驻内存方式。macOS 14 实机、VoiceOver 和接近上限的大备份性能仍待人工验收。既有界面遍历测试的运行警告未被屏蔽，具体记录随 coverage.json 保存。

验证后重启当前应用，使移除规则和标签的界面立即生效。此前 145 项测试、8 个模块的报告是移除功能前的历史记录，不代表当前范围。

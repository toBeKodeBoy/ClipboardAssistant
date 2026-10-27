# 签名与公证

v1 直接分发使用 Developer ID，不进沙盒。没有证书时，本地调试使用 ad-hoc 签名即可运行和测试。

1. 用 Developer ID Application 证书打开硬化运行时并签名 `ClipboardAssistant.app`。
2. 打包 zip 后执行 `xcrun notarytool submit ClipboardAssistant.zip --apple-id <apple-id> --team-id <team> --password <app-password> --wait`。
3. `xcrun stapler staple ClipboardAssistant.app`。
4. 公证前在辅助功能已授权的机器上确认 ⌘V 能送进 Safari、文本编辑和 Terminal。

不要加入 App Sandbox。上架 Mac App Store 需要单独打开沙盒并复测文件粘贴。

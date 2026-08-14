# DeepSeek Harness for macOS

SwiftUI + AppKit 混合原生客户端。不使用 WebKit 或第三方 UI 框架，直接连接 DeepSeek Harness Web Host 的 HTTP / WebSocket 协议。SwiftUI 负责窗口与主要界面，AppKit 负责应用生命周期和窗口恢复修复。

## 运行

1. 先启动工作区根目录的 `start-dsh-web.command`。
2. 用 Xcode 打开 `deepseek-harness-macos.xcodeproj` 并运行。
3. 默认连接 `http://localhost:3080`；可在“设置”中修改。

当前实现包含会话列表与搜索、新建/重命名会话、历史记录、工具与思考行、模型选择、权限选择、发送/停止、实时刷新、原生设置窗口和系统深浅色外观。逐界面状态见 `UI-STATUS.md`。

# Dsh-macUI

DeepSeek Harness 的原生 Apple 客户端与加密同步中继。仓库采用单仓库结构，包含
macOS、iOS/iPadOS 和 Node.js 服务端三部分；客户端不使用 WebView 来承载主界面。

> **非官方项目。** 本项目与 DeepSeek AI 无隶属或背书关系。使用前请阅读
> [免责声明](DISCLAIMER.md) 和 [第三方声明](THIRD_PARTY_NOTICES.md)。

## 三端组成

| 组件 | 技术 | 用途 |
| --- | --- | --- |
| `deepseek-harness-macos` | SwiftUI + AppKit | 原生 macOS 会话、工具调用、计划、Goal、设置与工作区界面 |
| `deepseek-harness-mobile` | SwiftUI | iPhone/iPad 会话客户端，支持局域网 Host 和加密中继配置 |
| `deepseek-harness-sync-server` | Node.js | 配对、密文同步和 Host RPC 帧转发；服务端不解密消息正文 |
| `deepseek-harness-shared` | Swift | macOS 与移动端共用的 Markdown 和轨迹解析逻辑 |

## 主要能力

- 原生侧边栏、标题栏、菜单、Popover、工具栏和系统材质；
- 会话、工作区、模型、推理强度、权限预设、插件和上下文信息；
- 流式消息、Markdown、代码块、终端输出、文件红绿 Diff 和折叠工具调用；
- 计划模式、任务列表、Goal 状态与子 Agent 会话导航；
- iOS 原生抽屉手势、悬浮输入框、简洁显示模式和工作区选择；
- P-256 设备配对、AES-256-GCM 负载加密、Keychain 凭据存储和密文中继。

实现状态和已知的像素/协议差异见
[`deepseek-harness-macos/UI-STATUS.md`](deepseek-harness-macos/UI-STATUS.md)。

## 环境要求

- macOS 13 或更高版本；
- iOS/iPadOS 17 或更高版本；
- Xcode 27 或能够打开当前工程格式的兼容版本；
- Node.js 20 或更高版本；运行当前 DeepSeek Harness 源码建议使用 Node.js 24；
- 单独获取的 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) Host。

本仓库不内置官方 Harness 源码。若使用随附启动脚本，请将它克隆到仓库根目录的
`deepseek-harness-master`：

```bash
git clone https://github.com/deepseek-ai/deepseek-harness.git deepseek-harness-master
cd deepseek-harness-master
corepack enable
pnpm install
```

## macOS 客户端

先启动只监听本机的 Harness Web Host：

```bash
./start-dsh-web.command
```

随后用 Xcode 打开 `deepseek-harness-macos.xcodeproj`，选择
`deepseek-harness-macos` scheme 运行。也可以生成一个本地临时签名的 Release App：

```bash
./build-macos.command
```

默认 Host 地址为 `http://127.0.0.1:3080`，可在应用设置中修改。

## iOS / iPadOS 客户端

用 Xcode 打开 `deepseek-harness-mobile.xcodeproj`，配置自己的 Development Team 和
Bundle Identifier 后运行。移动端支持两种连接：

1. **局域网 Host**：直接连接 Mac 上的 Harness API；
2. **加密中继**：通过 HTTPS Relay 配对并传递端到端加密的 RPC 帧。

仅在可信网络临时启动局域网监听：

```bash
./start-dsh-web-lan.command
```

测试结束后关闭：

```bash
./stop-dsh-web.command
```

局域网模式会把具备命令和文件操作能力的 Host API 暴露给同网设备，不能用于公共
Wi-Fi 或公网。更完整说明见[免责声明](DISCLAIMER.md)。

## 加密同步服务端

```bash
cd deepseek-harness-sync-server
npm test
DSH_RELAY_HOST=127.0.0.1 DSH_RELAY_PORT=9443 npm start
```

公网监听必须同时提供 TLS 证书和私钥，否则服务会拒绝启动：

```bash
DSH_RELAY_HOST=0.0.0.0 \
DSH_RELAY_PORT=9443 \
DSH_RELAY_TLS_CERT=/secure/path/fullchain.pem \
DSH_RELAY_TLS_KEY=/secure/path/privkey.pem \
DSH_RELAY_DATA_DIR=/secure/path/dsh-relay-data \
npm start
```

协议与威胁边界见
[`deepseek-harness-sync-server/PROTOCOL.md`](deepseek-harness-sync-server/PROTOCOL.md)。
生产环境仍需反向代理、限流、监控、备份和独立安全审计。

## 仓库结构

```text
Dsh-macUI/
├── deepseek-harness-macos/          # macOS 客户端
├── deepseek-harness-macos.xcodeproj
├── deepseek-harness-mobile/         # iOS/iPadOS 客户端
├── deepseek-harness-mobile.xcodeproj
├── deepseek-harness-shared/         # Apple 客户端共享解析层
├── deepseek-harness-sync-server/    # 加密同步/中继服务
└── validation/                      # 原生渲染与行为验证
```

## 安全与隐私

- 移动端设备私钥、Relay token 和 Vault key 保存在 iOS Keychain，并使用
  `ThisDeviceOnly` 可访问性；
- Relay 持久化 token 哈希和 AES-GCM 密文，不应收到明文提示词、回复、路径或 Vault key；
- 本地 Host、模型提供方和插件仍能看到完成任务所必需的数据；
- 权限预设不是沙箱的替代品。启用 `danger-full-access` 前请确认工作区和操作范围。

## 许可证

项目代码使用 [MIT License](LICENSE)。源自或参考 DeepSeek Harness 的内容保留其
MIT 声明，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。商标不在许可证
授权范围内。

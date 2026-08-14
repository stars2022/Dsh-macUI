# Dsh-macUI

English | [简体中文](README.md)

Native Apple clients and an encrypted synchronization relay for DeepSeek
Harness. This monorepo contains macOS, iOS/iPadOS, and Node.js components. The
clients render their primary interfaces natively and do not embed the WebUI in
a WebView.

> **Unofficial project.** This project is not affiliated with or endorsed by
> DeepSeek AI. Read the [disclaimer](DISCLAIMER.md) and
> [third-party notices](THIRD_PARTY_NOTICES.md) before use.

## Components

| Component | Technology | Purpose |
| --- | --- | --- |
| `deepseek-harness-macos` | SwiftUI + AppKit | Native macOS conversations, tool calls, plans, goals, settings, and workspaces |
| `deepseek-harness-mobile` | SwiftUI | iPhone and iPad client with LAN Host and encrypted relay profiles |
| `deepseek-harness-sync-server` | Node.js | Device pairing, encrypted synchronization, and Host RPC frame forwarding without decrypting message bodies |
| `deepseek-harness-shared` | Swift | Markdown and transcript parsing shared by the Apple clients |

## Highlights

- Native sidebars, title bars, menus, popovers, toolbars, and system materials;
- Sessions, workspaces, models, reasoning effort, permission presets, plugins,
  and context information;
- Streaming messages, Markdown, code blocks, terminal output, red/green file
  diffs, and collapsible tool calls;
- Plan mode, task lists, goal state, and subagent conversation navigation;
- Native iOS drawer gestures, a floating composer, compact display mode, and
  workspace selection;
- P-256 device pairing, AES-256-GCM payload encryption, Keychain credential
  storage, and an opaque encrypted relay.

See [`deepseek-harness-macos/UI-STATUS.md`](deepseek-harness-macos/UI-STATUS.md)
for implementation status and known pixel/protocol differences.

## Requirements

- macOS 13 or later;
- iOS/iPadOS 17 or later;
- Xcode 27, or another compatible Xcode version that can open the current
  project format;
- Node.js 20 or later. Node.js 24 is recommended for the current DeepSeek
  Harness source tree;
- A separate checkout of the
  [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) Host.

## Release downloads

Every `v*` tag is built and published by GitHub Actions. The latest release is
available from the [GitHub Releases page](https://github.com/stars2022/Dsh-macUI/releases/latest).
Each release contains:

- `Dsh-macUI-macOS.zip`: an ad-hoc-signed macOS Release app;
- `Dsh-macUI-iOS-unsigned.ipa`: an unsigned iOS/iPadOS package that must be
  re-signed with your own certificate before installation;
- `Dsh-macUI-relay-server.tar.gz`: the encrypted synchronization relay;
- `SHA256SUMS.txt`: SHA-256 checksums for the release artifacts.

Branch pushes and pull requests also run both Apple Release builds and the
relay test suite, but do not publish a GitHub Release.

This repository does not bundle the official Harness source. To use the
included launch scripts, clone it as `deepseek-harness-master` in the repository
root:

```bash
git clone https://github.com/deepseek-ai/deepseek-harness.git deepseek-harness-master
cd deepseek-harness-master
corepack enable
pnpm install
```

## macOS client

Start a Harness Web Host that listens only on localhost:

```bash
./start-dsh-web.command
```

Open `deepseek-harness-macos.xcodeproj` in Xcode and run the
`deepseek-harness-macos` scheme. You can also create a locally ad-hoc-signed
Release app:

```bash
./build-macos.command
```

The default Host URL is `http://127.0.0.1:3080` and can be changed in the app's
settings.

## iOS and iPadOS client

Open `deepseek-harness-mobile.xcodeproj` in Xcode, select your Development Team,
and use a Bundle Identifier registered to that team. The mobile client supports
two connection modes:

1. **LAN Host:** connect directly to the Harness API running on your Mac;
2. **Encrypted relay:** pair through an HTTPS relay and forward end-to-end
   encrypted RPC frames.

Temporarily expose the Host to a trusted local network with:

```bash
./start-dsh-web-lan.command
```

Stop the LAN listener after testing:

```bash
./stop-dsh-web.command
```

LAN mode exposes a Host API capable of running commands and modifying files to
other devices on the same network. Never use it on public Wi-Fi or expose the
plaintext listener to the public Internet. See the
[disclaimer](DISCLAIMER.md) for the complete warning.

## Encrypted relay server

```bash
cd deepseek-harness-sync-server
npm test
DSH_RELAY_HOST=127.0.0.1 DSH_RELAY_PORT=9443 npm start
```

A public listener requires both a TLS certificate and private key; otherwise
the server refuses to start:

```bash
DSH_RELAY_HOST=0.0.0.0 \
DSH_RELAY_PORT=9443 \
DSH_RELAY_TLS_CERT=/secure/path/fullchain.pem \
DSH_RELAY_TLS_KEY=/secure/path/privkey.pem \
DSH_RELAY_DATA_DIR=/secure/path/dsh-relay-data \
npm start
```

See [`deepseek-harness-sync-server/PROTOCOL.md`](deepseek-harness-sync-server/PROTOCOL.md)
for the protocol and threat boundaries. A production deployment still needs a
reverse proxy, rate limiting, monitoring, backups, and an independent security
review.

## Repository layout

```text
Dsh-macUI/
├── deepseek-harness-macos/          # macOS client
├── deepseek-harness-macos.xcodeproj
├── deepseek-harness-mobile/         # iOS/iPadOS client
├── deepseek-harness-mobile.xcodeproj
├── deepseek-harness-shared/         # shared Apple parsing layer
├── deepseek-harness-sync-server/    # encrypted synchronization relay
└── validation/                      # native rendering and behavior checks
```

## Security and privacy

- Mobile device private keys, relay tokens, and Vault keys are stored in the
  iOS Keychain with a `ThisDeviceOnly` accessibility class;
- The relay persists token hashes and AES-GCM ciphertext. It should not receive
  plaintext prompts, replies, paths, or Vault keys;
- The local Host, model providers, and plugins still see the data required to
  perform a task;
- Permission presets are not a sandbox. Review the workspace and operation
  scope before enabling `danger-full-access`.

## License

Project code is available under the [MIT License](LICENSE). Content adapted
from or based on DeepSeek Harness retains its MIT notice; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). No trademark rights are
granted by the license.

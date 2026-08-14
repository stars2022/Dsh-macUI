# DeepSeek Harness Mobile

Native SwiftUI iPhone/iPad client with two connection modes:

- **Local Host** connects directly to `/api/<method>` on a LAN Harness Host.
- **Encrypted Relay** sends AES-256-GCM Host RPC frames through the sync server after approval-based P-256 pairing.

Secrets (device private key, relay token and vault key) live in the iOS Keychain with `ThisDeviceOnly` accessibility. The server profile list contains addresses and display names only.

Open `deepseek-harness-mobile.xcodeproj` in Xcode. A remote profile deliberately requires HTTPS. Remote RPC becomes available once a paired Mac runs the relay agent and advertises a `host` device.

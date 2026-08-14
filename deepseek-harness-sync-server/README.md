# DeepSeek Harness encrypted relay

This service is the remote rendezvous point for native Harness clients. It stores only opaque AES-256-GCM envelopes and token hashes. The vault key is created on the first trusted Apple device and is transferred to a newly paired device only after the existing device wraps it for that device's P-256 public key.

## Run

```bash
DSH_RELAY_HOST=127.0.0.1 DSH_RELAY_PORT=9443 npm start
```

For a network listener, configure `DSH_RELAY_TLS_CERT` and `DSH_RELAY_TLS_KEY`. The process refuses a plaintext non-loopback bind. A production deployment should additionally sit behind a reverse proxy with request-rate and connection limits.

The API provides:

- device vault creation and approval-based pairing;
- encrypted object synchronization with optimistic versions;
- an encrypted, cursor-based long-poll relay for Host RPC and event frames;
- no endpoint that accepts or returns a plaintext prompt, message, workspace path, or vault key.

See `PROTOCOL.md` for the pairing and envelope contract.

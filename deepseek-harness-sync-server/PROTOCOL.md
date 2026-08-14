# Relay protocol v1

All `/v1` requests use JSON. Authenticated requests use `Authorization: Bearer <device-token>`. Device tokens are random capabilities delivered only over HTTPS and stored as SHA-256 hashes by the relay.

Encrypted fields use this shape:

```json
{
  "algorithm": "AES.GCM.256",
  "nonce": "base64url",
  "ciphertext": "base64url",
  "tag": "base64url",
  "aad": "base64url-or-null"
}
```

The client derives per-purpose AES keys from its 256-bit vault key with HKDF-SHA256. AAD includes protocol version, vault id, object/frame id and purpose so ciphertext cannot be moved between records.

Pairing is approval-based:

1. The first device creates a P-256 key-agreement key and a random vault key, then calls `POST /v1/vaults` with only its public key.
2. It creates a short-lived code with `POST /v1/pairings`.
3. The new device calls `POST /v1/pairings/claim` with that code and its public key.
4. The existing device reads the claim, performs P-256 ECDH, derives a wrapping key, and uploads the wrapped vault key to `/approve`.
5. The new device polls its claim capability and unwraps the vault key locally.

Sync objects use `PUT /v1/sync/:opaqueObjectId` and `GET /v1/sync?after=<cursor>`. Relay frames use `POST` and `GET /v1/relay/frames`; their kind is routing metadata, while request bodies and Host events remain encrypted.

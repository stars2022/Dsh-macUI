import { readFile } from 'node:fs/promises'
import { createRelayServer } from './server.mjs'

const host = process.env.DSH_RELAY_HOST ?? '127.0.0.1'
const port = Number(process.env.DSH_RELAY_PORT ?? 9443)
const dataDir = process.env.DSH_RELAY_DATA_DIR ?? '.dsh-relay'
const certPath = process.env.DSH_RELAY_TLS_CERT
const keyPath = process.env.DSH_RELAY_TLS_KEY

if ((!certPath) !== (!keyPath)) throw new Error('DSH_RELAY_TLS_CERT and DSH_RELAY_TLS_KEY must be supplied together')
const tls = certPath && keyPath ? { cert: await readFile(certPath), key: await readFile(keyPath) } : null
if (!tls && !['127.0.0.1', '::1', 'localhost'].includes(host)) {
  throw new Error('Refusing a non-loopback plaintext listener; configure TLS or bind to loopback')
}

const relay = await createRelayServer({ dataDir, tls })
const origin = await relay.listen(port, host)
console.log(`[relay] listening on ${origin}`)
console.log('[relay] payloads are opaque AES-GCM envelopes; keep TLS enabled for authentication metadata and tokens')

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.once(signal, async () => {
    await relay.close()
    process.exit(0)
  })
}

import { createServer as createHTTPServer } from 'node:http'
import { createServer as createHTTPSServer } from 'node:https'
import { accessToken, pairingCode, randomId, tokenHash, tokenMatches } from './crypto.mjs'
import { RelayStore } from './store.mjs'

const MAX_BODY_BYTES = 1_048_576
const MAX_SYNC_OBJECTS = 20_000
const MAX_FRAMES_PER_VAULT = 2_000
const ID = /^[A-Za-z0-9_-]{8,160}$/
const ROLES = new Set(['host', 'mobile', 'desktop'])

class HTTPError extends Error {
  constructor(status, code, message) {
    super(message)
    this.status = status
    this.code = code
  }
}

export async function createRelayServer(options = {}) {
  const store = await new RelayStore(options.dataDir ?? '.dsh-relay').open()
  const waiters = new Map()
  const listener = async (request, response) => {
    try {
      await route(request, response, store, waiters)
    } catch (error) {
      const status = error instanceof HTTPError ? error.status : 500
      const code = error instanceof HTTPError ? error.code : 'internal-error'
      if (status === 500) console.error('[relay] request failed:', error)
      sendJSON(response, status, { error: { code, message: status === 500 ? 'Internal server error' : error.message } })
    }
  }
  const server = options.tls
    ? createHTTPSServer({ key: options.tls.key, cert: options.tls.cert }, listener)
    : createHTTPServer(listener)

  return {
    server,
    store,
    async listen(port = 0, host = '127.0.0.1') {
      await new Promise((resolve, reject) => {
        server.once('error', reject)
        server.listen(port, host, resolve)
      })
      const address = server.address()
      const protocol = options.tls ? 'https' : 'http'
      const shownHost = typeof address === 'object' && address?.address.includes(':') ? `[${address.address}]` : address.address
      return `${protocol}://${shownHost}:${address.port}`
    },
    async close() {
      for (const timers of waiters.values()) for (const finish of timers) finish()
      await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()))
    },
  }
}

async function route(request, response, store, waiters) {
  response.setHeader('cache-control', 'no-store')
  response.setHeader('x-content-type-options', 'nosniff')
  response.setHeader('content-security-policy', "default-src 'none'")
  const url = new URL(request.url, 'http://relay.invalid')

  if (request.method === 'GET' && url.pathname === '/healthz') {
    return sendJSON(response, 200, { ok: true, service: 'deepseek-harness-relay', protocol: 1 })
  }

  if (request.method === 'POST' && url.pathname === '/v1/vaults') {
    const body = await jsonBody(request)
    const device = deviceInput(body)
    const token = accessToken()
    const result = await store.change(data => {
      const vaultId = randomId()
      const deviceId = randomId()
      data.vaults[vaultId] = {
        id: vaultId,
        createdAt: now(),
        devices: {
          [deviceId]: { id: deviceId, ...device, tokenHash: tokenHash(token), createdAt: now(), revokedAt: null },
        },
      }
      return { vaultId, deviceId, accessToken: token }
    })
    return sendJSON(response, 201, result)
  }

  if (request.method === 'POST' && url.pathname === '/v1/pairings/claim') {
    const body = await jsonBody(request)
    const code = requiredString(body.code, 'code', 16).toUpperCase()
    const device = deviceInput(body)
    const claimSecret = accessToken()
    const claim = await store.change(data => {
      const pairing = Object.values(data.pairings).find(value => value.code === code && value.status === 'open')
      if (!pairing || pairing.expiresAt <= Date.now()) throw new HTTPError(404, 'pairing-not-found', 'Pairing code is invalid or expired')
      const claimId = randomId()
      data.claims[claimId] = {
        id: claimId, pairingId: pairing.id, vaultId: pairing.vaultId,
        ...device, secretHash: tokenHash(claimSecret), status: 'pending', createdAt: now(),
      }
      pairing.claimId = claimId
      return { claimId, claimSecret, vaultId: pairing.vaultId, pairingId: pairing.id }
    })
    return sendJSON(response, 202, claim)
  }

  const claimMatch = url.pathname.match(/^\/v1\/pairing-claims\/([^/]+)$/)
  if (request.method === 'GET' && claimMatch) {
    const secret = bearer(request)
    const claim = await store.read(data => data.claims[claimMatch[1]])
    if (!claim || !tokenMatches(secret, claim.secretHash)) throw new HTTPError(401, 'invalid-claim-secret', 'Invalid pairing claim secret')
    return sendJSON(response, 200, claim.status === 'approved'
      ? { status: claim.status, vaultId: claim.vaultId, deviceId: claim.deviceId,
          accessToken: claim.accessToken, wrappedVaultKey: claim.wrappedVaultKey,
          approverPublicKey: claim.approverPublicKey }
      : { status: claim.status })
  }

  const auth = await authenticate(request, store)

  if (request.method === 'POST' && url.pathname === '/v1/pairings') {
    const body = await jsonBody(request)
    const ttlSeconds = Math.min(900, Math.max(60, Number(body.expiresInSeconds ?? 300)))
    const result = await store.change(data => {
      let code
      do code = pairingCode(); while (Object.values(data.pairings).some(value => value.code === code && value.status === 'open'))
      const pairingId = randomId()
      data.pairings[pairingId] = { id: pairingId, vaultId: auth.vaultId, creatorDeviceId: auth.device.id,
        code, status: 'open', createdAt: now(), expiresAt: Date.now() + ttlSeconds * 1000, claimId: null }
      return { pairingId, code, expiresAt: new Date(data.pairings[pairingId].expiresAt).toISOString() }
    })
    return sendJSON(response, 201, result)
  }

  const pairingMatch = url.pathname.match(/^\/v1\/pairings\/([^/]+)$/)
  if (request.method === 'GET' && pairingMatch) {
    const result = await store.read(data => {
      const pairing = data.pairings[pairingMatch[1]]
      if (!pairing || pairing.vaultId !== auth.vaultId) throw new HTTPError(404, 'pairing-not-found', 'Pairing not found')
      const claim = pairing.claimId ? data.claims[pairing.claimId] : null
      return { pairingId: pairing.id, status: pairing.status,
        claim: claim ? { claimId: claim.id, deviceName: claim.deviceName, role: claim.role, publicKey: claim.publicKey } : null }
    })
    return sendJSON(response, 200, result)
  }

  const approveMatch = url.pathname.match(/^\/v1\/pairings\/([^/]+)\/approve$/)
  if (request.method === 'POST' && approveMatch) {
    const body = await jsonBody(request)
    const wrappedVaultKey = encryptedEnvelope(body.wrappedVaultKey, 'wrappedVaultKey')
    const approved = await store.change(data => {
      const pairing = data.pairings[approveMatch[1]]
      if (!pairing || pairing.vaultId !== auth.vaultId || pairing.status !== 'open') throw new HTTPError(404, 'pairing-not-found', 'Open pairing not found')
      const claim = data.claims[requiredString(body.claimId, 'claimId')]
      if (!claim || claim.id !== pairing.claimId || claim.status !== 'pending') throw new HTTPError(409, 'claim-mismatch', 'Pairing claim does not match')
      const token = accessToken()
      const deviceId = randomId()
      data.vaults[auth.vaultId].devices[deviceId] = {
        id: deviceId, deviceName: claim.deviceName, role: claim.role, publicKey: claim.publicKey,
        tokenHash: tokenHash(token), createdAt: now(), revokedAt: null,
      }
      claim.status = 'approved'; claim.deviceId = deviceId; claim.accessToken = token; claim.wrappedVaultKey = wrappedVaultKey
      claim.approverPublicKey = auth.device.publicKey
      pairing.status = 'approved'
      return { deviceId }
    })
    return sendJSON(response, 200, approved)
  }

  if (request.method === 'GET' && url.pathname === '/v1/devices') {
    const devices = await store.read(data => Object.values(data.vaults[auth.vaultId].devices)
      .filter(device => device.revokedAt === null)
      .map(({ tokenHash: _, ...device }) => device))
    return sendJSON(response, 200, { items: devices })
  }

  const syncMatch = url.pathname.match(/^\/v1\/sync\/([^/]+)$/)
  if (request.method === 'PUT' && syncMatch) {
    if (!ID.test(syncMatch[1])) throw new HTTPError(400, 'invalid-object-id', 'Invalid encrypted object id')
    const body = await jsonBody(request)
    const envelope = encryptedEnvelope(body)
    const item = await store.change(data => {
      data.sync[auth.vaultId] ??= {}
      const bucket = data.sync[auth.vaultId]
      if (!bucket[syncMatch[1]] && Object.keys(bucket).length >= MAX_SYNC_OBJECTS) throw new HTTPError(409, 'vault-object-limit', 'Encrypted object limit reached')
      const current = bucket[syncMatch[1]]
      const expected = body.ifVersion === undefined || body.ifVersion === null ? null : Number(body.ifVersion)
      if (current && expected !== current.version) throw new HTTPError(409, 'version-conflict', 'Encrypted object version conflict')
      if (!current && expected !== null) throw new HTTPError(409, 'version-conflict', 'Encrypted object does not exist')
      const version = (current?.version ?? 0) + 1
      const cursor = store.nextCursor(data)
      bucket[syncMatch[1]] = { objectId: syncMatch[1], version, cursor, updatedAt: now(), envelope }
      return bucket[syncMatch[1]]
    })
    notify(waiters, auth.vaultId)
    return sendJSON(response, 200, item)
  }

  if (request.method === 'GET' && url.pathname === '/v1/sync') {
    const after = nonNegativeInteger(url.searchParams.get('after') ?? '0', 'after')
    const result = await store.read(data => {
      const items = Object.values(data.sync[auth.vaultId] ?? {}).filter(item => item.cursor > after).sort((a, b) => a.cursor - b.cursor)
      return { cursor: data.cursor, items }
    })
    return sendJSON(response, 200, result)
  }

  if (request.method === 'POST' && url.pathname === '/v1/relay/frames') {
    const body = await jsonBody(request)
    const envelope = encryptedEnvelope(body)
    const recipientDeviceId = body.recipientDeviceId === undefined ? null : requiredString(body.recipientDeviceId, 'recipientDeviceId')
    const frame = await store.change(data => {
      if (recipientDeviceId && !data.vaults[auth.vaultId].devices[recipientDeviceId]) throw new HTTPError(404, 'recipient-not-found', 'Recipient device not found')
      const cursor = store.nextCursor(data)
      const value = { cursor, vaultId: auth.vaultId, senderDeviceId: auth.device.id, recipientDeviceId,
        kind: requiredString(body.kind, 'kind', 80), createdAt: now(), envelope }
      data.frames.push(value)
      const own = data.frames.filter(item => item.vaultId === auth.vaultId)
      if (own.length > MAX_FRAMES_PER_VAULT) {
        const remove = new Set(own.slice(0, own.length - MAX_FRAMES_PER_VAULT).map(item => item.cursor))
        data.frames = data.frames.filter(item => !remove.has(item.cursor))
      }
      return value
    })
    notify(waiters, auth.vaultId)
    return sendJSON(response, 202, { cursor: frame.cursor })
  }

  if (request.method === 'GET' && url.pathname === '/v1/relay/frames') {
    const after = nonNegativeInteger(url.searchParams.get('after') ?? '0', 'after')
    const waitSeconds = Math.min(25, nonNegativeInteger(url.searchParams.get('wait') ?? '0', 'wait'))
    let result = await relayFrames(store, auth, after)
    if (result.items.length === 0 && waitSeconds > 0) {
      await waitForChange(waiters, auth.vaultId, waitSeconds * 1000)
      result = await relayFrames(store, auth, after)
    }
    return sendJSON(response, 200, result)
  }

  throw new HTTPError(404, 'not-found', 'Endpoint not found')
}

async function authenticate(request, store) {
  const token = bearer(request)
  return store.read(data => {
    for (const [vaultId, vault] of Object.entries(data.vaults)) {
      for (const device of Object.values(vault.devices)) {
        if (device.revokedAt === null && tokenMatches(token, device.tokenHash)) return { vaultId, device }
      }
    }
    throw new HTTPError(401, 'invalid-token', 'Invalid access token')
  })
}

async function relayFrames(store, auth, after) {
  return store.read(data => ({ cursor: data.cursor, items: data.frames.filter(frame =>
    frame.vaultId === auth.vaultId && frame.cursor > after && frame.senderDeviceId !== auth.device.id
      && (frame.recipientDeviceId === null || frame.recipientDeviceId === auth.device.id)).sort((a, b) => a.cursor - b.cursor) }))
}

function deviceInput(body) {
  const role = requiredString(body.role ?? 'mobile', 'role', 16)
  if (!ROLES.has(role)) throw new HTTPError(400, 'invalid-role', 'Invalid device role')
  return {
    deviceName: requiredString(body.deviceName, 'deviceName', 100),
    role,
    publicKey: requiredString(body.publicKey, 'publicKey', 512),
  }
}

function encryptedEnvelope(value, field = null) {
  const body = field ? value : value
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new HTTPError(400, 'invalid-envelope', `${field ?? 'body'} must be an encrypted envelope`)
  return {
    algorithm: requiredString(body.algorithm ?? 'AES.GCM.256', 'algorithm', 40),
    nonce: requiredString(body.nonce, 'nonce', 256),
    ciphertext: requiredString(body.ciphertext, 'ciphertext', MAX_BODY_BYTES),
    tag: requiredString(body.tag, 'tag', 256),
    aad: body.aad === undefined ? null : requiredString(body.aad, 'aad', 2048),
  }
}

function bearer(request) {
  const value = request.headers.authorization ?? ''
  if (!value.startsWith('Bearer ') || value.length <= 7) throw new HTTPError(401, 'missing-token', 'Bearer token required')
  return value.slice(7)
}

async function jsonBody(request) {
  const type = request.headers['content-type'] ?? ''
  if (!type.toLowerCase().startsWith('application/json')) throw new HTTPError(415, 'json-required', 'Content-Type application/json required')
  const chunks = []
  let total = 0
  for await (const chunk of request) {
    total += chunk.length
    if (total > MAX_BODY_BYTES) throw new HTTPError(413, 'body-too-large', 'Request body is too large')
    chunks.push(chunk)
  }
  try {
    const value = JSON.parse(Buffer.concat(chunks).toString('utf8'))
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('object required')
    return value
  } catch {
    throw new HTTPError(400, 'invalid-json', 'Invalid JSON object')
  }
}

function requiredString(value, name, max = 200) {
  if (typeof value !== 'string' || value.length === 0 || value.length > max) throw new HTTPError(400, `invalid-${name}`, `${name} must be a non-empty string`)
  return value
}

function nonNegativeInteger(value, name) {
  const number = Number(value)
  if (!Number.isSafeInteger(number) || number < 0) throw new HTTPError(400, `invalid-${name}`, `${name} must be a non-negative integer`)
  return number
}

function now() { return new Date().toISOString() }

function sendJSON(response, status, value) {
  if (response.headersSent) return
  const bytes = Buffer.from(JSON.stringify(value))
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': bytes.length })
  response.end(bytes)
}

function notify(waiters, vaultId) {
  for (const finish of waiters.get(vaultId) ?? []) finish()
}

function waitForChange(waiters, vaultId, timeout) {
  return new Promise(resolve => {
    const bucket = waiters.get(vaultId) ?? new Set()
    waiters.set(vaultId, bucket)
    let timer
    const finish = () => {
      clearTimeout(timer)
      bucket.delete(finish)
      if (bucket.size === 0) waiters.delete(vaultId)
      resolve()
    }
    bucket.add(finish)
    timer = setTimeout(finish, timeout)
  })
}

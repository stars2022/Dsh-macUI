import assert from 'node:assert/strict'
import { mkdtemp } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { createRelayServer } from '../src/server.mjs'

const envelope = (text = 'ciphertext') => ({
  algorithm: 'AES.GCM.256',
  nonce: Buffer.from('0123456789ab').toString('base64url'),
  ciphertext: Buffer.from(text).toString('base64url'),
  tag: Buffer.from('0123456789abcdef').toString('base64url'),
  aad: Buffer.from('dsh-relay-v1').toString('base64url'),
})

test('approval pairing, opaque sync, and encrypted relay round-trip', async t => {
  const dataDir = await mkdtemp(join(tmpdir(), 'dsh-relay-test-'))
  const relay = await createRelayServer({ dataDir })
  const origin = await relay.listen(0, '127.0.0.1')
  t.after(() => relay.close())

  const health = await request(origin, 'GET', '/healthz')
  assert.equal(health.status, 200)
  assert.equal(health.body.protocol, 1)

  const host = await request(origin, 'POST', '/v1/vaults', {
    deviceName: 'Mac Studio', role: 'host', publicKey: 'host-public-key',
  })
  assert.equal(host.status, 201)

  const pairing = await request(origin, 'POST', '/v1/pairings', { expiresInSeconds: 300 }, host.body.accessToken)
  assert.match(pairing.body.code, /^[A-Z2-9]{4}-[A-Z2-9]{4}$/)

  const claim = await request(origin, 'POST', '/v1/pairings/claim', {
    code: pairing.body.code, deviceName: 'iPhone', role: 'mobile', publicKey: 'phone-public-key',
  })
  assert.equal(claim.status, 202)

  const pending = await request(origin, 'GET', `/v1/pairings/${pairing.body.pairingId}`, undefined, host.body.accessToken)
  assert.equal(pending.body.claim.publicKey, 'phone-public-key')

  const approve = await request(origin, 'POST', `/v1/pairings/${pairing.body.pairingId}/approve`, {
    claimId: claim.body.claimId, wrappedVaultKey: envelope('wrapped-vault-key'),
  }, host.body.accessToken)
  assert.equal(approve.status, 200)

  const approved = await request(origin, 'GET', `/v1/pairing-claims/${claim.body.claimId}`, undefined, claim.body.claimSecret)
  assert.equal(approved.body.status, 'approved')
  assert.equal(approved.body.wrappedVaultKey.ciphertext, envelope('wrapped-vault-key').ciphertext)
  assert.ok(approved.body.accessToken.startsWith('dsh_'))

  const devices = await request(origin, 'GET', '/v1/devices', undefined, approved.body.accessToken)
  assert.deepEqual(new Set(devices.body.items.map(item => item.role)), new Set(['host', 'mobile']))
  assert.ok(devices.body.items.every(item => item.tokenHash === undefined))

  const objectId = 'session_01JTESTOBJECT'
  const synced = await request(origin, 'PUT', `/v1/sync/${objectId}`, {
    ...envelope('encrypted-session'), ifVersion: null,
  }, host.body.accessToken)
  assert.equal(synced.body.version, 1)

  const pulled = await request(origin, 'GET', '/v1/sync?after=0', undefined, approved.body.accessToken)
  assert.equal(pulled.body.items.length, 1)
  assert.equal(pulled.body.items[0].envelope.ciphertext, envelope('encrypted-session').ciphertext)

  const conflict = await request(origin, 'PUT', `/v1/sync/${objectId}`, {
    ...envelope('stale'), ifVersion: 0,
  }, approved.body.accessToken)
  assert.equal(conflict.status, 409)
  assert.equal(conflict.body.error.code, 'version-conflict')

  const frame = await request(origin, 'POST', '/v1/relay/frames', {
    kind: 'host.rpc.request', recipientDeviceId: host.body.deviceId, ...envelope('encrypted-prompt'),
  }, approved.body.accessToken)
  assert.equal(frame.status, 202)

  const inbox = await request(origin, 'GET', '/v1/relay/frames?after=0', undefined, host.body.accessToken)
  assert.equal(inbox.body.items.length, 1)
  assert.equal(inbox.body.items[0].senderDeviceId, approved.body.deviceId)
  assert.equal(inbox.body.items[0].envelope.ciphertext, envelope('encrypted-prompt').ciphertext)
})

async function request(origin, method, path, body, token) {
  const response = await fetch(`${origin}${path}`, {
    method,
    headers: {
      ...(body === undefined ? {} : { 'content-type': 'application/json' }),
      ...(token === undefined ? {} : { authorization: `Bearer ${token}` }),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
  return { status: response.status, body: await response.json() }
}

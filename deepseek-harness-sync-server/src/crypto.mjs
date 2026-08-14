import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'

export function randomId(bytes = 18) {
  return randomBytes(bytes).toString('base64url')
}

export function accessToken() {
  return `dsh_${randomId(32)}`
}

export function tokenHash(token) {
  return createHash('sha256').update(token, 'utf8').digest('hex')
}

export function tokenMatches(token, expectedHash) {
  const actual = Buffer.from(tokenHash(token), 'hex')
  const expected = Buffer.from(expectedHash ?? '', 'hex')
  return actual.length === expected.length && timingSafeEqual(actual, expected)
}

export function pairingCode() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
  const bytes = randomBytes(8)
  let value = ''
  for (const byte of bytes) value += alphabet[byte % alphabet.length]
  return `${value.slice(0, 4)}-${value.slice(4)}`
}

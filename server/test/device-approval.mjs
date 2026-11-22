// New-device approval against a local Worker: with the setting on, a password sign-in from a device the account
// never used is refused until a signed-in device approves it; denied devices stay out; off again, anyone signs in.
// usage: node test/device-approval.mjs <base-url>
import { webcrypto as c } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import assert from 'node:assert/strict'
const base = process.argv[2]
const enc = new TextEncoder(), dec = new TextDecoder()
const b64 = (u) => Buffer.from(u).toString('base64'), unb64 = (s) => new Uint8Array(Buffer.from(s, 'base64'))
const RUN = `${Date.now()}`
const ITER = 600000

const pbkdf2 = async (pw, salt, iter) => new Uint8Array(await c.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt, iterations: iter },
  await c.subtle.importKey('raw', pw, 'PBKDF2', false, ['deriveBits']), 256))
const expand = async (prk, info) => new Uint8Array(await c.subtle.sign('HMAC',
  await c.subtle.importKey('raw', prk, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']), new Uint8Array([...enc.encode(info), 1])))
const hmac = async (k, d) => new Uint8Array(await c.subtle.sign('HMAC', await c.subtle.importKey('raw', k, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']), d))
const encS = async (key64, data) => {
  const iv = c.getRandomValues(new Uint8Array(16))
  const ct = new Uint8Array(await c.subtle.encrypt({ name: 'AES-CBC', iv }, await c.subtle.importKey('raw', key64.slice(0, 32), 'AES-CBC', false, ['encrypt']),
    typeof data === 'string' ? enc.encode(data) : data))
  return `2.${b64(iv)}|${b64(ct)}|${b64(await hmac(key64.slice(32), new Uint8Array([...iv, ...ct])))}`
}
const decS = async (key64, s) => {
  const [iv, ct, mac] = s.slice(2).split('|').map(unb64)
  assert.equal(b64(await hmac(key64.slice(32), new Uint8Array([...iv, ...ct]))), b64(mac), 'mac')
  return new Uint8Array(await c.subtle.decrypt({ name: 'AES-CBC', iv }, await c.subtle.importKey('raw', key64.slice(0, 32), 'AES-CBC', false, ['decrypt']), ct))
}
const rsaPair = () => c.subtle.generateKey({ name: 'RSA-OAEP', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-1' }, true, ['encrypt', 'decrypt'])
const rsaEnc = async (spkiB64, data) => `4.${b64(new Uint8Array(await c.subtle.encrypt({ name: 'RSA-OAEP' },
  await c.subtle.importKey('spki', unb64(spkiB64), { name: 'RSA-OAEP', hash: 'SHA-1' }, false, ['encrypt']), data)))}`
const rsaDec = async (pkcs8, s) => new Uint8Array(await c.subtle.decrypt({ name: 'RSA-OAEP' },
  await c.subtle.importKey('pkcs8', pkcs8, { name: 'RSA-OAEP', hash: 'SHA-1' }, false, ['decrypt']), unb64(s.slice(2))))

const api = async (tok, method, path, body) => {
  const r = await fetch(base + path, { method, headers: { 'content-type': 'application/json', ...(tok ? { authorization: `Bearer ${tok}` } : {}) }, body: body ? JSON.stringify(body) : undefined })
  const t = await r.text()
  return { status: r.status, body: t ? (() => { try { return JSON.parse(t) } catch { return t } })() : null }
}
const ok = async (...a) => { const r = await api(...a); assert.ok(r.status < 300, `${a[1]} ${a[2]} → ${r.status} ${JSON.stringify(r.body)}`); return r.body }

const login = async (email, password) => {
  const mk = await pbkdf2(enc.encode(password), enc.encode(email), ITER)
  const hash = b64(await pbkdf2(mk, enc.encode(password), 1))
  const r = await fetch(`${base}/identity/connect/token`, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'password', username: email, password: hash, scope: 'api offline_access', client_id: 'ios', deviceType: '1', deviceIdentifier: process.env.DEV_ID || c.randomUUID(), deviceName: 'test' }) })
  const j = await r.json()
  if (!j.access_token) { if (process.env.DEBUG) console.error('login', r.status, JSON.stringify(j).slice(0, 200)); return null }
  const stretched = new Uint8Array([...await expand(mk, 'enc'), ...await expand(mk, 'mac')])
  const userKey = await decS(stretched, j.Key || j.key)
  const priv = await decS(userKey, j.PrivateKey || j.privateKey)
  return { tok: j.access_token, hash, userKey, priv, email }
}
const register = (email, password) => execFileSync('node', [new URL('./register.mjs', import.meta.url).pathname, base, email, password], { stdio: ['ignore', 'pipe', 'inherit'] })
const sync = (u) => ok(u.tok, 'GET', '/api/sync?excludeDomains=true')


const A = `dev-${RUN}@example.com`, P = `Pw-dev-${RUN}-x!`
register(A, P)
const as = async (id) => { process.env.DEV_ID = id; const r = await login(A, P); delete process.env.DEV_ID; return r }
const first = await as('dev-one')
assert.equal((await ok(first.tok, 'GET', '/api/azet/device-approval')).enabled, false)
assert.ok(await as('dev-two'), 'off: a new device signs in')
assert.ok((await api(first.tok, 'POST', '/api/azet/device-approval', { enabled: true, masterPasswordHash: 'wrong' })).status >= 400, 'wrong password turns it on')
await ok(first.tok, 'POST', '/api/azet/device-approval', { enabled: true, masterPasswordHash: first.hash })
assert.ok(await as('dev-two'), 'a known device signs in again')
assert.equal(await as('dev-three'), null, 'a new device is held')
assert.equal(await as('dev-three'), null, 'and held again')
const st = await ok(first.tok, 'GET', '/api/azet/device-approval')
assert.equal(st.enabled, true); assert.deepEqual(st.pending.map((d) => d.identifier), ['dev-three'])
assert.equal((await ok(first.tok, 'GET', '/api/devices')).data.some((d) => d.identifier === 'dev-three'), false, 'held device is not a device')
await ok(first.tok, 'POST', '/api/azet/device-approval/dev-three/approve')
assert.ok(await as('dev-three'), 'approved device signs in')
assert.equal((await ok(first.tok, 'GET', '/api/azet/device-approval')).pending.length, 0)
assert.equal(await as('dev-four'), null)
await ok(first.tok, 'POST', '/api/azet/device-approval/dev-four/deny')
assert.equal(await as('dev-four'), null, 'denied device is held again')
assert.ok((await api(first.tok, 'POST', '/api/azet/device-approval/nobody/approve')).status === 404)
await ok(first.tok, 'POST', '/api/azet/device-approval', { enabled: false, masterPasswordHash: first.hash })
assert.ok(await as('dev-five'), 'off again: a new device signs in')
console.log('DEVICE APPROVAL RESULT: ok')

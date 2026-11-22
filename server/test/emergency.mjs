// Emergency access against a local Worker with real client-side crypto (WebCrypto, Bitwarden formats):
// grantor invites → contact accepts → grantor wraps its user key to the contact's public key → the contact asks →
// rejected → asks again → approved → reads the grantor's items; then takeover: the wait runs out by itself → the
// contact sets a new account password → the grantor's old sessions end and the new password opens the same vault.
// usage: node test/emergency.mjs <base-url>
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
    body: new URLSearchParams({ grant_type: 'password', username: email, password: hash, scope: 'api offline_access', client_id: 'ios', deviceType: '1', deviceIdentifier: c.randomUUID(), deviceName: 'test' }) })
  const j = await r.json()
  if (!j.access_token) { if (process.env.DEBUG) console.error('login', r.status, JSON.stringify(j).slice(0, 200)); return null }
  const stretched = new Uint8Array([...await expand(mk, 'enc'), ...await expand(mk, 'mac')])
  const userKey = await decS(stretched, j.Key || j.key)
  const priv = await decS(userKey, j.PrivateKey || j.privateKey)
  return { tok: j.access_token, hash, userKey, priv, email }
}
const register = (email, password) => execFileSync('node', [new URL('./register.mjs', import.meta.url).pathname, base, email, password], { stdio: ['ignore', 'pipe', 'inherit'] })
const sync = (u) => ok(u.tok, 'GET', '/api/sync?excludeDomains=true')


const pw = (n) => `Pw-${n}-${RUN}-x!`
const [A, B, C] = ['grantor', 'contact', 'stranger'].map((n) => `ea-${n}-${RUN}@example.com`)
for (const e of [A, B, C]) register(e, pw(e))
const a = await login(A, pw(A)), b = await login(B, pw(B)), cc = await login(C, pw(C))
const SENT = { name: `Bank-${RUN}`, pass: `Emergency-Secret-${RUN}` }
await ok(a.tok, 'POST', '/api/ciphers', { type: 1, name: await encS(a.userKey, SENT.name), notes: null, favorite: false,
  login: { username: null, password: await encS(a.userKey, SENT.pass), uris: [] } })
const no = async (tok, method, path, body, why) => { const r = await api(tok, method, path, body); assert.ok(r.status >= 400, `${why}: ${method} ${path} → ${r.status}`) }

// invite: checked terms, not oneself, not twice
await no(a.tok, 'POST', '/api/emergency-access/invite', { email: B, type: 1, waitTimeDays: 0 }, 'wait 0 days')
await no(a.tok, 'POST', '/api/emergency-access/invite', { email: A, type: 0, waitTimeDays: 1 }, 'self')
const { id } = await ok(a.tok, 'POST', '/api/emergency-access/invite', { email: B.toUpperCase(), type: 0, waitTimeDays: 2 })
await no(a.tok, 'POST', '/api/emergency-access/invite', { email: B, type: 0, waitTimeDays: 2 }, 'twice')
const mine = (await ok(b.tok, 'GET', '/api/emergency-access/granted')).data
assert.equal(mine.length, 1); assert.equal(mine[0].email, A); assert.equal(mine[0].status, 0)
await no(cc.tok, 'POST', `/api/emergency-access/${id}/accept`, {}, 'someone else accepts')
await ok(b.tok, 'POST', `/api/emergency-access/${id}/accept`, {})
await no(b.tok, 'POST', `/api/emergency-access/${id}/initiate`, null, 'ask before confirm')
console.log('1 invite → accept: ok')

// confirm: the grantor wraps its user key to the contact's public key
const trusted = (await ok(a.tok, 'GET', '/api/emergency-access/trusted')).data
assert.equal(trusted[0].granteeId !== null && trusted[0].email === B, true)
const bPub = (await ok(a.tok, 'GET', `/api/users/${trusted[0].granteeId}/public-key`)).publicKey
await no(cc.tok, 'GET', `/api/users/${trusted[0].granteeId}/public-key`, null, 'stranger reads the public key')
await ok(a.tok, 'POST', `/api/emergency-access/${id}/confirm`, { key: await rsaEnc(bPub, a.userKey) })
console.log('2 confirm: ok')

// ask → nothing before approval → rejected → ask → approved → view
await ok(b.tok, 'POST', `/api/emergency-access/${id}/initiate`)
assert.ok((await ok(b.tok, 'GET', '/api/emergency-access/granted')).data[0].azetOpensAt)
await no(b.tok, 'POST', `/api/emergency-access/${id}/view`, null, 'view while waiting')
await no(b.tok, 'POST', `/api/emergency-access/${id}/approve`, null, 'contact approves itself')
await ok(a.tok, 'POST', `/api/emergency-access/${id}/reject`)
assert.equal((await ok(a.tok, 'GET', `/api/emergency-access/${id}`)).status, 2)
await ok(b.tok, 'POST', `/api/emergency-access/${id}/initiate`)
await ok(a.tok, 'POST', `/api/emergency-access/${id}/approve`)
await no(cc.tok, 'POST', `/api/emergency-access/${id}/view`, null, 'stranger views')
await no(b.tok, 'POST', `/api/emergency-access/${id}/takeover`, null, 'takeover on a view grant')
const v = await ok(b.tok, 'POST', `/api/emergency-access/${id}/view`)
const theirKey = await rsaDec(b.priv, v.keyEncrypted)
assert.equal(v.ciphers.length, 1)
assert.equal(dec.decode(await decS(theirKey, v.ciphers[0].login.password)), SENT.pass)
console.log('3 ask → reject → ask → approve → view: ok')

// takeover, approved by the wait running out
await ok(a.tok, 'PUT', `/api/emergency-access/${id}`, { type: 1, waitTimeDays: 1 })
await ok(a.tok, 'POST', `/api/emergency-access/${id}/reject`)
await ok(b.tok, 'POST', `/api/emergency-access/${id}/initiate`)
await no(b.tok, 'POST', `/api/emergency-access/${id}/takeover`, null, 'takeover while waiting')
execFileSync('npx', ['-y', 'wrangler@4', 'd1', 'execute', 'vault1', '-c', 'wrangler.test.toml', '--local', '--command',
  `UPDATE emergency_access SET recovery_initiated_at = '2020-01-01T00:00:00.000Z' WHERE id = '${id}'`],
  { stdio: 'ignore', env: { ...process.env, D1_DATABASE_ID: '00000000-0000-0000-0000-000000000000' } })
assert.equal((await ok(a.tok, 'GET', '/api/emergency-access/trusted')).data[0].status, 4, 'approved after the wait')
const t = await ok(b.tok, 'POST', `/api/emergency-access/${id}/takeover`)
assert.equal(t.kdf, 0)
const k2 = await rsaDec(b.priv, t.keyEncrypted)
const NEW = `New-${RUN}-pw!`
const mk = await pbkdf2(enc.encode(NEW), enc.encode(A), t.kdfIterations)
const newHash = b64(await pbkdf2(mk, enc.encode(NEW), 1))
const stretched = new Uint8Array([...await expand(mk, 'enc'), ...await expand(mk, 'mac')])
await ok(b.tok, 'POST', `/api/emergency-access/${id}/password`, { newMasterPasswordHash: newHash, key: await encS(stretched, k2) })
assert.equal(await login(A, pw(A)), null, 'old password still works')
const a2 = await login(A, NEW)
assert.equal(b64(a2.userKey), b64(a.userKey))
assert.ok((await api(a.tok, 'GET', '/api/sync?excludeDomains=true')).status === 401, 'old session still works')
console.log('4 takeover after the wait → new password: ok')

await ok(b.tok, 'DELETE', `/api/emergency-access/${id}`)
assert.equal((await ok(a2.tok, 'GET', '/api/emergency-access/trusted')).data.length, 0)
console.log('5 contact leaves: ok')
console.log(`SENTINEL ${SENT.name}`)
console.log(`SENTINEL ${SENT.pass}`)
console.log('EMERGENCY RESULT: ok')

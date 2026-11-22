// Passkey sign-in to the account against a local Worker, with a software authenticator (WebCrypto P-256, CBOR made
// here): make a passkey in settings → sign in with it (and get the PRF unlock keys back) → replays, a counter that
// goes back, another site's answer and a forged signature are refused → removed passkey signs in no more.
// usage: node test/webauthn.mjs <base-url>
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


const u8 = (...parts) => new Uint8Array(parts.flatMap((p) => [...p]))
const b64u = (b) => Buffer.from(b).toString('base64url')
const sha = async (b) => new Uint8Array(await c.subtle.digest('SHA-256', b))
// CBOR: unsigned/negative ints, byte and text strings, maps (all a COSE key and an attestation object need)
const head = (major, n) => n < 24 ? [major << 5 | n] : n < 256 ? [major << 5 | 24, n] : [major << 5 | 25, n >> 8, n & 255]
const cb = (v) => typeof v === 'number' ? (v >= 0 ? head(0, v) : head(1, -1 - v))
  : typeof v === 'string' ? [...head(3, enc.encode(v).length), ...enc.encode(v)]
  : v instanceof Uint8Array ? [...head(2, v.length), ...v]
  : [...head(5, v.length), ...v.flatMap(([k, x]) => [...cb(k), ...cb(x)])]
const der = (raw) => { const int = (b) => { let i = 0; while (i < b.length - 1 && b[i] === 0) i++; b = b.slice(i); return b[0] & 0x80 ? [0, ...b] : [...b] }
  const r = int(raw.slice(0, 32)), s = int(raw.slice(32)); return new Uint8Array([0x30, r.length + s.length + 4, 2, r.length, ...r, 2, s.length, ...s]) }
const ORIGIN = 'https://pass.azet.io', RP = await sha(enc.encode('pass.azet.io'))
const kp = await c.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
const jwk = await c.subtle.exportKey('jwk', kp.publicKey)
const credId = c.getRandomValues(new Uint8Array(32))
let counter = 0
const n32 = (n) => [n >>> 24, (n >> 16) & 255, (n >> 8) & 255, n & 255]
const created = (challenge) => {
  const cose = cb([[1, 2], [3, -7], [-1, 1], [-2, new Uint8Array(Buffer.from(jwk.x, 'base64url'))], [-3, new Uint8Array(Buffer.from(jwk.y, 'base64url'))]])
  const auth = u8(RP, [0x45], n32(counter), new Uint8Array(16), [0, 32], credId, cose)
  return { id: b64u(credId), rawId: b64u(credId), type: 'public-key', extensions: {}, response: {
    attestationObject: b64u(new Uint8Array(cb([['fmt', 'none'], ['attStmt', []], ['authData', auth]]))),
    clientDataJson: b64u(enc.encode(JSON.stringify({ type: 'webauthn.create', challenge, origin: ORIGIN }))), transports: ['internal'] } }
}
const asserted = async (challenge, { origin = ORIGIN, key = kp.privateKey, bump = 1 } = {}) => {
  counter += bump
  const auth = u8(RP, [0x05], n32(counter))
  const cd = enc.encode(JSON.stringify({ type: 'webauthn.get', challenge, origin }))
  const sig = new Uint8Array(await c.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, u8(auth, await sha(cd))))
  return { id: b64u(credId), rawId: b64u(credId), type: 'public-key', extensions: {},
    response: { authenticatorData: b64u(auth), signature: b64u(der(sig)), clientDataJSON: b64u(cd), userHandle: '' } }
}
const passkeyLogin = async (deviceResponse, token) => {
  token ??= (await ok(null, 'GET', '/identity/accounts/webauthn/assertion-options')).token
  const r = await fetch(`${base}/identity/connect/token`, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'webauthn', token, deviceResponse: JSON.stringify(deviceResponse), scope: 'api offline_access',
      client_id: 'web', deviceType: '9', deviceIdentifier: c.randomUUID(), deviceName: 'chrome' }) })
  return { status: r.status, body: await r.json() }
}
const options = async () => (await ok(null, 'GET', '/identity/accounts/webauthn/assertion-options'))

const A = `wa-${RUN}@example.com`, P = `Pw-wa-${RUN}-x!`
register(A, P)
const a = await login(A, P)
assert.ok((await api(a.tok, 'POST', '/api/webauthn/attestation-options', { secret: 'wrong' })).status >= 400, 'wrong password')
const co = await ok(a.tok, 'POST', '/api/webauthn/attestation-options', { secret: a.hash })
assert.equal(co.options.rp.id, 'pass.azet.io'); assert.equal(co.options.authenticatorSelection.userVerification, 'required')
const KEYS = { encryptedUserKey: `4.prf-user-key-${RUN}`, encryptedPublicKey: '2.a|b|c', encryptedPrivateKey: '2.d|e|f' }
const save = { deviceResponse: created(co.options.challenge), name: 'MacBook Touch ID', token: co.token, supportsPrf: true, ...KEYS }
await ok(a.tok, 'POST', '/api/webauthn', save)
assert.ok((await api(a.tok, 'POST', '/api/webauthn', save)).status >= 400, 'the same token twice')
const co2 = await ok(a.tok, 'POST', '/api/webauthn/attestation-options', { secret: a.hash })
assert.equal(co2.options.excludeCredentials[0].id, b64u(credId))
const list = (await ok(a.tok, 'GET', '/api/webauthn')).data
assert.equal(list.length, 1); assert.equal(list[0].prfStatus, 0); assert.equal(list[0].name, 'MacBook Touch ID')
console.log('1 passkey saved: ok')

const o1 = await options()
assert.deepEqual(o1.options.allowCredentials, []); assert.equal(o1.options.rpId, 'pass.azet.io')
const r1 = await asserted(o1.options.challenge, { bump: 5 })
const in1 = await passkeyLogin(r1, o1.token)
assert.equal(in1.status, 200, JSON.stringify(in1.body))
assert.equal(in1.body.UserDecryptionOptions.WebAuthnPrfOption.EncryptedUserKey, KEYS.encryptedUserKey)
assert.equal(in1.body.Key, (await ok(a.tok, 'GET', '/api/accounts/profile')).key ?? in1.body.Key)
assert.equal((await api(in1.body.access_token, 'GET', '/api/sync?excludeDomains=true')).status, 200)
console.log('2 passkey sign-in with PRF unlock keys: ok')

assert.equal((await passkeyLogin(r1, o1.token)).status, 400, 'replay with the used token')
const o2 = await options()
assert.equal((await passkeyLogin(await asserted(o2.options.challenge, { bump: -1 }), o2.token)).status, 400, 'counter went back')
counter += 1
assert.equal((await passkeyLogin(await asserted(o2.options.challenge), o2.token)).status, 400, 'a challenge is used once')
const o3 = await options()
assert.equal((await passkeyLogin(await asserted(o3.options.challenge, { origin: 'https://evil.example' }), o3.token)).status, 400, 'another site')
const other = await c.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign'])
const o4 = await options()
assert.equal((await passkeyLogin(await asserted(o4.options.challenge, { key: other.privateKey }), o4.token)).status, 400, 'forged signature')
const o5 = await options()
assert.equal((await passkeyLogin(await asserted('not-ours'), o5.token)).status, 400, 'challenge mismatch')
console.log('3 replay, counter, origin, forgery: refused')

assert.ok((await api(a.tok, 'POST', `/api/webauthn/${list[0].id}/delete`, { secret: 'wrong' })).status >= 400)
await ok(a.tok, 'POST', `/api/webauthn/${list[0].id}/delete`, { secret: a.hash })
const o6 = await options()
assert.equal((await passkeyLogin(await asserted(o6.options.challenge), o6.token)).status, 400, 'removed passkey')
console.log('4 removed passkey: refused')
console.log('WEBAUTHN RESULT: ok')

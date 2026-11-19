// For team.sh, the key-change checks. What a member's device holds, taken while they are still a member, and whether
// that can open a value later:
//   AZET_PASS_URL=… AZET_PASS_EMAIL=… AZET_PASS_PASSWORD=… node test/old-key.mjs key <org>     → the team key (base64)
//   AZET_PASS_URL=… AZET_PASS_EMAIL=… AZET_PASS_PASSWORD=… node test/old-key.mjs token         → an access token
//   … node test/old-key.mjs item <org> <vault> <name> <secret>                                  → the id of a new shared login
//   node test/old-key.mjs opens <key base64> <sealed value>     exit 0 when that key opens it, 1 when it does not
import { webcrypto as c } from 'node:crypto'
const [mode, a, b] = process.argv.slice(2)
const enc = new TextEncoder(), b64 = (u) => Buffer.from(u).toString('base64'), unb64 = (s) => new Uint8Array(Buffer.from(s, 'base64'))
const hmac = async (k, d) => new Uint8Array(await c.subtle.sign('HMAC', await c.subtle.importKey('raw', k, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']), d))
const opens = async (key, s) => { const [iv, ct, mac] = s.slice(2).split('|').map(unb64); return b64(await hmac(key.slice(32), new Uint8Array([...iv, ...ct]))) === b64(mac) }
if (mode === 'opens') process.exit((await opens(unb64(a), b)) ? 0 : 1)

const base = process.env.AZET_PASS_URL, email = process.env.AZET_PASS_EMAIL, password = process.env.AZET_PASS_PASSWORD
const pbkdf2 = async (pw, salt, iter) => new Uint8Array(await c.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt, iterations: iter }, await c.subtle.importKey('raw', pw, 'PBKDF2', false, ['deriveBits']), 256))
const expand = (prk, info) => hmac(prk, new Uint8Array([...enc.encode(info), 1]))
const decS = async (key, s) => { if (!(await opens(key, s))) throw new Error('mac'); const [iv, ct] = s.slice(2).split('|').map(unb64); return new Uint8Array(await c.subtle.decrypt({ name: 'AES-CBC', iv }, await c.subtle.importKey('raw', key.slice(0, 32), 'AES-CBC', false, ['decrypt']), ct)) }
const post = (path, body, headers) => fetch(base + path, { method: 'POST', headers, body }).then((r) => r.json())
const pre = await post('/identity/accounts/prelogin', JSON.stringify({ email }), { 'content-type': 'application/json' })
const mk = await pbkdf2(enc.encode(password), enc.encode(email), pre.kdfIterations)
const j = await post('/identity/connect/token', new URLSearchParams({ grant_type: 'password', username: email, password: b64(await pbkdf2(mk, enc.encode(password), 1)), scope: 'api offline_access', client_id: 'cli', deviceType: '8', deviceIdentifier: c.randomUUID(), deviceName: 'old-key-test' }), { 'content-type': 'application/x-www-form-urlencoded' })
if (mode === 'token') { console.log(j.access_token); process.exit(0) }
const userKey = await decS(new Uint8Array([...await expand(mk, 'enc'), ...await expand(mk, 'mac')]), j.Key || j.key)
const priv = await decS(userKey, j.PrivateKey || j.privateKey)
const sync = await fetch(`${base}/api/sync?excludeDomains=true`, { headers: { authorization: `Bearer ${j.access_token}` } }).then((r) => r.json())
const wrapped = sync.profile.organizations.find((o) => o.id === a).key
const orgKey = new Uint8Array(await c.subtle.decrypt({ name: 'RSA-OAEP' }, await c.subtle.importKey('pkcs8', priv, { name: 'RSA-OAEP', hash: 'SHA-1' }, false, ['decrypt']), unb64(wrapped.slice(2))))
if (mode === 'item') { // a login sealed straight with the team key, saved into the shared vault
  const [, , vault, name, secret] = process.argv.slice(2)
  const seal = async (t) => { const iv = c.getRandomValues(new Uint8Array(16)), ct = new Uint8Array(await c.subtle.encrypt({ name: 'AES-CBC', iv }, await c.subtle.importKey('raw', orgKey.slice(0, 32), 'AES-CBC', false, ['encrypt']), enc.encode(t))); return `2.${b64(iv)}|${b64(ct)}|${b64(await hmac(orgKey.slice(32), new Uint8Array([...iv, ...ct])))}` }
  const made = await post('/api/ciphers/create', JSON.stringify({ cipher: { type: 1, organizationId: a, name: await seal(name), login: { username: await seal('page'), password: await seal(secret) } }, collectionIds: [vault] }), { 'content-type': 'application/json', authorization: `Bearer ${j.access_token}` })
  console.log(made.id); process.exit(made.id ? 0 : 1)
}
console.log(b64(orgKey))

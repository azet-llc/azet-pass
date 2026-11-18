// Changes an account's master password the way a client does: the account key is unwrapped with the old password and
// wrapped again with the new one; the server gets hashes and the re-wrapped key only. Passwords come in through the
// environment (OLD_PW, NEW_PW) and nothing secret is printed.
// usage: OLD_PW=… NEW_PW=… node test/rotate-password.mjs <base-url> <email>
import { webcrypto as c } from 'node:crypto'
const [base, email] = process.argv.slice(2), { OLD_PW, NEW_PW } = process.env
if (!base || !email || !OLD_PW || !NEW_PW || NEW_PW.length < 16) { console.error('usage: OLD_PW=… NEW_PW=… (16+ chars) rotate-password.mjs <base-url> <email>'); process.exit(2) }
const enc = new TextEncoder(), b64 = (u) => Buffer.from(u).toString('base64'), raw = (s) => new Uint8Array(Buffer.from(s, 'base64'))
const pbkdf2 = async (pw, salt, iter) => new Uint8Array(await c.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt, iterations: iter },
  await c.subtle.importKey('raw', pw, 'PBKDF2', false, ['deriveBits']), 256))
const hmacKey = (k, use) => c.subtle.importKey('raw', k, { name: 'HMAC', hash: 'SHA-256' }, false, [use])
const expand = async (prk, info) => new Uint8Array(await c.subtle.sign('HMAC', await hmacKey(prk, 'sign'), new Uint8Array([...enc.encode(info), 1])))
const keys = async (pw, iter) => {
  const master = await pbkdf2(enc.encode(pw), enc.encode(email.trim().toLowerCase()), iter)
  return { hash: b64(await pbkdf2(master, enc.encode(pw), 1)), encKey: await expand(master, 'enc'), macKey: await expand(master, 'mac') }
}
const post = (path, body, headers = {}) => fetch(base + path, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(body) })
const signIn = (hash) => fetch(base + '/identity/connect/token', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
  body: new URLSearchParams({ grant_type: 'password', username: email, password: hash, scope: 'api offline_access', client_id: 'cli',
    deviceType: '8', deviceIdentifier: '5b1f6c1e-0c0a-4d6e-9a55-7c1f0c5e2a11', deviceName: 'rotate-password' }) })

const pre = await (await post('/identity/accounts/prelogin', { email })).json()
if ((pre.kdf ?? pre.Kdf) !== 0) { console.error('this script handles PBKDF2 accounts only'); process.exit(1) }
const iter = pre.kdfIterations ?? pre.KdfIterations
const old = await keys(OLD_PW, iter), next = await keys(NEW_PW, iter)
const session = await signIn(old.hash)
if (!session.ok) { console.error('sign-in with the old password failed:', session.status); process.exit(1) }
const { access_token, Key, key } = await session.json()
const [iv, ct, mac] = (Key ?? key).slice(2).split('|').map(raw)
// the account key must unwrap cleanly before anything is changed
if (!await c.subtle.verify('HMAC', await hmacKey(old.macKey, 'verify'), mac, new Uint8Array([...iv, ...ct]))) { console.error('the account key does not match the old password'); process.exit(1) }
const userKey = new Uint8Array(await c.subtle.decrypt({ name: 'AES-CBC', iv }, await c.subtle.importKey('raw', old.encKey, 'AES-CBC', false, ['decrypt']), ct))
if (userKey.length !== 64) { console.error('unexpected account key length', userKey.length); process.exit(1) }
const iv2 = c.getRandomValues(new Uint8Array(16))
const ct2 = new Uint8Array(await c.subtle.encrypt({ name: 'AES-CBC', iv: iv2 }, await c.subtle.importKey('raw', next.encKey, 'AES-CBC', false, ['encrypt']), userKey))
const mac2 = new Uint8Array(await c.subtle.sign('HMAC', await hmacKey(next.macKey, 'sign'), new Uint8Array([...iv2, ...ct2])))
const res = await post('/api/accounts/password', { masterPasswordHash: old.hash, newMasterPasswordHash: next.hash, key: `2.${b64(iv2)}|${b64(ct2)}|${b64(mac2)}` }, { authorization: 'Bearer ' + access_token })
console.log('change:', res.status)
if (!res.ok) process.exit(1)
console.log('sign-in with the new password:', (await signIn(next.hash)).status, '· with the old one:', (await signIn(old.hash)).status)

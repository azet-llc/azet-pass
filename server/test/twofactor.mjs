// Two-step sign-in (an authenticator app) end to end against a Worker: node test/twofactor.mjs <base url> <email> <password>
// The account must exist (test/register.mjs). Turns two-step sign-in on, then signs in every way that must be
// refused and every way that must work, uses the recovery code, and leaves the account without two-step sign-in.
// Prints one line per check; any refusal that should not happen (or the reverse) throws.
import { webcrypto as c, createHmac } from 'node:crypto'
import assert from 'node:assert/strict'

const [base, email, password] = process.argv.slice(2)
const enc = new TextEncoder(), b64 = (u) => Buffer.from(u).toString('base64')
const pbkdf2 = async (pw, salt, iter) => new Uint8Array(await c.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt, iterations: iter }, await c.subtle.importKey('raw', pw, 'PBKDF2', false, ['deriveBits']), 256))
const pre = await (await fetch(`${base}/identity/accounts/prelogin`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email }) })).json()
const hash = b64(await pbkdf2(await pbkdf2(enc.encode(password), enc.encode(email), pre.kdfIterations), enc.encode(password), 1))
const device = c.randomUUID()
const signIn = async (extra = {}, pw = hash) => {
  const r = await fetch(`${base}/identity/connect/token`, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'password', username: email, password: pw, scope: 'api offline_access', client_id: 'cli', deviceType: '8', deviceIdentifier: device, deviceName: 'twofactor-test', ...extra }) })
  return { status: r.status, body: await r.json().catch(() => ({})) }
}
// RFC 6238 with the server's settings (SHA-1, 30 seconds, 6 digits); `step` picks the next or the previous code
const base32 = (s) => { let bits = ''; for (const ch of s.replace(/=+$/, '').toUpperCase()) bits += 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'.indexOf(ch).toString(2).padStart(5, '0'); return Buffer.from(bits.match(/.{8}/g).map((b) => parseInt(b, 2))) }
const totp = (secret, step = 0) => {
  const counter = Buffer.alloc(8); counter.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 30000) + step))
  const h = createHmac('sha1', base32(secret)).update(counter).digest(), o = h[19] & 15
  return String(((h.readUInt32BE(o) & 0x7fffffff) % 1e6)).padStart(6, '0')
}
const api = async (tok, method, path, body) => { const r = await fetch(base + path, { method, headers: { 'content-type': 'application/json', authorization: `Bearer ${tok}` }, body: body ? JSON.stringify(body) : undefined }); return { status: r.status, body: await r.json().catch(() => ({})) } }

const first = await signIn()
assert.equal(first.status, 200, 'an account without two-step sign-in signs in with the password alone')
const tok = first.body.access_token
assert.equal((await api(tok, 'POST', '/api/two-factor/get-authenticator', { masterPasswordHash: 'wrong' })).status >= 400, true, 'the secret is not shown without the master password')
const { key, userVerificationToken: uvt } = (await api(tok, 'POST', '/api/two-factor/get-authenticator', { masterPasswordHash: hash })).body
assert.ok(/^\d+\.[0-9a-f]{40}$/.test(uvt || ''), 'get-authenticator answers a user verification token (web vaults send it instead of the password)')
const setup = (await api(tok, 'POST', '/api/two-factor/get-authenticator', { masterPasswordHash: hash })).body
assert.deepEqual(setup.authenticator, { enabled: false, key: setup.key }, 'the web vault reads the secret from authenticator.key')
assert.ok(key && key.length >= 16, 'a secret for the authenticator app')
assert.equal((await api(tok, 'POST', '/api/two-factor/authenticator', { key, token: '000000', masterPasswordHash: hash })).status >= 400, true, 'a wrong code does not turn it on')
const forged = uvt.replace(/.$/, (ch) => (ch === '0' ? '1' : '0'))
assert.equal((await api(tok, 'PUT', '/api/two-factor/authenticator', { key, token: totp(key, -1), userVerificationToken: forged })).status >= 400, true, 'a changed token without the password does not turn it on')
assert.equal((await api(tok, 'PUT', '/api/two-factor/authenticator', { key: 'A'.repeat(32), token: totp('A'.repeat(32), -1), userVerificationToken: uvt })).status >= 400, true, 'the token works only for the secret it was given with')
const on = await api(tok, 'PUT', '/api/two-factor/authenticator', { key, token: totp(key, -1), userVerificationToken: uvt })
assert.equal(on.status, 200, `turning it on with a right code and the token: ${JSON.stringify(on.body)}`)
assert.equal(on.body.authenticator?.enabled, true, 'the answer says it is on where the web vault reads it')
console.log('1 two-step sign-in turned on with the verification token (as the web vault does) and a code from the app: ok')

const none = await signIn()
assert.equal(none.status, 400); assert.ok(JSON.stringify(none.body).includes('TwoFactorProviders'), 'the password alone is answered "second step needed"')
assert.equal(none.body.access_token, undefined)
const wrong = await signIn({ twoFactorToken: '000000', twoFactorProvider: '0' })
assert.ok(wrong.status >= 400 && !wrong.body.access_token, 'a wrong code is refused')
const badPw = await signIn({ twoFactorToken: totp(key), twoFactorProvider: '0' }, b64(new Uint8Array(32)))
assert.ok(badPw.status >= 400 && !badPw.body.access_token, 'a right code with a wrong password is refused')
console.log('2 refused: the password alone, a wrong code, a right code with a wrong password: ok')

const code = totp(key)
const good = await signIn({ twoFactorToken: code, twoFactorProvider: '0' })
assert.equal(good.status, 200, `password and code sign in: ${JSON.stringify(good.body).slice(0, 200)}`)
const again = await signIn({ twoFactorToken: code, twoFactorProvider: '0' })
assert.ok(again.status >= 400 && !again.body.access_token, 'the same code does not work twice')
console.log('3 the password and a fresh code sign in; the same code a second time is refused: ok')

const recover = (await api(good.body.access_token, 'POST', '/api/two-factor/get-recover', { masterPasswordHash: hash })).body.code
assert.ok(recover && recover.length >= 16, 'a recovery code')
const badRecover = await signIn({ twoFactorToken: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', twoFactorProvider: '8' })
assert.ok(badRecover.status >= 400 && !badRecover.body.access_token, 'a wrong recovery code is refused')
const recovered = await signIn({ twoFactorToken: recover, twoFactorProvider: '8' })
assert.equal(recovered.status, 200, 'the recovery code signs in')
assert.equal((await signIn()).status, 200, 'and turned two-step sign-in off, as the apps say it does')
assert.ok((await signIn({ twoFactorToken: recover, twoFactorProvider: '8' })).body.access_token, 'no second step is asked any more')
console.log('4 the recovery code signs in once and turns two-step sign-in off; a wrong one is refused: ok')
console.log(`SECRETS ${key} ${recover}`)

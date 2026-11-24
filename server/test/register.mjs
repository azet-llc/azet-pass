// Test-only account creation, done the way a Bitwarden-family client does it (the `bw` CLI cannot register).
// Everything secret is derived and encrypted here; the request carries only hashes, encrypted keys and a public key.
// usage: node test/register.mjs <base-url> <email> <master-password>
import { webcrypto as c } from 'node:crypto'
import fs from 'node:fs'
import { makeSignupToken } from '../src/signup.js'
const [base, email, password] = process.argv.slice(2)
const enc = new TextEncoder()
const b64 = (u) => Buffer.from(u).toString('base64')
const ITER = 600000

const pbkdf2 = async (pw, salt, iter) =>
  new Uint8Array(await c.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt, iterations: iter },
    await c.subtle.importKey('raw', pw, 'PBKDF2', false, ['deriveBits']), 256))
// HKDF-Expand only (Bitwarden stretches the master key with expand, no extract), one block of 32 bytes.
const expand = async (prk, info) => {
  const k = await c.subtle.importKey('raw', prk, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  return new Uint8Array(await c.subtle.sign('HMAC', k, new Uint8Array([...enc.encode(info), 1])))
}
// EncString type 2: AES-256-CBC + HMAC-SHA256 over iv||ct
const encString = async (encKey, macKey, data) => {
  const iv = c.getRandomValues(new Uint8Array(16))
  const ct = new Uint8Array(await c.subtle.encrypt({ name: 'AES-CBC', iv },
    await c.subtle.importKey('raw', encKey, 'AES-CBC', false, ['encrypt']), data))
  const mac = new Uint8Array(await c.subtle.sign('HMAC',
    await c.subtle.importKey('raw', macKey, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']), new Uint8Array([...iv, ...ct])))
  return `2.${b64(iv)}|${b64(ct)}|${b64(mac)}`
}

const salt = enc.encode(email.trim().toLowerCase())
const masterKey = await pbkdf2(enc.encode(password), salt, ITER)
const masterPasswordHash = b64(await pbkdf2(masterKey, enc.encode(password), 1))
const userKey = c.getRandomValues(new Uint8Array(64))
const key = await encString(await expand(masterKey, 'enc'), await expand(masterKey, 'mac'), userKey)
const rsa = await c.subtle.generateKey({ name: 'RSA-OAEP', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-1' }, true, ['encrypt', 'decrypt'])
const publicKey = b64(new Uint8Array(await c.subtle.exportKey('spki', rsa.publicKey)))
const encryptedPrivateKey = await encString(userKey.slice(0, 32), userKey.slice(32), new Uint8Array(await c.subtle.exportKey('pkcs8', rsa.privateKey)))

// The emailed sign-up token, minted with the server's JWT_SECRET (env, or the local .dev.vars the test scripts write).
const secret = process.env.JWT_SECRET || fs.readFileSync(new URL('../.dev.vars', import.meta.url), 'utf8').match(/^JWT_SECRET=(.*)$/m)[1]
const emailVerificationToken = await makeSignupToken(secret, email)

const res = await fetch(`${base}/identity/accounts/register`, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ email, name: process.env.NAME || null, masterPasswordHash, masterPasswordHint: process.env.HINT || null, key, kdf: 0, kdfIterations: ITER, userAsymmetricKeys: { publicKey, encryptedPrivateKey }, emailVerificationToken }),
})
console.error('register', res.status, (await res.text()).slice(0, 200))
if (!res.ok) process.exit(1)
if (process.env.PRINT_TOKEN) { // password grant, as clients do, for API tests that need a bearer token
  const t = await fetch(`${base}/identity/connect/token`, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'password', username: email, password: masterPasswordHash, scope: 'api offline_access', client_id: 'cli', deviceType: '8', deviceIdentifier: crypto.randomUUID(), deviceName: 'test' }) })
  console.log((await t.json()).access_token)
  if (process.env.PRINT_HASH) console.log(masterPasswordHash) // second line: for routes that re-check the master password
}

// Family flow against a local Worker, with real client-side crypto (WebCrypto, Bitwarden formats):
// owner makes a family → invites → member accepts → owner confirms with the family key wrapped to the member's
// public key → shared item round trip → read-only vault → outsider sees nothing → suspend/restore → organizer
// recovery → travel mode. Prints SENTINEL values for family.sh to look for in D1 afterwards.
// usage: node test/family.mjs <base-url>
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
const [A, B, C] = ['owner', 'mom', 'stranger'].map((n) => `fam-${n}-${RUN}@example.com`)
for (const e of [A, B, C]) register(e, pw(e))
const a = await login(A, pw(A)), b = await login(B, pw(B)), cc = await login(C, pw(C))
const aProfile = await ok(a.tok, 'GET', '/api/accounts/profile')

// 1 family
const orgKey = c.getRandomValues(new Uint8Array(64))
const orgRsa = await rsaPair()
const orgPub = b64(new Uint8Array(await c.subtle.exportKey('spki', orgRsa.publicKey)))
const org = await ok(a.tok, 'POST', '/api/organizations', {
  name: '우리 가족', billingEmail: A, planType: 11, key: await rsaEnc(aProfile.accountKeys?.publicKeyEncryptionKeyPair?.publicKey || (await ok(a.tok, 'GET', `/api/users/${aProfile.id}/public-key`)).publicKey, orgKey),
  keys: { publicKey: orgPub, encryptedPrivateKey: await encS(orgKey, new Uint8Array(await c.subtle.exportKey('pkcs8', orgRsa.privateKey))) },
  collectionName: await encS(orgKey, '가족 공유') })
assert.equal(org.type, 0)
const s1 = await sync(a)
assert.equal(s1.profile.organizations.length, 1); assert.equal(s1.collections.length, 1)
const shared = s1.collections[0].id
assert.deepEqual(await rsaDec(a.priv, s1.profile.organizations[0].key), orgKey, 'owner unwraps family key')
console.log('1 family created: ok')
assert.equal((await api(a.tok, 'POST', '/api/organizations', { name: 'x', key: 'x' })).status, 400, 'one family per organizer')

// 2 invite by link, accept, confirm
const inv = await ok(a.tok, 'POST', `/api/organizations/${org.id}/users/invite`, { emails: [B], type: 2, displayName: '엄마', collections: [{ id: shared, readOnly: false }] })
const { id: mid, token } = inv.data[0]
const prev = await ok(null, 'GET', `/api/azet/invites/${mid}/${token}`)
assert.equal(prev.organizationName, '우리 가족'); assert.equal(prev.displayName, '엄마')
assert.equal((await api(cc.tok, 'POST', `/api/organizations/${org.id}/users/${mid}/accept`, { token })).status, 400, 'other email cannot take the invite')
assert.equal((await api(b.tok, 'POST', `/api/organizations/${org.id}/users/${mid}/accept`, { token: 'nope' })).status, 400, 'wrong token')
await ok(b.tok, 'POST', `/api/organizations/${org.id}/users/${mid}/accept`, { token })
assert.equal((await api(b.tok, 'POST', `/api/organizations/${org.id}/users/${mid}/accept`, { token })).status, 400, 'token used once')
const bOrgPub = (await ok(b.tok, 'GET', `/api/organizations/${org.id}/public-key`)).publicKey
assert.equal(bOrgPub, orgPub)
await ok(b.tok, 'PUT', `/api/organizations/${org.id}/users/${(await ok(b.tok, 'GET', '/api/accounts/profile')).id}/reset-password-enrollment`, { resetPasswordKey: await rsaEnc(bOrgPub, b.userKey), masterPasswordHash: b.hash })
let ms = (await ok(a.tok, 'GET', `/api/organizations/${org.id}/users`)).data
const bm = ms.find((m) => m.email === B)
assert.equal(bm.status, 1); assert.ok(bm.publicKey, 'organizer sees the key to compare fingerprints with'); assert.equal(bm.resetPasswordEnrolled, true)
assert.equal((await api(b.tok, 'POST', `/api/organizations/${org.id}/users/${mid}/confirm`, { key: 'x' })).status, 404, 'unconfirmed member cannot confirm')
await ok(a.tok, 'POST', `/api/organizations/${org.id}/users/${mid}/confirm`, { key: await rsaEnc(bm.publicKey, orgKey) })
const sb = await sync(b)
assert.deepEqual(await rsaDec(b.priv, sb.profile.organizations[0].key), orgKey, 'member unwraps family key')
assert.equal(sb.collections.length, 1)
console.log('2 invite link → accept → confirm: ok')

// 2b a parent signs up straight from the invite link (no mail link), only for the invited address
const D = `fam-dad-${RUN}@example.com`
const dinv = (await ok(a.tok, 'POST', `/api/organizations/${org.id}/users/invite`, { emails: [D], type: 2, displayName: '아빠' })).data[0]
const regWith = async (email, extra) => {
  const mk = await pbkdf2(enc.encode(pw(email)), enc.encode(email), ITER)
  const uk = c.getRandomValues(new Uint8Array(64)), kp = await rsaPair()
  return fetch(`${base}/identity/accounts/register`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({
    email, name: null, masterPasswordHash: b64(await pbkdf2(mk, enc.encode(pw(email)), 1)), masterPasswordHint: null, kdf: 0, kdfIterations: ITER,
    key: await encS(new Uint8Array([...await expand(mk, 'enc'), ...await expand(mk, 'mac')]), uk),
    userAsymmetricKeys: { publicKey: b64(new Uint8Array(await c.subtle.exportKey('spki', kp.publicKey))), encryptedPrivateKey: await encS(uk, new Uint8Array(await c.subtle.exportKey('pkcs8', kp.privateKey))) },
    ...extra }) })
}
assert.equal((await regWith(`other-${RUN}@example.com`, { orgInviteToken: dinv.token, organizationUserId: dinv.id })).status, 400, 'invite token is for one address')
assert.equal((await regWith(D, { orgInviteToken: 'bad', organizationUserId: dinv.id })).status, 400)
assert.equal((await regWith(D, { orgInviteToken: dinv.token, organizationUserId: dinv.id })).status, 200, 'parent signs up from the invite')
const d = await login(D, pw(D))
await ok(d.tok, 'POST', `/api/organizations/${org.id}/users/${dinv.id}/accept`, { token: dinv.token })
await ok(a.tok, 'DELETE', `/api/organizations/${org.id}/users/${dinv.id}`)
console.log('2b sign up from invite link: ok')

// 3 shared item round trip (organizer writes, member reads and edits)
const SENT = { name: `Netflix-${RUN}`, user: `family-${RUN}@mail.test`, pass: `Wifi-Secret-${RUN}` }
const cipher = (k, n, u, p) => Promise.all([encS(k, n), encS(k, u), encS(k, p)]).then(([name, username, password]) => ({ type: 1, organizationId: org.id, name, notes: null, favorite: false, login: { username, password, uris: [] } }))
const item = await ok(a.tok, 'POST', '/api/ciphers/create', { cipher: await cipher(orgKey, SENT.name, SENT.user, SENT.pass), collectionIds: [shared] })
const sb2 = await sync(b)
const got = sb2.ciphers.find((x) => x.id === item.id)
assert.ok(got, 'member sees the shared item'); assert.equal(got.edit, true); assert.deepEqual(got.collectionIds, [shared])
assert.equal(dec.decode(await decS(orgKey, got.login.password)), SENT.pass)
await ok(b.tok, 'PUT', `/api/ciphers/${item.id}`, { ...(await cipher(orgKey, SENT.name, SENT.user, SENT.pass + '2')), organizationId: org.id })
assert.equal(dec.decode(await decS(orgKey, (await sync(a)).ciphers.find((x) => x.id === item.id).login.password)), SENT.pass + '2', 'organizer sees member edit')
// a personal item moves into the family
const mine = await ok(b.tok, 'POST', '/api/ciphers', { type: 2, name: await encS(b.userKey, 'memo'), notes: null, secureNote: { type: 0 } })
assert.equal((await api(cc.tok, 'PUT', `/api/ciphers/${mine.id}/share`, { cipher: { type: 2, organizationId: org.id, name: 'x', secureNote: { type: 0 } }, collectionIds: [shared] })).status, 404)
await ok(b.tok, 'PUT', `/api/ciphers/${mine.id}/share`, { cipher: { type: 2, organizationId: org.id, name: await encS(orgKey, 'memo'), secureNote: { type: 0 } }, collectionIds: [shared] })
assert.ok((await sync(a)).ciphers.some((x) => x.id === mine.id), 'shared memo reaches the organizer')
console.log('3 shared items: ok')

// 4 a vault only some people see, read-only for the member
const parents = await ok(a.tok, 'POST', `/api/organizations/${org.id}/collections`, { name: await encS(orgKey, '부모님 은행'), users: [{ id: mid, readOnly: true }] })
const bank = await ok(a.tok, 'POST', '/api/ciphers/create', { cipher: await cipher(orgKey, 'bank', 'id', 'pin'), collectionIds: [parents.id] })
let sb3 = await sync(b)
assert.equal(sb3.ciphers.find((x) => x.id === bank.id).edit, false, 'read-only vault')
await api(b.tok, 'PUT', `/api/ciphers/${bank.id}`, { ...(await cipher(orgKey, 'hacked', 'id', 'pin')), organizationId: org.id })
assert.equal(dec.decode(await decS(orgKey, (await sync(a)).ciphers.find((x) => x.id === bank.id).name)), 'bank', 'read-only edit ignored')
assert.equal((await api(b.tok, 'POST', '/api/ciphers/create', { cipher: await cipher(orgKey, 'x', 'y', 'z'), collectionIds: [parents.id] })).status, 400, 'cannot add to read-only vault')
console.log('4 read-only vault: ok')

// 4b files on family items: a member with edit attaches, the organizer opens it, read-only and outsiders cannot
const blob = enc.encode(`2.ciphertext-of-a-passport-scan-${RUN}`)
const slot = await ok(b.tok, 'POST', `/api/ciphers/${item.id}/attachment/v2`, { key: await encS(orgKey, 'k'), fileName: await encS(orgKey, 'passport.jpg'), fileSize: blob.length })
const put = await fetch(slot.url, { method: 'PUT', headers: { 'content-length': String(blob.length) }, body: blob })
assert.ok(put.status < 300, `upload → ${put.status} ${await put.text()}`)
const meta = await ok(a.tok, 'GET', `/api/ciphers/${item.id}/attachment/${slot.attachmentId}`)
assert.deepEqual(new Uint8Array(await (await fetch(meta.url)).arrayBuffer()), blob, 'organizer downloads the same ciphertext')
assert.equal((await api(b.tok, 'POST', `/api/ciphers/${bank.id}/attachment/v2`, { key: 'k', fileName: 'f', fileSize: 1 })).status, 404, 'no files on a read-only vault')
assert.equal((await api(cc.tok, 'GET', `/api/ciphers/${item.id}/attachment/${slot.attachmentId}`)).status, 404, 'outsider cannot open the file')
console.log('4b family files: ok')
// 4c the many-at-once share (the web vault's "Assign to collections") and taking one back
const aOwn = await ok(a.tok, 'POST', '/api/ciphers', { type: 2, name: await encS(a.userKey, 'mine only'), notes: null, secureNote: { type: 0 } })
const sharedName = await encS(orgKey, 'x')
const bulk = (tok, id, name = sharedName) => api(tok, 'PUT', '/api/ciphers/share', { ciphers: [{ id, type: 2, organizationId: org.id, name, secureNote: { type: 0 } }], collectionIds: [shared] })
assert.equal((await bulk(a.tok, aOwn.id, 'readable name')).status, 400, 'the server refuses an item whose name is not encrypted')
assert.equal((await bulk(b.tok, aOwn.id)).status, 404, 'a member cannot share someone else\'s personal item')
assert.ok(!(await sync(b)).ciphers.some((x) => x.id === aOwn.id), 'and it did not move')
assert.equal((await bulk(a.tok, aOwn.id)).body.data[0].id, aOwn.id, 'its owner can')
const ownName = await encS(a.userKey, 'x')
const back = (tok, id) => api(tok, 'PUT', `/api/ciphers/${id}/unshare`, { cipher: { type: 2, name: ownName, secureNote: { type: 0 } } })
assert.equal((await back(b.tok, aOwn.id)).status, 400, 'only an organizer takes an item back')
assert.equal((await back(a.tok, item.id)).status, 400, 'an item with files is refused, not orphaned')
assert.ok((await back(a.tok, aOwn.id)).status < 300); assert.ok(!(await sync(b)).ciphers.some((x) => x.id === aOwn.id), 'taken back: the member no longer gets it')
console.log('4c many-at-once share and take-back: ok')


// 5 outsider sees nothing and cannot inject
const sc = await sync(cc)
assert.equal(sc.ciphers.length, 0); assert.equal(sc.profile.organizations.length, 0)
assert.equal((await api(cc.tok, 'GET', `/api/organizations/${org.id}`)).status, 404)
assert.equal((await api(cc.tok, 'GET', `/api/ciphers/${item.id}`)).status, 404)
assert.equal((await api(cc.tok, 'POST', '/api/ciphers/create', { cipher: await cipher(orgKey, 'x', 'y', 'z'), collectionIds: [shared] })).status, 404)
assert.equal((await api(cc.tok, 'POST', `/api/organizations/${org.id}/users/invite`, { emails: [C], type: 2 })).status, 404)
assert.equal((await api(cc.tok, 'GET', `/api/users/${aProfile.id}/public-key`)).status, 404)
assert.equal((await api(b.tok, 'POST', `/api/organizations/${org.id}/users/invite`, { emails: [C], type: 2 })).status, 400, 'member cannot invite')
console.log('5 outsider: ok')

// 6 seats: 5 people, guests extra
const more = await ok(a.tok, 'POST', `/api/organizations/${org.id}/users/invite`, { emails: ['k1@x.test', 'k2@x.test', 'k3@x.test'], type: 2 })
assert.equal(more.data.length, 3)
assert.equal((await api(a.tok, 'POST', `/api/organizations/${org.id}/users/invite`, { emails: ['k4@x.test'], type: 2 })).status, 400, 'sixth person refused')
await ok(a.tok, 'POST', `/api/organizations/${org.id}/users/invite`, { emails: ['sitter@x.test'], type: 5, collections: [{ id: shared, readOnly: true }] })
for (const m of more.data) await ok(a.tok, 'DELETE', `/api/organizations/${org.id}/users/${m.id}`)
console.log('6 five seats + guest: ok')

// 7 suspend and restore
await ok(a.tok, 'PUT', `/api/organizations/${org.id}/users/${mid}/revoke`)
assert.equal((await sync(b)).ciphers.filter((x) => x.organizationId).length, 0, 'suspended member sees no family items')
await ok(a.tok, 'PUT', `/api/organizations/${org.id}/users/${mid}/restore`)
assert.ok((await sync(b)).ciphers.some((x) => x.id === item.id))
console.log('7 suspend/restore: ok')

// 8 organizer recovers the member who forgot their password
const det = await ok(a.tok, 'GET', `/api/organizations/${org.id}/users/${mid}/reset-password-details`)
const orgPriv = await decS(orgKey, det.encryptedPrivateKey)
const bUserKey = await rsaDec(orgPriv, det.resetPasswordKey)
assert.deepEqual(bUserKey, b.userKey)
const temp = `Temp-${RUN}-!`
const nmk = await pbkdf2(enc.encode(temp), enc.encode(B), det.kdfIterations)
await ok(a.tok, 'PUT', `/api/organizations/${org.id}/users/${mid}/reset-password`, {
  newMasterPasswordHash: b64(await pbkdf2(nmk, enc.encode(temp), 1)),
  key: await encS(new Uint8Array([...await expand(nmk, 'enc'), ...await expand(nmk, 'mac')]), bUserKey) })
assert.equal(await login(B, pw(B)), null, 'old password stops working')
const b2 = await login(B, temp)
assert.deepEqual(b2.userKey, b.userKey, 'same vault after recovery')
assert.equal((await api(b2.tok, 'GET', `/api/organizations/${org.id}/users/${(await ok(a.tok, 'GET', `/api/organizations/${org.id}/users`)).data.find((m) => m.email === A).id}/reset-password-details`)).status, 400, 'member cannot recover the owner')
console.log('8 organizer recovery: ok')

// 9 travel mode
await ok(a.tok, 'PUT', `/api/organizations/${org.id}/collections/${shared}`, { travelSafe: true })
assert.equal((await api(a.tok, 'PUT', `/api/organizations/${org.id}/collections/00000000-not-this-family`, { users: [{ id: mid, readOnly: false, manage: true }] })).status, 400, 'a vault that is not this family\'s cannot be given members')
await ok(b2.tok, 'POST', '/api/azet/travel-mode', { enabled: true, masterPasswordHash: b2.hash })
const st = await sync(b2)
assert.ok(st.ciphers.some((x) => x.id === item.id), 'travel-safe vault stays'); assert.ok(!st.ciphers.some((x) => x.id === bank.id), 'other vault leaves the device')
assert.equal(st.collections.length, 1)
await ok(b2.tok, 'POST', '/api/azet/travel-mode', { enabled: false, masterPasswordHash: b2.hash })
assert.ok((await sync(b2)).ciphers.some((x) => x.id === bank.id))
console.log('9 travel mode: ok')

// 10 the family key is changed (scripts/team.mjs rotate): the item, the file's name and key, and the member's recovery
// key all open with the new keys, the old family key opens none of them, and the file itself is the same
const rot = JSON.parse(execFileSync('node', [new URL('../scripts/team.mjs', import.meta.url).pathname, 'rotate', org.id],
  { env: { ...process.env, AZET_PASS_URL: base, AZET_PASS_EMAIL: A, AZET_PASS_PASSWORD: pw(A) }, stdio: ['ignore', 'pipe', 'inherit'] }))
assert.equal(rot.rotated, true); assert.equal(rot.files, 1); assert.deepEqual(rot.needConfirmAgain, [])
const a3 = await login(A, pw(A)), s3 = await sync(a3), b3 = await login(B, temp)
const newKey = await rsaDec(a3.priv, s3.profile.organizations.find((o) => o.id === org.id).key)
assert.notDeepEqual(newKey, orgKey)
assert.deepEqual(await rsaDec(b3.priv, (await sync(b3)).profile.organizations.find((o) => o.id === org.id).key), newKey, 'the member was handed the new key')
const say = async (key, v) => Buffer.from(await decS(key, v)).toString()
const x3 = s3.ciphers.find((x) => x.id === item.id), f3 = x3.attachments[0]
assert.equal(await say(newKey, x3.name), SENT.name); assert.ok((await say(newKey, x3.login.password)).startsWith(SENT.pass)) // a member edited it in step 3
assert.equal(await say(newKey, f3.fileName), 'passport.jpg'); assert.equal(await say(newKey, f3.key), 'k')
for (const sealed of [x3.name, f3.fileName, f3.key]) await assert.rejects(decS(orgKey, sealed), 'the old family key opens nothing')
assert.deepEqual(new Uint8Array(await (await fetch((await ok(a3.tok, 'GET', `/api/ciphers/${item.id}/attachment/${slot.attachmentId}`)).url)).arrayBuffer()), blob, 'the file is unchanged')
const det3 = await ok(a3.tok, 'GET', `/api/organizations/${org.id}/users/${mid}/reset-password-details`)
assert.deepEqual(await rsaDec(await decS(newKey, det3.encryptedPrivateKey), det3.resetPasswordKey), b.userKey, 'recovery still works, with the new key pair')
await assert.rejects(rsaDec(orgPriv, det3.resetPasswordKey), 'the old family private key opens no recovery key')
console.log('10 key change: item, file, recovery key and member all on the new key: ok')

console.log('SENTINEL', SENT.name, SENT.user, SENT.pass, pw(A), pw(B), temp)

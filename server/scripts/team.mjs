#!/usr/bin/env node
// AZET Pass team sharing from a terminal, for people and AI agent accounts. The team key never leaves a client in
// the clear: it is made here, and handed to each member wrapped to that member's RSA public key. The server stores
// only wrapped keys and encrypted items. Reading and writing items afterwards is done with the official `bw` CLI.
//
//   AZET_PASS_EMAIL=… AZET_PASS_PASSWORD=… [AZET_PASS_URL=https://pass.azet.io] node scripts/team.mjs <command>
//
//   create <name> [seats]                      make a team and its first shared vault → {org, vault}
//   invite <org> <email> [--read-only] [--agent] [--days <n>] [--vault <id>] [--name <display name>]   → {member, token}
//                                              --agent: an AI agent account, its reads go to the access log; --days: access ends after n days
//   join <org> <member> <token>                the invited account takes the invite (signs up first if it is new)
//   members <org>                              who is in, their status and key fingerprint
//   confirm <org> <email> <fingerprint>        hand the team key to an accepted member; the fingerprint must match
//   access <org> <email> <days|forever|off|on> how long a member's access lasts from now, or suspend / restore it
//   log <org>                                  the access log, checked: every row's hash, and against this team's last checkpoint
//
// The password is read from the environment only, never from the command line.
import { webcrypto as c } from 'node:crypto'

const base = (process.env.AZET_PASS_URL || 'https://pass.azet.io').replace(/\/$/, '')
const email = (process.env.AZET_PASS_EMAIL || '').trim().toLowerCase(), password = process.env.AZET_PASS_PASSWORD || ''
const enc = new TextEncoder()
const b64 = (u) => Buffer.from(u).toString('base64'), unb64 = (s) => new Uint8Array(Buffer.from(s, 'base64'))
const die = (m) => { console.error(m); process.exit(1) }

const pbkdf2 = async (pw, salt, iter) => new Uint8Array(await c.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt, iterations: iter },
  await c.subtle.importKey('raw', pw, 'PBKDF2', false, ['deriveBits']), 256))
const hmac = async (k, d) => new Uint8Array(await c.subtle.sign('HMAC', await c.subtle.importKey('raw', k, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']), d))
const expand = (prk, info) => hmac(prk, new Uint8Array([...enc.encode(info), 1])) // Bitwarden stretches with HKDF-Expand only
const encS = async (key64, data) => { // EncString type 2: AES-256-CBC + HMAC-SHA256 over iv||ct
  const iv = c.getRandomValues(new Uint8Array(16))
  const ct = new Uint8Array(await c.subtle.encrypt({ name: 'AES-CBC', iv }, await c.subtle.importKey('raw', key64.slice(0, 32), 'AES-CBC', false, ['encrypt']),
    typeof data === 'string' ? enc.encode(data) : data))
  return `2.${b64(iv)}|${b64(ct)}|${b64(await hmac(key64.slice(32), new Uint8Array([...iv, ...ct])))}`
}
const decS = async (key64, s) => {
  const [iv, ct, mac] = s.slice(2).split('|').map(unb64)
  if (b64(await hmac(key64.slice(32), new Uint8Array([...iv, ...ct]))) !== b64(mac)) die('Wrong password, or the data was changed (MAC mismatch).')
  return new Uint8Array(await c.subtle.decrypt({ name: 'AES-CBC', iv }, await c.subtle.importKey('raw', key64.slice(0, 32), 'AES-CBC', false, ['decrypt']), ct))
}
const rsaPair = () => c.subtle.generateKey({ name: 'RSA-OAEP', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-1' }, true, ['encrypt', 'decrypt'])
const rsaEnc = async (spkiB64, data) => `4.${b64(new Uint8Array(await c.subtle.encrypt({ name: 'RSA-OAEP' },
  await c.subtle.importKey('spki', unb64(spkiB64), { name: 'RSA-OAEP', hash: 'SHA-1' }, false, ['encrypt']), data)))}`
const rsaDec = async (pkcs8, s) => new Uint8Array(await c.subtle.decrypt({ name: 'RSA-OAEP' },
  await c.subtle.importKey('pkcs8', pkcs8, { name: 'RSA-OAEP', hash: 'SHA-1' }, false, ['decrypt']), unb64(s.slice(2))))
// What two people read to each other before a confirm: SHA-256 of the member's public key, first 20 hex digits.
const fingerprint = async (spkiB64) => Buffer.from(await c.subtle.digest('SHA-256', unb64(spkiB64))).toString('hex').slice(0, 20).match(/.{5}/g).join('-')

const api = async (tok, method, path, body) => {
  const r = await fetch(base + path, { method, headers: { 'content-type': 'application/json', ...(tok ? { authorization: `Bearer ${tok}` } : {}) }, body: body ? JSON.stringify(body) : undefined })
  const t = await r.text()
  let j = null; try { j = t ? JSON.parse(t) : null } catch { j = t }
  return { status: r.status, body: j }
}
const ok = async (...a) => { const r = await api(...a); if (r.status >= 300) die(`${a[1]} ${a[2]} → ${r.status} ${JSON.stringify(r.body).slice(0, 300)}`); return r.body }

const masterKeys = async () => {
  const pre = await ok(null, 'POST', '/identity/accounts/prelogin', { email })
  if ((pre.kdf ?? pre.Kdf ?? 0) !== 0) die('This account uses Argon2; this tool supports PBKDF2 accounts only.')
  const mk = await pbkdf2(enc.encode(password), enc.encode(email), pre.kdfIterations ?? pre.KdfIterations)
  return { mk, hash: b64(await pbkdf2(mk, enc.encode(password), 1)), iter: pre.kdfIterations ?? pre.KdfIterations }
}
const login = async () => {
  const { mk, hash } = await masterKeys()
  const r = await fetch(`${base}/identity/connect/token`, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'password', username: email, password: hash, scope: 'api offline_access', client_id: 'cli', deviceType: '8', deviceIdentifier: c.randomUUID(), deviceName: 'azet-pass-team' }) })
  const j = await r.json()
  if (!j.access_token) return null
  const userKey = await decS(new Uint8Array([...await expand(mk, 'enc'), ...await expand(mk, 'mac')]), j.Key || j.key)
  return { tok: j.access_token, userKey, priv: await decS(userKey, j.PrivateKey || j.privateKey) }
}
const need = async () => (await login()) ?? die('Sign-in failed: check AZET_PASS_EMAIL and AZET_PASS_PASSWORD.')
const orgKeyOf = async (u, org) => {
  const o = (await ok(u.tok, 'GET', '/api/sync?excludeDomains=true')).profile.organizations.find((x) => x.id === org) ?? die('You are not a confirmed member of that team.')
  return rsaDec(u.priv, o.key)
}

const [cmd, ...rest] = process.argv.slice(2)
const flag = (n) => { const i = rest.indexOf(n); return i < 0 ? null : rest.splice(i, 2)[1] }
const has = (n) => { const i = rest.indexOf(n); if (i < 0) return false; rest.splice(i, 1); return true }
if (!email || !password) die('Set AZET_PASS_EMAIL and AZET_PASS_PASSWORD.')

if (cmd === 'create') {
  const [name, seats] = rest
  if (!name) die('usage: create <name> [seats]')
  const u = await need(), me = await ok(u.tok, 'GET', '/api/accounts/profile')
  const myPub = me.accountKeys?.publicKeyEncryptionKeyPair?.publicKey || (await ok(u.tok, 'GET', `/api/users/${me.id}/public-key`)).publicKey
  const orgKey = c.getRandomValues(new Uint8Array(64)), rsa = await rsaPair()
  const org = await ok(u.tok, 'POST', '/api/organizations', {
    name, billingEmail: email, ...(seats ? { seats: Number(seats) } : {}), key: await rsaEnc(myPub, orgKey),
    keys: { publicKey: b64(new Uint8Array(await c.subtle.exportKey('spki', rsa.publicKey))), encryptedPrivateKey: await encS(orgKey, new Uint8Array(await c.subtle.exportKey('pkcs8', rsa.privateKey))) },
    collectionName: await encS(orgKey, 'Shared') })
  const vault = (await ok(u.tok, 'GET', '/api/sync?excludeDomains=true')).collections.find((x) => x.organizationId === org.id)
  console.log(JSON.stringify({ org: org.id, vault: vault.id, seats: org.seats }))
} else if (cmd === 'invite') {
  const vault = flag('--vault'), displayName = flag('--name'), days = flag('--days'), readOnly = has('--read-only'), agent = has('--agent'), [org, who] = rest
  if (!org || !who) die('usage: invite <org> <email> [--read-only] [--vault <id>] [--name <display name>]')
  const u = await need()
  const v = vault || (await ok(u.tok, 'GET', '/api/sync?excludeDomains=true')).collections.find((x) => x.organizationId === org)?.id
  const inv = (await ok(u.tok, 'POST', `/api/organizations/${org}/users/invite`, { emails: [who.toLowerCase()], type: 2, displayName, agent, ...(days ? { accessDays: Number(days) } : {}), collections: [{ id: v, readOnly }] })).data[0]
  console.log(JSON.stringify({ org, member: inv.id, token: inv.token, email: who.toLowerCase(), vault: v, readOnly }))
} else if (cmd === 'join') {
  const [org, member, token] = rest
  if (!token) die('usage: join <org> <member> <token>')
  let u = await login()
  if (!u) { // a new account signs up straight from the invite (the server takes it for the invited address only)
    const iter = 600000, mk = await pbkdf2(enc.encode(password), enc.encode(email), iter)
    const userKey = c.getRandomValues(new Uint8Array(64)), rsa = await rsaPair()
    const r = await api(null, 'POST', '/identity/accounts/register', {
      email, name: null, masterPasswordHash: b64(await pbkdf2(mk, enc.encode(password), 1)), masterPasswordHint: null, kdf: 0, kdfIterations: iter,
      key: await encS(new Uint8Array([...await expand(mk, 'enc'), ...await expand(mk, 'mac')]), userKey),
      userAsymmetricKeys: { publicKey: b64(new Uint8Array(await c.subtle.exportKey('spki', rsa.publicKey))), encryptedPrivateKey: await encS(userKey, new Uint8Array(await c.subtle.exportKey('pkcs8', rsa.privateKey))) },
      orgInviteToken: token, organizationUserId: member })
    if (r.status >= 300) die(`Sign-in failed and sign-up from the invite was refused (${r.status}): wrong password, or the invite is for another address.`)
    u = await need()
  }
  await ok(u.tok, 'POST', `/api/organizations/${org}/users/${member}/accept`, { token })
  const me = await ok(u.tok, 'GET', '/api/accounts/profile')
  const pub = me.accountKeys?.publicKeyEncryptionKeyPair?.publicKey || (await ok(u.tok, 'GET', `/api/users/${me.id}/public-key`)).publicKey
  console.log(JSON.stringify({ accepted: true, email, fingerprint: await fingerprint(pub) }))
} else if (cmd === 'members') {
  const [org] = rest
  if (!org) die('usage: members <org>')
  const u = await need()
  const rows = await Promise.all((await ok(u.tok, 'GET', `/api/organizations/${org}/users`)).data.map(async (m) => ({
    email: m.email, name: m.name ?? null, agent: !!m.agent, accessUntil: m.accessUntil ?? null, status: ['invited', 'accepted', 'confirmed'][m.status] ?? 'suspended', role: ['owner', 'admin', 'member', , , 'guest'][m.azetRole ?? m.type],
    fingerprint: m.publicKey ? await fingerprint(m.publicKey) : null })))
  console.log(JSON.stringify(rows, null, 1))
} else if (cmd === 'confirm') {
  const [org, who, fp] = rest
  if (!fp) die('usage: confirm <org> <email> <fingerprint>   (the fingerprint the member read out after join)')
  const u = await need()
  const m = (await ok(u.tok, 'GET', `/api/organizations/${org}/users`)).data.find((x) => x.email === who.toLowerCase()) ?? die('No such member.')
  if (m.status !== 1) die(`That member is ${['invited: they have not joined yet', , 'confirmed already'][m.status] ?? 'suspended'}.`)
  // The server hands us this public key, so a server that swapped it would get the team key. The fingerprint the
  // member read from their own device is what rules that out.
  if ((await fingerprint(m.publicKey)) !== fp) die(`Fingerprint mismatch: the server shows ${await fingerprint(m.publicKey)}. Nothing was shared.`)
  await ok(u.tok, 'POST', `/api/organizations/${org}/users/${m.id}/confirm`, { key: await rsaEnc(m.publicKey, await orgKeyOf(u, org)) })
  console.log(JSON.stringify({ confirmed: who.toLowerCase() }))
} else if (cmd === 'access') {
  const [org, who, what] = rest
  if (!what) die('usage: access <org> <email> <days|forever|off|on>')
  const u = await need()
  const m = (await ok(u.tok, 'GET', `/api/organizations/${org}/users`)).data.find((x) => x.email === who.toLowerCase()) ?? die('No such member.')
  if (what === 'off' || what === 'on') await ok(u.tok, 'PUT', `/api/organizations/${org}/users/${m.id}/${what === 'off' ? 'revoke' : 'restore'}`)
  else console.log(JSON.stringify(await ok(u.tok, 'PUT', `/api/organizations/${org}/users/${m.id}/azet/access`, what === 'forever' ? {} : { accessDays: Number(what) })))
  if (what === 'off' || what === 'on') console.log(JSON.stringify({ access: what }))
} else if (cmd === 'log') {
  const [org] = rest
  if (!org) die('usage: log <org>')
  const u = await need(), orgKey = await orgKeyOf(u, org)
  const { events, checkpoint } = await ok(u.tok, 'GET', `/api/organizations/${org}/azet/access-log`)
  const names = Object.fromEntries((await ok(u.tok, 'GET', `/api/organizations/${org}/users`)).data.map((m) => [m.id, m.name || m.email]))
  // 1 every row's hash is recomputed here, and each row must point at the one before it
  let prev = events[0]?.prev ?? ''
  for (const e of events) {
    const line = [prev, org, e.memberId, e.kind, e.cipherId ?? '', String(e.count), e.detail ?? '', e.createdAt].join('|')
    const h = Buffer.from(await c.subtle.digest('SHA-256', enc.encode(line))).toString('hex')
    if (e.prev !== prev || e.hash !== h) die(`ACCESS LOG CHANGED: row ${e.seq} does not match its hash. Someone edited or removed a row.`)
    prev = h
  }
  // 2 the last row this team's organizer checked must still be there, unchanged (the server cannot read or forge it)
  if (checkpoint) {
    const cp = JSON.parse(new TextDecoder().decode(await decS(orgKey, checkpoint)))
    const at = events.find((e) => e.seq === cp.seq)
    if (events.length && events[0].seq > cp.seq) { /* checkpoint is older than the 1,000 rows shown: nothing to compare */ }
    else if (!at || at.hash !== cp.hash) die(`ACCESS LOG CHANGED: the row checked last time (${cp.seq}) is missing or different.`)
  }
  const last = events.at(-1)
  if (last) await ok(u.tok, 'PUT', `/api/organizations/${org}/azet/access-log/checkpoint`, { value: await encS(orgKey, JSON.stringify({ seq: last.seq, hash: last.hash })) })
  const week = events.filter((e) => Date.now() - Date.parse(e.createdAt) < 7 * 864e5)
  const sum = (k) => week.filter((e) => e.kind === k).reduce((n, e) => n + e.count, 0)
  console.log(JSON.stringify({ verified: true, rows: events.length, last7days: { read: sum('read'), write: sum('write'), delete: sum('delete') },
    events: events.slice(-50).map((e) => ({ seq: e.seq, at: e.createdAt, who: names[e.memberId] ?? e.memberId, kind: e.kind, count: e.count, item: e.cipherId, detail: e.detail })) }, null, 1))
} else die('commands: create | invite | join | members | confirm | access | log   (see the top of this file)')

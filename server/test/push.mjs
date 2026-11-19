// For push.sh.
//   node test/push.mjs listen <port> <google public key pem> <apple public key pem> <log file>
//     stands in for Google's token and FCM endpoints and for Apple's APNs: checks each token's signature with the
//     public key, writes one JSON line per request to the log, answers "that phone is gone" for the tokens
//     gone-android (404 UNREGISTERED) and gone-ios (410).
//   node test/push.mjs phone <base url> <email> <password> <device type> <identifier> [push token]
//     signs in as that device (0 Android, 1 iPhone, 8 a computer), registers the push token, prints the access token.
//   node test/push.mjs save <base url> <access token>      saves a personal login, prints its id
import { webcrypto as c, verify, createPublicKey } from 'node:crypto'
import { createServer } from 'node:http'
import { readFileSync, appendFileSync } from 'node:fs'

const [mode, ...args] = process.argv.slice(2)
if (mode === 'listen') {
  const [port, googlePem, applePem, log] = args
  const google = createPublicKey(readFileSync(googlePem)), apple = createPublicKey(readFileSync(applePem))
  const jwt = (t) => { const [h, p, s] = t.split('.'); return { head: JSON.parse(Buffer.from(h, 'base64url')), claims: JSON.parse(Buffer.from(p, 'base64url')), signed: Buffer.from(`${h}.${p}`), sig: Buffer.from(s, 'base64url') } }
  createServer((req, res) => {
    let body = ''
    req.on('data', (d) => (body += d)).on('end', () => {
      const line = { path: req.url }, answer = (status, json) => { appendFileSync(log, JSON.stringify(line) + '\n'); res.writeHead(status, { 'content-type': 'application/json' }).end(JSON.stringify(json)) }
      if (req.url === '/token') {
        const t = jwt(new URLSearchParams(body).get('assertion'))
        line.signed = t.head.alg === 'RS256' && verify('RSA-SHA256', t.signed, google, t.sig); line.claims = t.claims
        return answer(line.signed ? 200 : 401, { access_token: 'google-access', expires_in: 3600 })
      }
      if (req.url.startsWith('/3/device/')) {
        const t = jwt(req.headers.authorization.replace(/^bearer /, ''))
        line.signed = t.head.alg === 'ES256' && verify('SHA256', t.signed, { key: apple, dsaEncoding: 'ieee-p1363' }, t.sig)
        line.kid = t.head.kid; line.iss = t.claims.iss; line.iat = t.claims.iat
        line.topic = req.headers['apns-topic']; line.pushType = req.headers['apns-push-type']; line.body = JSON.parse(body)
        return req.url.endsWith('/gone-ios') ? answer(410, { reason: 'Unregistered' }) : answer(200, {})
      }
      line.bearer = req.headers.authorization; line.body = JSON.parse(body)
      return line.body.message.token === 'gone-android' ? answer(404, { error: { status: 'NOT_FOUND', details: [{ errorCode: 'UNREGISTERED' }] } }) : answer(200, { name: 'sent' })
    })
  }).listen(Number(port), '127.0.0.1')
} else if (mode === 'phone') {
  const [base, email, password, deviceType, identifier, pushToken] = args
  const enc = new TextEncoder(), b64 = (u) => Buffer.from(u).toString('base64')
  const pbkdf2 = async (pw, salt, iter) => new Uint8Array(await c.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt, iterations: iter }, await c.subtle.importKey('raw', pw, 'PBKDF2', false, ['deriveBits']), 256))
  const pre = await (await fetch(`${base}/identity/accounts/prelogin`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email }) })).json()
  const hash = b64(await pbkdf2(await pbkdf2(enc.encode(password), enc.encode(email), pre.kdfIterations), enc.encode(password), 1))
  const j = await (await fetch(`${base}/identity/connect/token`, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'password', username: email, password: hash, scope: 'api offline_access', client_id: 'mobile', deviceType, deviceIdentifier: identifier, deviceName: 'push-test' }) })).json()
  if (pushToken) {
    const r = await fetch(`${base}/api/devices/identifier/${identifier}/token`, { method: 'PUT', headers: { 'content-type': 'application/json', authorization: `Bearer ${j.access_token}` }, body: JSON.stringify({ pushToken }) })
    if (!r.ok) { console.error('token not registered', r.status); process.exit(1) }
  }
  console.log(j.access_token)
} else if (mode === 'save') {
  const [base, token] = args, sealed = `2.${Buffer.from('0123456789abcdef').toString('base64')}|${Buffer.from('push-test-item!!').toString('base64')}|${Buffer.alloc(32, 7).toString('base64')}`
  const made = await (await fetch(`${base}/api/ciphers`, { method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` }, body: JSON.stringify({ type: 1, name: sealed, login: { username: sealed, password: sealed } }) })).json()
  console.log(made.id); process.exit(made.id ? 0 : 1)
}

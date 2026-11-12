// Local web vault for UI tests: API paths go to the local Worker, everything else is the web vault's static files
// fetched from a deployed vault (the same build that production serves). Logs every API call with its status.
// usage: node test/webvault-proxy.mjs <port> <worker-url> <static-origin> <log-file> <key.pem> <cert.pem>   (the web vault refuses plain http)
import https from 'node:https'
import fs from 'node:fs'
const [port, worker, origin, log, key, cert] = process.argv.slice(2)
const API = /^\/(api|identity|notifications|icons|events)\b/
const cache = new Map()
https.createServer({ key: fs.readFileSync(key), cert: fs.readFileSync(cert) }, async (req, res) => {
  const chunks = []; for await (const c of req) chunks.push(c)
  const body = Buffer.concat(chunks)
  try {
    if (API.test(req.url)) {
      const h = { ...req.headers }; delete h.host; delete h['content-length']
      const r = await fetch(worker + req.url, { method: req.method, headers: h, body: body.length ? body : undefined })
      const buf = Buffer.from(await r.arrayBuffer())
      fs.appendFileSync(log, `${r.status} ${req.method} ${req.url.split('?')[0]}\n`)
      const out = Object.fromEntries(r.headers); delete out['content-encoding']; delete out['content-length']; delete out['transfer-encoding']
      res.writeHead(r.status, out); res.end(buf)
    } else if (/^\/team\/?(\?|$)/.test(req.url)) { // the team page is served by the gateway Worker from gw/team.html
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }); res.end(fs.readFileSync(new URL('../gw/team.html', import.meta.url)))
    } else {
      const key = req.url.split('?')[0]
      if (!cache.has(key)) { const r = await fetch(origin + key); cache.set(key, [r.status, r.headers.get('content-type') || 'text/html', Buffer.from(await r.arrayBuffer())]) }
      const [s, t, b] = cache.get(key)
      res.writeHead(s, { 'content-type': t }); res.end(b)
    }
  } catch (e) { res.writeHead(502); res.end(String(e)) }
}).listen(Number(port), '127.0.0.1')

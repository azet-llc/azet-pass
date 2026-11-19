// For team-page.sh: serves gw/team.html next to the local Worker (the page calls the API on its own origin) and
// drives it in a headless browser as the organizer.
//   node test/team-page.mjs <worker url> <playwright folder> <organizer email> <password> remove <member email>
//   node test/team-page.mjs <worker url> <playwright folder> <organizer email> <password> open
// `remove` takes the member out with two taps and waits for the page to say the vault key was changed; `open` only
// signs in (a key change that is due happens then). Prints the toast or the hub title; exits 1 when neither shows.
import { createServer, request } from 'node:http'
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'

const [worker, playwrightDir, email, password, what, member] = process.argv.slice(2)
const { chromium } = createRequire(import.meta.url)(playwrightDir)
const page = readFileSync(new URL('../gw/team.html', import.meta.url))
const server = createServer((req, res) => {
  if (req.url.split(/[?#]/)[0] === '/team') return res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }).end(page)
  const up = request(worker + req.url, { method: req.method, headers: { ...req.headers, host: new URL(worker).host } }, (r) => { res.writeHead(r.statusCode, r.headers); r.pipe(res) })
  up.on('error', () => res.writeHead(502).end())
  req.pipe(up)
}).listen(0, '127.0.0.1')
await new Promise((ready) => server.once('listening', ready))

// CHROME: a headless browser binary to use instead of the one this Playwright version would download
const browser = await chromium.launch({ headless: true, ...(process.env.CHROME ? { executablePath: process.env.CHROME } : {}) })
let code = 1
try {
  const tab = await (await browser.newContext({ locale: 'en-US' })).newPage()
  const errors = []
  tab.on('pageerror', (e) => errors.push(String(e)))
  await tab.goto(`http://127.0.0.1:${server.address().port}/team`)
  await tab.fill('input[name=email]', email)
  await tab.fill('input[name=password]', password)
  await tab.locator('form[data-form=signin]').evaluate((form) => form.requestSubmit())
  await tab.waitForSelector('[data-go=people]', { timeout: 60000 }) // the hub: signed in, and any key change that was due is done
  if (what === 'remove') {
    for (const list of ['people', 'agents']) {
      await tab.click(`[data-go=${list}]`)
      const row = tab.locator('[data-act=member]', { hasText: member })
      if (await row.count()) {
        await row.click()
        await tab.click('[data-act=kick]') // first tap asks again
        await tab.click('[data-act=kick]')
        console.log((await tab.waitForSelector('.toast', { timeout: 60000 }).then((t) => t.textContent())).trim())
        code = 0
        break
      }
      await tab.click('[data-go]') // back to the hub
      await tab.waitForSelector('[data-go=people]')
    }
  } else {
    console.log(await tab.locator('h1').first().textContent())
    code = 0
  }
  if (errors.length) { console.error('page errors:', errors.join(' | ')); code = 1 }
} catch (e) {
  console.error(String(e).split('\n')[0])
} finally {
  await browser.close()
  server.close()
}
process.exit(code)

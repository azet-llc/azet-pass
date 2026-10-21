// Turns a pinned bitwarden/android checkout (GPL-3.0) into AZET Pass for Android. Everything else stays as upstream.
//  - default server: the US region is https://pass.azet.io
//  - app id io.azet.pass, name "AZET Pass" in every string table (Korean particles fixed), Bridge label
//  - launcher foreground, logo wordmark, logo icons and shield glyph: our key mark in the same vector slots
//  - 변형 축 needs no client change here: every TOTP gate is `isPremium || organizationUseTotp`, and the server
//    sends organizationUseTotp=true
// usage: node rebrand-android.mjs <android-checkout>
import fs from 'node:fs'
import path from 'node:path'

const root = path.resolve(process.argv[2])
const here = path.dirname(new URL(import.meta.url).pathname)
const p = (...a) => path.join(root, ...a)
const edit = (file, fn) => {
  const before = fs.readFileSync(p(file), 'utf8')
  const after = fn(before)
  if (after === before) throw new Error(`rebrand-android: no change in ${file}`)
  fs.writeFileSync(p(file), after)
}
const MARK = 'M13 1a8 8 0 1 1 0 16a8 8 0 0 1 0-16Zm0 5a3 3 0 1 0 0 6a3 3 0 0 0 0-6ZM11 16h4v15h-4ZM15 21h5v3.5h-5ZM15 26.5h4v3.5h-4Z'
const wm = JSON.parse(fs.readFileSync(path.join(here, 'brand/generated/wordmark.json'), 'utf8'))

edit('data/src/main/kotlin/com/bitwarden/data/datasource/disk/model/EnvironmentUrlDataJson.kt', (s) =>
  s.replace('val DEFAULT_US: EnvironmentUrlDataJson =\n            EnvironmentUrlDataJson(base = "https://vault.bitwarden.com")',
    'val DEFAULT_US: EnvironmentUrlDataJson =\n            EnvironmentUrlDataJson(base = "https://pass.azet.io")'))
// the US region's service URLs are hard-coded constants (they ignore DEFAULT_US.base); all point at our Worker
edit('data/src/main/kotlin/com/bitwarden/data/repository/util/EnvironmentExtensions.kt', (s) => s
  .replace('DEFAULT_US_API_URL: String = "https://api.bitwarden.com"', 'DEFAULT_US_API_URL: String = "https://pass.azet.io/api"')
  .replace('DEFAULT_US_EVENTS_URL: String = "https://events.bitwarden.com"', 'DEFAULT_US_EVENTS_URL: String = "https://pass.azet.io/events"')
  .replace('DEFAULT_US_IDENTITY_URL: String = "https://identity.bitwarden.com"', 'DEFAULT_US_IDENTITY_URL: String = "https://pass.azet.io/identity"')
  .replace('DEFAULT_US_WEB_VAULT_URL: String = "https://vault.bitwarden.com"', 'DEFAULT_US_WEB_VAULT_URL: String = "https://pass.azet.io"')
  .replace('DEFAULT_US_WEB_SEND_URL: String = "https://send.bitwarden.com/#"', 'DEFAULT_US_WEB_SEND_URL: String = "https://pass.azet.io/#/send/"')
  .replace('DEFAULT_US_ICON_URL: String = "https://icons.bitwarden.net"', 'DEFAULT_US_ICON_URL: String = "https://pass.azet.io/icons"'))
// one ABI and compressed native code: our SDK build is arm64-v8a only (Note20 and nearly every phone since 2017), and a
// compressed, stripped .so keeps the APK under the 25 MiB file limit of azet.io's static hosting (Bitwarden: 4 ABIs, ~90-130 MB)
edit('app/build.gradle.kts', (s) => s.replace(`    packaging {
        resources {`, `    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
        dex {
            useLegacyPackaging = true
        }
        resources {`).replace(/(\n        versionName = libs\.versions\.appVersionName\.get\(\)\n)/, '$1        ndk { abiFilters += listOf("arm64-v8a") }\n'))
// our own version line: upstream 2026.9.1 + AZET build 4 (ready-zero) (versionCode grows with each AZET release)
edit('gradle/libs.versions.toml', (s) => s.replace(/appVersionCode = "\d+"/, 'appVersionCode = "20260905"').replace(/appVersionName = "[^"]+"/, 'appVersionName = "2026.9.1-azet5"'))
// GPL-3.0 source offer on the About screen's copyright line
edit('app/src/main/kotlin/com/x8bit/bitwarden/ui/platform/feature/settings/about/AboutViewModel.kt', (s) =>
  s.replace('copyrightInfo = "© Bitwarden Inc. 2015-${Year.now(clock).value}".asText(),', 'copyrightInfo = "© Bitwarden Inc. 2015-${Year.now(clock).value}, AZET LLC. GPL-3.0, source: github.com/neulketing/azet-pass".asText(),'))
// our privacy policy and terms (help pages stay on bitwarden.com: they describe this same software)
for (const f of ['app/src/main/kotlin/com/x8bit/bitwarden/ui/auth/feature/startregistration/StartRegistrationScreen.kt', 'app/src/main/kotlin/com/x8bit/bitwarden/ui/platform/feature/settings/about/AboutScreen.kt'])
  edit(f, (s) => s.replaceAll('"https://bitwarden.com/privacy/"', '"https://azet.io/privacy"').replaceAll('"https://bitwarden.com/privacy"', '"https://azet.io/privacy"').replaceAll('"https://bitwarden.com/terms/"', '"https://azet.io/terms"'))
edit('data/src/main/kotlin/com/bitwarden/data/repository/model/Environment.kt', (s) =>
  s.replace('override val label: String get() = "bitwarden.com"', 'override val label: String get() = "pass.azet.io"'))
edit('app/build.gradle.kts', (s) => s.replace('applicationId = "com.x8bit.bitwarden"', 'applicationId = "io.azet.pass"'))
edit('app/src/main/AndroidManifest.xml', (s) => s.replace('android:label="Bitwarden Bridge"', 'android:label="AZET Pass Bridge"'))

// every string table of the password manager (the separate Authenticator app module is not shipped)
let renamed = 0
const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) =>
  e.name === 'build' || e.name.startsWith('.') ? [] : e.isDirectory() ? walk(path.join(d, e.name)) : [path.join(d, e.name)])
for (const mod of ['app', 'ui', 'core', 'data', 'network', 'cxf', 'authenticatorbridge']) {
  if (!fs.existsSync(p(mod))) continue
  for (const f of walk(p(mod)).filter((f) => /\/res\/values[^/]*\/strings[^/]*\.xml$/.test(f))) {
    const ko = /values-ko/.test(f)
    const s = fs.readFileSync(f, 'utf8')
    const out = s.replace(/>([^<]*[Bb][Ii]t[Ww]arden[^<]*)</g, (m, t) => {
      renamed++
      let v = t.replace(/[Bb][Ii]t[Ww]arden(?!\.[a-z])/g, 'AZET Pass') // any casing (lane 151: "bitwarden auto-fill service", "BitWarden"); domains are handled below
      if (ko) v = v.replace(/AZET Pass(은|을|과|으로|이 )/g, (_, x) => 'AZET Pass' + { '은': '는', '을': '를', '과': '와', '으로': '로', '이 ': '가 ' }[x])
      return `>${v}<`
    }).replace(/>([^<]*bitwarden\.com[^<]*)</g, (m, t) => `>${t // domains in sentences (lane 98): our pages
      .replaceAll('bitwarden.com/download', 'azet.io/products/pass').replaceAll('bitwarden.com/help', 'pass.azet.io/help')
      .replace(/privacy policy on bitwarden\.com/g, 'privacy policy on azet.io').replaceAll('bitwarden.com', 'pass.azet.io')}<`)
    if (out !== s) fs.writeFileSync(f, out)
  }
}

// Ready-zero (lane 98, inventory-pass.md #32-#37): no Bitwarden region, page or feature our server lacks
const A = 'app/src/main/kotlin/com/x8bit/bitwarden/'
// #32 region picker: pass.azet.io and self-hosted only (EU sent the email and password hash to Bitwarden EU)
edit(A + 'ui/auth/feature/landing/LandingViewModel.kt', (s) => s.replace('.filterNot { it == Environment.Type.FED_RAMP && !isFedRampEnabled }', '.filterNot { it == Environment.Type.EU || (it == Environment.Type.FED_RAMP && !isFedRampEnabled) }'))
edit(A + 'ui/auth/feature/startregistration/StartRegistrationViewModel.kt', (s) => s.replace('.filterNot { it == Environment.Type.FED_RAMP }', '.filterNot { it == Environment.Type.FED_RAMP || it == Environment.Type.EU }'))
// #33 enterprise SSO (the server has none)
edit(A + 'ui/auth/feature/login/LoginScreen.kt', (s) => s.replace(/\n        BitwardenOutlinedButton\(\n            label = stringResource\(id = BitwardenString\.log_in_sso\),[\s\S]*?\n        \)\n/, '\n'))
// #34 marketing-mail switch (we send no newsletter; its link was bitwarden.com/email-preferences)
edit(A + 'ui/auth/feature/startregistration/StartRegistrationScreen.kt', (s) => s.replace(/\n        if \(state\.selectedEnvironmentType != Environment\.Type\.SELF_HOSTED\) \{\n            Spacer\(modifier = Modifier\.height\(8\.dp\)\)\n            ReceiveMarketingEmailsSwitch\([\s\S]*?\n        \}\n/, '\n'))
// #35 the sign-up mail link (https://pass.azet.io/redirect-connector.html#finish-signup…) opens the app; assetlinks.json is
// served by the gateway (server/gw/worker.ts)
edit('app/src/main/AndroidManifest.xml', (s) => s.replace('<data android:host="*.bitwarden.com" />', '<data android:host="pass.azet.io" />\n                <data android:host="*.bitwarden.com" />'))
// #37 "allow authenticator syncing" needs Bitwarden's own Authenticator app (signed by Bitwarden)
edit(A + 'ui/platform/feature/settings/accountsecurity/AccountSecurityViewModel.kt', (s) => s.replace('shouldShowEnableAuthenticatorSync = isBuildVersionAtLeast(Build.VERSION_CODES.S),', 'shouldShowEnableAuthenticatorSync = false, // AZET: no Authenticator app to sync with'))
// About: "learn about organizations" (no organizations)
edit(A + 'ui/platform/feature/settings/about/AboutScreen.kt', (s) => s.replace(/\n        BitwardenExternalLinkRow\(\n            text = stringResource\(id = BitwardenString\.learn_org\),[\s\S]*?\n        \)\n/, '\n'))
// Play (fdroid) build: no "Upgraded to Premium" card — its Learn more opens a pricing page (Play payments policy, lane458 10-16)
edit(A + 'data/billing/manager/PremiumStateManagerImpl.kt', (s) => s
  .replace('\nimport com.x8bit.bitwarden.data.auth.datasource.disk.AuthDiskSource\n', '\nimport com.x8bit.bitwarden.BuildConfig\nimport com.x8bit.bitwarden.data.auth.datasource.disk.AuthDiskSource\n')
  .replace('                        isPending && !isConsumed && isPremiumFromSelf\n', `                        // AZET: the Play build (fdroid) never shows this card. Its Learn more
                        // opens azet.io/products/pass, a pricing page (Play payments policy).
                        isPending && !isConsumed && isPremiumFromSelf &&
                            BuildConfig.FLAVOR != "fdroid"\n`))
// #36 help and product links in Kotlin -> pass.azet.io/help (anchors) or azet.io
const HELP = 'https://pass.azet.io/help/'
const helpTopic = (slug) => {
  const t = [[/^import/, 'import'], [/auto-?fill|uri-match|fill-assist/, 'autofill'], [/two-step/, 'two-step'], [/send/, 'send'],
    [/kdf|encryption-key|fingerprint/, 'encryption'], [/passkey/, 'passkeys'], [/website-icons/, 'icons'], [/managing-items|generator|authenticator/, 'items'],
    [/server-geographies/, 'server'], [/organization|transfer-ownership|families/, 'not-included'], [/flight-recorder/, 'contact']].find(([re]) => re.test(slug))
  return HELP + (t ? '#' + t[1] : '')
}
const mapBw = (url) => {
  const pth = new URL(url.replace(/\.$/, '')).pathname
  if (pth.startsWith('/email-preferences')) return url
  if (pth.startsWith('/help/password-manager-plans')) return 'https://azet.io/products/pass#plans'
  if (pth.startsWith('/help')) return helpTopic(pth.slice(6))
  return 'https://azet.io/products/pass'
}
let relinked = 0
for (const mod of ['app', 'ui', 'core', 'data', 'network', 'cxf', 'authenticatorbridge']) {
  if (!fs.existsSync(p(mod, 'src/main'))) continue
  for (const f of walk(p(mod, 'src/main')).filter((f) => f.endsWith('.kt'))) {
    const s = fs.readFileSync(f, 'utf8')
    const out = s.replace(/https?:\/\/(?:www\.)?bitwarden\.com(?![\w.-])(?:\/[^"'\s)]*)?/g, mapBw)
    if (out !== s) { fs.writeFileSync(f, out); relinked++ }
  }
}
console.log(`rebrand-android: ready-zero links rewritten in ${relinked} files`)

// #38 Premium cannot be bought yet (supervisor 10-08: no upgrade or purchase buttons before checkout): every
// "Premium required" two-button dialog whose confirm is "Upgrade to Premium" becomes a one-button notice (title, message, OK)
const callEnd = (s, open) => { let d = 0; for (let i = open; i < s.length; i++) { if (s[i] === '(') d++; else if (s[i] === ')' && --d === 0) return i } return -1 }
const topArgs = (body) => { const out = []; let d = 0, cur = ''; for (const ch of body) { if ('({['.includes(ch)) d++; if (')}]'.includes(ch)) d--; if (ch === ',' && d === 0) { out.push(cur); cur = '' } else cur += ch } if (cur.trim()) out.push(cur); return out }
let unupgraded = 0
for (const f of walk(p('app/src/main/kotlin')).filter((f) => f.endsWith('.kt'))) {
  let s = fs.readFileSync(f, 'utf8')
  if (!s.includes('BitwardenString.upgrade_to_premium')) continue
  let from = 0, changed = false
  for (;;) {
    const at = s.indexOf('BitwardenTwoButtonDialog(', from)
    if (at < 0) break
    const open = at + 'BitwardenTwoButtonDialog'.length, end = callEnd(s, open)
    const body = s.slice(open + 1, end)
    if (!body.includes('BitwardenString.upgrade_to_premium')) { from = end; continue }
    const args = Object.fromEntries(topArgs(body).map((a) => a.trim()).filter(Boolean).map((a) => [a.split('=')[0].trim(), a.slice(a.indexOf('=') + 1).trim()]))
    const ind = s.slice(s.lastIndexOf('\n', at) + 1, at).match(/^\s*/)[0]
    const call = `BitwardenBasicDialog(\n${ind}    title = ${args.title},\n${ind}    message = ${args.message},\n${ind}    onDismissRequest = ${args.onDismissRequest},\n${ind})`
    s = s.slice(0, at) + call + s.slice(end + 1); from = at + call.length; changed = true; unupgraded++
  }
  if (changed) {
    if (!s.includes('import com.bitwarden.ui.platform.components.dialog.BitwardenBasicDialog')) s = s.replace(/\nimport /, '\nimport com.bitwarden.ui.platform.components.dialog.BitwardenBasicDialog\nimport ')
    fs.writeFileSync(f, s)
  }
}
console.log(`rebrand-android: ${unupgraded} upgrade dialogs made notices`)

// vectors: same files, same viewports
const vector = (w, h, body) => `<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="${w}dp"
    android:height="${h}dp"
    android:viewportWidth="${w}"
    android:viewportHeight="${h}">
${body}
</vector>
`
const mark = (color, scale, dx, dy) => `    <group android:translateX="${dx}" android:translateY="${dy}" android:scaleX="${scale}" android:scaleY="${scale}">
        <path android:fillColor="${color}" android:fillType="evenOdd" android:pathData="${MARK}"/>
    </group>`
// adaptive-icon foreground: 108 viewport, safe zone 66; mark 26x32 scaled to fill ~48 high
for (const f of ['app/src/main/res/drawable/ic_launcher_foreground.xml', 'app/src/release/res/drawable/ic_launcher_foreground.xml', 'app/src/beta/res/drawable/ic_launcher_foreground.xml'])
  if (fs.existsSync(p(f))) fs.writeFileSync(p(f), vector(108, 108, mark('#FFFFFF', 1.5, 34.5, 30)))
for (const f of ['app/src/main/res/drawable/ic_launcher_monochrome.xml', 'app/src/release/res/drawable/ic_launcher_monochrome.xml'])
  if (fs.existsSync(p(f))) fs.writeFileSync(p(f), vector(108, 108, mark('#000000', 1.5, 34.5, 30)))
const ui = 'ui/src/main/res/drawable'
fs.writeFileSync(p(ui, 'logo_bitwarden.xml'), vector(218, 34, mark('#175DDC', 34 / 32, 0, 0) +
  `\n    <group android:translateX="${(218 - wm.width).toFixed(1)}"><path android:fillColor="#175DDC" android:pathData="${wm.path}"/></group>`))
fs.writeFileSync(p(ui, 'logo_bitwarden_icon.xml'), vector(1024, 1024, `    <path android:fillColor="#175DDC" android:pathData="M184,0h656a184,184 0 0 1 184,184v656a184,184 0 0 1 -184,184h-656a184,184 0 0 1 -184,-184v-656a184,184 0 0 1 184,-184z"/>\n` + mark('#FFFFFF', 24, 200, 128)))
fs.writeFileSync(p(ui, 'logo_shield_icon.xml'), vector(108, 108, mark('#FFFFFF', 1.5, 34.5, 30)))
fs.writeFileSync(p(ui, 'ic_shield.xml'), vector(20, 20, mark('#000000', 0.56, 2.7, 1)))

// AZET_LITE=1: AZET Pass Lite for Google Play (owner 10-21: Lite and Pro are separate apps, Lite is free and sells nothing).
// App id io.azet.pass.lite, name "AZET Pass Lite", and every string about Premium, plans, upgrades, prices or subscriptions
// is emptied in every language: pass.azet.io gives every account all features, so those screens never open, and Lite
// carries none of that wording (App Store 3.1.1 / Play payments rule, removed at the source rather than hidden).
let liteId = 'io.azet.pass'
if (process.env.AZET_LITE === '1') {
  liteId = 'io.azet.pass.lite'
  edit('app/build.gradle.kts', (s) => s.replace('applicationId = "io.azet.pass"', 'applicationId = "io.azet.pass.lite"'))
  edit('app/src/release/res/values/strings_non_localized.xml', (s) => s.replace('<string name="app_name" translatable="false">AZET Pass</string>', '<string name="app_name" translatable="false">AZET Pass Lite</string>'))
  const sells = /premium|upgrade|prices?\b|pricing|subscri|checkout|stripe|구매|결제|요금제|구독/i
  let emptied = 0
  for (const mod of ['app', 'ui', 'core', 'data', 'network', 'cxf', 'authenticatorbridge']) {
    if (!fs.existsSync(p(mod))) continue
    for (const f of walk(p(mod)).filter((f) => /\/res\/values[^/]*\/strings[^/]*\.xml$/.test(f))) {
      const s = fs.readFileSync(f, 'utf8')
      const out = s.replace(/(<string name="[^"]+"[^>]*>)([\s\S]*?)(<\/string>)/g, (m, o, t, c) => sells.test(t) ? (emptied++, o + c) : m)
        .replace(/(<plurals name="[^"]+"[^>]*>)([\s\S]*?)(<\/plurals>)/g, (m, o, t, c) => sells.test(t) ? (emptied++, o + t.replace(/(<item [^>]*>)[\s\S]*?(<\/item>)/g, '$1$2') + c) : m)
      if (out !== s) fs.writeFileSync(f, out)
    }
  }
  console.log(`rebrand-android: Lite — ${emptied} Premium/plan strings emptied`)
  // Lite has no Accessibility Service autofill: Play's Accessibility API declaration does not fit a password manager that
  // already fills through the Autofill framework and the credential provider. Service and its settings switch go.
  edit('app/src/main/AndroidManifest.xml', (s) => s.replace(/\s*<!--\s*The AccessibilityService name[\s\S]*?<\/service>/, ''))
  edit('app/src/main/kotlin/com/x8bit/bitwarden/ui/platform/feature/settings/autofill/AutoFillScreen.kt',
    (s) => s.replace(/\n\s*AccessibilityAutofillSwitch\(\n[\s\S]*?\n {8}\)\n/, '\n'))
}
console.log(`rebrand-android: ${renamed} strings renamed, server https://pass.azet.io, app id ${liteId}`)

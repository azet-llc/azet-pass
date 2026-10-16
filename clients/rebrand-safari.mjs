// AZET Pass for Safari (Mac App Store): turns Bitwarden's Safari container project (apps/browser/src/safari) into
// "AZET Pass for Safari" — bundle ids io.azet.pass.safari(.extension), AZET team, names, version, icon.
// Run after rebrand.mjs and `npm run build:safari` (the project references apps/browser/build).
// usage: node rebrand-safari.mjs <clients dir> <marketing version e.g. 2026.9.3> <build number>
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'

const [root, ver, build] = process.argv.slice(2)
if (!root || !/^\d+\.\d+\.\d+$/.test(ver || '') || !/^\d+$/.test(build || '')) throw new Error('usage: rebrand-safari.mjs <clients dir> <x.y.z> <build>')
const S = path.join(root, 'apps/browser/src/safari')
const here = path.dirname(new URL(import.meta.url).pathname)
const edit = (f, fn) => { const p = path.join(S, f); const a = fs.readFileSync(p, 'utf8'); const b = fn(a); if (a === b) throw new Error(`rebrand-safari: nothing changed in ${f}`); fs.writeFileSync(p, b) }
const all = (s, a, b) => { if (!s.includes(a)) throw new Error(`rebrand-safari: ${a} not found`); return s.split(a).join(b) }

edit('desktop.xcodeproj/project.pbxproj', (s) => {
  s = all(s, 'PRODUCT_BUNDLE_IDENTIFIER = com.bitwarden.desktop.safari;', 'PRODUCT_BUNDLE_IDENTIFIER = io.azet.pass.safari.extension;')
  s = all(s, 'PRODUCT_BUNDLE_IDENTIFIER = com.bitwarden.desktop;\n\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";',
    'PRODUCT_BUNDLE_IDENTIFIER = io.azet.pass.safari;\n\t\t\t\tPRODUCT_NAME = "AZET Pass for Safari";')
  s = all(s, 'DEVELOPMENT_TEAM = LTZ2PFU5D6;', 'DEVELOPMENT_TEAM = 95P4H2RG24;')
  return s.replace(/MACOSX_DEPLOYMENT_TARGET = 10\.1[45];/g, 'MACOSX_DEPLOYMENT_TARGET = 12.0;')
})

edit('desktop/ViewController.swift', (s) => all(all(s, 'let appName = "desktop"', 'let appName = "AZET Pass"'),
  'let extensionBundleIdentifier = "com.bitwarden.desktop.Extension"', 'let extensionBundleIdentifier = "io.azet.pass.safari.extension"')
  .replace(/You can turn it on in Safari Extensions preferences\./g, 'Turn it on in Safari Settings, Extensions.'))

edit('desktop/Base.lproj/Main.storyboard', (s) => s
  .replace(/(title="[^"]*?)\bdesktop\b/g, '$1AZET Pass')
  .replace("App Name's extension is currently off. You can turn it on in Safari Extensions preferences.", "AZET Pass's extension is currently off. Turn it on in Safari Settings, Extensions.")
  .replace('Quit and Open Safari Extensions Preferences…', 'Quit and Open Safari Settings…'))

edit('safari/SafariWebExtensionHandler.swift', (s) => all(s, 'let ServiceName = "Bitwarden"', 'let ServiceName = "AZET Pass"'))

const COPY = 'Copyright © 2015-2026 Bitwarden Inc. (original code, GPL-3.0), © 2026 AZET LLC (AZET Pass).'
const plist = (f, set, del = []) => {
  const p = path.join(S, f)
  for (const k of del) try { execFileSync('plutil', ['-remove', k, p]) } catch {}
  for (const [k, v] of Object.entries(set)) execFileSync('plutil', ['-replace', k, '-string', v, p])
}
plist('safari/Info.plist', {
  CFBundleDisplayName: 'AZET Pass', CFBundleShortVersionString: ver, CFBundleVersion: build, NSHumanReadableCopyright: COPY,
  NSHumanReadableDescription: 'Fill and save passwords in Safari, synced end-to-end encrypted with your AZET Pass vault.',
}, ['SFSafariAppExtensionBundleIdentifiersToReplace'])
plist('desktop/Info.plist', { CFBundleDisplayName: 'AZET Pass for Safari', CFBundleShortVersionString: ver, CFBundleVersion: build, NSHumanReadableCopyright: COPY })

// App icon: every Mac slot from the AZET Pass desktop icon (brand/generated/icon.icns)
const set = path.join(S, 'desktop/Assets.xcassets/AppIcon.appiconset')
const tmp = fs.mkdtempSync(path.join(fs.realpathSync('/tmp'), 'passicon-')) + '/i.iconset'
execFileSync('iconutil', ['-c', 'iconset', '-o', tmp, path.join(here, 'brand/generated/icon.icns')])
for (const f of fs.readdirSync(set)) if (f.endsWith('.png')) fs.unlinkSync(path.join(set, f))
const images = []
for (const pt of [16, 32, 128, 256, 512]) for (const sc of [1, 2]) {
  const name = `icon_${pt}x${pt}${sc === 2 ? '@2x' : ''}.png`
  if (!fs.existsSync(path.join(tmp, name))) throw new Error(`icon.icns lacks ${name}`)
  fs.copyFileSync(path.join(tmp, name), path.join(set, name))
  images.push({ size: `${pt}x${pt}`, idiom: 'mac', filename: name, scale: `${sc}x` })
}
fs.writeFileSync(path.join(set, 'Contents.json'), JSON.stringify({ images, info: { version: 1, author: 'xcode' } }, null, 2))
console.log('rebrand-safari: done', ver, build)

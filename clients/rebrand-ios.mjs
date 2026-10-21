// Rebrand pinned GPL Bitwarden iOS client for AZET Pass.
import fs from 'node:fs';
import path from 'node:path';
const root = path.resolve(process.argv[2] ?? 'ios');
const edit = (rel, fn) => { const p = path.join(root, rel); const a=fs.readFileSync(p,'utf8'), b=fn(a); if(a===b) throw new Error(`No replacement: ${rel}`); fs.writeFileSync(p,b); };
edit('Configs/Common-bwpm.xcconfig', s => s.replace('ORGANIZATION_IDENTIFIER = com.8bit','ORGANIZATION_IDENTIFIER = io.azet').replace('BASE_BUNDLE_ID = $(ORGANIZATION_IDENTIFIER).bitwarden','BASE_BUNDLE_ID = io.azet.pass').replace('BMPW_BUNDLE_DISPLAY_NAME = Bitwarden','BMPW_BUNDLE_DISPLAY_NAME = AZET Pass').replace('SHARED_APP_GROUP_IDENTIFIER = group.com.bitwarden.bitwarden-authenticator','SHARED_APP_GROUP_IDENTIFIER = group.io.azet.pass'));
edit('BitwardenKit/Core/Platform/Models/Domain/EnvironmentURLData.swift',s=>{
 const a=s.indexOf('    static let defaultUS = EnvironmentURLData('), b=s.indexOf('\n    )',a)+6;
 if(a<0||b<6) throw new Error('missing defaultUS');
 return s.slice(0,a)+`    static let defaultUS = EnvironmentURLData(\n        api: URL(string: "https://pass.azet.io/api")!,\n        base: URL(string: "https://pass.azet.io")!,\n        events: URL(string: "https://pass.azet.io/events")!,\n        icons: URL(string: "https://pass.azet.io/icons")!,\n        identity: URL(string: "https://pass.azet.io/identity")!,\n        notifications: URL(string: "https://pass.azet.io")!,\n        webVault: URL(string: "https://pass.azet.io")!,\n    )`+s.slice(b);
});
edit('BitwardenShared/Core/Platform/Models/Enum/RegionType.swift', s => s.replace('case .unitedStates: \"bitwarden.com\"', 'case .unitedStates: \"pass.azet.io\"').replace('case .europe, .gov, .selfHosted, .unitedStates: true', 'case .selfHosted, .unitedStates: true\n        case .europe, .gov: false'));
const locales=path.join(root,'BitwardenResources/Localizations');
let n=0;
for(const lang of fs.readdirSync(locales)){
 const file=path.join(locales,lang,'Localizable.strings'); if(!fs.existsSync(file))continue;
 const a=fs.readFileSync(file,'utf8'); const b=a.replace(/^("(?:[^"\\]|\\.)*"\s*=\s*")((?:[^"\\]|\\.)*)(";)/gm,(m,k,v,e)=>k+v.replaceAll('Bitwarden','AZET Pass').replaceAll('bitwarden.com','pass.azet.io')+e); // values only: keys feed SwiftGen names
 if(a!==b){fs.writeFileSync(file,lang==='ko.lproj'?b.replace(/AZET Pass(을|은|이|과|으로)/g,(m,j)=>'AZET Pass'+({'을':'를','은':'는','이':'가','과':'와','으로':'로'})[j]):b);n++;} // 패스 ends in a vowel
}
const brand=path.resolve(path.dirname(new URL(import.meta.url).pathname),'brand/generated');
const icons=[];
function walk(d){for(const ent of fs.readdirSync(d,{withFileTypes:true})){const p=path.join(d,ent.name); if(ent.isDirectory())walk(p); else if(ent.name==='Contents.json'&&p.includes('.appiconset/')) icons.push(p);}}
walk(root);
for(const f of icons){const j=JSON.parse(fs.readFileSync(f,'utf8'));for(const item of j.images??[]){if(!item.filename)continue;const dest=path.join(path.dirname(f),item.filename); if(fs.existsSync(dest)&&fs.existsSync(path.join(brand,'blue-1024.png'))){fs.copyFileSync(path.join(brand,'blue-1024.png'),dest);}}}
// The login screen renders Asset.Images.logo. Replace its monochrome image mask.
const {execFileSync} = await import('node:child_process');
const mark='M13 1a8 8 0 1 1 0 16a8 8 0 0 1 0-16Zm0 5a3 3 0 1 0 0 6a3 3 0 0 0 0-6ZM11 16h4v15h-4ZM15 21h5v3.5h-5ZM15 26.5h4v3.5h-4Z';
const wordmark=JSON.parse(fs.readFileSync(path.join(brand,'wordmark.json'),'utf8'));
const logoDir=path.join(root,'BitwardenShared/UI/Platform/Application/Support/Images.xcassets/logo.imageset');
const svg=`<svg xmlns="http://www.w3.org/2000/svg" width="220" height="34" viewBox="0 0 220 34"><path fill="black" fill-rule="evenodd" d="${mark}"/><path fill="black" transform="translate(36 0)" d="${wordmark.path}"/></svg>`;
for(const scale of [1,2,3]){
 const filename=scale===1?'logo.png':`logo@${scale}x.png`;
 execFileSync('rsvg-convert',['-w',String(220*scale),'-h',String(34*scale),'-o',path.join(logoDir,filename)],{input:svg});
}
console.log(`AZET Pass: localized ${n} tables, updated ${icons.length} icon catalogs`);

// Help links -> pass.azet.io/help anchors (same table as rebrand-android.mjs #36). Idempotent.
const HELP='https://pass.azet.io/help/';
const helpTopic=(slug)=>{const t=[[/^import/,'import'],[/auto-?fill|uri-match|fill-assist/,'autofill'],[/two-step/,'two-step'],[/send/,'send'],[/kdf|encryption-key|fingerprint/,'encryption'],[/passkey/,'passkeys'],[/website-icons/,'icons'],[/managing-items|generator|authenticator/,'items'],[/server-geographies/,'server'],[/organization|transfer-ownership|families/,'not-included'],[/flight-recorder/,'contact']].find(([re])=>re.test(slug));return HELP+(t?'#'+t[1]:'');};
const mapBw=(url)=>{const pth=new URL(url.replace(/\.$/,'')).pathname;if(pth.startsWith('/email-preferences'))return url;if(pth.startsWith('/help/password-manager-plans'))return 'https://azet.io/products/pass#plans';if(pth.startsWith('/help'))return helpTopic(pth.slice(6));return 'https://azet.io/products/pass';};
const swift=[];(function w(d){for(const e of fs.readdirSync(d,{withFileTypes:true})){const p=path.join(d,e.name);if(e.isDirectory()){if(!/Tests?$|\.git$/.test(e.name))w(p);}else if(e.name.endsWith('.swift')&&!/Tests?\.swift$/.test(e.name))swift.push(p);}})(path.join(root,'BitwardenShared'));(function w(d){for(const e of fs.readdirSync(d,{withFileTypes:true})){const p=path.join(d,e.name);if(e.isDirectory()){if(!/Tests?$/.test(e.name))w(p);}else if(e.name.endsWith('.swift')&&!/Tests?\.swift$/.test(e.name))swift.push(p);}})(path.join(root,'BitwardenKit'));
let relinked=0;for(const f of swift){const s=fs.readFileSync(f,'utf8');const o=s.replace(/https?:\/\/(?:www\.)?bitwarden\.com(?![\w.-])(?:\/[^"'\s)]*)?/g,mapBw);if(o!==s){fs.writeFileSync(f,o);relinked++;}}
console.log(`AZET Pass: help links rewritten in ${relinked} files`);

// Premium cannot be bought yet (supervisor 10-08: no upgrade or purchase buttons before checkout): the "Premium required"
// alerts keep their title and message and get one OK button instead of "Upgrade to Premium" + Cancel. Idempotent.
{const f=path.join(root,'BitwardenShared/UI/Vault/Extensions/Alert+Vault.swift');let s=fs.readFileSync(f,'utf8'),k=0;
 s=s.replace(/let preferredAction = (AlertAction\(title: Localizations\.upgradeToPremium[\s\S]*?)alertActions: \[\s*preferredAction,\s*AlertAction\(title: Localizations\.cancel, style: \.cancel\),\s*\],([\s\S]*?)\n\s*alert\.preferredAction = preferredAction\n/g,(m,a,b)=>{k++;return `_ = ${a}alertActions: [AlertAction(title: Localizations.ok, style: .cancel)],${b}\n`;});
 fs.writeFileSync(f,s);console.log(`AZET Pass: ${k} upgrade alerts made notices`);}

// App Store build under AZET's team: no push relay (pass.azet.io sends no APNs), no associated domains for
// bitwarden.com hosts, no iCloud container; Bitwarden's export-compliance code belongs to their account, so declare
// like Bitwarden's own Mac App Store build (ITSAppUsesNonExemptEncryption false). Idempotent (plutil -remove fails quietly).
const plistEdit = (rel, removes, bools = {}) => { const p = path.join(root, rel); for (const k of removes) try { execFileSync('plutil', ['-remove', k, p], {stdio: 'ignore'}) } catch {} for (const [k, v] of Object.entries(bools)) execFileSync('plutil', ['-replace', k, '-bool', String(v), p]) }
plistEdit('Bitwarden/Application/Support/Bitwarden.entitlements', ['aps-environment', 'com\\.apple\\.developer\\.associated-domains', 'com\\.apple\\.developer\\.ubiquity-container-identifiers'])
for (const rel of ['Bitwarden/Application/Support/Info.plist', 'BitwardenAutoFillExtension/Application/Support/Info.plist', 'BitwardenActionExtension/Application/Support/Info.plist', 'BitwardenShareExtension/Application/Support/Info.plist'])
  if (fs.existsSync(path.join(root, rel))) plistEdit(rel, ['ITSEncryptionExportComplianceCode'], {ITSAppUsesNonExemptEncryption: false})

// App Store signing (Apple Distribution, profiles "<bundle id> ios" made with the App Store Connect API): the optional
// Configs/Local-bwpm.xcconfig every target includes sets the team and the per-target profile names the xcconfigs reference.
fs.writeFileSync(path.join(root, 'Configs/Local-bwpm.xcconfig'), [
  'DEVELOPMENT_TEAM = 95P4H2RG24',
  ...Object.entries({ '': 'io.azet.pass', _ACTION_EXTENSION: 'io.azet.pass.find-login-action-extension', _AUTOFILL_EXTENSION: 'io.azet.pass.autofill',
    _NOTIFICATION_EXTENSION: 'io.azet.pass.notification', _SHARE_EXTENSION: 'io.azet.pass.share-extension', _WATCH_APP: 'io.azet.pass.watchkitapp',
    _WATCH_WIDGET_EXTENSION: 'io.azet.pass.watchkitapp.widget-extension' }).filter(([k]) => k).map(([k, id]) => `PROVISIONING_PROFILE_SPECIFIER${k} = ${id} ios`),
].join('\n') + '\n')
for (const f of ['Bitwarden-Release']) { // the main app's xcconfig sets no specifier of its own
  const p = path.join(root, 'Configs', f + '.xcconfig'); const s = fs.readFileSync(p, 'utf8')
  if (!s.includes('PROVISIONING_PROFILE_SPECIFIER')) fs.writeFileSync(p, s + '\nPROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*] = io.azet.pass ios\n')
}

// App Store rejects app icons with an alpha channel (ITMS-90396/90717); the brand PNGs have transparent corners, so
// flatten every app icon onto white (iOS applies its own mask). Idempotent.
{
  const pngs = []
  const walkIcons = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walkIcons(p); else if (e.name.endsWith('.png') && p.includes('.appiconset/')) pngs.push(p) } }
  walkIcons(root)
  execFileSync('python3', ['-c', 'import sys\nfrom PIL import Image\nfor f in sys.argv[1:]:\n im=Image.open(f)\n if im.mode in ("RGBA","LA","P"):\n  im=im.convert("RGBA"); bg=Image.new("RGB",im.size,(255,255,255)); bg.paste(im,mask=im.split()[3]); bg.save(f)', ...pngs])
  console.log(`AZET Pass: ${pngs.length} app icons without alpha`)
}

// Launch screen (logoBitwarden, white on the dark splash) and the watch app's logo/complication PDFs still showed Bitwarden.
{
  const both = (fill) => `<svg xmlns="http://www.w3.org/2000/svg" width="282" height="44" viewBox="0 0 220 34"><path fill="${fill}" fill-rule="evenodd" d="${mark}"/><path fill="${fill}" transform="translate(36 0)" d="${wordmark.path}"/></svg>`
  const launch = path.join(root, 'Bitwarden/Application/Support/Assets.xcassets/logoBitwarden.imageset')
  for (const [scale, name] of [[1, 'logo.png'], [2, 'logo@2x.png'], [3, 'logo@3x.png']])
    execFileSync('rsvg-convert', ['-w', String(282 * scale), '-h', String(44 * scale), '-o', path.join(launch, name)], { input: both('white') })
  const watch = path.join(root, 'BitwardenWatchApp/Assets.xcassets/BitwardenImagetype.imageset')
  for (const f of fs.readdirSync(watch).filter((f) => f.endsWith('.pdf'))) execFileSync('rsvg-convert', ['-f', 'pdf', '-o', path.join(watch, f)], { input: both('#175DDC') })
  const markSvg = `<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32"><path fill="black" fill-rule="evenodd" transform="translate(3 0)" d="${mark}"/></svg>`
  for (const d of ['BitwardenWatchApp/Assets.xcassets/ComplicationIcon.imageset', 'BitwardenWatchWidgetExtension/Assets.xcassets/AccentedComplicationIcon.imageset'])
    if (fs.existsSync(path.join(root, d, 'bw-logo.pdf'))) execFileSync('rsvg-convert', ['-f', 'pdf', '-o', path.join(root, d, 'bw-logo.pdf')], { input: markSvg })
  console.log('AZET Pass: launch logo and watch logos replaced')
}

// pass.azet.io sends no push (no APNs entitlement above): never show the "Allow automatic syncing" push prompt or ask
// for notification permission; the vault syncs on open and pull-to-refresh.
edit('BitwardenShared/UI/Vault/Vault/VaultList/VaultListProcessor.swift', (s) => s.includes('// AZET Pass: no push') ? s + ' ' : s.replace(
  '    private func handleNotifications() async {\n',
  '    private func handleNotifications() async {\n        if true { return } // AZET Pass: no push relay, no permission prompt\n'))
// The watch app still reads "Bitwarden" and would need its own App Store screenshots (ASC 409
// SCREENSHOT_REQUIRED.APPLE_WATCH, 10-17): ship the iPhone/iPad app without it.
edit('project-pm.yml', (s) => s.includes('      - target: BitwardenWatchApp\n') ? s.replace('      - target: BitwardenWatchApp\n', '') : s + ' ')

// AZET_LITE=1: AZET Pass Lite for the App Store (owner 10-21: Lite and Pro are separate apps, Lite is free and sells
// nothing). Bundle io.azet.pass.lite (+ extensions), name "AZET Pass Lite", one app group group.io.azet.pass.lite, and
// every string about Premium, plans, upgrades, prices or subscriptions emptied in every language — same rule as
// rebrand-android.mjs (pass.azet.io gives every account all features, so those screens never open).
if (process.env.AZET_LITE === '1') {
  edit('Configs/Common-bwpm.xcconfig', (s) => s.replace('BASE_BUNDLE_ID = io.azet.pass\n', 'BASE_BUNDLE_ID = io.azet.pass.lite\n')
    .replace('BMPW_BUNDLE_DISPLAY_NAME = AZET Pass\n', 'BMPW_BUNDLE_DISPLAY_NAME = AZET Pass Lite\n')
    .replace('SHARED_APP_GROUP_IDENTIFIER = group.io.azet.pass\n', 'SHARED_APP_GROUP_IDENTIFIER = group.io.azet.pass.lite\n'))
  for (const f of ['Configs/Local-bwpm.xcconfig', 'Configs/Bitwarden-Release.xcconfig'])
    edit(f, (s) => s.replace(/= io\.azet\.pass(\.| ios)/g, '= io.azet.pass.lite$1'))
  const sells = /premium|upgrade|prices?\b|pricing|subscri|checkout|stripe|구매|결제|요금제|구독/i
  let emptied = 0
  const walkStrings = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walkStrings(p); else if (e.name.endsWith('.strings')) {
    const s = fs.readFileSync(p, 'utf8')
    // keep the format placeholders: SwiftGen turns a string with %@/%d into a function, and its callers pass arguments
    const ph = (v) => (v.match(/%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDuUxXoOfeEgGcCsSpaAi]/g) || []).join(' ')
    const out = s.replace(/^("(?:[^"\\]|\\.)*"\s*=\s*")((?:[^"\\]|\\.)*)(";)$/gm, (m, k, v, end) => sells.test(v) ? (emptied++, k + ph(v) + end) : m)
    if (out !== s) fs.writeFileSync(p, out) } } }
  walkStrings(path.join(root, 'BitwardenResources/Localizations'))
  console.log(`AZET Pass Lite: io.azet.pass.lite, ${emptied} Premium/plan strings emptied`)
}

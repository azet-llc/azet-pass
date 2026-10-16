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

// App Store signing (Apple Distribution, profiles "<bundle id> ios" made with the App Store Connect API): only the
// app and extension targets get a profile; frameworks must not.
for (const f of ['Bitwarden-Release', 'BitwardenActionExtension-Release', 'BitwardenAutoFillExtension', 'BitwardenNotificationExtension', 'BitwardenShareExtension', 'BitwardenWatchApp-Release', 'BitwardenWatchWidgetExtension']) {
  const p = path.join(root, 'Configs', f + '.xcconfig'); const s = fs.readFileSync(p, 'utf8')
  if (!s.includes('PROVISIONING_PROFILE_SPECIFIER')) fs.writeFileSync(p, s + '\nPROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*] = $(PRODUCT_BUNDLE_IDENTIFIER) ios\nPROVISIONING_PROFILE_SPECIFIER[sdk=watchos*] = $(PRODUCT_BUNDLE_IDENTIFIER) ios\n')
}

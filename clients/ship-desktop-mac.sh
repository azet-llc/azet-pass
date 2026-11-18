#!/bin/zsh
# AZET Pass for Mac, from the pinned upstream tag to a signed, notarized release with an update feed:
#   rebrand -> build -> sign with AZET LLC's Developer ID -> notarize -> check the built app -> (with --publish)
#   GitHub release + the feed file that pass.azet.io/desktop serves.
#
#   zsh clients/ship-desktop-mac.sh [--publish]
#
# Runs on the release Mac only (azet-dist keychain, Apple's notarization login from the key vault). Without --publish
# nothing leaves this computer. Do not run it while another Mac build is using the same keychain.
set -e
here=${0:A:h}; . "$here/pins.env"
V=${DESKTOP_TAG#desktop-v}; W=${AZET_PASS_WORK:-$here/../../azet-pass-work}; src="$W/clients-desktop"; d="$src/apps/desktop"
OUT="$W/dist-mac-$V"; TEAM=95P4H2RG24
fail() { echo "SHIP STOPPED: $1"; exit 1; }
export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:/opt/homebrew/opt/llvm/bin:$PATH

echo "== 1/5 source $DESKTOP_TAG, rebranded"
[ -d "$src" ] && [ "$(git -C "$src" describe --tags 2>/dev/null)" != "$DESKTOP_TAG" ] && rm -rf "$src"
[ -d "$src" ] || git clone -q --depth 1 --branch "$DESKTOP_TAG" "$CLIENTS_REPO" "$src"
git -C "$src" checkout -q -- . && git -C "$src" clean -qfd -e node_modules
node "$here/rebrand.mjs" "$src"
# Ours is a Developer ID app without a provisioning profile: entitlements that need one (app groups, the AutoFill
# provider, an application identifier) would make macOS refuse to start it. What is left lets the JavaScript engine run.
python3 - "$d" "$TEAM" <<'PY'
import json, sys
d, team = sys.argv[1], sys.argv[2]
p = d + '/electron-builder.json'; j = json.load(open(p)); m = j['mac']
m.pop('provisioningProfile', None); m['extendInfo'].pop('BitwardenAppGroupIdentifier', None)
m['target'] = [{'target': 'dmg', 'arch': ['arm64']}, {'target': 'zip', 'arch': ['arm64']}]
m['entitlements'] = m['entitlementsInherit'] = 'resources/entitlements.mac.inherit.plist'
json.dump(j, open(p, 'w'), indent=2)
p = d + '/scripts/after-sign.js'; s = open(p).read()
assert 'teamId: "LTZ2PFU5D6"' in s, 'upstream moved the notarization team id'
open(p, 'w').write(s.replace('teamId: "LTZ2PFU5D6"', f'teamId: "{team}"'))
# The system AutoFill extension is left out: it works only with an entitlement Apple grants through a provisioning
# profile, which this Developer ID build does not carry. Filling in browsers is the browser extension's job.
p = d + '/scripts/after-pack.js'; s = open(p).read()
assert '      copyMacOsAutofillExtension(context);\n' in s, 'upstream moved the AutoFill extension step'
s = s.replace('      copyMacOsAutofillExtension(context);\n', '')
# The helper browsers talk to is signed without the sandbox and App Group upstream gives it (those need the profile
# too): unsandboxed, it and the app meet in the same per-user folder, as they did before upstream sandboxed it.
anchor = '  "com.bitwarden.desktop": "entitlements.desktop_proxy.plist",\n'
assert anchor in s, 'upstream moved the proxy entitlements table'
s = s.replace(anchor, anchor + '  "io.azet.pass": "entitlements.mac.inherit.plist",\n')
# That step signs with CSC_NAME as given; our keychain holds two certificates with that name, so it names the kind.
own = '      id = process.env.CSC_NAME;\n'
assert own in s, 'upstream moved the signing identity choice'
open(p, 'w').write(s.replace(own, '      id = "Developer ID Application: " + process.env.CSC_NAME;\n'))
PY

echo "== 2/5 build, sign, notarize"
(cd "$src" && npm install --no-audit --no-fund --ignore-scripts >/dev/null 2>&1)
(cd "$d/desktop_native" && node build.js >/dev/null)
(cd "$d" && npm run build >/dev/null)
. ~/.secrets/master.env >/dev/null 2>&1 # not exported: only the three values below reach the build
export APPLE_ID_USERNAME="$APPLE_AZET_APPLE_ID" APPLE_ID_PASSWORD="$APPLE_AZET_APP_SPECIFIC_PASSWORD"
export CSC_KEYCHAIN="$HOME/Library/Keychains/azet-dist.keychain-db" CSC_NAME="AZET LLC ($TEAM)"
security list-keychains -d user -s ~/Library/Keychains/login.keychain-db ~/Library/Keychains/azet-dist.keychain-db
azet-keychain-unlock
trap 'security list-keychains -d user -s ~/Library/Keychains/login.keychain-db; security lock-keychain ~/Library/Keychains/azet-dist.keychain-db' EXIT
rm -rf "$d/dist"
(cd "$d" && npx electron-builder --mac --arm64 -p never)

echo "== 3/5 check the built app"
ZIP=$(ls "$d"/dist/*-arm64-mac.zip 2>/dev/null | head -1); DMG=$(ls "$d"/dist/*.dmg 2>/dev/null | head -1)
[ -f "$ZIP" ] && [ -f "$DMG" ] && [ -f "$d/dist/latest-mac.yml" ] || fail "the zip, dmg or feed file was not built"
T=$(mktemp -d); ditto -x -k "$ZIP" "$T"; APP="$T/AZET Pass.app"
spctl -a -vv "$APP" 2>&1 | grep -q "Notarized Developer ID" || fail "Gatekeeper does not see a notarized app"
[ "$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)" = "$V" ] || fail "the app is not version $V"
codesign -dv "$APP" 2>&1 | grep -q "TeamIdentifier=$TEAM" || fail "not signed by AZET LLC"
# it must start: an app signed with entitlements macOS rejects dies before its first window
"$APP/Contents/MacOS/AZET Pass" --user-data-dir="$T/profile" >"$T/run.log" 2>&1 & PID=$!
sleep 12; kill -0 $PID 2>/dev/null || fail "the app exited on launch: $(tail -3 "$T/run.log")"
kill $PID; rm -rf "$T"
# the installer image is signed and notarized as its own file (the app inside already is), so it opens without a warning
codesign --force --timestamp -s "Developer ID Application: $CSC_NAME" "$DMG"
xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID_USERNAME" --password "$APPLE_ID_PASSWORD" --team-id $TEAM --wait >/dev/null
xcrun stapler staple "$DMG" >/dev/null
spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 | grep -q "Notarized Developer ID" || fail "the dmg is not notarized"

echo "== 4/5 collect"
rm -rf "$OUT"; mkdir -p "$OUT"
cp "$ZIP" "$OUT/azet-pass-mac-arm64-$V.zip"; cp "$DMG" "$OUT/azet-pass-mac-arm64-$V.dmg"
# The feed carries the zip only (what an installed copy updates from), under the name it is published with; its size
# and hash are the builder's own. The dmg was re-signed after the builder hashed it, so its lines are dropped.
python3 - "$d/dist/latest-mac.yml" "$OUT/latest-mac.yml" "azet-pass-mac-arm64-$V.zip" <<'PY'
import re, sys
src, out, name = sys.argv[1:]
s = open(src).read()
zip_entry = re.search(r"  - url: [^\n]*-mac\.zip\n    sha512: ([^\n]+)\n    size: (\d+)\n", s)
date = re.search(r"releaseDate: [^\n]+", s).group(0)
version = re.search(r"version: [^\n]+", s).group(0)
open(out, 'w').write(f"{version}\nfiles:\n  - url: {name}\n    sha512: {zip_entry.group(1)}\n    size: {zip_entry.group(2)}\npath: {name}\nsha512: {zip_entry.group(1)}\n{date}\n")
PY
(cd "$src" && git diff > "$OUT/azet-pass-desktop-$V.patch") # GPL: our changes to the upstream tag, with the tag named in the release notes
ls -l "$OUT" | awk 'NR>1{print $5, $9}'; cat "$OUT/latest-mac.yml"

[ "$1" = "--publish" ] || { echo "== built and checked; not published (run again with --publish)"; exit 0; }
echo "== 5/5 publish"
TAG="v$V-mac1"
gh release view "$TAG" -R azet-llc/azet-pass >/dev/null 2>&1 && fail "$TAG is already published"
gh release create "$TAG" -R azet-llc/azet-pass --title "AZET Pass $V for Mac (notarized)" --notes "AZET Pass for Mac $V, for Apple silicon Macs on macOS 12 or later. Signed with AZET LLC's Developer ID and notarized by Apple. Installed copies of this version and later update themselves (Help > Check for updates).

Source (GPL-3.0): the Bitwarden desktop client at tag \`$DESKTOP_TAG\` with the changes in \`azet-pass-desktop-$V.patch\`, produced by \`clients/rebrand.mjs\` in this repository." \
  "$OUT/azet-pass-mac-arm64-$V.dmg" "$OUT/azet-pass-mac-arm64-$V.zip" "$OUT/latest-mac.yml" "$OUT/azet-pass-desktop-$V.patch"
echo "published $TAG — the feed at pass.azet.io/desktop follows the latest *-mac* release"

#!/bin/zsh
# AZET Pass for Windows (x64 NSIS installer), cross-built on this Mac from the tree ship-desktop-mac.sh left
# (same tag, already rebranded and `npm run build` done), signed with AZET LLC's Artifact Signing certificate.
# usage: ship-desktop-win.sh [--publish]   -> <work>/dist-win-<version>/ (installer, latest.yml, source patch)
# After --publish nothing else: pass.azet.io/desktop serves the newest v*-win* release, and installed apps update to it.
set -euo pipefail
here=${0:A:h}; . "$here/pins.env"
W=${AZET_PASS_WORK:-$here/../../azet-pass-work}; src="$W/clients-desktop"; d="$src/apps/desktop"
V=${DESKTOP_VERSION:-${DESKTOP_TAG#desktop-v}}; OUT="$W/dist-win-$V"; NAME="azet-pass-windows-x64-setup-$V.exe"
export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:/opt/homebrew/opt/llvm/bin:$PATH
stop() { echo "SHIP STOPPED: $1"; exit 1; }
[ "$(git -C "$src" describe --tags)" = "$DESKTOP_TAG" ] || stop "work tree is not at $DESKTOP_TAG (run ship-desktop-mac.sh first)"
[ -f "$d/build/main.js" ] || stop "no built app in the work tree (run ship-desktop-mac.sh first)"

if [ -z "${AZET_PASS_SKIP_BUILD:-}" ]; then
echo "== 1/4 build the Windows app"
(cd "$d/desktop_native" && node build.js --target=x86_64-pc-windows-msvc)
rm -rf "$d/dist/win-unpacked"
(cd "$d" && npx electron-builder --win dir --x64 -p never -c.win.signAndEditExecutable=false)
# the dir target leaves out the update feed file the installed app reads (the NSIS target writes it only when it packs itself)
printf 'provider: generic\nurl: https://pass.azet.io/desktop\nupdaterCacheDirName: azet-pass-updater\n' > "$d/dist/win-unpacked/resources/app-update.yml"
(cd "$here/tools" && { [ -d node_modules ] || npm i -q --no-save resedit@2 pe-library@1; } && node seticon.mjs "$d/dist/win-unpacked/AZET Pass.exe" "$d/resources/icon.ico" "AZET Pass" "$V")

echo "== 2/4 sign, pack, sign"
TOKEN=$(mktemp); chmod 600 "$TOKEN"; trap 'rm -f "$TOKEN"' EXIT
curl -sf -m 30 "https://login.microsoftonline.com/$(tkt get AZET_SIGN_AZURE_TENANT_ID)/oauth2/v2.0/token" \
  --data-urlencode grant_type=client_credentials --data-urlencode scope=https://codesigning.azure.net/.default \
  --data-urlencode "client_id=$(tkt get AZET_SIGN_AZURE_CLIENT_ID)" --data-urlencode "client_secret=$(tkt get AZET_SIGN_AZURE_CLIENT_SECRET)" \
  | python3 -c 'import sys, json; sys.stdout.write(json.load(sys.stdin)["access_token"])' > "$TOKEN"
[ -s "$TOKEN" ] || stop "no signing token"
sign() { jsign --storetype TRUSTEDSIGNING --keystore eus.codesigning.azure.net --storepass "file:$TOKEN" \
  --alias azet-signing/azet-public --tsaurl http://timestamp.acs.microsoft.com --tsmode RFC3161 "$@" >/dev/null; }
# our own programs inside the app (the ones not already signed by someone else)
for f in "$d"/dist/win-unpacked/*.exe; do osslsigncode verify -in "$f" 2>/dev/null | grep -q "Signature verification: ok" || sign "$f"; done
# NSIS with Homebrew's arm64 makensis (electron-builder's bundled one is x86)
N="$W/nsis-local"; rm -rf "${N:?}"; cp -R "$(brew --prefix makensis)/share/nsis" "$N"; mkdir -p "$N/mac"; cp "$(brew --prefix makensis)/bin/makensis" "$N/mac/"
# elevate.exe (MIT) comes from electron-builder's NSIS bundle
E=~/Library/Caches/electron-builder/nsis/nsis-3.0.4.1-nsis-3.0.4.1
[ -f "$E/elevate.exe" ] || { mkdir -p "$E" && curl -sfL -m 300 -o "$W/nsis-3.0.4.1.7z" https://github.com/electron-userland/electron-builder-binaries/releases/download/nsis-3.0.4.1/nsis-3.0.4.1.7z && 7zz x -y -o"$E" "$W/nsis-3.0.4.1.7z" >/dev/null; }
cp "$E/elevate.exe" "$N/"
(cd "$d" && ELECTRON_BUILDER_NSIS_DIR="$N" npx electron-builder --win nsis --x64 -p never -c.win.signAndEditExecutable=false --prepackaged dist/win-unpacked)
SETUP="$d/dist/AZET Pass Setup $V.exe"; sign "$SETUP"

fi
SETUP="$d/dist/AZET Pass Setup $V.exe"

echo "== 3/4 check"
# the file must hash to what the signature covers (this Mac has no Microsoft root, so the chain itself is not judged here)
sig=$(osslsigncode verify -in "$SETUP" 2>&1 || true); app=$(osslsigncode verify -in "$d/dist/win-unpacked/AZET Pass.exe" 2>&1 || true)
[ "$(print -r -- "$sig" | awk '/message digest/{print $NF}' | sort -u | wc -l | tr -d ' ')" = 1 ] || stop "the installer does not match its signature"
[[ "$sig" == *"CN=AZET LLC"* ]] || stop "the installer is not signed by AZET LLC"
[[ "$app" == *"CN=AZET LLC"* ]] || stop "the app is not signed by AZET LLC"
grep -q "pass.azet.io/desktop" "$d/dist/win-unpacked/resources/app-update.yml" || stop "the app has no update feed"

echo "== 4/4 collect"
rm -rf "$OUT"; mkdir -p "$OUT"; cp "$SETUP" "$OUT/$NAME"
# the feed is written here: the builder hashed the installer before it was signed
python3 - "$OUT/$NAME" "$OUT/latest.yml" "$V" <<'PY'
import base64, datetime, hashlib, os, sys
f, out, v = sys.argv[1:]
h = base64.b64encode(hashlib.sha512(open(f, 'rb').read()).digest()).decode(); n = os.path.basename(f)
when = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')
open(out, 'w').write(f"version: {v}\nfiles:\n  - url: {n}\n    sha512: {h}\n    size: {os.path.getsize(f)}\npath: {n}\nsha512: {h}\nreleaseDate: '{when}'\n")
PY
(cd "$src" && git diff > "$OUT/azet-pass-desktop-$V.patch")
ls -l "$OUT"; shasum -a 256 "$OUT/$NAME"
if [ "${1:-}" = "--publish" ]; then
  gh release create "v$V-win1" -R azet-llc/azet-pass --title "AZET Pass $V for Windows (signed)" --notes "AZET Pass for Windows $V, x64, Windows 10 or 11. Signed by AZET LLC. This version and later update themselves; if you have 2026.9.1, install this one over it once.

Source (GPL-3.0): the Bitwarden desktop client at tag \`$DESKTOP_TAG\` with the changes in \`azet-pass-desktop-$V.patch\`, produced by \`clients/rebrand.mjs\` and \`clients/ship-desktop-win.sh\` in this repository." "$OUT/$NAME" "$OUT/latest.yml" "$OUT/azet-pass-desktop-$V.patch"
  gh release upload desktop-feed "$OUT/latest.yml" --clobber -R azet-llc/azet-pass # the feed installed apps read
fi

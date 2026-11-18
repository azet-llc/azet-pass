#!/usr/bin/env bash
# AZET Pass for Windows as an MSIX for the Microsoft Store, from this Mac. Same steps as Bitwarden's
# apps/desktop/scripts/appx-cross-build.ps1 (custom-appx-manifest.xml filled from electron-builder.json's appx block,
# makemsix from msix-packaging, optional osslsigncode), but packs the win-unpacked folder build-desktop.sh made.
# The Store signs the package itself; sign only for a sideload test: build-msix.sh <work> <test.p12> (password in P12_PASS).
# Needs: brew install iinuwa/msix-packaging-tap/msix-packaging osslsigncode
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); . "$here/pins.env"
W=${1:-$here/../../azet-pass-work}; d="$W/clients-desktop/apps/desktop"
MAKEMSIX=$(command -v makemsix || echo /opt/homebrew/opt/msix-packaging/bin/makemsix)
AZET_BUILD=${AZET_BUILD:-1}
# Store version = upstream major.minor.(patch*100 + AZET build).0, e.g. 2026.9.1 build 1 -> 2026.9.101.0 (Android: 2026.9.1-azet1);
# the Store reserves the fourth number (must be 0) and refuses a second package with an already uploaded full name
IFS=. read -r v1 v2 v3 <<<"${DESKTOP_TAG#desktop-v}"; ver="$v1.$v2.$((v3 * 100 + AZET_BUILD)).0"
out="$W/dist/azet-pass-windows-x64-${ver}.msix"
lay="$W/msix-layout"; rm -rf "$lay"; mkdir -p "$lay/assets"
cp -R "$d/dist/win-unpacked" "$lay/app"
cp "$d"/resources/appx/* "$lay/assets/"
# as appx-cross-build.ps1 does since 2026.10 (the passkey plugin itself is not declared: customExtensions stays empty)
sed 's/"name": "Bitwarden"/"name": "AZET Pass"/' "$d/resources/windows_plugin_authenticator_config.stable.json" > "$lay/app/resources/plugin_authenticator_config.json"
for t in light dark; do cp "$d/resources/windows_plugin_authenticator_logo_$t.stable.svg" "$lay/app/resources/plugin_authenticator_logo_$t.svg"; done
node -e '
const fs = require("fs"), [d, ver, lay] = process.argv.slice(1)
const b = JSON.parse(fs.readFileSync(d + "/electron-builder.json", "utf8")), a = b.appx
const min = a.minVersion ?? "10.0.14316.0" // electron-builder default for x64
const v = { arch: "x64", applicationId: a.applicationId, backgroundColor: a.backgroundColor, customExtensions: "",
  displayName: b.productName, executable: `app\\${b.productName}.exe`, identityName: a.identityName,
  maxVersionTested: a.maxVersionTested ?? min, minVersion: min, publisher: a.publisher,
  publisherDisplayName: a.publisherDisplayName, version: ver }
let m = fs.readFileSync(d + "/custom-appx-manifest.xml", "utf8")
for (const k in v) m = m.replaceAll("${" + k + "}", v[k])
// Store listing languages = the manifest Resources; we write listings in English and Korean only, so declare those two
// (Bitwarden declares 62). The app keeps all its translations: Electron picks the UI language itself.
m = m.replace(/(<Resource Language="en-US" \/>)[\s\S]*?(\s*<\/Resources>)/, "$1\n        <Resource Language=\"ko\" />$2")
if (/\$\{\w+\}/.test(m)) throw new Error("unfilled macro in manifest")
fs.writeFileSync(lay + "/AppxManifest.xml", m)' "$d" "$ver" "$lay"
# No makemsix on this Mac (the Homebrew formula stopped building on macOS 27): the layout goes out as a zip and the
# msix-pack workflow packs it with makeappx on a Windows runner.
if [ ! -x "$MAKEMSIX" ]; then
  z="$W/dist/azet-pass-msix-layout-${ver}.zip"; rm -f "$z"; (cd "$lay" && zip -qr -1 "$z" .); rm -rf "$lay"; ls -la "$z"
  echo "pack it: gh release create msix-input-${ver} --prerelease \"$z\" && gh workflow run msix-pack.yml -f tag=msix-input-${ver}"; exit 0
fi
rm -f "$out"; "$MAKEMSIX" pack -d "$lay" -p "$out" >/dev/null
if [ -n "${2:-}" ]; then
  osslsigncode sign -pkcs12 "$2" -pass "${P12_PASS:?}" -in "$out" -out "${out%.msix}-test-signed.msix" >/dev/null
  echo "${out%.msix}-test-signed.msix"
fi
rm -rf "$lay"; ls -la "$out"

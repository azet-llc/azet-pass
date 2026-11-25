#!/usr/bin/env bash
# AZET Pass desktop for Linux x64 (AppImage and .deb, unsigned), built on a Linux machine.
# Needs: node 22+, rustup, build-essential pkg-config libsecret-1-dev libglib2.0-dev fakeroot.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); . "$here/pins.env"
W=${1:-$here/../../azet-pass-work}; mkdir -p "$W/dist"; src="$W/clients-desktop"
export PATH=$HOME/.cargo/bin:$PATH
[ -d "$src" ] || git clone -q --depth 1 --branch "$DESKTOP_TAG" "$CLIENTS_REPO" "$src"
git -C "$src" checkout -q -- . && git -C "$src" clean -qfd -e node_modules
node "$here/rebrand.mjs" "$src"
node "$here/rebrand-desktop.mjs" "$src" "${DESKTOP_VERSION:-}"
(cd "$src" && npm install --no-audit --no-fund --ignore-scripts)
d="$src/apps/desktop"
(cd "$d/desktop_native" && node build.js)
(cd "$d" && npm run build)
python3 "$here/../server/tools/rebrand-web-vault.py" "$d/build" # the current mark in the built screens (stops if the old one is left)
(cd "$d" && npx electron-builder --linux AppImage deb --x64 -p never)
cp "$d"/dist/*.AppImage "$W/dist/azet-pass-linux-x64.AppImage"
cp "$d"/dist/*.deb "$W/dist/azet-pass-linux-x64.deb"
ls -la "$W/dist"

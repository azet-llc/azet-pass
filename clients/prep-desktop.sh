#!/bin/zsh
# Prepares the desktop work tree that ship-desktop-win.sh (and the Linux build) pack, without the Mac signing and
# notarization ship-desktop-mac.sh also does: clean pinned source, rebrand (version, azetpass:// scheme, icons), build,
# then the current mark in the built screens (server/tools/rebrand-web-vault.py, which stops if the old mark is left).
#   zsh clients/prep-desktop.sh   (version = pins.env DESKTOP_VERSION)
set -e
here=${0:A:h}; . "$here/pins.env"
V=${DESKTOP_VERSION:-${DESKTOP_TAG#desktop-v}}; W=${AZET_PASS_WORK:-$here/../../azet-pass-work}; src="$W/clients-desktop"; d="$src/apps/desktop"
export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:/opt/homebrew/opt/llvm/bin:$PATH
echo "== source $DESKTOP_TAG as $V"
[ -d "$src" ] && [ "$(git -C "$src" describe --tags 2>/dev/null)" != "$DESKTOP_TAG" ] && rm -rf "$src"
[ -d "$src" ] || git clone -q --depth 1 --branch "$DESKTOP_TAG" "$CLIENTS_REPO" "$src"
git -C "$src" checkout -q -- . && git -C "$src" clean -qfd -e node_modules
node "$here/rebrand.mjs" "$src"
node "$here/rebrand-desktop.mjs" "$src" "$V"
echo "== build"
(cd "$src" && npm install --no-audit --no-fund --ignore-scripts >/dev/null 2>&1)
(cd "$d/desktop_native" && node build.js >/dev/null)
(cd "$d" && npm run build >/dev/null)
echo "== mark"
python3 "$here/../server/tools/rebrand-web-vault.py" "$d/build"
grep -q '"version": "'"$V"'"' "$d/package.json" || { echo "PREP STOPPED: package.json is not $V"; exit 1; }
echo "PREP OK $V"

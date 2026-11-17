#!/usr/bin/env bash
# AZET Pass web vault (self-hosted flavour of Bitwarden web, OSS build) into server/public/web-vault, served by the Worker.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); . "$here/pins.env"
W=${1:-$here/../../azet-pass-work}; src="$W/clients-browser"
[ -d "$src" ] || git clone -q --depth 1 --branch "$BROWSER_TAG" "$CLIENTS_REPO" "$src"
git -C "$src" checkout -q -- . && git -C "$src" clean -qfd
node "$here/rebrand.mjs" "$src"
(cd "$src" && npm install --no-audit --no-fund --ignore-scripts)
(cd "$src/apps/web" && rm -rf build && NODE_OPTIONS=--max-old-space-size=8192 npm run build:oss:selfhost:prod)
find "$src/apps/web/build" -name '*.map' -delete
rm -rf "$here/../server/public/web-vault" && cp -R "$src/apps/web/build" "$here/../server/public/web-vault"
# the built pages (loading logo alt text, passkey connector titles) still name upstream: our name in every .html
find "$here/../server/public/web-vault" -maxdepth 1 -name '*.html' -exec sed -i '' -e 's/Bitwarden/AZET Pass/g' {} +
cp -R "$here/brand/help" "$here/../server/public/web-vault/help" # pass.azet.io/help, target of every help link (rebrand.mjs section 8)
echo "web vault: $(find "$here/../server/public/web-vault" -type f | wc -l) files; deploy with server/scripts/azet-deploy.sh"

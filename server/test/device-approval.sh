#!/usr/bin/env bash
# New-device approval on a local Worker (test/device-approval.mjs).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH
W=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
worker-build --release --locked >/dev/null
printf 'JWT_SECRET=%s\nJWT_REFRESH_SECRET=%s\nALLOWED_EMAILS=*\n' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" > .dev.vars
rm -rf .wrangler/state; mkdir -p public/web-vault
# prebuilt above; login limiter opened (one IP makes many logins); the test talks to the backend directly (entry.js), without the gw internal key
sed -e '/^\[build\]/,/^command/d' -e 's|^main = "src/private.js"|main = "src/entry.js"|' -e 's|simple = { limit = 5, period = 60 }|simple = { limit = 1000, period = 60 }|' wrangler.toml > wrangler.test.toml
for f in sql/schema.sql migrations/001[5-9]_*.sql migrations/002*.sql; do
  D1_DATABASE_ID=00000000-0000-0000-0000-000000000000 npx -y wrangler@4 d1 execute vault1 -c wrangler.test.toml --local --file "$f" >/dev/null 2>&1
done
D1_DATABASE_ID=00000000-0000-0000-0000-000000000000 npx -y wrangler@4 dev -c wrangler.test.toml --local --port 48797 >"$W/dev.log" 2>&1 &
for i in $(seq 60); do curl -sf -o /dev/null http://127.0.0.1:48797/api/alive && break; sleep 1; done
node test/device-approval.mjs http://127.0.0.1:48797 | tee "$W/out" || { tail -30 "$W/dev.log"; exit 1; }

#!/usr/bin/env bash
# Two-step sign-in with an authenticator app on a local Worker: turned on only with the master password and a right
# code; then the password alone, a wrong code, a used code and a wrong recovery code are all refused, a fresh code and
# the recovery code sign in. See test/twofactor.mjs for each check.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH
W=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
RUN=$RANDOM$RANDOM; PORT=48827; URL=http://127.0.0.1:$PORT
EMAIL="twostep-$RUN@example.com"; PW="TwoStep-$RUN-pw-long"
worker-build --release --locked >/dev/null
printf 'JWT_SECRET=%s\nJWT_REFRESH_SECRET=%s\nALLOWED_EMAILS=*\n' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" > .dev.vars
rm -rf .wrangler/state; mkdir -p public/web-vault
sed -e '/^\[build\]/,/^command/d' -e 's|^main = "src/private.js"|main = "src/entry.js"|' -e 's|simple = { limit = 5, period = 60 }|simple = { limit = 1000, period = 60 }|' wrangler.toml > wrangler.test.toml
for f in sql/schema.sql migrations/001[5-9]_*.sql migrations/002*.sql; do
  D1_DATABASE_ID=00000000-0000-0000-0000-000000000000 npx -y wrangler@4 d1 execute vault1 -c wrangler.test.toml --local --file "$f" >/dev/null 2>&1
done
D1_DATABASE_ID=00000000-0000-0000-0000-000000000000 npx -y wrangler@4 dev -c wrangler.test.toml --local --port $PORT >"$W/dev.log" 2>&1 &
for i in $(seq 60); do curl -sf -o /dev/null $URL/api/alive && break; sleep 1; done
node test/register.mjs $URL "$EMAIL" "$PW"
node test/twofactor.mjs $URL "$EMAIL" "$PW" | tee "$W/out" | grep -v '^SECRETS'
grep -q '^4 ' "$W/out" || { echo "FAIL: two-step sign-in"; exit 1; }
echo "PASS: two-step sign-in"

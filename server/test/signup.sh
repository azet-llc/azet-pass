#!/usr/bin/env bash
# Sign-up needs the emailed token: no token or a forged one -> 400; send-verification-email mails a link (captured
# here through MAIL_WEBHOOK) whose token passes verification-email-clicked and registers that address only.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH
W=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
worker-build --release --locked >/dev/null 2>&1
printf 'JWT_SECRET=%s\nJWT_REFRESH_SECRET=%s\nALLOWED_EMAILS=*\nMAIL_WEBHOOK=http://127.0.0.1:48790\n' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" > .dev.vars
rm -rf .wrangler/state; mkdir -p public/web-vault
# the test talks to the backend directly (entry.js): the wrangler main (private.js) answers only the gateway's internal key
sed -e '/^\[build\]/,/^command/d' -e 's|^main = "src/private.js"|main = "src/entry.js"|' wrangler.toml > wrangler.test.toml
for f in sql/schema.sql migrations/001[5-9]_*.sql; do
  D1_DATABASE_ID=00000000-0000-0000-0000-000000000000 npx -y wrangler@4 d1 execute vault1 -c wrangler.test.toml --local --file "$f" >/dev/null 2>&1
done
node -e 'require("http").createServer((q,r)=>{let b="";q.on("data",c=>b+=c).on("end",()=>{require("fs").appendFileSync(process.argv[1],b+"\n");r.end("ok")})}).listen(48790,"127.0.0.1")' "$W/mail.jsonl" &
D1_DATABASE_ID=00000000-0000-0000-0000-000000000000 npx -y wrangler@4 dev -c wrangler.test.toml --local --port 48787 >"$W/dev.log" 2>&1 &
for i in $(seq 60); do curl -sf -o /dev/null http://127.0.0.1:48787/api/alive && break; sleep 1; done
B=http://127.0.0.1:48787; E="signup-$RANDOM@example.com"
post() { curl -s -o "$W/body" -w '%{http_code}' "$B$1" -H 'content-type: application/json' -d "$2"; }
REG='"name":null,"masterPasswordHash":"x","key":"2.a|b|c","kdf":0,"kdfIterations":600000,"userAsymmetricKeys":{"publicKey":"p","encryptedPrivateKey":"2.a|b|c"}'

c=$(post /identity/accounts/register/finish "{\"email\":\"$E\",$REG}"); echo "finish without token: $c"; [ "$c" = 400 ]
c=$(post /identity/accounts/register/finish "{\"email\":\"$E\",$REG,\"emailVerificationToken\":\"fixed-token-to-mock\"}"); echo "finish with the old mock token: $c"; [ "$c" = 400 ]
c=$(post /identity/accounts/register/send-verification-email "{\"email\":\"$E\",\"name\":null,\"receiveMarketingEmails\":false}"); echo "send-verification-email: $c"; [ "$c" = 204 ]
for i in $(seq 40); do [ -s "$W/mail.jsonl" ] && break; sleep 0.5; done # the mail leaves after the answer
LINK=$(jq -r .text "$W/mail.jsonl" | grep -o 'http[^ ]*finish-signup[^ ]*' | head -1); echo "mailed link: ${LINK%%token=*}token=…"
TOKEN=$(node -e 'console.log(decodeURIComponent(/[?&]token=([^&]+)/.exec(process.argv[1])[1]))' "$LINK") # the link keeps its query after the #
c=$(post /identity/accounts/register/verification-email-clicked "{\"email\":\"$E\",\"emailVerificationToken\":\"$TOKEN\"}"); echo "clicked, right address: $c"; [ "$c" = 200 ]
c=$(post /identity/accounts/register/verification-email-clicked "{\"email\":\"other-$E\",\"emailVerificationToken\":\"$TOKEN\"}"); echo "clicked, other address: $c"; [ "$c" = 400 ]
c=$(post /identity/accounts/register/finish "{\"email\":\"other-$E\",$REG,\"emailVerificationToken\":\"$TOKEN\"}"); echo "finish, other address: $c"; [ "$c" = 400 ]
node test/register.mjs $B "$E" "pw-$RANDOM-long-enough" # real client-shaped registration with a minted token
c=$(post /identity/accounts/register/send-verification-email "{\"email\":\"$E\",\"name\":null}"); echo "send again for an existing account: $c, mails: $(wc -l < "$W/mail.jsonl" | tr -d ' ')"; [ "$c" = 204 ] && [ "$(wc -l < "$W/mail.jsonl" | tr -d ' ')" = 1 ]
echo "signup: ok"

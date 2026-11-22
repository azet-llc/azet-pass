#!/usr/bin/env bash
# Premium follows the AZET licence: free account -> premium false; licence upload -> licence service activate
# (stub here, same answers as CONTRACT.md) -> premium true; a wrong key -> the contract sentence, premium stays false.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH
W=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
worker-build --release --locked >/dev/null 2>&1
printf 'JWT_SECRET=%s\nJWT_REFRESH_SECRET=%s\nALLOWED_EMAILS=*\nSUITE_API_URL=http://127.0.0.1:48789\n' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" > .dev.vars
rm -rf .wrangler/state; mkdir -p public/web-vault
# the test talks to the backend directly (entry.js): the wrangler main (private.js) answers only the gateway's internal key
sed -e '/^\[build\]/,/^command/d' -e 's|^main = "src/private.js"|main = "src/entry.js"|' wrangler.toml > wrangler.test.toml
for f in sql/schema.sql migrations/001[5-9]_*.sql migrations/002*.sql; do
  D1_DATABASE_ID=00000000-0000-0000-0000-000000000000 npx -y wrangler@4 d1 execute vault1 -c wrangler.test.toml --local --file "$f" >/dev/null 2>&1
done
node -e '
require("http").createServer((q,r)=>{let b="";q.on("data",c=>b+=c).on("end",()=>{const j=JSON.parse(b||"{}");console.log(q.url,JSON.stringify(j));
 const good=j.license_key==="AZET-AAAAA-BBBBB-CCCCC-DDDDD";
 const [s,o]= q.url.endsWith("/activate") ? (good?[200,{ok:true,status:"active",plan:"pass-yearly",seats:1,seats_used:1,expires_at:"2099-01-01T00:00:00.000Z"}]:[404,{ok:false,error:"invalid_key"}])
  : [200,{ok:true,status:good?"active":"none"}];
 r.writeHead(s,{"content-type":"application/json"}).end(JSON.stringify(o))})}).listen(48789,"127.0.0.1")' >"$W/suite.log" &
D1_DATABASE_ID=00000000-0000-0000-0000-000000000000 npx -y wrangler@4 dev -c wrangler.test.toml --local --port 48787 >"$W/dev.log" 2>&1 &
for i in $(seq 60); do curl -sf -o /dev/null http://127.0.0.1:48787/api/alive && break; sleep 1; done
B=http://127.0.0.1:48787
T=$(PRINT_TOKEN=1 node test/register.mjs $B "prem-$RANDOM@example.com" "pw-$RANDOM-long-enough")
prem() { curl -s $B/api/accounts/profile -H "authorization: Bearer $T" | jq -r .premium; }
echo "free account premium: $(prem)"; [ "$(prem)" = false ]
echo "wrong key: $(curl -s $B/api/accounts/license -H "authorization: Bearer $T" -F license=@<(echo AZET-ZZZZZ-ZZZZZ-ZZZZZ-ZZZZZ) | head -c 300)"
[ "$(prem)" = false ]
echo "good key: $(curl -s $B/api/accounts/license -H "authorization: Bearer $T" -F license=@<(echo AZET-AAAAA-BBBBB-CCCCC-DDDDD) | head -c 300)"
echo "licensed account premium: $(prem)"; [ "$(prem)" = true ]
echo "sync premium: $(curl -s "$B/api/sync" -H "authorization: Bearer $T" | jq -r .profile.premium)"
echo "licence service saw:"; cat "$W/suite.log"
echo "PASS: premium follows the AZET licence"

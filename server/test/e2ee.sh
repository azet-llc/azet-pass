#!/usr/bin/env bash
# Proves the server never sees plaintext: the official Bitwarden CLI (`bw`) talks to this Worker running locally
# through a proxy that records every byte both ways; afterwards the wire log and the local D1 files are searched
# for the master password and every secret field of the item. Any hit fails the test.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH
W=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
RUN=$RANDOM$RANDOM
EMAIL="e2ee-$RUN@example.com"
MASTER="Master-Sentinel-$RUN-pw"
S_NAME="ItemName-Sentinel-$RUN"; S_USER="user-sentinel-$RUN"; S_PASS="Secret-Sentinel-$RUN!"
S_NOTE="Note-Sentinel-$RUN"; S_URI="https://sentinel-$RUN.example.org/login"; S_TOTP="JBSWY3DPEHPK3PXP$(printf %s $RUN | tr 0-9 A-HJK)"

worker-build --release --locked >/dev/null
printf 'JWT_SECRET=%s\nJWT_REFRESH_SECRET=%s\nALLOWED_EMAILS=*\n' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" > .dev.vars
rm -rf .wrangler/state; mkdir -p public/web-vault
# prebuilt above (skip the cargo hook); the test talks to the backend directly (entry.js), without the gw internal key
sed -e '/^\[build\]/,/^command/d' -e 's|^main = "src/private.js"|main = "src/entry.js"|' wrangler.toml > wrangler.test.toml
for f in sql/schema.sql migrations/0015_api_key.sql migrations/0016_family.sql; do
  D1_DATABASE_ID=00000000-0000-0000-0000-000000000000 npx -y wrangler@4 d1 execute vault1 -c wrangler.test.toml --local --file "$f" >/dev/null 2>&1
done
D1_DATABASE_ID=00000000-0000-0000-0000-000000000000 npx -y wrangler@4 dev -c wrangler.test.toml --local --port 48787 >"$W/dev.log" 2>&1 &
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost -addext subjectAltName=IP:127.0.0.1 -keyout "$W/k.pem" -out "$W/c.pem" 2>/dev/null
export NODE_EXTRA_CA_CERTS="$W/c.pem"
node test/wire-proxy.mjs 48788 http://127.0.0.1:48787 "$W/wire.log" "$W/k.pem" "$W/c.pem" &
for i in $(seq 60); do curl -sf -o /dev/null http://127.0.0.1:48787/api/alive && break; sleep 1; done

node test/register.mjs https://127.0.0.1:48788 "$EMAIL" "$MASTER"
export BITWARDENCLI_APPDATA_DIR="$W/bw"
bw config server https://127.0.0.1:48788 >/dev/null
export BW_SESSION=$(bw login "$EMAIL" "$MASTER" --raw)
ITEM=$(bw get template item | jq -c --arg n "$S_NAME" --arg u "$S_USER" --arg p "$S_PASS" --arg no "$S_NOTE" --arg uri "$S_URI" --arg t "$S_TOTP" \
  '.name=$n | .notes=$no | .login={username:$u,password:$p,totp:$t,uris:[{match:null,uri:$uri}]}')
ID=$(echo "$ITEM" | bw encode | bw create item | jq -r .id)
bw sync >/dev/null
BACK=$(bw get item "$ID" | jq -r '[.name,.login.username,.login.password,.notes,.login.uris[0].uri,.login.totp]|join("|")')
WANT="$S_NAME|$S_USER|$S_PASS|$S_NOTE|$S_URI|$S_TOTP"
[ "$BACK" = "$WANT" ] && echo "client round trip: ok (the client decrypts what it stored)" || { echo "client round trip FAILED: $BACK"; exit 1; }
# 변형 축: a free account (no AZET licence) is told every item may show TOTP codes (organizationUseTotp), which
# opens the autofill/copy gates in the clients; the item view gate is patched in clients/ (see clients/patches).
SYNC_TOTP=$(grep -a -o '"organizationUseTotp":[a-z]*' "$W/wire.log" | sort | uniq -c | tr -s ' '); echo "sync says:$SYNC_TOTP"
echo "$SYNC_TOTP" | grep -q '"organizationUseTotp":true' && ! echo "$SYNC_TOTP" | grep -q ':false' || { echo "FAIL: free plan not given TOTP"; exit 1; }
bw logout >/dev/null

DB=$(find .wrangler/state/v3/d1 -name '*.sqlite' ! -name metadata.sqlite | head -1)
sqlite3 "$DB" "PRAGMA wal_checkpoint(FULL);" >/dev/null 2>&1 || true
echo "wire log: $(wc -c <"$W/wire.log") bytes, $(grep -c '^>>> ' "$W/wire.log") requests; D1 file: $DB"
echo "stored cipher fields start with: $(sqlite3 "$DB" "select substr(json_extract(data,'$.name'),1,2)||' '||substr(json_extract(data,'$.login.password'),1,2) from ciphers limit 1")"
fail=0
# positive control: what the server is meant to see (the email) must be found, or the search itself is broken
pw=$(grep -c -F -- "$EMAIL" "$W/wire.log" || true); pd=$(cat .wrangler/state/v3/d1/*/* | grep -a -c -F -- "$EMAIL" || true)
printf '%-44s wire=%s d1=%s (control, must be >0)\n' "$EMAIL" "$pw" "$pd"; [ "$pw" -gt 0 ] && [ "$pd" -gt 0 ] || fail=1
for s in "$MASTER" "$S_NAME" "$S_USER" "$S_PASS" "$S_NOTE" "$S_URI" "sentinel-$RUN.example.org" "$S_TOTP"; do
  w=$(grep -c -F -- "$s" "$W/wire.log" || true); d=$(cat .wrangler/state/v3/d1/*/* 2>/dev/null | grep -a -c -F -- "$s" || true)
  printf '%-44s wire=%s d1=%s\n' "$s" "$w" "$d"; [ "$w$d" = "00" ] || fail=1
done
[ $fail = 0 ] && echo "PASS: no plaintext reached the server" || { echo "FAIL: plaintext reached the server"; exit 1; }

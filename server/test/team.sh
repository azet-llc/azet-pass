#!/usr/bin/env bash
# Team sharing with an AI agent account, end to end on a local Worker: scripts/team.mjs makes the team and moves the
# team key (wrapped), the official Bitwarden CLI (`bw`) writes a shared item as the owner and reads it as the agent.
# A read-only agent cannot change it, a wrong fingerprint shares nothing, seats are enforced, and neither the wire
# log nor the D1 files contain any secret the test used. Any hit fails.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH
W=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
RUN=$RANDOM$RANDOM
OWNER="team-owner-$RUN@example.com"; AGENT="team-agent-$RUN@example.com"; OUT="team-outsider-$RUN@example.com"
PW_O="Owner-Sentinel-$RUN-pw"; PW_A="Agent-Sentinel-$RUN-pw"; PW_X="Out-Sentinel-$RUN-pw"
S_NAME="Deploy-Key-Sentinel-$RUN"; S_USER="deploy-sentinel-$RUN"; S_PASS="Team-Secret-Sentinel-$RUN!"

worker-build --release --locked >/dev/null
printf 'JWT_SECRET=%s\nJWT_REFRESH_SECRET=%s\nALLOWED_EMAILS=*\nTEAM_OWNERS=%s\n' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" "someone@example.com, $OWNER" > .dev.vars
rm -rf .wrangler/state; mkdir -p public/web-vault
sed -e '/^\[build\]/,/^command/d' -e 's|^main = "src/private.js"|main = "src/entry.js"|' -e 's|simple = { limit = 5, period = 60 }|simple = { limit = 1000, period = 60 }|' wrangler.toml > wrangler.test.toml
for f in sql/schema.sql migrations/001[5-9]_*.sql; do
  D1_DATABASE_ID=00000000-0000-0000-0000-000000000000 npx -y wrangler@4 d1 execute vault1 -c wrangler.test.toml --local --file "$f" >/dev/null 2>&1
done
D1_DATABASE_ID=00000000-0000-0000-0000-000000000000 npx -y wrangler@4 dev -c wrangler.test.toml --local --port 48807 >"$W/dev.log" 2>&1 &
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost -addext subjectAltName=IP:127.0.0.1 -keyout "$W/k.pem" -out "$W/c.pem" 2>/dev/null
export NODE_EXTRA_CA_CERTS="$W/c.pem"
node test/wire-proxy.mjs 48808 http://127.0.0.1:48807 "$W/wire.log" "$W/k.pem" "$W/c.pem" &
for i in $(seq 60); do curl -sf -o /dev/null http://127.0.0.1:48807/api/alive && break; sleep 1; done
URL=https://127.0.0.1:48808
team() { local e=$1 p=$2; shift 2; AZET_PASS_URL=$URL AZET_PASS_EMAIL=$e AZET_PASS_PASSWORD=$p node scripts/team.mjs "$@"; }
no() { if "$@" >"$W/no.out" 2>&1; then echo "FAIL: expected a refusal: $*"; cat "$W/no.out"; exit 1; fi; }

node test/register.mjs $URL "$OWNER" "$PW_O"; node test/register.mjs $URL "$OUT" "$PW_X"
# 1 only a listed organizer gets team seats
no team "$OUT" "$PW_X" create "Outsider team" 12
T=$(team "$OWNER" "$PW_O" create "AZET team" 7); ORG=$(jq -r .org <<<"$T"); VAULT=$(jq -r .vault <<<"$T")
[ "$(jq -r .seats <<<"$T")" = 7 ] && echo "1 team of 7 seats, outsider refused: ok"

# 2 the agent account joins from the invite (it did not exist before), read-only
INV=$(team "$OWNER" "$PW_O" invite "$ORG" "$AGENT" --read-only --agent --days 30 --name "Deploy agent")
MID=$(jq -r .member <<<"$INV"); TOK=$(jq -r .token <<<"$INV")
no team "$OUT" "$PW_X" join "$ORG" "$MID" "$TOK"
FP=$(team "$AGENT" "$PW_A" join "$ORG" "$MID" "$TOK" | jq -r .fingerprint)
no team "$OWNER" "$PW_O" confirm "$ORG" "$AGENT" "00000-00000-00000-00000"
grep -q "Fingerprint mismatch" "$W/no.out"
team "$OWNER" "$PW_O" confirm "$ORG" "$AGENT" "$FP" >/dev/null
[ "$(team "$OWNER" "$PW_O" members "$ORG" | jq -r --arg e "$AGENT" '.[]|select(.email==$e)|.status')" = confirmed ] && echo "2 invite → join → fingerprint → confirm: ok"

# 3 the owner writes a shared item with the official CLI
export BITWARDENCLI_APPDATA_DIR="$W/bw-owner"
bw config server $URL >/dev/null
export BW_SESSION=$(bw login "$OWNER" "$PW_O" --raw)
ITEM=$(bw get template item | jq -c --arg n "$S_NAME" --arg u "$S_USER" --arg p "$S_PASS" --arg o "$ORG" --arg v "$VAULT" \
  '.name=$n | .notes=null | .organizationId=$o | .collectionIds=[$v] | .login={username:$u,password:$p,totp:null,uris:[]}')
ID=$(echo "$ITEM" | bw encode | bw create item | jq -r .id)
bw logout >/dev/null; unset BW_SESSION
echo "3 owner stored a team item with bw: ok"

# 4 the agent reads it with the official CLI, and cannot change it
export BITWARDENCLI_APPDATA_DIR="$W/bw-agent"
bw config server $URL >/dev/null
export BW_SESSION=$(BW_PASSWORD=$PW_A bw login "$AGENT" --passwordenv BW_PASSWORD --raw)
GOT=$(bw get item "$ID" | jq -r '[.name,.login.username,.login.password]|join("|")')
[ "$GOT" = "$S_NAME|$S_USER|$S_PASS" ] && echo "4 agent decrypts the team item with bw: ok" || { echo "FAIL: agent read $GOT"; exit 1; }
no bash -c "bw get item $ID | jq '.login.password=\"changed\"' | bw encode | bw edit item $ID"
bw sync >/dev/null
[ "$(bw get item "$ID" | jq -r .login.password)" = "$S_PASS" ] && echo "4b read-only agent cannot change it: ok" || { echo "FAIL: read-only item changed"; exit 1; }
bw logout >/dev/null; unset BW_SESSION

# 4c what the agent read is in the access log, and the log checks out
DBF() { find .wrangler/state/v3/d1 -name '*.sqlite' ! -name metadata.sqlite | head -1; }
L=$(team "$OWNER" "$PW_O" log "$ORG")
[ "$(jq -r .verified <<<"$L")" = true ] && [ "$(jq -r .last7days.read <<<"$L")" -ge 1 ] && [ "$(jq -r '[.events[]|select(.kind=="read" and .who=="Deploy agent")]|length' <<<"$L")" -ge 1 ] \
  && echo "4c agent reads are in the access log, verified: ok" || { echo "FAIL: access log $L"; exit 1; }
# 4d a row removed on the server is noticed
sqlite3 "$(DBF)" "DELETE FROM org_events WHERE seq = (SELECT MIN(seq) + 1 FROM org_events);"
no team "$OWNER" "$PW_O" log "$ORG"
grep -q "ACCESS LOG CHANGED" "$W/no.out" && echo "4d a removed log row is detected: ok"
# 4e access that has run out gives the agent nothing; extending it gives the items back
sqlite3 "$(DBF)" "UPDATE org_members SET access_until = '2020-01-01T00:00:00.000Z' WHERE email = '$AGENT';"
export BITWARDENCLI_APPDATA_DIR="$W/bw-agent2"
bw config server $URL >/dev/null
export BW_SESSION=$(BW_PASSWORD=$PW_A bw login "$AGENT" --passwordenv BW_PASSWORD --raw)
[ "$(bw list items | jq length)" = 0 ] && echo "4e expired access: the agent gets no items: ok" || { echo "FAIL: expired agent still reads"; exit 1; }
team "$OWNER" "$PW_O" access "$ORG" "$AGENT" 30 >/dev/null
bw sync >/dev/null
[ "$(bw list items | jq length)" = 1 ] && echo "4f access extended 30 days: the item is back: ok" || { echo "FAIL: extended agent reads nothing"; exit 1; }
team "$OWNER" "$PW_O" access "$ORG" "$AGENT" off >/dev/null
bw sync >/dev/null
[ "$(bw list items | jq length)" = 0 ] && echo "4g access turned off: nothing again: ok" || { echo "FAIL: suspended agent still reads"; exit 1; }
team "$OWNER" "$PW_O" access "$ORG" "$AGENT" on >/dev/null
# 4h the refused change in 4b left no "write" record; once the agent may edit, its change is recorded
[ "$(sqlite3 "$(DBF)" "SELECT COUNT(*) FROM org_events WHERE kind = 'write'")" = 0 ] || { echo "FAIL: refused write was logged"; exit 1; }
sqlite3 "$(DBF)" "UPDATE collection_members SET read_only = 0 WHERE member_id = (SELECT id FROM org_members WHERE email = '$AGENT');"
bw sync >/dev/null
bw get item "$ID" | jq '.notes="rotated"' | bw encode | bw edit item "$ID" >/dev/null
[ "$(sqlite3 "$(DBF)" "SELECT COUNT(*) FROM org_events WHERE kind = 'write' AND cipher_id = '$ID'")" = 1 ] && echo "4h an editing agent's change is in the log: ok" || { echo "FAIL: agent write not logged"; exit 1; }
bw logout >/dev/null; unset BW_SESSION

# 5 the outsider sees nothing
export BITWARDENCLI_APPDATA_DIR="$W/bw-out"
bw config server $URL >/dev/null
export BW_SESSION=$(bw login "$OUT" "$PW_X" --raw)
[ "$(bw list items | jq length)" = 0 ] && echo "5 outsider sees no items: ok" || { echo "FAIL: outsider sees items"; exit 1; }
bw logout >/dev/null; unset BW_SESSION

# 6 seats: owner + agent + 5 more = 7, the 8th is refused
for n in 1 2 3 4 5; do team "$OWNER" "$PW_O" invite "$ORG" "team-m$n-$RUN@example.com" >/dev/null; done
no team "$OWNER" "$PW_O" invite "$ORG" "team-m6-$RUN@example.com"
grep -q "7 seats" "$W/no.out" && echo "6 seven seats enforced: ok"

DB=$(find .wrangler/state/v3/d1 -name '*.sqlite' ! -name metadata.sqlite | head -1)
sqlite3 "$DB" "PRAGMA wal_checkpoint(FULL);" >/dev/null 2>&1 || true
fail=0
pw=$(grep -c -F -- "$AGENT" "$W/wire.log" || true); pd=$(cat .wrangler/state/v3/d1/*/* | grep -a -c -F -- "$AGENT" || true)
printf '%-44s wire=%s d1=%s (control, must be >0)\n' "$AGENT" "$pw" "$pd"; [ "$pw" -gt 0 ] && [ "$pd" -gt 0 ] || fail=1
for s in "$PW_O" "$PW_A" "$S_NAME" "$S_USER" "$S_PASS"; do
  w=$(grep -c -F -- "$s" "$W/wire.log" || true); d=$(cat .wrangler/state/v3/d1/*/* 2>/dev/null | grep -a -c -F -- "$s" || true)
  printf '%-44s wire=%s d1=%s\n' "$s" "$w" "$d"; [ "$w$d" = "00" ] || fail=1
done
[ $fail = 0 ] && echo "PASS: team sharing with an agent account, no plaintext reached the server" || { echo "FAIL: plaintext reached the server"; exit 1; }

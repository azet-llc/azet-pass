#!/usr/bin/env bash
# The team page (gw/team.html) changing a shared vault's key, in a real (headless) browser against a local Worker:
# the organizer removes a member with two taps and the page changes the key; a member leaves on their own and the
# key is changed the next time the organizer opens the page. After each change the member who stayed reads the
# shared item with the new key, and the key the one who is gone held opens nothing in the database.
# Needs Playwright: PLAYWRIGHT=<folder of the playwright package> (default: the AZET Desktop work tree's copy) and
# CHROME=<headless browser binary> (default: the newest one in Playwright's cache).
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH
PLAYWRIGHT=${PLAYWRIGHT:-$HOME/Code/_work/azet-desktop-pass/node_modules/playwright}
export CHROME=${CHROME:-$(ls -d "$HOME"/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-mac-arm64/chrome-headless-shell 2>/dev/null | tail -1)}
W=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
RUN=$RANDOM$RANDOM; PORT=48817; URL=http://127.0.0.1:$PORT
OWNER="page-owner-$RUN@example.com"; STAYS="page-stays-$RUN@example.com"; GONE="page-gone-$RUN@example.com"; LEFT="page-left-$RUN@example.com"
PW_O="Owner-$RUN-pw-long"; PW_S="Stays-$RUN-pw-long"; PW_G="Gone-$RUN-pw-long"; PW_L="Left-$RUN-pw-long"
S_NAME="Page-Item-$RUN"; S_PASS="Page-Secret-$RUN!"

worker-build --release --locked >/dev/null
printf 'JWT_SECRET=%s\nJWT_REFRESH_SECRET=%s\nALLOWED_EMAILS=*\nTEAM_OWNERS=%s\n' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" "$OWNER" > .dev.vars
rm -rf .wrangler/state; mkdir -p public/web-vault
sed -e '/^\[build\]/,/^command/d' -e 's|^main = "src/private.js"|main = "src/entry.js"|' -e 's|simple = { limit = 5, period = 60 }|simple = { limit = 1000, period = 60 }|' wrangler.toml > wrangler.test.toml
for f in sql/schema.sql migrations/001[5-9]_*.sql; do
  D1_DATABASE_ID=00000000-0000-0000-0000-000000000000 npx -y wrangler@4 d1 execute vault1 -c wrangler.test.toml --local --file "$f" >/dev/null 2>&1
done
D1_DATABASE_ID=00000000-0000-0000-0000-000000000000 npx -y wrangler@4 dev -c wrangler.test.toml --local --port $PORT >"$W/dev.log" 2>&1 &
for i in $(seq 60); do curl -sf -o /dev/null $URL/api/alive && break; sleep 1; done
team() { local e=$1 p=$2; shift 2; AZET_PASS_URL=$URL AZET_PASS_EMAIL=$e AZET_PASS_PASSWORD=$p node scripts/team.mjs "$@"; }
old() { local e=$1 p=$2; shift 2; AZET_PASS_URL=$URL AZET_PASS_EMAIL=$e AZET_PASS_PASSWORD=$p node test/old-key.mjs "$@"; }
page() { nodock node test/team-page.mjs $URL "$PLAYWRIGHT" "$OWNER" "$PW_O" "$@"; }
DBF() { find .wrangler/state/v3/d1 -name '*.sqlite' ! -name metadata.sqlite | head -1; }
gen() { sqlite3 "$(DBF)" "SELECT key_gen || ' ' || rotate_due FROM organizations WHERE id = '$ORG'"; }
probe() { sqlite3 "$(DBF)" "SELECT COALESCE(json_extract(data, '$.key'), json_extract(data, '$.name')) FROM ciphers WHERE id = '$ID'"; }

node test/register.mjs $URL "$OWNER" "$PW_O"
T=$(team "$OWNER" "$PW_O" create "Page team" 7); ORG=$(jq -r .org <<<"$T"); VAULT=$(jq -r .vault <<<"$T")
for who in "$STAYS $PW_S" "$GONE $PW_G" "$LEFT $PW_L"; do
  set -- $who
  I=$(team "$OWNER" "$PW_O" invite "$ORG" "$1")
  FP=$(team "$1" "$2" join "$ORG" "$(jq -r .member <<<"$I")" "$(jq -r .token <<<"$I")" | jq -r .fingerprint)
  team "$OWNER" "$PW_O" confirm "$ORG" "$1" "$FP" >/dev/null
done
# the organizer's item in the shared vault
ID=$(old "$OWNER" "$PW_O" item "$ORG" "$VAULT" "$S_NAME" "$S_PASS")
K_GONE=$(old "$GONE" "$PW_G" key "$ORG"); K_LEFT=$(old "$LEFT" "$PW_L" key "$ORG")
node test/old-key.mjs opens "$K_GONE" "$(probe)" || { echo "FAIL: the member's key does not open the item before the change"; exit 1; }

# 1 two taps on the page: removed, and the key changed
SAID=$(page remove "$GONE") || { echo "FAIL: the page did not remove the member: $SAID"; exit 1; }
[ "$SAID" = "Removed, and the vault key was changed." ] && [ "$(gen)" = "2 0" ] && ! node test/old-key.mjs opens "$K_GONE" "$(probe)" \
  && [ "$(sqlite3 "$(DBF)" "SELECT COUNT(*) FROM org_members WHERE org_id = '$ORG' AND status = 2 AND akey IS NOT NULL")" = 3 ] \
  && echo "1 removed on the page: the key was changed, the old key opens nothing, the three who stay keep theirs: ok" || { echo "FAIL: after the page removed a member: said '$SAID', generation $(gen)"; exit 1; }
[ "$(old "$STAYS" "$PW_S" key "$ORG" | wc -c)" -gt 80 ] && node test/old-key.mjs opens "$(old "$STAYS" "$PW_S" key "$ORG")" "$(probe)" \
  && echo "1b the member who stayed opens the item with the new key: ok" || { echo "FAIL: the member who stayed cannot open the item"; exit 1; }

# 2 a member leaves on their own: the key change is due, and is done when the organizer opens the page
curl -sf -X POST "$URL/api/organizations/$ORG/leave" -H "authorization: Bearer $(old "$LEFT" "$PW_L" token)" >/dev/null
[ "$(gen)" = "2 1" ] || { echo "FAIL: leaving did not mark the key change as due: $(gen)"; exit 1; }
page open >/dev/null || { echo "FAIL: the page did not open"; exit 1; }
[ "$(gen)" = "3 0" ] && ! node test/old-key.mjs opens "$K_LEFT" "$(probe)" && node test/old-key.mjs opens "$(old "$STAYS" "$PW_S" key "$ORG")" "$(probe)" \
  && echo "2 a member left: the key was changed when the organizer opened the page, and the one who stayed still opens the item: ok" || { echo "FAIL: after a member left: generation $(gen)"; exit 1; }
echo "PASS: the team page changes the vault key when a member is removed or leaves"

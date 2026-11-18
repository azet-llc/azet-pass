#!/usr/bin/env bash
# The same check as e2ee.sh against production (https://pass.azet.io): the official `bw` CLI stores an item,
# the wire log is recorded client-side, then the production D1 is exported and searched. The test account is deleted after.
set -euo pipefail
cd "$(dirname "$0")/.."
W=$(mktemp -d); RUN=$RANDOM$RANDOM; B=https://pass.azet.io
trap 'rm -rf "$W"' EXIT # the export holds every account's (encrypted) rows: it does not outlive the run
EMAIL="e2ee-live-$RUN@example.com"; MASTER="Master-Sentinel-$RUN-pw"
S=("ItemName-Sentinel-$RUN" "user-sentinel-$RUN" "Secret-Sentinel-$RUN!" "Note-Sentinel-$RUN" "sentinel-$RUN.example.org" "JBSWY3DPEHPK3PXP$RUN")
# Sign-up needs the emailed token; the test mints one with the production secret from the key vault (never printed).
JWT_SECRET="$(tkt get AZET_PASS_JWT_SECRET)" node test/register.mjs $B "$EMAIL" "$MASTER" 2>&1
export BITWARDENCLI_APPDATA_DIR="$W/bw"
bw config server $B >/dev/null 2>&1
export BW_SESSION=$(bw login "$EMAIL" "$MASTER" --raw 2>/dev/null)
ID=$(bw get template item 2>/dev/null | jq -c --arg n "${S[0]}" --arg u "${S[1]}" --arg p "${S[2]}" --arg no "${S[3]}" --arg uri "https://${S[4]}/login" --arg t "${S[5]}" \
  '.name=$n | .notes=$no | .login={username:$u,password:$p,totp:$t,uris:[{match:null,uri:$uri}]}' | bw encode | bw create item 2>/dev/null | jq -r .id)
bw sync >/dev/null 2>&1
echo "client round trip: $(bw get item "$ID" 2>/dev/null | jq -r '[.name,.login.password]|join(" ")')"
npx wrangler d1 export azet-pass -c wrangler.deploy.toml --remote --output "$W/d1.sql" >/dev/null 2>&1
echo "production D1 export: $(wc -c <"$W/d1.sql") bytes; account row present: $(grep -c -F "$EMAIL" "$W/d1.sql")"
fail=0
for s in "$MASTER" "${S[@]}"; do n=$(grep -c -F -- "$s" "$W/d1.sql" || true); printf '%-40s d1=%s\n' "$s" "$n"; [ "$n" = 0 ] || fail=1; done
bw delete item "$ID" --permanent >/dev/null 2>&1 || true
npx wrangler d1 execute azet-pass -c wrangler.deploy.toml --remote --command "DELETE FROM ciphers WHERE user_id=(SELECT id FROM users WHERE email='$EMAIL'); DELETE FROM devices WHERE user_id=(SELECT id FROM users WHERE email='$EMAIL'); DELETE FROM users WHERE email='$EMAIL';" >/dev/null 2>&1 && echo "test account removed"
[ $fail = 0 ] && echo "PASS: production stores no plaintext" || { echo FAIL; exit 1; }

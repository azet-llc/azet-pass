#!/usr/bin/env bash
# Can production hold a whole key store? A throwaway account imports N made-up keys (default 4200, the size of the
# largest .env file we keep) through the desktop CLI, reads them back by name, writes a linked .env file, and is
# deleted afterwards. Times and counts only; every value here is made up.
# usage: scale-live.sh [N]    needs: bw, ~/Code/_work/azet-desktop-pass/out/cli/index.js (or AZET_DESKTOP_CLI), tkt
set -euo pipefail
cd "$(dirname "$0")/.."
N=${1:-4200}; W=$(mktemp -d); RUN=$RANDOM$RANDOM; B=https://pass.azet.io
EMAIL="scale-live-$RUN@example.com"; MASTER="Scale-$RUN-$(openssl rand -hex 8)"
cleanup() {
  npx wrangler d1 execute azet-pass -c wrangler.deploy.toml --remote --command "DELETE FROM ciphers WHERE user_id=(SELECT id FROM users WHERE email='$EMAIL'); DELETE FROM devices WHERE user_id=(SELECT id FROM users WHERE email='$EMAIL'); DELETE FROM users WHERE email='$EMAIL';" >/dev/null 2>&1 && echo "test account removed" || echo "CLEANUP FAILED for $EMAIL"
  rm -rf "$W"
}
trap cleanup EXIT
JWT_SECRET="$(tkt get AZET_PASS_JWT_SECRET)" node test/register.mjs $B "$EMAIL" "$MASTER" >/dev/null 2>&1
UD="$W/ud"; P="$UD/azet-pass"; mkdir -p "$P/data"
export BITWARDENCLI_APPDATA_DIR="$P/data"; bw config server $B >/dev/null 2>&1
MASTER="$MASTER" bw login "$EMAIL" --passwordenv MASTER --raw 2>/dev/null > "$P/session"; chmod 600 "$P/session"
unset BITWARDENCLI_APPDATA_DIR
export AZET_DESKTOP_USER_DATA_PATH="$UD"
CLI() { node "${AZET_DESKTOP_CLI:-$HOME/Code/_work/azet-desktop-pass/out/cli/index.js}" pass "$@"; }
t() { local s=$SECONDS; "$@"; echo "  ($((SECONDS - s))s)"; }
for i in $(seq 1 "$N"); do printf 'SCALE_KEY_%05d=v-%s-%05d-%s\n' "$i" "$RUN" "$i" "abcdefghijklmnopqrstuvwxyz0123456789"; done > "$W/in.env"
echo "== import $N keys"; t CLI import --file "$W/in.env"
echo "== import again (nothing should change)"; t CLI import --file "$W/in.env"
echo "== list"; s=$SECONDS; C=$(CLI list --kind key | wc -l | tr -d ' '); echo "listed $C  ($((SECONDS - s))s)"
echo "== get the first, a middle and the last by name"
ok=0; for i in 1 $((N / 2)) "$N"; do k=$(printf 'SCALE_KEY_%05d' "$i"); [ "$(CLI get --name "$k")" = "$(grep "^$k=" "$W/in.env" | cut -d= -f2-)" ] && ok=$((ok + 1)); done; echo "matched $ok of 3"
echo "== run with every key"; s=$SECONDS; R=$(CLI run --command 'env | grep -c "^SCALE_KEY_"'); echo "the program saw $R  ($((SECONDS - s))s)"
echo "== a second device signs in and sees them"; export BITWARDENCLI_APPDATA_DIR="$W/bw2"; bw config server $B >/dev/null 2>&1
S2=$(MASTER="$MASTER" bw login "$EMAIL" --passwordenv MASTER --raw 2>/dev/null); D2=$(BW_SESSION="$S2" bw list items 2>/dev/null | jq length); echo "second device holds $D2"
[ "$C" = "$N" ] && [ "$ok" = 3 ] && [ "$R" = "$N" ] && [ "$D2" = "$N" ] && echo "SCALE RESULT: ok ($N keys)" || { echo "SCALE RESULT: FAIL"; exit 1; }

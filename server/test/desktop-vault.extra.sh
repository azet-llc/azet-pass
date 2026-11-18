# sourced inside the server's e2ee test after the dummy account is signed in ($W, $BW_SESSION, bw data in $W/bw)
set +e
UD="$W/ud"; P="$UD/azet-pass"; mkdir -p "$P"; ln -s "$W/bw" "$P/data"; printf %s "$BW_SESSION" > "$P/session"; chmod 600 "$P/session"
export AZET_DESKTOP_USER_DATA_PATH="$UD"
CLI() { node "${AZET_DESKTOP_CLI:-$HOME/Code/_work/azet-desktop-pass/out/cli/index.js}" pass "$@"; }
K1="sk-e2e-AAAA-$RUN"; K1B="sk-e2e-BBBB-$RUN"; K2="sk-e2e-CCCC-$RUN"; DB="postgres://u:p w@h/db-$RUN"
ok() { echo "  [ok] $1"; }; bad() { echo "  [FAIL] $1"; FAILS=$((FAILS+1)); }; FAILS=0
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "== 1 status"; S=$(CLI status); chk "status unlocked" '[ "$S" = "AZET Pass: unlocked" ]'
echo "== 2 set (value by stdin)"; O=$(printf %s "$K1" | CLI set --name API_KEY --value-file -); chk "set added ($O)" '[ "$O" = "API_KEY: added" ]'
echo "== 3 import .env"; printf 'API_KEY=%s\nexport API_KEY_2=%s\nDB_URL="%s"\n# c\nEMPTY=\n' "$K1B" "$K2" "$DB" > "$W/in.env"
O=$(CLI import --file "$W/in.env"); chk "import counts ($O)" '[ "$O" = "added 2 · changed 1 · already the same 0" ]'
O=$(CLI import --file "$W/in.env"); chk "second import ($O)" '[ "$O" = "added 0 · changed 0 · already the same 3" ]'
echo "== 4 list (names only)"; L=$(CLI list --kind key); echo "$L" | sed 's/^/    /'
chk "list has 3 keys" '[ "$(echo "$L" | wc -l | tr -d " ")" = 3 ]'
ALL=$(CLI list --json); chk "list carries no value" '! echo "$L$ALL" | grep -q -e "sk-e2e" -e "postgres://"'
echo "== 5 run (injected, hidden in output, absent from argv)"
O=$(CLI run --keys API_KEY,DB_URL --command 'echo "key=$API_KEY len=${#API_KEY} db=$DB_URL other=${API_KEY_2:-unset}"; ps -o args= -p $$; exit 7' 2>&1); RC=$?
echo "$O" | sed 's/^/    /'
chk "child got the key (length ${#K1B})" 'echo "$O" | grep -q "len=${#K1B} "'
chk "values hidden in output" '! echo "$O" | grep -q -e "sk-e2e" -e "postgres://"; echo "$O" | grep -q "key=(hidden)"'
chk "only named keys injected" 'echo "$O" | grep -q "other=unset"'
chk "exit code is the command's (7)" '[ $RC = 7 ]'
O=$(CLI run --keys NOPE --command true 2>&1); chk "unknown key refused" 'echo "$O" | grep -q "no key named NOPE"'
echo "== 6 link + sync"; CLI link add --file "$W/proj.env" --var STRIPE --name API_KEY >/dev/null; CLI link add --file "$W/proj.env" --var DB_URL >/dev/null
O=$(CLI sync --check); chk "check writes nothing" '[ ! -e "$W/proj.env" ] && echo "$O" | grep -q "would write"'
CLI sync >/dev/null; chk "file has the values" 'grep -qx "STRIPE=$K1B" "$W/proj.env" && grep -q "^DB_URL=\"postgres" "$W/proj.env"'
chk "file is private (600)" '[ "$(stat -f %Lp "$W/proj.env")" = 600 ]'
O=$(CLI sync); chk "second sync is same" '! echo "$O" | grep -q written'
echo "== 7 browser reference through the reader script"
cat > "$P/read" <<R
#!/bin/sh
D='$P'
[ -f "\$D/session" ] || { if [ -f "\$D/session.sealed" ]; then echo 'AZET Pass is locked: run \`azet-desktop pass unlock\` and approve it on the computer' >&2; else echo 'AZET Pass is not signed in' >&2; fi; exit 1; }
export BITWARDENCLI_APPDATA_DIR="\$D/data" BW_SESSION="\$(cat "\$D/session")"
[ "\$1" = list ] && exec bw list items --search "\$2"
exec bw get "\$@"
R
chmod 700 "$P/read"
bw get template item | jq -c '.type=3|.name="e2e card"|.login=null|.card={cardholderName:"H",brand:"Visa",number:"4111111111111111",expMonth:"12",expYear:"2030",code:"987"}' | bw encode | bw create item >/dev/null
bw get template item | jq -c '.type=4|.name="e2e me"|.login=null|.identity={firstName:"F",ssn:"900101-1234567",phone:"010-1234-5678"}' | bw encode | bw create item >/dev/null
REF() { AZET_BROWSER_SECRET_CMD="$P/read" REF="$1" node "$(dirname "$EXTRA")/desktop-vault.ref.mjs"; }
chk "key by name (also a prefix of API_KEY_2)" '[ "$(REF "{{azet-pass:key:API_KEY}}")" = "$K1B" ]'
chk "card number" '[ "$(REF "{{azet-pass:card.number:e2e card}}")" = 4111111111111111 ]'
chk "card code" '[ "$(REF "{{azet-pass:card.code:e2e card}}")" = 987 ]'
chk "identity ssn" '[ "$(REF "{{azet-pass:identity.ssn:e2e me}}")" = 900101-1234567 ]'
chk "identity phone" '[ "$(REF "{{azet-pass:identity.phone:e2e me}}")" = 010-1234-5678 ]'
chk "login password (old path)" '[ "$(REF "{{azet-pass:password:$S_NAME}}")" = "$S_PASS" ]'
L=$(CLI list); chk "list shows card and identity kinds" 'echo "$L" | grep -q "^card *e2e card" && echo "$L" | grep -q "^identity *e2e me"'
echo "== 7b get (the pipe form scripts use, as with a key vault CLI)"
chk "get in a command substitution" '[ "$(CLI get --name API_KEY)" = "$K1B" ]'
chk "get of an unknown name fails and prints nothing" '! O=$(CLI get --name NOT_THERE 2>/dev/null) && [ -z "$O" ]'
echo "== 8 rm"; CLI rm --name API_KEY_2 >/dev/null; L=$(CLI list --kind key); chk "removed" '! echo "$L" | grep -q API_KEY_2'
echo "== 9 locked"; mv "$P/session" "$P/session.sealed"
O=$(CLI list 2>&1); chk "CLI says locked" 'echo "$O" | grep -q "AZET Pass is locked"'
chk "browser reference says locked" 'REF "{{azet-pass:key:API_KEY}}" | grep -q "AZET Pass is locked"'
chk "status locked" '[ "$(CLI status)" = "AZET Pass: locked" ]'
mv "$P/session.sealed" "$P/session"
echo "== 10 server saw no plaintext"; sleep 1
for s in "$K1" "$K1B" "$K2" "db-$RUN" 4111111111111111 900101-1234567; do
  n=$(grep -c -F -- "$s" "$W/wire.log"); d=$(grep -c -a -F -- "$s" .wrangler/state/v3/d1/miniflare-D1DatabaseObject/*.sqlite* 2>/dev/null | awk -F: '{t+=$NF}END{print t+0}')
  chk "wire=$n d1=$d for ${s:0:10}…" '[ "$n" = 0 ] && [ "$d" = 0 ]'
done
chk "no import file left behind" '[ -z "$(ls "$P" | grep import-)" ]'
echo "== 13 AI agents get only what I share (the readers follow the AI account's folder)"
mkdir -p "$P/ai"; ln -s "$W/bw" "$P/ai/data"; cp "$P/session" "$P/ai/session"; mv "$P/session" "$P/session.owner"
S=$(CLI status); chk "status names the setting ($S)" '[ "$S" = "AZET Pass: unlocked (AI agents get only what the person shared)" ]'
O=$(printf x | CLI set --name NEW_BY_AGENT --value-file - 2>&1); chk "set is refused" 'echo "$O" | grep -q "only read what the person shared"'
O=$(CLI get --name NOT_GIVEN_KEY 2>&1 | cat); chk "a key that was not given says so, not unlock" 'echo "$O" | grep -q "Not shared with AI agents" && ! echo "$O" | grep -q "pass unlock"'
chk "a given key is read" '[ "$(CLI get --name API_KEY | cat)" = "$K1B" ]'
chk "links stay one list per computer" '[ -n "$(CLI link list | grep STRIPE)" ] && [ ! -e "$P/ai/links.json" ]'
rm "$P/ai/session"; O=$(CLI list 2>&1); chk "AI account signed out: says that, never falls back to the owner" 'echo "$O" | grep -q "AI account on this computer is signed out"'
rm -rf "$P/ai"; mv "$P/session.owner" "$P/session"
echo "== EXTRA RESULT: fails=$FAILS"
set -e

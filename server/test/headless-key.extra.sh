# sourced inside the e2ee test after the dummy account stored its item ($W, $EMAIL, $MASTER): the desktop CLI and the
# headless script must read and write the same keys in the same account
set +e
K=clients/../../clients/tools/azet-pass-key; K="$(cd .. && pwd)/clients/tools/azet-pass-key"
ok() { echo "  [ok] $1"; }; bad() { echo "  [FAIL] $1"; FAILS=$((FAILS+1)); }; FAILS=0
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# desktop side: the account's own folder, as desktop-vault.extra.sh sets it up
UD="$W/ud"; P="$UD/azet-pass"; mkdir -p "$P"; ln -s "$W/bw" "$P/data"; printf %s "$BW_SESSION" > "$P/session"; chmod 600 "$P/session"
CLI() { AZET_DESKTOP_USER_DATA_PATH="$UD" node "${AZET_DESKTOP_CLI:-$HOME/Code/_work/azet-desktop-pass/out/cli/index.js}" pass "$@"; }
HK() { (unset BW_SESSION; AZET_PASS_KEY_HOME="$W/headless" AZET_PASS_SERVER=https://127.0.0.1:48788 "$K" "$@"); }
V1="hk-one-$RUN"; V2="hk-two-$RUN"; V3='with "quotes" $and spaces-'"$RUN"
chk "status before" '[ "$(HK status)" = "signed out" ]'
chk "get before sign-in fails" '! HK get A >/dev/null 2>&1'
chk "signin (password on stdin)" '[ "$(printf "%s\n" "$MASTER" | HK signin "$EMAIL")" = "signed in" ]'
chk "session file is private" '[ "$(stat -f %Lp "$W/headless/session")" = 600 ]'
printf %s "$V1" | CLI set --name FROM_DESKTOP --value-file - >/dev/null; rm -f "$W/headless/synced"
chk "headless reads a key the desktop saved" '[ "$(HK get FROM_DESKTOP)" = "$V1" ]'
chk "headless set (added)" '[ "$(printf %s "$V2" | HK set FROM_HEADLESS)" = "FROM_HEADLESS: added" ]'
rm -f "$P/synced"   # each side pulls other devices' changes at most every five minutes; the test does not wait
chk "desktop reads a key the headless script saved" '[ "$(CLI get --name FROM_HEADLESS)" = "$V2" ]'
chk "headless set again (changed), odd characters kept" '[ "$(printf %s "$V3" | HK set FROM_HEADLESS)" = "FROM_HEADLESS: changed" ] && [ "$(HK get FROM_HEADLESS)" = "$V3" ]'
chk "list shows both names and no value" 'L=$(HK list); echo "$L" | grep -qx FROM_DESKTOP && echo "$L" | grep -qx FROM_HEADLESS && ! echo "$L" | grep -q "$RUN"'
chk "get of an unknown name fails" '! HK get NOT_THERE >/dev/null 2>&1'
chk "del" 'HK del FROM_DESKTOP >/dev/null && ! HK get FROM_DESKTOP >/dev/null 2>&1'
sleep 1; n=0; for s in "$V1" "$V2" "spaces-$RUN" "$MASTER"; do n=$((n + $(grep -c -F -- "$s" "$W/wire.log"))); done
chk "server saw none of the values or the password ($n)" '[ "$n" = 0 ]'
chk "signout removes the session" 'HK signout >/dev/null && [ ! -f "$W/headless/session" ]'
echo "HEADLESS RESULT: fails=$FAILS"
exit 0

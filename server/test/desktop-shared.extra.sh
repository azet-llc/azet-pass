# sourced inside team.sh after the agent account is a confirmed, read-only member of the owner's shared vault
set +e
cd "${AZET_DESKTOP_REPO:-$HOME/Code/_work/azet-desktop-pass}"
AZET_PASS_SERVER=$URL AZET_PASS_E2E_OWNER=$OWNER AZET_PASS_E2E_OWNER_PW=$PW_O AZET_PASS_E2E_AI=$AGENT AZET_PASS_E2E_AI_PW=$PW_A \
  npx vitest run src/main/host/azet-pass-shared.e2e.test.ts > "$W/shared.log" 2>&1
RC=$?
grep -E "✓|×|Tests |AssertionError|Error:|expected|received" "$W/shared.log" | head -20
# the command line itself, as an agent runs it, reading through the AI account: saving when the account may, and what it is told when it may not
cd "$OLDPWD"
UD="$W/ud2"; P="$UD/azet-pass"; mkdir -p "$P/ai/data"; export AZET_DESKTOP_USER_DATA_PATH="$UD"
CLI() { node "${AZET_DESKTOP_CLI:-$HOME/Code/_work/azet-desktop-pass/out/cli/index.js}" pass "$@"; }
BITWARDENCLI_APPDATA_DIR="$P/ai/data" bw config server $URL >/dev/null
BW_PASSWORD=$PW_A BITWARDENCLI_APPDATA_DIR="$P/ai/data" bw login "$AGENT" --passwordenv BW_PASSWORD --raw > "$P/ai/session"; chmod 600 "$P/ai/session"
F2=0; chk() { if eval "$2"; then echo "  [ok] $1"; else echo "  [FAIL] $1"; F2=$((F2+1)); fi; }
O=$(printf %s "agent-made-$RUN" | CLI set --name AGENT_MADE --value-file - 2>&1); echo "  (read-only answer: ${O:0:160})"
chk "read-only AI account: set is refused with the way out" 'echo "$O" | grep -q "may not save a key"'
O=$(CLI rm --name NO_SUCH_ITEM 2>&1); chk "a missing item still says so" 'echo "$O" | grep -q "No item is named"'
team "$OWNER" "$PW_O" access "$ORG" "$AGENT" can-edit >/dev/null; rm -f "$P/ai/synced"
O=$(printf %s "agent-made-$RUN" | CLI set --name AGENT_MADE --value-file - 2>&1); chk "allowed to edit: set saves ($O)" '[ "$O" = "AGENT_MADE: added" ]'
chk "it reads back" '[ "$(CLI get --name AGENT_MADE | cat)" = "agent-made-$RUN" ]'
export BITWARDENCLI_APPDATA_DIR="$W/bw-owner-see"; bw config server $URL >/dev/null; OS2=$(bw login "$OWNER" "$PW_O" --raw)
chk "the person sees it, in the shared vault" '[ "$(BW_SESSION=$OS2 bw list items --search AGENT_MADE | jq -r ".[0].organizationId")" = "$ORG" ]'
O=$(CLI rm --name AGENT_MADE 2>&1); chk "rm works ($O)" 'echo "$O" | grep -q "moved to the AZET Pass trash"'
team "$OWNER" "$PW_O" access "$ORG" "$AGENT" read-only >/dev/null
[ $RC = 0 ] && [ $F2 = 0 ] && grep -q "1 passed" "$W/shared.log" && echo "SHARED RESULT: ok" || { echo "SHARED RESULT: FAILED"; RC=1; }
return $RC 2>/dev/null

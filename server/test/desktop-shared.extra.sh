# sourced inside team.sh after the agent account is a confirmed, read-only member of the owner's shared vault
set +e
cd "${AZET_DESKTOP_REPO:-$HOME/Code/_work/azet-desktop-pass}"
AZET_PASS_SERVER=$URL AZET_PASS_E2E_OWNER=$OWNER AZET_PASS_E2E_OWNER_PW=$PW_O AZET_PASS_E2E_AI=$AGENT AZET_PASS_E2E_AI_PW=$PW_A \
  npx vitest run src/main/host/azet-pass-shared.e2e.test.ts > "$W/shared.log" 2>&1
RC=$?
grep -E "✓|×|Tests |AssertionError|Error:|expected|received" "$W/shared.log" | head -20
[ $RC = 0 ] && grep -q "1 passed" "$W/shared.log" && echo "SHARED RESULT: ok" || echo "SHARED RESULT: FAILED"
return $RC 2>/dev/null

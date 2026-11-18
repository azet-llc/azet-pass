#!/usr/bin/env bash
# AZET Desktop's "AI agents get only what I share" against this Worker running locally: the accounts and the shared
# vault are made as in team.sh (scripts/team.mjs), then the desktop app's own sign-in, AI-account connection, share
# and take-back run against it (src/main/host/azet-pass-shared.e2e.test.ts in ~/Code/_work/azet-desktop-pass, or
# AZET_DESKTOP_REPO). The owner's key must never be readable while the setting is on.
set -euo pipefail
cd "$(dirname "$0")/.."
awk '{print} /2 invite → join → fingerprint → confirm: ok/{print "source \"$EXTRA\""; print "exit $?"}' test/team.sh > test/.desktop-shared.tmp.sh
trap 'rm -f test/.desktop-shared.tmp.sh' EXIT
EXTRA="$PWD/test/desktop-shared.extra.sh" bash test/.desktop-shared.tmp.sh | tee /dev/stderr | grep "SHARED RESULT: ok" >/dev/null

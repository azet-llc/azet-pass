#!/usr/bin/env bash
# The web vault in server/public/web-vault against this Worker running locally: a throwaway account stores an item
# with the official CLI, then a headless browser signs in to the web vault and must see that item.
set -euo pipefail
cd "$(dirname "$0")/.."
awk 'NR==39{print; print "source \"$EXTRA\""; next}1' test/e2ee.sh > test/.webvault.tmp.sh
trap 'rm -f test/.webvault.tmp.sh' EXIT
EXTRA="$PWD/test/webvault-login.extra.sh" bash test/.webvault.tmp.sh | tee /dev/stderr | grep "WEB RESULT: item seen=ok" >/dev/null

#!/usr/bin/env bash
# rotate-password.mjs against this Worker running locally: a throwaway account stores an item, its master password is
# changed, and the official CLI must read the item back with the new password and be refused with the old one.
set -euo pipefail
cd "$(dirname "$0")/.."
awk 'NR==39{print; print "source \"$EXTRA\""; next}1' test/e2ee.sh > test/.rotate.tmp.sh
trap 'rm -f test/.rotate.tmp.sh' EXIT
EXTRA="$PWD/test/rotate-password.extra.sh" bash test/.rotate.tmp.sh | tee /dev/stderr | grep "ROTATE RESULT: item readable with the new password=ok · old password refused=ok" >/dev/null

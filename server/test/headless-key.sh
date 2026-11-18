#!/usr/bin/env bash
# clients/tools/azet-pass-key against this Worker running locally, next to the desktop CLI on the same throwaway account.
set -euo pipefail
cd "$(dirname "$0")/.."
awk 'NR==39{print; print "source \"$EXTRA\""; next}1' test/e2ee.sh > test/.headless.tmp.sh
trap 'rm -f test/.headless.tmp.sh' EXIT
EXTRA="$PWD/test/headless-key.extra.sh" bash test/.headless.tmp.sh | tee /dev/stderr | grep "HEADLESS RESULT: fails=0" >/dev/null

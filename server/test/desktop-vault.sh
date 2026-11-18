#!/usr/bin/env bash
# AZET Desktop's `pass` commands and the browser's {{azet-pass:…}} references against this Worker running locally,
# with a throwaway account: keys saved, imported, handed to a program, written to a .env file, read by name; then
# the wire log and the local D1 files are searched for every value. Needs ~/Code/_work/azet-desktop-pass (or
# AZET_DESKTOP_CLI=<out/cli/index.js>) built with `node config/scripts/cli-build/build-cli.mjs`.
set -euo pipefail
cd "$(dirname "$0")/.."
awk 'NR==39{print; print "source \"$EXTRA\""; next}1' test/e2ee.sh > test/.desktop-vault.tmp.sh
trap 'rm -f test/.desktop-vault.tmp.sh' EXIT
EXTRA="$PWD/test/desktop-vault.extra.sh" bash test/.desktop-vault.tmp.sh | tee /dev/stderr | grep "EXTRA RESULT: fails=0" >/dev/null

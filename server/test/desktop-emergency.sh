#!/usr/bin/env bash
# AZET Desktop's emergency access, new-device approval and counter codes (`pass emergency`, `pass devices approval`,
# `pass otp`) against this Worker running locally, with two throwaway accounts. Needs AZET_DESKTOP_CLI (or
# ~/Code/azet-desktop-pass2/out/cli/index.js) built with `node config/scripts/cli-build/build-cli.mjs`.
set -euo pipefail
cd "$(dirname "$0")/.."
awk 'NR==39{print; print "source \"$EXTRA\""; next}1' test/e2ee.sh > test/.desktop-emergency.tmp.sh
trap 'rm -f test/.desktop-emergency.tmp.sh' EXIT
EXTRA="$PWD/test/desktop-emergency.extra.sh" bash test/.desktop-emergency.tmp.sh | tee /dev/stderr | grep "EMERGENCY DESKTOP RESULT: fails=0" >/dev/null

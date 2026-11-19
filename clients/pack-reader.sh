#!/usr/bin/env bash
# AZET Pass reader: the official Bitwarden CLI (GPL-3.0, the OSS build), repackaged unchanged with its licence and a
# source note so the published zip meets GPL-3.0 section 6. The binary is byte-for-byte the upstream one (hash checked).
# usage: pack-reader.sh [work-dir]   -> <work-dir>/dist/pass-reader-darwin-arm64.zip  (bw + LICENSE.txt + SOURCE.txt)
# The app pins the zip by sha256 (azet-desktop READER_SHA256). The zip is NOT reproducible (ditto records mtimes), so
# its hash differs every run: pin the hash of the exact file you upload, under a NEW asset name, updating READER_URL
# and READER_SHA256 together — never clobber the live pass-reader-1 asset. See SOURCE.md + docs/APP-STORE-GPL-DECISION.md.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); . "$here/pins.env"
W=${1:-$here/../../azet-pass-work}; dist="$W/dist"; stage="$W/pass-reader"; mkdir -p "$dist"
ver=${CLI_TAG#cli-v}
asset="bw-oss-macos-arm64-$ver.zip"

rm -rf "$stage"; mkdir -p "$stage"
gh release download "$CLI_TAG" -R bitwarden/clients -p "$asset" -D "$stage" --clobber
ditto -x -k "$stage/$asset" "$stage"
got=$(shasum -a 256 "$stage/bw" | cut -d' ' -f1)
[ "$got" = "$CLI_BW_SHA256" ] || { echo "bw hash mismatch: $got != $CLI_BW_SHA256 (not the pinned OSS build)"; exit 1; }

pack="$stage/pack"; rm -rf "$pack"; mkdir -p "$pack"; mv "$stage/bw" "$pack/bw"
cp "$here/LICENSE" "$pack/LICENSE.txt"   # GPL-3.0, the CLI's licence
cat > "$pack/SOURCE.txt" <<EOF
AZET Pass reader

This folder's \`bw\` is the Bitwarden CLI, used unchanged under the GNU General Public License v3.0
(see LICENSE.txt). It is the OSS build (no bitwarden_license/ code).

Source: https://github.com/bitwarden/clients/tree/$CLI_TAG
Written offer: for three years from distribution, AZET LLC will provide the complete corresponding
source on request at hello@azet.io, at no charge beyond the cost of the medium.

Bitwarden is a trademark of Bitwarden Inc.; AZET Pass is not affiliated with or endorsed by Bitwarden Inc.
EOF

out="$dist/pass-reader-darwin-arm64.zip"; rm -f "$out"
ditto -c -k "$pack" "$out"   # no --keepParent: bw, LICENSE.txt, SOURCE.txt land at the zip root

# self-check: the app extracts with this exact ditto command and runs bin/bw
chk="$stage/check"; rm -rf "$chk"; ditto -x -k "$out" "$chk"
[ -x "$chk/bw" ] && [ "$(shasum -a 256 "$chk/bw" | cut -d' ' -f1)" = "$CLI_BW_SHA256" ] || { echo "self-check failed"; exit 1; }
[ -f "$chk/LICENSE.txt" ] && [ -f "$chk/SOURCE.txt" ] || { echo "licence/source missing from zip"; exit 1; }
echo "built $out"
echo "zip sha256: $(shasum -a 256 "$out" | cut -d' ' -f1)   # this file -> azet-desktop READER_SHA256 (differs each run; pin what you upload)"

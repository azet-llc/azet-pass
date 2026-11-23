#!/bin/sh
# Registers the AZET Pass browser helper (io.azet.pass) for AZET Browser, Chrome and Edge on this Mac.
#   sh install.sh [extra extension id …]   (the built-in AZET Browser copy's id is always allowed)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
DEST="$HOME/Library/Application Support/AZET Pass/native-host"
NODE=""
for n in "/Applications/AZET Browser.app/Contents/Resources/bin/node" /opt/homebrew/bin/node /usr/local/bin/node "$(command -v node || true)"; do
  [ -n "$n" ] && [ -x "$n" ] && { NODE="$n"; break; }
done
[ -n "$NODE" ] || { echo "no node found"; exit 1; }
mkdir -p "$DEST"; cp "$HERE/host.mjs" "$DEST/host.mjs"
printf '#!/bin/sh\nexec "%s" "%s/host.mjs" "$@"\n' "$NODE" "$DEST" > "$DEST/host.sh"; chmod 755 "$DEST/host.sh"
ORIGINS="\"chrome-extension://cbgppofpaabnaanjjmlmfgofeiclcpif/\""
for id in "$@"; do ORIGINS="$ORIGINS, \"chrome-extension://$id/\""; done
for d in "AZET Browser" "Google/Chrome" "Microsoft Edge" "Chromium"; do
  base="$HOME/Library/Application Support/$d"
  [ -d "$base" ] || continue
  mkdir -p "$base/NativeMessagingHosts"
  printf '{\n  "name": "io.azet.pass",\n  "description": "AZET Pass: unlock with Touch ID through AZET Desktop",\n  "path": "%s/host.sh",\n  "type": "stdio",\n  "allowed_origins": [%s]\n}\n' "$DEST" "$ORIGINS" > "$base/NativeMessagingHosts/io.azet.pass.json"
  echo "registered for $d"
done
# Firefox names the extension, not an origin.
FF="$HOME/Library/Application Support/Mozilla"
if [ -d "$FF" ]; then
  mkdir -p "$FF/NativeMessagingHosts"
  printf '{\n  "name": "io.azet.pass",\n  "description": "AZET Pass: unlock with Touch ID through AZET Desktop",\n  "path": "%s/host.sh",\n  "type": "stdio",\n  "allowed_extensions": ["pass@azet.io"]\n}\n' "$DEST" > "$FF/NativeMessagingHosts/io.azet.pass.json"
  echo "registered for Firefox"
fi

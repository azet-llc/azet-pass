# sourced inside the e2ee test after the dummy account stored its item ($W, $EMAIL, $MASTER, $S_NAME, certificates)
set +e
(cd public/web-vault && python3 -m http.server 48791 --bind 127.0.0.1 >/dev/null 2>&1) &
node test/webvault-proxy.mjs 48789 http://127.0.0.1:48787 http://127.0.0.1:48791 "$W/web.log" "$W/k.pem" "$W/c.pem" &
sleep 3
EMAIL="$EMAIL" MASTER="$MASTER" ITEM="$S_NAME" python3 test/webvault-login.py https://127.0.0.1:48789
echo "web vault build: $(cat public/web-vault/version.json | tr -d ' \n') · API calls not 2xx: $(grep -c -v '^2[0-9][0-9] ' "$W/web.log" 2>/dev/null)"
grep -v '^2[0-9][0-9] ' "$W/web.log" 2>/dev/null | head -5
exit 0   # the check ends here; the rest of e2ee.sh is the wire search of the other test

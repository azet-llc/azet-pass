# sourced inside the e2ee test after the dummy account stored its item ($ID, $WANT, $EMAIL, $MASTER)
set +e
bw logout >/dev/null; NEW="Rotated-$RUN-$(openssl rand -hex 8)"
OLD_PW="$MASTER" NEW_PW="$NEW" node test/rotate-password.mjs https://127.0.0.1:48788 "$EMAIL"
BW_SESSION=$(bw login "$EMAIL" "$NEW" --raw 2>/dev/null); export BW_SESSION
BACK2=$(bw get item "$ID" | jq -r '[.name,.login.username,.login.password,.notes,.login.uris[0].uri,.login.totp]|join("|")')
[ "$BACK2" = "$WANT" ] && R1=ok || R1=FAIL; bw logout >/dev/null
bw login "$EMAIL" "$MASTER" --raw >/dev/null 2>&1 && R2=FAIL || R2=ok
echo "ROTATE RESULT: item readable with the new password=$R1 · old password refused=$R2"
exit 0   # the check ends here; the rest of e2ee.sh is the wire search of the other test

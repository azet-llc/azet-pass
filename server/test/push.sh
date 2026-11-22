#!/usr/bin/env bash
# Push to phones on a local Worker, with a local listener standing in for Google (FCM) and Apple (APNs):
# a change reaches the account's Android phone and iPhone in the form each app decodes, signed with the right keys,
# not the phone that made the change; a shared item reaches the other member's phone with that member's id; the
# sender tokens are made once, not per message; a phone Google or Apple reports as gone loses its push token.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH
W=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
RUN=$RANDOM$RANDOM; PORT=48837; FAKE=48838; URL=http://127.0.0.1:$PORT; LOG=$W/sent.jsonl; : > "$LOG"
A="push-a-$RUN@example.com"; B="push-b-$RUN@example.com"; PW_A="Push-A-$RUN-pw-long"; PW_B="Push-B-$RUN-pw-long"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$W/google.pem" 2>/dev/null; openssl pkey -in "$W/google.pem" -pubout -out "$W/google.pub"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$W/apple.pem" 2>/dev/null; openssl pkey -in "$W/apple.pem" -pubout -out "$W/apple.pub"
node test/push.mjs listen $FAKE "$W/google.pub" "$W/apple.pub" "$LOG" &

worker-build --release --locked >/dev/null
ACCOUNT=$(jq -c -n --rawfile key "$W/google.pem" --arg uri "http://127.0.0.1:$FAKE/token" '{project_id: "test-project", client_email: "sender@test-project.example", token_uri: $uri, private_key: $key}')
{ printf 'JWT_SECRET=%s\nJWT_REFRESH_SECRET=%s\nALLOWED_EMAILS=*\nTEAM_OWNERS=%s\n' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" "$A"
  printf "FCM_SERVICE_ACCOUNT='%s'\nFCM_BASE=http://127.0.0.1:%s\nAPNS_BASE=http://127.0.0.1:%s\nAPNS_KEY_ID=TESTKEY123\nAPNS_TEAM_ID=TESTTEAM12\nAPNS_TOPIC=io.azet.pass\n" "$ACCOUNT" $FAKE $FAKE
  printf 'APNS_KEY="%s"\n' "$(awk '{printf "%s\\n", $0}' "$W/apple.pem")"; } > .dev.vars
rm -rf .wrangler/state; mkdir -p public/web-vault
sed -e '/^\[build\]/,/^command/d' -e 's|^main = "src/private.js"|main = "src/entry.js"|' -e 's|simple = { limit = 5, period = 60 }|simple = { limit = 1000, period = 60 }|' wrangler.toml > wrangler.test.toml
for f in sql/schema.sql migrations/001[5-9]_*.sql migrations/002*.sql; do
  D1_DATABASE_ID=00000000-0000-0000-0000-000000000000 npx -y wrangler@4 d1 execute vault1 -c wrangler.test.toml --local --file "$f" >/dev/null 2>&1
done
D1_DATABASE_ID=00000000-0000-0000-0000-000000000000 npx -y wrangler@4 dev -c wrangler.test.toml --local --port $PORT >"$W/dev.log" 2>&1 &
for i in $(seq 60); do curl -sf -o /dev/null $URL/api/alive && break; sleep 1; done
DBF() { find .wrangler/state/v3/d1 -name '*.sqlite' ! -name metadata.sqlite | head -1; }
sent() { jq -c -s "[.[] | select($1)]" "$LOG"; }                       # the listener's lines that match
settle() { sleep 3; }                                                   # pushes go out after the response
fail() { echo "FAIL: $1"; tail -5 "$W/dev.log"; exit 1; }

node test/register.mjs $URL "$A" "$PW_A"; node test/register.mjs $URL "$B" "$PW_B"
ID_A=$(sqlite3 "$(DBF)" "SELECT id FROM users WHERE email = '$A'"); ID_B=$(sqlite3 "$(DBF)" "SELECT id FROM users WHERE email = '$B'")
AND=$(uuidgen | tr A-Z a-z); IOS=$(uuidgen | tr A-Z a-z); PC=$(uuidgen | tr A-Z a-z); AND_B=$(uuidgen | tr A-Z a-z)
T_AND=$(node test/push.mjs phone $URL "$A" "$PW_A" 0 $AND token-android)
node test/push.mjs phone $URL "$A" "$PW_A" 1 $IOS token-ios >/dev/null
T_PC=$(node test/push.mjs phone $URL "$A" "$PW_A" 8 $PC)
node test/push.mjs phone $URL "$B" "$PW_B" 0 $AND_B token-android-b >/dev/null

# 1 a change made on the computer reaches both phones, in each app's form
ITEM=$(node test/push.mjs save $URL "$T_PC"); settle
G=$(sent '.path == "/v1/projects/test-project/messages:send"'); P=$(sent '.path == "/3/device/token-ios"')
[ "$(jq length <<<"$G")" = 1 ] && [ "$(jq -r '.[0].bearer' <<<"$G")" = "Bearer google-access" ] \
  && [ "$(jq -r '.[0].body.message | .token + " " + .data.type + " " + .data.contextId + " " + .android.priority' <<<"$G")" = "token-android 1 $PC high" ] \
  && [ "$(jq -r '.[0].body.message.data.payload | fromjson | .id + " " + .userId' <<<"$G")" = "$ITEM $ID_A" ] \
  && [ "$(jq -r '.[0].body.message.data.payload | fromjson | .revisionDate | test("^20[0-9-]+T")' <<<"$G")" = true ] \
  || fail "Android: $G"
[ "$(jq length <<<"$P")" = 1 ] && [ "$(jq -r '.[0] | (.signed|tostring) + " " + .kid + " " + .iss + " " + .topic + " " + .pushType' <<<"$P")" = "true TESTKEY123 TESTTEAM12 io.azet.pass background" ] \
  && [ "$(jq -c '.[0].body.aps' <<<"$P")" = '{"content-available":1}' ] && [ "$(jq -r '.[0].body.data | (.type|tostring) + " " + .contextId' <<<"$P")" = "1 $PC" ] \
  && [ "$(jq -r '.[0].body.data.payload | fromjson | .id + " " + .userId' <<<"$P")" = "$ITEM $ID_A" ] || fail "iPhone: $P"
T=$(sent '.path == "/token"')
[ "$(jq -r '.[0] | (.signed|tostring) + " " + .claims.iss + " " + .claims.scope' <<<"$T")" = "true sender@test-project.example https://www.googleapis.com/auth/firebase.messaging" ] || fail "Google token request: $T"
echo "1 a change on the computer reached the Android phone and the iPhone, each in its own form, with signed sender tokens: ok"

# 2 the phone that made the change is not told; the sender tokens are not made again
: > "$LOG"; node test/push.mjs save $URL "$T_AND" >/dev/null; settle
[ "$(sent '.path | startswith("/v1/")' | jq length)" = 0 ] && [ "$(sent '.path == "/3/device/token-ios"' | jq length)" = 1 ] && [ "$(sent '.path == "/token"' | jq length)" = 0 ] \
  && echo "2 the phone that made the change got nothing, the other phone did, and no new Google token was asked for: ok" || fail "second change: $(cat "$LOG")"
IAT1=$(jq -r '.[0].iat' <<<"$P"); [ "$(sent '.path == "/3/device/token-ios"' | jq -r '.[0].iat')" = "$IAT1" ] || fail "the Apple token was made again"

# 3 a shared item reaches the other member's phone, addressed to that member
team() { local e=$1 p=$2; shift 2; AZET_PASS_URL=$URL AZET_PASS_EMAIL=$e AZET_PASS_PASSWORD=$p node scripts/team.mjs "$@"; }
TEAM=$(team "$A" "$PW_A" create "Push team" 5); ORG=$(jq -r .org <<<"$TEAM"); VAULT=$(jq -r .vault <<<"$TEAM")
I=$(team "$A" "$PW_A" invite "$ORG" "$B")
FP=$(team "$B" "$PW_B" join "$ORG" "$(jq -r .member <<<"$I")" "$(jq -r .token <<<"$I")" | jq -r .fingerprint)
team "$A" "$PW_A" confirm "$ORG" "$B" "$FP" >/dev/null; settle; : > "$LOG"
SHARED=$(AZET_PASS_URL=$URL AZET_PASS_EMAIL=$A AZET_PASS_PASSWORD=$PW_A node test/old-key.mjs item "$ORG" "$VAULT" "Push-Shared-$RUN" "Push-Secret-$RUN"); settle
[ "$(sent '.path | startswith("/v1/")' | jq -c --arg id "$SHARED" '[.[] | select(.body.message.data.payload | fromjson | .id == $id) | .body.message | .token + " " + (.data.payload | fromjson | .userId)] | sort')" = "$(jq -c -n --arg a "token-android $ID_A" --arg b "token-android-b $ID_B" '[$a, $b] | sort')" ] \
  && echo "3 a shared item reached the other member's phone with that member's id: ok" || fail "shared item: $(cat "$LOG")"
! grep -q "Push-Secret-$RUN\|Push-Shared-$RUN" "$LOG" || fail "the item's name or secret went out"

# 4 a phone reported as gone loses its push token; the others keep theirs
node test/push.mjs phone $URL "$A" "$PW_A" 0 $AND gone-android >/dev/null; node test/push.mjs phone $URL "$A" "$PW_A" 1 $IOS gone-ios >/dev/null
node test/push.mjs save $URL "$T_PC" >/dev/null; settle
[ "$(sqlite3 "$(DBF)" "SELECT COUNT(*) FROM devices WHERE identifier IN ('$AND', '$IOS') AND push_token IS NULL")" = 2 ] \
  && [ "$(sqlite3 "$(DBF)" "SELECT push_token FROM devices WHERE identifier = '$AND_B'")" = token-android-b ] \
  && echo "4 phones reported as gone by Google and Apple lost their push tokens; the other phone kept its own: ok" || fail "gone phones: $(sqlite3 "$(DBF)" "SELECT identifier, push_token FROM devices")"
echo "PASS: push to phones"

# sourced inside the server's e2ee test after the dummy account (the grantor) is signed in ($W, $BW_SESSION, $W/bw)
set +e
CLI_JS="${AZET_DESKTOP_CLI:-$HOME/Code/azet-desktop-pass2/out/cli/index.js}"
mk() { local ud="$1" bw="$2" s="$3"; mkdir -p "$ud/azet-pass"; ln -s "$bw" "$ud/azet-pass/data"; printf %s "$s" > "$ud/azet-pass/session"; chmod 600 "$ud/azet-pass/session"; }
A() { AZET_DESKTOP_USER_DATA_PATH="$W/ua" node "$CLI_JS" pass "$@"; }
B() { AZET_DESKTOP_USER_DATA_PATH="$W/ub" node "$CLI_JS" pass "$@"; }
ok() { echo "  [ok] $1"; }; bad() { echo "  [FAIL] $1"; FAILS=$((FAILS+1)); }; FAILS=0
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
BASE=https://127.0.0.1:48788
mk "$W/ua" "$W/bw" "$BW_SESSION"
E2="contact-$RUN@example.com"; M2="Contact-Master-$RUN-pw"
node test/register.mjs "$BASE" "$E2" "$M2"
S2=$(BITWARDENCLI_APPDATA_DIR="$W/bw2" bash -c "bw config server $BASE >/dev/null && bw login '$E2' '$M2' --raw")
mk "$W/ub" "$W/bw2" "$S2"

echo "== 1 invite → accept"
O=$(A emergency invite --email "$E2" --type view --wait-days 1); chk "invited ($O)" 'echo "$O" | grep -q "is invited"'
ID=$(B emergency list --json | jq -r '.result.namedMe[0].id')
chk "contact sees the invite" '[ -n "$ID" ] && [ "$ID" != null ]'
O=$(B emergency accept --id "$ID"); chk "accepted" 'echo "$O" | grep -q accepted'

echo "== 2 fingerprints come from the keys each computer opened"
FA=$(A emergency list --json | jq -r .result.myFingerprint); FB=$(B emergency list --json | jq -r .result.myFingerprint)
# the grantor confirms the way pass emergency confirm does (that command asks the person through the running app)
WANT=$(EMAIL="$EMAIL" MASTER="$MASTER" ID="$ID" BASE="$BASE" node --input-type=module -e '
import { webcrypto as c, createHash } from "node:crypto"
const { EMAIL, MASTER, ID, BASE } = process.env, enc = new TextEncoder(), b64 = (u) => Buffer.from(u).toString("base64")
const pb = async (pw, salt, it) => new Uint8Array(await c.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations: it }, await c.subtle.importKey("raw", pw, "PBKDF2", false, ["deriveBits"]), 256))
const hm = async (k, d) => new Uint8Array(await c.subtle.sign("HMAC", await c.subtle.importKey("raw", k, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]), d))
const dec = async (k, s) => { const [iv, ct] = s.slice(2).split("|").map((x) => Buffer.from(x, "base64")); return new Uint8Array(await c.subtle.decrypt({ name: "AES-CBC", iv }, await c.subtle.importKey("raw", k.slice(0, 32), "AES-CBC", false, ["decrypt"]), ct)) }
const mk = await pb(enc.encode(MASTER), enc.encode(EMAIL), 600000)
const r = await (await fetch(BASE + "/identity/connect/token", { method: "POST", body: new URLSearchParams({ grant_type: "password", username: EMAIL, password: b64(await pb(mk, enc.encode(MASTER), 1)), scope: "api offline_access", client_id: "cli", deviceType: "8", deviceIdentifier: c.randomUUID(), deviceName: "t" }) })).json()
const uk = await dec(new Uint8Array([...await hm(mk, new Uint8Array([...enc.encode("enc"), 1])), ...await hm(mk, new Uint8Array([...enc.encode("mac"), 1]))]), r.Key)
const api = async (m, p, b) => (await fetch(BASE + "/api" + p, { method: m, headers: { authorization: "Bearer " + r.access_token, "content-type": "application/json" }, body: b && JSON.stringify(b) })).json().catch(() => null)
const g = (await api("GET", "/emergency-access/trusted")).data.find((x) => x.id === ID)
const me = await api("GET", "/accounts/profile")
const pub = (await api("GET", `/users/${g.granteeId}/public-key`)).publicKey
const own = (await api("GET", `/users/${me.id}/public-key`)).publicKey
const fp = (k) => createHash("sha256").update(Buffer.from(k, "base64")).digest("hex").slice(0, 20).match(/.{4}/g).join("-")
await api("POST", `/emergency-access/${ID}/confirm`, { key: "4." + b64(new Uint8Array(await c.subtle.encrypt({ name: "RSA-OAEP" }, await c.subtle.importKey("spki", Buffer.from(pub, "base64"), { name: "RSA-OAEP", hash: "SHA-1" }, false, ["encrypt"]), uk))) })
console.log(fp(own) + " " + fp(pub))')
chk "grantor fingerprint = its public key on the server" '[ "$FA" = "${WANT% *}" ]'
chk "contact fingerprint = its public key on the server" '[ "$FB" = "${WANT#* }" ]'

echo "== 3 ask → nothing yet → the wait runs out → view"
O=$(B emergency request --id "$ID"); chk "asked ($O)" 'echo "$O" | grep -q "Access opens in 1 days"'
O=$(B emergency view --id "$ID" 2>&1); chk "no view while waiting" 'echo "$O" | grep -q "not approved"'
O=$(A emergency list); chk "grantor sees the request with its date" 'echo "$O" | grep -q "asked for access (given by itself on"'
D1_DATABASE_ID=00000000-0000-0000-0000-000000000000 npx -y wrangler@4 d1 execute vault1 -c wrangler.test.toml --local --command "UPDATE emergency_access SET recovery_initiated_at = '2020-01-01T00:00:00.000Z' WHERE id = '$ID'" >/dev/null 2>&1
O=$(B emergency view --id "$ID"); echo "$O" | sed 's/^/    /'
chk "contact reads the grantor's item name and user name" 'echo "$O" | grep -q "$S_NAME" && echo "$O" | grep -q "$S_USER"'
chk "no password in the view" '! echo "$O" | grep -q -e "$S_PASS" -e "$MASTER"'
O=$(A emergency reject --id "$ID"); chk "grantor ends the access" 'echo "$O" | grep -q stopped'
O=$(B emergency view --id "$ID" 2>&1); chk "no view after reject" 'echo "$O" | grep -q "not approved"'
O=$(B emergency remove --id "$ID"); chk "contact leaves" 'echo "$O" | grep -q removed && [ "$(A emergency list --json | jq ".result.myContacts | length")" = 0 ]'

echo "== 4 counter codes (RFC 4226 secret)"
bw get template item | jq -c '.name="e2e bank otp"|.login={username:"u",password:"p",totp:"otpauth://hotp/bank?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&counter=0"}' | bw encode | bw create item >/dev/null
chk "first code" '[ "$(A otp --name "e2e bank otp")" = 755224 ]'
chk "next code" '[ "$(A otp --name "e2e bank otp")" = 287082 ]'
bw sync >/dev/null; chk "the item keeps counter 2" 'bw get item "e2e bank otp" | jq -r .login.totp | grep -q "counter=2"'

echo "== 5 new-device approval"
O=$(printf %s "wrong-password" | A devices approval --enable --password-file - 2>&1); chk "a wrong password changes nothing" 'echo "$O" | grep -qi "answered 400" && A devices approval | grep -q "password alone"'
O=$(printf %s "$MASTER" | A devices approval --enable --password-file -); chk "on" 'echo "$O" | grep -q "wait for approval"'
O=$(BITWARDENCLI_APPDATA_DIR="$W/bw3" bash -c "bw config server $BASE >/dev/null; bw login '$EMAIL' '$MASTER' --raw" 2>&1); chk "a new device is held" 'echo "$O" | grep -q "needs approval"'
WID=$(A devices --json | jq -r '.result.waiting[0].identifier'); chk "it waits in pass devices" '[ -n "$WID" ] && [ "$WID" != null ]'
O=$(A devices deny --id "$WID"); chk "denied" 'echo "$O" | grep -q denied && [ "$(A devices --json | jq ".result.waiting | length")" = 0 ]'
O=$(printf %s "$MASTER" | A devices approval --disable --password-file -); chk "off" 'echo "$O" | grep -q "password alone"'
echo "EMERGENCY DESKTOP RESULT: fails=$FAILS"
exit 0

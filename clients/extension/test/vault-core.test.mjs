// Live check against pass.azet.io: node test/vault-core.test.mjs < creds.json  ({"email":..,"password":..}; read from stdin, never argv)
import { createRequire } from "node:module";
import { Vault, serverPasswordHash, matchesSite } from "../src/vault-core.mjs";
import assert from "node:assert/strict";
const sdk = createRequire(import.meta.url)(process.env.AZET_SDK_NODE);
assert.equal(matchesSite([{ uri: "https://login.example.com/x" }], "https://www.example.com/"), true);
assert.equal(matchesSite([{ uri: "https://example.org" }], "https://example.com"), false);
assert.equal((await serverPasswordHash("a@b.c", "pw", 1000)).length, 44);
let input = ""; for await (const c of process.stdin) input += c;
const { email, password } = JSON.parse(input);
const v = new Vault({ sdk, base: "https://pass.azet.io", deviceId: crypto.randomUUID() });
await v.signIn(email, password);
const r = await v.sync();
console.log("synced", r);
assert.ok(r.items > 0, "vault has items");
const login = v.list.find((x) => x.type?.login);
const full = await v.view(login.id);
assert.equal(typeof full.name, "string");
console.log("view ok, has password:", !!full.login?.password, "uris:", full.login?.uris?.length ?? 0);
const t = v.totp("JBSWY3DPEHPK3PXP"); assert.match(t.code, /^\d{6}$/); console.log("totp ok, period", t.period);
assert.equal(v.password({ length: 24 }).length, 24); console.log("generator ok");
// resume from the kept user key (what the background worker does after a restart)
const key = v.userKey; v.lock();
const v2 = new Vault({ sdk, base: "https://pass.azet.io", deviceId: "x" }); v2.account = v.account; await v2.resume(key);
assert.equal((await v2.sync()).items, r.items); console.log("resume ok");

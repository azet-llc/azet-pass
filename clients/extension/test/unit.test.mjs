import test from "node:test";
import assert from "node:assert/strict";
import { matchesSite, hostOf, toSdkCipher, toRequest, serverPasswordHash } from "../src/vault-core.mjs";
import { strength } from "../src/health.mjs";

test("site matching", () => {
  assert.equal(hostOf("https://www.naver.com/x"), "naver.com");
  assert.equal(matchesSite([{ uri: "https://nid.naver.com/login" }], "https://www.naver.com"), true);
  assert.equal(matchesSite([{ uri: "https://naver.com.evil.io" }], "https://naver.com"), false);
  assert.equal(matchesSite([{ uri: "androidapp://com.x" }], "https://x.com"), false);
});
test("password strength", () => {
  assert.equal(strength("password123") < 2, true);
  assert.equal(strength("aB3$kq9!Zr7#mW2p") >= 3, true);
});
test("cipher round trip keeps the fields the server needs", () => {
  const c = toSdkCipher({ id: "1", type: 1, name: "2.n", revisionDate: "2026-01-01T00:00:00Z", login: { username: "2.u", uris: [{ uri: "2.x", match: null }] } });
  assert.equal(c.login.uris[0].uri, "2.x");
  const r = toRequest(c, c.revisionDate);
  assert.equal(r.lastKnownRevisionDate, "2026-01-01T00:00:00Z");
  assert.equal(r.login.username, "2.u");
});
test("server hash is base64 of 32 bytes", async () => assert.equal(atob(await serverPasswordHash("a@b.c", "x", 1000)).length, 32));

import { cbor, credIdBytes, credIdString, rpAllowed, createPasskey, signAssertion } from "../src/passkey.mjs";
test("passkey helpers", async () => {
  assert.deepEqual([...cbor({ a: 1 })], [0xa1, 0x61, 0x61, 0x01]);
  assert.deepEqual([...cbor(-7)], [0x26]);
  const id = crypto.randomUUID(); assert.equal(credIdString(credIdBytes(id)), id);
  assert.equal(rpAllowed("example.com", "https://login.example.com/x"), true);
  assert.equal(rpAllowed("com", "https://example.com"), false);
  assert.equal(rpAllowed("example.com", "http://example.com"), false);
  assert.equal(rpAllowed("other.com", "https://example.com"), false);
  const { response, record } = await createPasskey({ rp: { id: "example.com", name: "Ex" }, user: { id: "AQID", name: "u", displayName: "U" }, challenge: "Y2g" }, "https://example.com");
  const a = await signAssertion({ rpId: "example.com", challenge: "Y2g" }, "https://example.com", record, record.keyValue);
  assert.equal(a.id, response.id);
  assert.equal(a.userHandle, "AQID");
});

import { pinWrap, pinUnwrap, csvLogins, maskedEmail, lookalike } from "../src/extras.mjs";
test("PIN seals the vault key; a wrong PIN opens nothing", async () => {
  const sealed = await pinWrap("2.userkey==", "4821");
  assert.equal(await pinUnwrap(sealed, "4821"), "2.userkey==");
  assert.equal(await pinUnwrap(sealed, "4822"), null);
});
test("csv import reads Chrome and Samsung Pass style headers", () => {
  const chrome = csvLogins('name,url,username,password,note\nShop,https://www.shop.example/login,me,"p,w""1",x\n');
  assert.deepEqual(chrome, [{ name: "Shop", uri: "https://www.shop.example/login", username: "me", password: 'p,w"1', totp: undefined }]);
  assert.equal(csvLogins("Title,Website,ID,Password\n,bank.example,kim,pw\n")[0].name, "bank.example");
  assert.deepEqual(csvLogins("a,b\n1,2\n"), []);
});
test("masked address keeps the mailbox and names the site", () => {
  assert.equal(maskedEmail("kim+old@mail.example", "www.shop-mall.co.kr", new Uint8Array([0, 1, 2])), "kim+shopmall-abc@mail.example");
  assert.equal(maskedEmail("nope", "x.com"), null);
});
test("look-alike sites are flagged, the saved site and unrelated sites are not", () => {
  const saved = ["accounts.google.com", "www.naver.com", "kakaobank.com"];
  assert.equal(lookalike("accounts.g00gle.com", saved), null); // two letters off a short name is not flagged
  assert.equal(lookalike("gitlab.com", ["github.com"]), null);
  assert.equal(lookalike("kakaobenk-login.com", ["kakaobank-login.com"]), "kakaobank-login.com");
  assert.equal(lookalike("login.gooogle.com", saved), "google.com");
  assert.equal(lookalike("kakaobenk.com", saved), "kakaobank.com");
  assert.equal(lookalike("mail.google.com", saved), null);
  assert.equal(lookalike("daum.net", saved), null);
});

test("the same site is the registered name, never a shared ending or a plain-http copy", async () => {
  const { siteOf, matchesSite } = await import("../src/vault-core.mjs");
  assert.equal(siteOf("login.bank.co.kr"), "bank.co.kr");
  assert.equal(siteOf("nid.naver.com"), "naver.com");
  assert.equal(matchesSite([{ uri: "https://www.bank.co.kr/login" }], "https://evil.co.kr/"), false);
  assert.equal(matchesSite([{ uri: "https://victim.github.io" }], "https://attacker.github.io/x"), false);
  assert.equal(matchesSite([{ uri: "https://bank.com" }], "http://bank.com:8080/"), false);
  assert.equal(matchesSite([{ uri: "https://accounts.google.com" }], "https://www.google.com/"), true);
  assert.equal(matchesSite([{ uri: "naver.com" }], "https://nid.naver.com/login"), true);
});

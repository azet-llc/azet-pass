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

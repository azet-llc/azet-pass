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

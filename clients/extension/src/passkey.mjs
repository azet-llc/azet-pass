// Passkeys made and used by AZET Pass (WebAuthn, ES256 only), stored in the vault in the same shape the
// iPhone app and the other AZET Pass apps read: credentialId as a UUID, keyValue = base64url PKCS#8 P-256.
const te = new TextEncoder();
export const b64u = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
export const fromB64u = (s) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));
const sha256 = async (data) => new Uint8Array(await crypto.subtle.digest("SHA-256", typeof data === "string" ? te.encode(data) : data));
const cat = (...parts) => { const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let o = 0; for (const p of parts) { out.set(p, o); o += p.length; } return out; };
const u32 = (n) => new Uint8Array([n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]);

// Minimal CBOR (RFC 8949) for what WebAuthn needs: unsigned/negative ints, byte and text strings, maps.
function head(major, n) {
  if (n < 24) return new Uint8Array([(major << 5) | n]);
  if (n < 256) return new Uint8Array([(major << 5) | 24, n]);
  if (n < 65536) return new Uint8Array([(major << 5) | 25, n >> 8, n & 255]);
  return cat(new Uint8Array([(major << 5) | 26]), u32(n));
}
export function cbor(v) {
  if (typeof v === "number") return v >= 0 ? head(0, v) : head(1, -1 - v);
  if (typeof v === "string") { const b = te.encode(v); return cat(head(3, b.length), b); }
  if (v instanceof Uint8Array) return cat(head(2, v.length), v);
  const entries = v instanceof Map ? [...v] : Object.entries(v);
  return cat(head(5, entries.length), ...entries.flatMap(([k, x]) => [cbor(k), cbor(x)]));
}

/** UUID credential ids are 16 raw bytes; others are kept as "b64.<base64url>". */
export const credIdBytes = (id) => /^[0-9a-f-]{36}$/i.test(id) ? Uint8Array.from(id.replace(/-/g, "").match(/../g), (h) => parseInt(h, 16)) : fromB64u(id.replace(/^b64\./, ""));
export const credIdString = (bytes) => bytes.length === 16 ? [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("").replace(/^(.{8})(.{4})(.{4})(.{4})/, "$1-$2-$3-$4-") : "b64." + b64u(bytes);

/** The relying party may claim the page's host or a registrable parent of it, on https (or localhost). */
export function rpAllowed(rpId, pageUrl) {
  let u; try { u = new URL(pageUrl); } catch { return false; }
  if (u.protocol !== "https:" && u.hostname !== "localhost") return false;
  const h = u.hostname;
  return !!rpId && (h === rpId || (h.endsWith("." + rpId) && rpId.includes(".")));
}

const FLAGS = { UP: 1, UV: 4, BE: 8, BS: 16, AT: 64 };
const AAGUID = new Uint8Array([80, 243, 26, 184, 251, 30, 76, 52, 169, 193, 90, 1, 125, 135, 206, 179]); // AZET Pass's authenticator id 50f31ab8-fb1e-4c34-a9c1-5a017d87ceb3 (the Android app stamps the same)

// WebCrypto ECDSA gives r||s; WebAuthn wants DER.
function der(sig) {
  const int = (b) => { let i = 0; while (i < b.length - 1 && b[i] === 0) i++; b = b.slice(i); return b[0] & 128 ? cat(new Uint8Array([0]), b) : b; };
  const r = int(sig.slice(0, 32)), s = int(sig.slice(32));
  return cat(new Uint8Array([0x30, r.length + s.length + 4, 2, r.length]), r, new Uint8Array([2, s.length]), s);
}

const clientData = (type, challenge, origin) => te.encode(JSON.stringify({ type, challenge, origin, crossOrigin: false }));

/** navigator.credentials.create: a new P-256 key; returns the page's response and the vault record. */
export async function createPasskey({ rp, user, challenge }, origin) {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign"]);
  const jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const spki = new Uint8Array(await crypto.subtle.exportKey("spki", pair.publicKey));
  const credentialId = crypto.randomUUID(), rawId = credIdBytes(credentialId);
  const cose = cbor(new Map([[1, 2], [3, -7], [-1, 1], [-2, fromB64u(jwk.x)], [-3, fromB64u(jwk.y)]]));
  const authData = cat(await sha256(rp.id), new Uint8Array([FLAGS.UP | FLAGS.UV | FLAGS.BE | FLAGS.BS | FLAGS.AT]), u32(0),
    AAGUID, new Uint8Array([rawId.length >> 8, rawId.length & 255]), rawId, cose);
  const cdj = clientData("webauthn.create", challenge, origin);
  return {
    response: { id: b64u(rawId), rawId: b64u(rawId), type: "public-key", authenticatorAttachment: "platform",
      clientDataJSON: b64u(cdj), attestationObject: b64u(cbor({ fmt: "none", attStmt: {}, authData })),
      authenticatorData: b64u(authData), publicKey: b64u(spki), publicKeyAlgorithm: -7, transports: ["internal", "hybrid"] },
    record: { credentialId, keyType: "public-key", keyAlgorithm: "ECDSA", keyCurve: "P-256", keyValue: b64u(pkcs8), rpId: rp.id,
      userHandle: user.id, userName: user.name, counter: "0", rpName: rp.name, userDisplayName: user.displayName, discoverable: "true",
      creationDate: new Date().toISOString() },
  };
}

/** navigator.credentials.get: signs the challenge with a saved key (keyValue = base64url PKCS#8). */
export async function signAssertion({ rpId, challenge }, origin, cred, keyValue) {
  const key = await crypto.subtle.importKey("pkcs8", fromB64u(keyValue), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const authData = cat(await sha256(rpId), new Uint8Array([FLAGS.UP | FLAGS.UV | FLAGS.BE | FLAGS.BS]), u32(0));
  const cdj = clientData("webauthn.get", challenge, origin);
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, cat(authData, await sha256(cdj))));
  const rawId = credIdBytes(cred.credentialId);
  return { id: b64u(rawId), rawId: b64u(rawId), type: "public-key", authenticatorAttachment: "platform",
    clientDataJSON: b64u(cdj), authenticatorData: b64u(authData), signature: b64u(der(sig)), userHandle: cred.userHandle || null };
}

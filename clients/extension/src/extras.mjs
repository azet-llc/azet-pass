// PIN unlock, importing a .csv, a masked address for sign-ups, and the look-alike site warning.
// Pure functions (WebCrypto only), so the unit tests run them without a browser.

const enc = new TextEncoder(), dec = new TextDecoder();
const b64 = (u8) => btoa(String.fromCharCode(...u8));
const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

async function pinKey(pin, salt) {
  const base = await crypto.subtle.importKey("raw", enc.encode(pin), "PBKDF2", false, ["deriveKey"]);
  return crypto.subtle.deriveKey({ name: "PBKDF2", hash: "SHA-256", salt, iterations: 600000 }, base, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
}

/** The vault key sealed with a PIN (kept in the browser's storage; a wrong PIN cannot open it). */
export async function pinWrap(userKey, pin) {
  const salt = crypto.getRandomValues(new Uint8Array(16)), iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await pinKey(pin, salt), enc.encode(userKey)));
  return { salt: b64(salt), iv: b64(iv), ct: b64(ct) };
}

/** The vault key back, or null when the PIN is wrong. */
export async function pinUnwrap(sealed, pin) {
  try {
    return dec.decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64(sealed.iv) }, await pinKey(pin, unb64(sealed.salt)), unb64(sealed.ct)));
  } catch { return null; }
}

/** RFC 4180 rows: quotes, doubled quotes, line breaks inside quotes. */
export function csvRows(text) {
  const rows = []; let row = [], f = "", q = false;
  const s = text.replace(/^﻿/, "");
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (q && ch === '"' && s[i + 1] === '"') { f += '"'; i++; }
    else if (ch === '"') q = !q;
    else if (!q && ch === ",") { row.push(f); f = ""; }
    else if (!q && (ch === "\n" || ch === "\r")) {
      if (ch === "\r" && s[i + 1] === "\n") i++;
      row.push(f); f = ""; if (row.some((x) => x !== "")) rows.push(row); row = [];
    } else f += ch;
  }
  row.push(f); if (row.some((x) => x !== "")) rows.push(row);
  return rows;
}

/** Sign-ins from the .csv exports of Chrome, Edge, Firefox, Safari, Samsung Pass, 1Password, LastPass and others
 *  (the header names differ; the columns are found by name). */
export function csvLogins(text) {
  const rows = csvRows(text); if (rows.length < 2) return [];
  const h = rows[0].map((x) => x.trim().toLowerCase());
  const col = (...names) => { for (const n of names) { const i = h.indexOf(n); if (i >= 0) return i; } return -1; };
  const name = col("name", "title", "login_name"), url = col("url", "login_uri", "website", "origin_url", "hostname");
  const user = col("username", "login_username", "user", "id", "email"), pass = col("password", "login_password");
  const totp = col("totp", "login_totp", "otpauth", "otp"), type = col("type");
  if (pass < 0 && user < 0) return [];
  const v = (r, i) => (i >= 0 ? (r[i] || "").trim() : "") || undefined;
  return rows.slice(1).flatMap((r) => {
    if (type >= 0 && v(r, type) && v(r, type) !== "login") return [];
    const uri = v(r, url);
    let host; try { host = uri && new URL(uri.includes("://") ? uri : `https://${uri}`).hostname.replace(/^www\./, ""); } catch { host = undefined; }
    const n = v(r, name) || host || v(r, user);
    return n ? [{ name: n, uri, username: v(r, user), password: v(r, pass), totp: v(r, totp) }] : [];
  });
}

/** An address of your own mailbox that names the site, so mail to it shows who passed it on: you+shop-x7k2@mail.com.
 *  Works where the mail service delivers "+tag" addresses (Gmail, iCloud, Outlook, Fastmail, Proton); nothing is created
 *  on a server. */
export function maskedEmail(email, host, rand = crypto.getRandomValues(new Uint8Array(3))) {
  const at = email.lastIndexOf("@"); if (at < 1) return null;
  const site = (host || "").replace(/^www\./, "").split(".")[0].replace(/[^a-z0-9]/gi, "").toLowerCase().slice(0, 12);
  const tag = Array.from(rand, (b) => "abcdefghjkmnpqrstuvwxyz23456789"[b % 31]).join("");
  return `${email.slice(0, at).split("+")[0]}+${site ? `${site}-` : ""}${tag}${email.slice(at)}`;
}

const base = (h) => h.split(".").slice(-2).join(".");
function distance(a, b) {
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array(b.length).fill(0)]);
  for (let j = 1; j <= b.length; j++) d[0][j] = j;
  for (let i = 1; i <= a.length; i++) for (let j = 1; j <= b.length; j++)
    d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
  return d[a.length][b.length];
}

/** The saved site this page seems to imitate (a letter or two off, or a non-Latin spelling), or null.
 *  A page whose own site is saved is never flagged. */
export function lookalike(host, savedHosts) {
  const here = base(host.replace(/^www\./, "").toLowerCase());
  const saved = [...new Set(savedHosts.map((h) => base(h.toLowerCase())))];
  if (!here || saved.includes(here)) return null;
  const plain = here.startsWith("xn--") || here.includes(".xn--");
  for (const s of saved) {
    if (s.length < 6) continue; // short names are one letter from many honest sites
    const d = distance(here, s);
    // One letter off; two only for long names (github.com and gitlab.com are two apart and both honest).
    if (d > 0 && (d <= (s.length >= 13 ? 2 : 1) || (plain && d <= 4))) return s;
  }
  return null;
}

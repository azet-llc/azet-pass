// AZET Pass vault core: sign in, sync, decrypt, one-time codes, generator, save — shared by the extension's
// background worker and the Node test. The crypto engine is the GPL-3.0 sdk-internal WebAssembly build (pinned to
// 9794da5, the same revision as the iPhone app); everything around it here is ours.
const te = new TextEncoder();
const b64 = (u8) => btoa(String.fromCharCode(...new Uint8Array(u8)));

async function pbkdf2(password, salt, iterations) {
  const key = await crypto.subtle.importKey("raw", typeof password === "string" ? te.encode(password) : password, "PBKDF2", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt: te.encode(salt), iterations }, key, 256));
}

/** The hash the server checks at sign-in: PBKDF2(master key, password, 1). The master key never leaves the device. */
export async function serverPasswordHash(email, password, iterations) {
  const masterKey = await pbkdf2(password, email, iterations);
  return b64(await pbkdf2(masterKey, password, 1));
}

const pick = (o, keys) => Object.fromEntries(keys.map((k) => [k, o?.[k] ?? undefined]));

/** Server JSON (camelCase API model) -> the SDK's Cipher. `data` stays empty: in the SDK it means a sealed blob. */
export function toSdkCipher(c) {
  const login = c.login && {
    ...pick(c.login, ["username", "password", "passwordRevisionDate", "totp", "autofillOnPageLoad"]),
    uris: c.login.uris?.map((u) => pick(u, ["uri", "match", "uriChecksum"])),
    fido2Credentials: c.login.fido2Credentials ?? undefined,
  };
  return {
    ...pick(c, ["id", "organizationId", "folderId", "key", "name", "notes", "type", "favorite", "reprompt", "organizationUseTotp",
      "edit", "viewPassword", "creationDate", "deletedDate", "revisionDate", "archivedDate"]),
    collectionIds: c.collectionIds ?? [],
    login: login || undefined,
    identity: c.identity ?? undefined, card: c.card ?? undefined, secureNote: c.secureNote ?? undefined, sshKey: c.sshKey ?? undefined,
    bankAccount: undefined, driversLicense: undefined, passport: undefined,
    favorite: !!c.favorite, reprompt: c.reprompt ?? 0, organizationUseTotp: c.organizationUseTotp ?? true, edit: c.edit ?? true,
    viewPassword: c.viewPassword ?? true, permissions: c.permissions ?? undefined, localData: undefined,
    attachments: c.attachments ?? undefined, fields: c.fields ?? undefined, passwordHistory: c.passwordHistory ?? undefined,
    creationDate: c.creationDate ?? c.revisionDate, revisionDate: c.revisionDate, data: undefined,
  };
}

/** SDK Cipher (encrypted) -> the server's create/update request body. */
export function toRequest(c, lastKnownRevisionDate) {
  return {
    type: c.type, organizationId: c.organizationId ?? null, folderId: c.folderId ?? null, favorite: c.favorite, reprompt: c.reprompt,
    key: c.key ?? null, name: c.name, notes: c.notes ?? null, fields: c.fields ?? null, passwordHistory: c.passwordHistory ?? null,
    login: c.login ? { ...c.login, uris: c.login.uris ?? null, fido2Credentials: c.login.fido2Credentials ?? null } : null,
    card: c.card ?? null, identity: c.identity ?? null, secureNote: c.secureNote ?? null, sshKey: c.sshKey ?? null,
    lastKnownRevisionDate: lastKnownRevisionDate ?? null,
  };
}

/** Host of a URL without "www.", or "" for non-web addresses. */
export const hostOf = (u) => { try { const h = new URL(/^[a-z][a-z0-9+.-]*:/i.test(u) ? u : `https://${u}`).hostname; return h.replace(/^www\./, ""); } catch { return ""; } }; // an address saved without "https://" is still a site
// Second-level names that hand out names to anyone, so "x.github.io" and "y.github.io" are different sites.
const SHARED = new Set(["github.io", "gitlab.io", "vercel.app", "netlify.app", "pages.dev", "workers.dev", "web.app", "firebaseapp.com", "herokuapp.com",
  "cloudfront.net", "azurewebsites.net", "blogspot.com", "appspot.com", "amazonaws.com", "tistory.com", "cafe24.com", "myshopify.com", "wixsite.com", "glitch.me", "fly.dev", "onrender.com", "r2.dev"]);
/** The part of a host one owner registers: "login.bank.co.kr" is "bank.co.kr", never "co.kr".
 *  shortcut: no public-suffix list here. A two-letter country ending whose second label is short ("co.kr", "ac.uk",
 *  "com.au") or a known shared host takes three labels, which errs toward treating sites as different; ship the list if
 *  people report sign-ins missing on honest sub-sites. */
export function siteOf(host) {
  const p = host.toLowerCase().replace(/^www\./, "").split(".");
  if (p.length <= 2) return p.join(".");
  const wide = SHARED.has(p.slice(-2).join(".")) || (p.at(-1).length === 2 && p.at(-2).length <= 3);
  return p.slice(wide ? -3 : -2).join(".");
}
/** Logins whose saved address is the page's site (example.com matches login.example.com and back). A sign-in saved
 *  for an https address is not offered to the same name served without https. */
export function matchesSite(uris, pageUrl) {
  const page = hostOf(pageUrl); if (!page) return false;
  const plain = /^http:/i.test(pageUrl);
  return (uris || []).some((u) => { const s = u.uri || u, h = hostOf(s); return h && siteOf(h) === siteOf(page) && !(plain && /^https:/i.test(s)); });
}

/** Works on any client, also one with no account behind it (the generator needs no keys). */
export function generatePassword(client, opts = {}) {
  return client.generator().password({ lowercase: true, uppercase: true, numbers: true, special: opts.special ?? true, length: opts.length ?? 20,
    avoidAmbiguous: true, minLowercase: undefined, minUppercase: undefined, minNumber: undefined, minSpecial: undefined });
}

export class Vault {
  constructor({ sdk, base, deviceId, deviceType = 2, deviceName = "AZET Pass extension", store }) {
    Object.assign(this, { sdk, base: base.replace(/\/$/, ""), deviceId, deviceType, deviceName, store });
    this.client = null; this.account = null; this.ciphers = []; this.list = [];
  }
  async api(method, path, body, form) {
    const headers = { "Device-Type": String(this.deviceType), "Bitwarden-Client-Name": "azet-extension" };
    if (this.account?.access && !form) headers.authorization = `Bearer ${this.account.access}`;
    let payload;
    if (form) { headers["content-type"] = "application/x-www-form-urlencoded"; payload = new URLSearchParams(form).toString(); }
    else if (body !== undefined) { headers["content-type"] = "application/json"; payload = JSON.stringify(body); }
    let r = await fetch(this.base + path, { method, headers, body: payload });
    if (r.status === 401 && this.account?.refresh && !form) { await this.refresh(); return this.api(method, path, body); }
    const text = await r.text(); let json = {}; try { json = text ? JSON.parse(text) : {}; } catch {}
    if (!r.ok) { const e = new Error(json.message || json.error_description || json.Message || `HTTP ${r.status}`); e.status = r.status; e.body = json; throw e; }
    return json;
  }
  async refresh() {
    const t = await this.api("POST", "/identity/connect/token", undefined, { grant_type: "refresh_token", client_id: "browser", refresh_token: this.account.refresh });
    this.account.access = t.access_token; if (t.refresh_token) this.account.refresh = t.refresh_token; await this.store?.saveAccount(this.account);
  }
  async signIn(email, password, twoFactorCode) {
    email = email.trim().toLowerCase();
    const pre = await this.api("POST", "/identity/accounts/prelogin", { email });
    if ((pre.kdf ?? pre.Kdf ?? 0) !== 0) throw new Error("This account uses Argon2id. Switch it to PBKDF2 in the web vault, then sign in here.");
    const iterations = pre.kdfIterations ?? pre.KdfIterations ?? 600000;
    const form = { grant_type: "password", username: email, password: await serverPasswordHash(email, password, iterations), scope: "api offline_access",
      client_id: "browser", deviceType: String(this.deviceType), deviceIdentifier: this.deviceId, deviceName: this.deviceName };
    if (twoFactorCode) Object.assign(form, { twoFactorToken: twoFactorCode, twoFactorProvider: "0", twoFactorRemember: "1" });
    let t;
    try { t = await this.api("POST", "/identity/connect/token", undefined, form); }
    catch (e) { if (e.body?.TwoFactorProviders || e.body?.TwoFactorProviders2) { const x = new Error("two-factor"); x.twoFactor = true; throw x; } throw e; }
    const sub = JSON.parse(atob(t.access_token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).sub;
    this.account = { email, userId: sub, iterations, key: t.Key ?? t.key, privateKey: t.PrivateKey ?? t.privateKey, access: t.access_token, refresh: t.refresh_token };
    await this.store?.saveAccount(this.account);
    await this.unlock(password);
  }
  async initCrypto(method) {
    const a = this.account, sdk = this.sdk;
    this.client = new sdk.PasswordManagerClient({ get_access_token: async () => a.access }, { apiUrl: this.base + "/api", identityUrl: this.base + "/identity", deviceType: "ChromeExtension", userAgent: "AZET Pass" });
    await this.client.crypto().initialize_user_crypto({ userId: a.userId, kdfParams: { pBKDF2: { iterations: a.iterations } }, email: a.email,
      accountCryptographicState: { V1: { private_key: a.privateKey } }, method });
  }
  async unlock(password) {
    const a = this.account;
    try { await this.initCrypto({ masterPasswordUnlock: { password, master_password_unlock: { kdf: { pBKDF2: { iterations: a.iterations } }, masterKeyWrappedUserKey: a.key, salt: a.email } } }); }
    catch (e) { const x = new Error("That account password is not right."); x.cause = e; throw x; }
    this.userKey = await this.client.crypto().get_user_encryption_key();
    await this.store?.saveUserKey?.(this.userKey);
  }
  /** After the background worker restarts: the decrypted user key kept for this browser session only. */
  async resume(userKey) { await this.initCrypto({ decryptedKey: { decrypted_user_key: userKey } }); this.userKey = userKey; }
  async sync() {
    const s = await this.api("GET", "/api/sync?excludeDomains=true");
    const snap = { orgKeys: Object.fromEntries((s.profile?.organizations ?? []).filter((o) => o.key).map((o) => [o.id, o.key])),
      ciphers: (s.ciphers ?? []).filter((c) => !c.deletedDate).map(toSdkCipher) };
    await this.store?.saveSync?.(snap);
    return this.restore(snap);
  }
  /** Decrypts a sync snapshot (fresh, or the encrypted copy kept on disk) into the item list. */
  async restore({ orgKeys, ciphers }) {
    if (Object.keys(orgKeys).length) await this.client.crypto().initialize_org_crypto({ organizationKeys: orgKeys }).catch(() => {});
    this.ciphers = ciphers;
    const r = await this.client.vault().ciphers().decrypt_list_with_failures(ciphers);
    this.list = r.successes ?? r; this.syncedAt = Date.now();
    return { items: this.list.length, failed: (r.failures ?? []).length };
  }
  async view(id) { return this.client.vault().ciphers().decrypt(this.ciphers.find((c) => c.id === id)); }
  totp(key) { return this.client.vault().totp().generate_totp(key, Date.now()); }
  password(opts = {}) { return generatePassword(this.client, opts); }
  /** Logins for the page, best match first. */
  forPage(url) { return this.list.filter((v) => v.type?.login && matchesSite(v.type.login.uris, url)); }
  /** Saves a new login (the "save to AZET Pass" offer after a sign-in). */
  async saveLogin({ name, username, password, uri, totp }) {
    const view = { id: undefined, organizationId: undefined, folderId: undefined, collectionIds: [], key: undefined, name, notes: undefined, type: 1,
      login: { username, password, passwordRevisionDate: undefined, uris: [{ uri, match: undefined, uriChecksum: undefined }], totp: totp || undefined, autofillOnPageLoad: undefined, fido2Credentials: undefined },
      identity: undefined, card: undefined, secureNote: undefined, sshKey: undefined, bankAccount: undefined, driversLicense: undefined, passport: undefined,
      favorite: false, reprompt: 0, organizationUseTotp: true, edit: true, permissions: undefined, viewPassword: true, localData: undefined,
      attachments: undefined, fields: undefined, passwordHistory: undefined, creationDate: new Date().toISOString(), deletedDate: undefined,
      revisionDate: new Date().toISOString(), archivedDate: undefined };
    const { cipher } = await this.client.vault().ciphers().encrypt(view);
    const saved = await this.api("POST", "/api/ciphers", toRequest(cipher));
    await this.sync(); return saved.id;
  }
  /** Puts a new passkey on the login for its site and user (a new login if there is none). */
  async savePasskey(record, origin) {
    const ciphers = this.client.vault().ciphers();
    const mine = await Promise.all(this.forPage(origin).map((i) => this.view(i.id)));
    let view = mine.find((c) => (c.login?.username || "") === (record.userName || ""));
    const now = new Date().toISOString();
    if (!view) {
      view = { id: undefined, organizationId: undefined, folderId: undefined, collectionIds: [], key: undefined, name: record.rpName || record.rpId, notes: undefined, type: 1,
        login: { username: record.userName, password: undefined, passwordRevisionDate: undefined, uris: [{ uri: origin, match: undefined, uriChecksum: undefined }], totp: undefined, autofillOnPageLoad: undefined, fido2Credentials: undefined },
        identity: undefined, card: undefined, secureNote: undefined, sshKey: undefined, bankAccount: undefined, driversLicense: undefined, passport: undefined,
        favorite: false, reprompt: 0, organizationUseTotp: true, edit: true, permissions: undefined, viewPassword: true, localData: undefined,
        attachments: undefined, fields: undefined, passwordHistory: undefined, creationDate: now, deletedDate: undefined, revisionDate: now, archivedDate: undefined };
    }
    const withKey = ciphers.set_fido2_credentials(view, [record]);
    const { cipher } = await ciphers.encrypt(withKey);
    if (view.id) await this.api("PUT", `/api/ciphers/${view.id}`, toRequest(cipher, this.ciphers.find((c) => c.id === view.id)?.revisionDate));
    else await this.api("POST", "/api/ciphers", toRequest(cipher));
    await this.sync();
  }
  /** Passkeys saved for a relying party: [{ itemId, credentialId, userName }]. */
  passkeysFor(rpId) {
    return this.list.flatMap((i) => (i.type?.login?.fido2Credentials || []).filter((f) => f.rpId === rpId)
      .map((f) => ({ itemId: i.id, credentialId: f.credentialId, userName: f.userName || f.userDisplayName || i.name })));
  }
  /** The decrypted key and record for one passkey. */
  async passkeySecret(itemId, credentialId) {
    const ciphers = this.client.vault().ciphers(), view = await this.view(itemId);
    const rec = ciphers.decrypt_fido2_credentials(view).find((f) => f.credentialId === credentialId);
    return { rec, keyValue: ciphers.decrypt_fido2_private_key(view) };
  }
  /** A text Send: an encrypted link that opens in any browser, gone after `days` (and after one view if asked). */
  async sendText({ name, text, days = 7, oneView = false }) {
    const end = new Date(Date.now() + (days || 1 / 24) * 864e5).toISOString();
    const view = await this.client.sends().create({ name, notes: undefined, viewType: { Text: { text, hidden: true } },
      maxAccessCount: oneView ? 1 : undefined, disabled: false, hideEmail: true, deletionDate: end, expirationDate: end, auth: { type: "none" } });
    this.lastSendId = view.id;
    return `${this.base}/#/send/${view.accessId}/${view.key.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")}`;
  }
  /** New password for a saved login; the old one goes to its password history. */
  async updatePassword(id, password) {
    const old = this.ciphers.find((c) => c.id === id), view = await this.view(id), now = new Date().toISOString();
    view.passwordHistory = [{ password: view.login.password, lastUsedDate: now }, ...(view.passwordHistory || [])].slice(0, 5);
    view.login.password = password; view.login.passwordRevisionDate = now;
    const { cipher } = await this.client.vault().ciphers().encrypt(view);
    await this.api("PUT", `/api/ciphers/${id}`, toRequest(cipher, old.revisionDate));
    await this.sync(); return id;
  }
  lock() { this.client?.free?.(); this.client = null; this.list = []; this.ciphers = []; this.userKey = null; }
}

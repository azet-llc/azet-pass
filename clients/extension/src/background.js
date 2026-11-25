// AZET Pass extension background: holds the unlocked vault, answers the popup and the page scripts.
// Account tokens and the encrypted sync copy live in storage.local; the decrypted user key only in
// storage.session (memory, gone when the browser quits) and is dropped on lock.
import * as bg from "./sdk/bitwarden_wasm_internal_bg.js";
import { Vault, hostOf, generatePassword } from "./vault-core.mjs";
import { passwordHealth } from "./health.mjs";
import { pinWrap, pinUnwrap, csvLogins, maskedEmail, lookalike } from "./extras.mjs";
import { createPasskey, signAssertion, rpAllowed, credIdString, fromB64u } from "./passkey.mjs";

const BASE = "https://pass.azet.io";
const local = chrome.storage.local, session = chrome.storage.session;
let sdkReady, vault, opening, bareClient;

function sdk() {
  return (sdkReady ??= (async () => {
    const bytes = await (await fetch(chrome.runtime.getURL("sdk/bitwarden_wasm_internal_bg.wasm"))).arrayBuffer();
    const { instance } = await WebAssembly.instantiate(bytes, { "./bitwarden_wasm_internal_bg.js": bg });
    bg.__wbg_set_wasm(instance.exports);
    return bg;
  })());
}

const store = {
  saveAccount: (account) => local.set({ account }),
  saveUserKey: (userKey) => session.set({ userKey }),
  saveSync: (snap) => local.set({ snap }),
};

async function deviceId() {
  let { deviceId: id } = await local.get("deviceId");
  if (!id) { id = crypto.randomUUID(); await local.set({ deviceId: id }); }
  return id;
}

async function newVault() {
  const isFirefox = typeof browser !== "undefined" || navigator.userAgent.includes("Firefox");
  return new Vault({ sdk: await sdk(), base: BASE, deviceId: await deviceId(), deviceType: isFirefox ? 3 : 2, store,
    deviceName: isFirefox ? "AZET Pass for Firefox" : "AZET Pass for Chrome" });
}

/** The unlocked vault, rebuilt from the session key after the worker slept; null when locked. */
async function openVault() {
  if (vault?.client) return vault;
  return (opening ??= (async () => {
    try {
      const { account, snap } = await local.get(["account", "snap"]);
      const { userKey } = await session.get("userKey");
      if (!account) return null;
      if (!userKey) return await openedWithDesktop();
      const v = await newVault(); v.account = account; await v.resume(userKey);
      if (snap) await v.restore(snap); else await v.sync();
      vault = v; return v;
    } finally { opening = null; }
  })());
}

async function state() {
  const { account } = await local.get("account");
  if (!account) return { phase: "signedOut" };
  const v = await openVault();
  return { phase: v ? "unlocked" : "locked", email: account.email, items: v?.list.length ?? 0, syncedAt: v?.syncedAt };
}

async function lock() {
  vault?.lock(); vault = null;
  await session.remove(["userKey", "pending"]);
  chrome.action.setBadgeText({ text: "" });
}

async function touch() {
  const { lockMinutes = 15 } = await local.get("lockMinutes");
  if (lockMinutes > 0) chrome.alarms.create("autolock", { delayInMinutes: lockMinutes });
}
chrome.alarms.onAlarm.addListener((a) => { if (a.name === "autolock") lock(); if (a.name === "sync") openVault().then((v) => v?.sync()).catch(() => {}); });
chrome.runtime.onInstalled.addListener(() => chrome.alarms.create("sync", { periodInMinutes: 30 }));

const TYPES = { 1: "login", 2: "note", 3: "card", 4: "identity", 5: "sshKey" };
const kindOf = (item) => (item.type?.login ? "login" : item.type?.card ? "card" : typeof item.type === "string" ? item.type : "other");
const row = (item) => ({ id: item.id, name: item.name, sub: item.subtitle, kind: kindOf(item), favorite: item.favorite,
  totp: (item.copyableFields || []).includes("LoginTotp") });

async function listFor(url) {
  const v = await openVault(); if (!v) return null;
  const host = hostOf(url);
  const saved = v.list.flatMap((i) => (i.type?.login?.uris || []).map((u) => hostOf(u.uri || ""))).filter((h) => h.includes("."));
  return { host, warn: host ? lookalike(host, saved) : null,
    here: v.forPage(url).map(row), all: v.list.map(row).sort((a, b) => a.name.localeCompare(b.name)) };
}

/** Only the fields the caller acts on leave the background. */
async function secret(id) {
  const v = await openVault(); if (!v) throw new Error("locked");
  const c = await v.view(id); const out = { name: c.name, kind: TYPES[c.type] || "other" };
  // Marked "ask for the password again": nothing of it leaves the background here; it is opened in the app or the web vault.
  if (c.reprompt) throw new Error(chrome.i18n.getMessage("repromptItem"));
  if (c.login) Object.assign(out, { username: c.login.username, password: c.login.password, uri: c.login.uris?.[0]?.uri,
    totp: c.login.totp ? v.totp(c.login.totp) : null });
  if (c.card) out.card = c.card;
  if (c.identity) out.identity = c.identity;
  if (c.notes) out.notes = c.notes;
  return out;
}

async function fillTab(tabId, id) {
  const s = await secret(id);
  // Every frame hears this, so it names the page's own host: a frame of another site (an ad, a widget) does not fill.
  const tab = await chrome.tabs.get(tabId);
  await chrome.tabs.sendMessage(tabId, { azet: "fill", host: new URL(tab.url).hostname, data: { username: s.username, password: s.password, card: s.card, identity: s.identity, code: s.totp?.code } });
  return { totp: s.totp?.code ?? null };
}

/** A sign-in the page just submitted: offer to save it unless the vault already has that username here. */
async function submitted(msg, sender) {
  if (!msg.password || !sender.tab) return;
  msg = { ...msg, url: sender.url }; // where the frame really is, not where it says it is
  const v = await openVault();
  if (!v) { await session.set({ pending: { ...msg, tabId: sender.tab.id } }); chrome.action.setBadgeText({ text: "1" }); return; }
  const known = await Promise.all(v.forPage(msg.url).map((i) => v.view(i.id)));
  const same = known.find((c) => (c.login?.username || "") === (msg.username || ""));
  if (same && same.login?.password === msg.password) return;
  await session.set({ offer: { ...msg, updateId: same?.id ?? null } });
  chrome.tabs.sendMessage(sender.tab.id, { azet: "offerSave", update: !!same, host: hostOf(msg.url) }).catch(() => {});
}

async function acceptOffer() {
  const { offer } = await session.get("offer"); if (!offer) return null;
  const v = await openVault(); if (!v) throw new Error("locked");
  await session.remove("offer");
  if (offer.updateId) return v.updatePassword(offer.updateId, offer.password);
  return v.saveLogin({ name: hostOf(offer.url), username: offer.username, password: offer.password, uri: new URL(offer.url).origin });
}

// Passkeys: the page script asks, the person picks in our bar, the background signs. The origin comes from the
// browser (sender.url), never from the page; sub-frames from another origin go to the browser's own sheet.
function passkeyOrigin(sender, rpId) {
  if (!sender.url || !sender.tab) return null;
  const origin = new URL(sender.url).origin;
  if (sender.frameId && new URL(sender.tab.url).origin !== origin) return null;
  return rpAllowed(rpId, sender.url) ? origin : null;
}
async function passkeyPrepare({ kind, req }, sender) {
  const rpId = kind === "create" ? req.rp?.id : req.rpId;
  if (!passkeyOrigin(sender, rpId)) return { use: false };
  const v = await openVault(); if (!v) return { use: false, locked: true };
  const saved = v.passkeysFor(rpId);
  if (kind === "create") {
    const exclude = new Set((req.exclude || []).map((b) => credIdString(fromB64u(b))));
    return saved.some((p) => exclude.has(p.credentialId)) ? { use: false } : { use: true, host: rpId };
  }
  const allow = new Set((req.allow || []).map((b) => credIdString(fromB64u(b))));
  const choices = saved.filter((p) => !allow.size || allow.has(p.credentialId));
  return choices.length ? { use: true, host: rpId, choices } : { use: false };
}
async function passkeyComplete({ kind, req, choice }, sender) {
  const rpId = kind === "create" ? req.rp?.id : req.rpId, origin = passkeyOrigin(sender, rpId);
  if (!origin) throw new Error("origin");
  const v = await openVault(); if (!v) throw new Error("locked");
  if (kind === "create") { const { response, record } = await createPasskey(req, origin); await v.savePasskey(record, origin); return response; }
  const { rec, keyValue } = await v.passkeySecret(choice.itemId, choice.credentialId);
  return signAssertion(req, origin, rec, keyValue);
}

// Touch ID unlock through AZET Desktop on a Mac: the user key stays here, wrapped (AES-GCM) with a random key that the
// helper io.azet.pass keeps and hands back only after AZET Pass on the Mac approves (Touch ID, the paired phone, or at
// once in bypass mode). Without the helper nothing changes.
const HOST = "io.azet.pass";
const b64 = (u8) => btoa(String.fromCharCode(...u8));
const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
const native = (msg) => new Promise((res) => {
  try { chrome.runtime.sendNativeMessage(HOST, msg, (r) => res(chrome.runtime.lastError ? null : r)); } catch { res(null); }
});
async function desktopState() {
  const { desktopUnlock, desktopAsked } = await local.get(["desktopUnlock", "desktopAsked"]);
  const ping = await native({ op: "ping" });
  // asked: it was turned on or off once already, so the popup does not turn it on by itself again.
  return { helper: !!ping?.ok, on: !!desktopUnlock && !!ping?.ok, asked: !!desktopAsked };
}
async function desktopOn() {
  const v = await openVault(); if (!v?.userKey) throw new Error("locked");
  const raw = crypto.getRandomValues(new Uint8Array(32)), iv = crypto.getRandomValues(new Uint8Array(12)), id = crypto.randomUUID();
  const key = await crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt"]);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(v.userKey)));
  const r = await native({ op: "store", id, key: b64(raw) });
  if (!r?.ok) throw new Error("AZET Desktop helper is not installed on this Mac");
  await local.set({ desktopUnlock: { id, iv: b64(iv), ct: b64(ct) }, desktopAsked: true });
  return desktopState();
}
async function desktopOff() {
  const { desktopUnlock } = await local.get("desktopUnlock");
  if (desktopUnlock) await native({ op: "forget", id: desktopUnlock.id });
  await local.remove("desktopUnlock"); await local.set({ desktopAsked: true });
  return desktopState();
}
// One lock (11-25): while AZET Desktop's vault is open, a page that needs the vault opens it without the popup.
// Only with a helper that answers ifOpen (it never prompts); a locked desktop gets nothing, tried at most every 30 s.
let desktopTriedAt = 0;
async function openedWithDesktop() {
  const { desktopUnlock } = await local.get("desktopUnlock");
  if (!desktopUnlock || Date.now() - desktopTriedAt < 30_000) return null;
  desktopTriedAt = Date.now();
  const ping = await native({ op: "ping" });
  if (!ping?.ifOpen) return null;
  try { return await desktopVault(true); } catch { return null; }
}
async function unlockWithDesktop() {
  await desktopVault(false);
  return state();
}
async function desktopVault(ifOpen) {
  const { desktopUnlock: d, account } = await local.get(["desktopUnlock", "account"]);
  if (!d || !account) throw new Error("Touch ID unlock is off");
  const r = await native({ op: "release", id: d.id, reason: "unlock AZET Pass in this browser", ...(ifOpen ? { ifOpen: true } : {}) });
  if (!r?.ok) throw new Error(r?.error || "AZET Desktop did not answer");
  const key = await crypto.subtle.importKey("raw", unb64(r.key), "AES-GCM", false, ["decrypt"]);
  const userKey = new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: unb64(d.iv) }, key, unb64(d.ct)));
  const v = await newVault(); v.account = account; await v.resume(userKey); await store.saveUserKey(userKey);
  const { snap } = await local.get("snap"); if (snap) await v.restore(snap); else await v.sync();
  vault = v; await touch(); v.sync().catch(() => {});
  return v;
}

let pinTurn = Promise.resolve();
const pinSealed = async () => (await session.get("pin")).pin ?? (await local.get("pin")).pin;
const handlers = {
  desktopState, desktopOn, desktopOff, unlockWithDesktop,
  passkeyPrepare,
  passkeyComplete,
  state,
  async signIn({ email, password, code }) {
    const v = await newVault(); await v.signIn(email, password, code); await v.sync(); vault = v; await touch(); return state();
  },
  async unlock({ password }) {
    const { account, unlockFails = 0 } = await local.get(["account", "unlockFails"]); const v = await newVault(); v.account = account;
    try { await v.unlock(password); } catch (e) {
      // Ten wrong passwords in a row sign this browser out (the vault stays in the account).
      if (unlockFails + 1 >= 10) { await handlers.signOut(); throw new Error(chrome.i18n.getMessage("tooManyTries")); }
      await local.set({ unlockFails: unlockFails + 1 }); throw e;
    }
    await local.remove("unlockFails"); await v.sync(); vault = v; await touch();
    const { pending } = await session.get("pending");
    if (pending) { await session.remove("pending"); chrome.action.setBadgeText({ text: "" }); await submitted(pending, { tab: { id: pending.tabId } }); }
    return state();
  },
  lock: async () => { await lock(); return state(); },
  async signOut() { await desktopOff().catch(() => {}); await lock(); await local.remove(["account", "snap", "pin", "pinFails", "unlockFails", "desktopAsked"]); await session.remove("pin"); return state(); },
  async pinState() { return { on: !!(await pinSealed()) }; },
  async pinOn({ pin, everyStart }) {
    const v = await openVault(); if (!v?.userKey) throw new Error("locked");
    if ((pin || "").length < 4 || pin.length > 64) throw new Error(chrome.i18n.getMessage("pinRule"));
    // By default the PIN lives in the browser's memory: it opens the vault after a lock, and a restarted browser asks
    // for the account password again, so nothing a PIN can open sits on disk. `everyStart: false` keeps it on disk.
    await local.remove("pin"); await session.remove("pin");
    await (everyStart === false ? local : session).set({ pin: await pinWrap(v.userKey, pin) });
    await local.set({ pinFails: 0 }); return { on: true };
  },
  async pinOff() { await local.remove(["pin", "pinFails"]); await session.remove("pin"); return { on: false }; },
  async unlockWithPin({ pin }) {
    // One try at a time, and the try is counted before the slow check: many tries sent together cannot share one count.
    const turn = pinTurn; let done; pinTurn = new Promise((r) => (done = r)); await turn;
    let userKey, account, snap;
    try {
      const got = await local.get(["pinFails", "account", "snap"]); ({ account, snap } = got);
      const sealed = await pinSealed(), pinFails = got.pinFails || 0;
      if (!sealed || !account) throw new Error(chrome.i18n.getMessage("pinGone"));
      // Five wrong PINs sign this browser out: the account password, and the second step if there is one, are needed again.
      if (pinFails >= 5) { await handlers.signOut(); throw new Error(chrome.i18n.getMessage("pinGone")); }
      await local.set({ pinFails: pinFails + 1 });
      userKey = await pinUnwrap(sealed, pin || "");
      if (!userKey) {
        if (pinFails + 1 >= 5) { await handlers.signOut(); throw new Error(chrome.i18n.getMessage("pinGone")); }
        throw new Error(chrome.i18n.getMessage("pinWrong", [String(4 - pinFails)]));
      }
      await local.set({ pinFails: 0 });
    } finally { done(); }
    const v = await newVault(); v.account = account; await v.resume(userKey); await store.saveUserKey(userKey);
    if (snap) await v.restore(snap); else await v.sync();
    vault = v; await touch(); v.sync().catch(() => {});
    return state();
  },
  async importCsv({ text }) {
    const v = await openVault(); if (!v) throw new Error("locked");
    const have = new Set(v.list.map(row).map((r) => `${r.name}\n${r.sub || ""}`));
    const fresh = csvLogins(text).filter((l) => !have.has(`${l.name}\n${l.username || ""}`));
    for (const l of fresh) await v.saveLogin(l);
    if (fresh.length) await v.sync();
    return { added: fresh.length, skipped: csvLogins(text).length - fresh.length };
  },
  async maskedEmail({ url }) { const { account } = await local.get("account"); return maskedEmail(account?.email || "", hostOf(url || "")); },
  async sync() { const v = await openVault(); if (!v) throw new Error("locked"); return v.sync(); },
  list: ({ url }) => listFor(url),
  secret: ({ id }) => secret(id),
  fill: ({ tabId, id }) => fillTab(tabId, id),
  async generate({ length, special }) {
    const c = (await openVault())?.client ?? (bareClient ??= new (await sdk()).PasswordManagerClient({ get_access_token: async () => null }, null));
    return generatePassword(c, { length, special });
  },
  async health() { const v = await openVault(); if (!v) throw new Error("locked"); return passwordHealth(v); },
  async settings({ lockMinutes, offerSave } = {}) {
    if (lockMinutes !== undefined) await local.set({ lockMinutes: Math.max(1, Math.min(1440, +lockMinutes || 15)) });
    if (offerSave !== undefined) await local.set({ offerSave: !!offerSave });
    return local.get(["lockMinutes", "offerSave"]);
  },
  async sendText(o) { const v = await openVault(); if (!v) throw new Error("locked"); return v.sendText(o); },
  submitted,
  // One-time code boxes: which logins for the page that sent this (its own frame address, not one it claims) have codes.
  async otpChoices(_m, sender) { const v = await openVault(); return v ? v.forPage(sender.url).map(row).filter((r) => r.totp) : null; },
  async otpCode({ id }, sender) {
    const v = await openVault(); if (!v) throw new Error("locked");
    if (!v.forPage(sender.url).some((i) => i.id === id)) throw new Error("not a login for this site");
    return (await secret(id)).totp?.code ?? null;
  },
  acceptOffer,
  declineOffer: () => session.remove("offer"),
};

// What a page's own script may ask for. Everything else (the list, a secret, sign-in, PIN, unlock, settings) is for the
// extension's own pages only, so a compromised page process cannot reach it.
const PAGE_OK = new Set(["submitted", "otpChoices", "otpCode", "passkeyPrepare", "passkeyComplete", "acceptOffer", "declineOffer"]);
chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  const h = handlers[msg?.type]; if (!h) return false;
  const own = sender.id === chrome.runtime.id && (sender.url || "").startsWith(chrome.runtime.getURL(""));
  if (!own && !PAGE_OK.has(msg.type)) return false;
  // Only the person's own use of the popup keeps the vault open; a page cannot hold it open by sending messages.
  Promise.resolve(h(msg, sender)).then((result) => { if (own && msg.type !== "state") touch(); reply({ ok: true, result }); },
    (e) => reply({ ok: false, error: e.twoFactor ? "twoFactor" : String(e.message || e) }));
  return true;
});

// Keyboard shortcut: fill the first match for the page in front.
chrome.commands?.onCommand.addListener(async (command) => {
  if (command !== "fill-login") return;
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const l = tab && (await listFor(tab.url));
  if (!l) { chrome.action.openPopup?.(); return; }
  if (l.here[0]) fillTab(tab.id, l.here[0].id).catch(() => {});
});

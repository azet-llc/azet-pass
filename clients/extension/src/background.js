// AZET Pass extension background: holds the unlocked vault, answers the popup and the page scripts.
// Account tokens and the encrypted sync copy live in storage.local; the decrypted user key only in
// storage.session (memory, gone when the browser quits) and is dropped on lock.
import * as bg from "./sdk/bitwarden_wasm_internal_bg.js";
import { Vault, hostOf, generatePassword } from "./vault-core.mjs";
import { passwordHealth } from "./health.mjs";
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
      if (!account || !userKey) return null;
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
  return { host, here: v.forPage(url).map(row), all: v.list.map(row).sort((a, b) => a.name.localeCompare(b.name)) };
}

/** Only the fields the caller acts on leave the background. */
async function secret(id) {
  const v = await openVault(); if (!v) throw new Error("locked");
  const c = await v.view(id); const out = { name: c.name, kind: TYPES[c.type] || "other" };
  if (c.login) Object.assign(out, { username: c.login.username, password: c.login.password, uri: c.login.uris?.[0]?.uri,
    totp: c.login.totp ? v.totp(c.login.totp) : null });
  if (c.card) out.card = c.card;
  if (c.identity) out.identity = c.identity;
  if (c.notes) out.notes = c.notes;
  return out;
}

async function fillTab(tabId, id) {
  const s = await secret(id);
  await chrome.tabs.sendMessage(tabId, { azet: "fill", data: { username: s.username, password: s.password, card: s.card, identity: s.identity } });
  return { totp: s.totp?.code ?? null };
}

/** A sign-in the page just submitted: offer to save it unless the vault already has that username here. */
async function submitted(msg, sender) {
  if (!msg.password || !sender.tab) return;
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

const handlers = {
  passkeyPrepare,
  passkeyComplete,
  state,
  async signIn({ email, password, code }) {
    const v = await newVault(); await v.signIn(email, password, code); await v.sync(); vault = v; await touch(); return state();
  },
  async unlock({ password }) {
    const { account } = await local.get("account"); const v = await newVault(); v.account = account;
    await v.unlock(password); await v.sync(); vault = v; await touch();
    const { pending } = await session.get("pending");
    if (pending) { await session.remove("pending"); chrome.action.setBadgeText({ text: "" }); await submitted(pending, { tab: { id: pending.tabId } }); }
    return state();
  },
  lock: async () => { await lock(); return state(); },
  async signOut() { await lock(); await local.remove(["account", "snap"]); return state(); },
  async sync() { const v = await openVault(); if (!v) throw new Error("locked"); return v.sync(); },
  list: ({ url }) => listFor(url),
  secret: ({ id }) => secret(id),
  fill: ({ tabId, id }) => fillTab(tabId, id),
  async generate({ length, special }) {
    const c = (await openVault())?.client ?? (bareClient ??= new (await sdk()).PasswordManagerClient({ get_access_token: async () => null }, null));
    return generatePassword(c, { length, special });
  },
  async health() { const v = await openVault(); if (!v) throw new Error("locked"); return passwordHealth(v); },
  async settings(patch) { if (patch) await local.set(patch); return local.get(["lockMinutes", "offerSave"]); },
  async sendText(o) { const v = await openVault(); if (!v) throw new Error("locked"); return v.sendText(o); },
  submitted,
  acceptOffer,
  declineOffer: () => session.remove("offer"),
};

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  const h = handlers[msg?.type]; if (!h) return false;
  Promise.resolve(h(msg, sender)).then((result) => { if (msg.type !== "state") touch(); reply({ ok: true, result }); },
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

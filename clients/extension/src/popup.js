const t = (k, ...a) => chrome.i18n.getMessage(k, a) || k;
const $ = (id) => document.getElementById(id);
const call = async (type, args = {}) => {
  const r = await chrome.runtime.sendMessage({ type, ...args });
  if (!r?.ok) throw Object.assign(new Error(r?.error || "error"), { code: r?.error });
  return r.result;
};
for (const el of document.querySelectorAll("[data-i18n]")) el.textContent = t(el.dataset.i18n);
for (const el of document.querySelectorAll("[data-i18n-placeholder]")) el.placeholder = t(el.dataset.i18nPlaceholder);

const showErr = (e) => { $("err").textContent = e ? (e.code === "locked" ? t("lockedNow") : e.message) : ""; $("err").hidden = !e; };
const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });

async function copy(text) {
  await navigator.clipboard.writeText(text);
  // Clear the clipboard after 30 s if it still holds what we put there (only while the popup is open).
  setTimeout(async () => { try { if ((await navigator.clipboard.readText()) === text) await navigator.clipboard.writeText(""); } catch {} }, 30000);
}

function itemRow(item) {
  const li = document.createElement("li");
  li.innerHTML = `<div class="who"><b></b><span></span></div><div class="acts"></div>`;
  li.querySelector("b").textContent = item.name;
  li.querySelector("span").textContent = item.sub || t(item.kind);
  const acts = li.querySelector(".acts");
  const btn = (label, fn, cls = "secondary") => { const b = Object.assign(document.createElement("button"), { textContent: t(label), className: cls }); b.onclick = () => fn().catch(showErr); acts.append(b); };
  if (item.kind === "login" || item.kind === "card" || item.kind === "identity") btn("fill", async () => {
    const r = await call("fill", { tabId: tab.id, id: item.id });
    if (r.totp) { await copy(r.totp); $("err").hidden = true; }
    window.close();
  }, "");
  if (item.kind === "login") {
    btn("copyUser", async () => copy((await call("secret", { id: item.id })).username || ""));
    btn("copyPassword", async () => copy((await call("secret", { id: item.id })).password || ""));
  }
  if (item.totp) btn("copyCode", async () => copy((await call("secret", { id: item.id })).totp?.code || ""));
  return li;
}

let all = [];
function renderAll() {
  const q = $("q").value.trim().toLowerCase();
  $("allList").replaceChildren(...all.filter((i) => !q || (i.name + " " + (i.sub || "")).toLowerCase().includes(q)).slice(0, 200).map(itemRow));
}

async function showUnlocked() {
  $("lockBtn").hidden = false;
  const l = await call("list", { url: tab?.url || "" });
  $("host").textContent = l.host;
  $("hereList").replaceChildren(...l.here.map(itemRow));
  $("hereEmpty").hidden = l.here.length > 0;
  $("warn").hidden = !l.warn; if (l.warn) $("warn").textContent = t("lookalike", l.host, l.warn);
  call("pinState").then((p) => { $("pinToggle").textContent = t(p.on ? "pinOff" : "pinOn"); $("pinToggle").dataset.on = p.on ? "1" : ""; }).catch(() => {});
  all = l.all; renderAll();
  if (!l.here.length) switchTab("all");
}

function switchTab(name) {
  for (const b of document.querySelectorAll(".tab")) b.classList.toggle("on", b.dataset.tab === name);
  for (const p of document.querySelectorAll(".pane")) p.hidden = p.id !== name;
  if (name === "gen" && !$("genOut").value) { newPassword(); newMask(); }
  if (name === "check") runCheck();
}

async function newPassword() { $("genOut").value = await call("generate", { length: +$("genLen").value, special: $("genSpecial").checked }); }

async function newMask() { $("maskOut").value = (await call("maskedEmail", { url: tab?.url || "" })) || ""; }

async function runCheck() {
  $("checkSum").textContent = t("checking");
  const h = await call("health");
  $("checkSum").textContent = t("checkSummary", String(h.checked), String(h.weak), String(h.reused), String(h.old));
  $("checkList").replaceChildren(...h.rows.slice(0, 100).map((r) => {
    const li = document.createElement("li"); li.innerHTML = "<b></b> <span class='note'></span>";
    li.querySelector("b").textContent = r.name;
    li.querySelector("span").textContent = [r.weak && t("weak"), r.reused && t("reused"), r.old && t("old")].filter(Boolean).join(" · ");
    return li;
  }));
}

async function render() {
  showErr(null);
  const s = await call("state");
  for (const id of ["signedOut", "locked", "unlocked"]) $(id).hidden = id !== s.phase;
  $("lockBtn").hidden = s.phase !== "unlocked";
  if (s.phase === "locked") { $("lockedAs").textContent = t("lockedAs", s.email); $("unlockPw").focus(); }
  if (s.phase === "locked") call("pinState").then((p) => { $("pinForm").hidden = !p.on; if (p.on) $("pinIn").focus(); }).catch(() => {});
  if (s.phase !== "signedOut") call("desktopState").then((d) => {
    $("desktopUnlock").hidden = !(s.phase === "locked" && d.on);
    $("desktopToggleWrap").hidden = !(s.phase === "unlocked" && d.helper);
    $("desktopToggle").textContent = t(d.on ? "desktopOff" : "desktopOn");
    $("desktopToggle").dataset.on = d.on ? "1" : "";
  }).catch(() => {});
  if (s.phase === "signedOut") $("email").focus();
  if (s.phase === "unlocked") await showUnlocked();
}

$("signInForm").onsubmit = async (e) => {
  e.preventDefault();
  try { await call("signIn", { email: $("email").value, password: $("password").value, code: $("code").value || undefined }); $("password").value = ""; await render(); }
  catch (err) { if (err.code === "twoFactor") { $("code").hidden = false; $("code").focus(); showErr(new Error(t("enterCode"))); } else showErr(err); }
};
$("unlockForm").onsubmit = async (e) => {
  e.preventDefault();
  try { await call("unlock", { password: $("unlockPw").value }); $("unlockPw").value = ""; await render(); } catch (err) { showErr(err); }
};
$("pinForm").onsubmit = async (e) => {
  e.preventDefault();
  try { await call("unlockWithPin", { pin: $("pinIn").value }); $("pinIn").value = ""; await render(); } catch (err) { $("pinIn").value = ""; await render(); showErr(err); }
};
$("pinToggle").onclick = async (e) => {
  e.preventDefault();
  try {
    if ($("pinToggle").dataset.on) { await call("pinOff"); await showUnlocked(); }
    else { $("pinSet").hidden = !$("pinSet").hidden; $("pinNew").focus(); }
  } catch (err) { showErr(err); }
};
$("pinSet").onsubmit = async (e) => {
  e.preventDefault();
  try { await call("pinOn", { pin: $("pinNew").value }); $("pinNew").value = ""; $("pinSet").hidden = true; await showUnlocked(); } catch (err) { showErr(err); }
};
// A file picker closes the toolbar popup in some browsers, so importing runs in a tab of its own.
$("csvPick").onclick = (e) => {
  e.preventDefault();
  if (location.hash === "#import") $("csvFile").click(); else chrome.tabs.create({ url: chrome.runtime.getURL("popup.html#import") });
};
$("csvFile").onchange = async () => {
  const f = $("csvFile").files[0]; if (!f) return;
  try { const r = await call("importCsv", { text: await f.text() }); await showUnlocked(); showErr(new Error(t("imported", String(r.added), String(r.skipped)))); } catch (err) { showErr(err); }
  $("csvFile").value = "";
};
$("maskNew").onclick = () => newMask().catch(showErr);
$("maskCopy").onclick = () => copy($("maskOut").value).catch(showErr);
$("lockBtn").onclick = () => call("lock").then(render, showErr);
$("desktopUnlock").onclick = async () => { try { await call("unlockWithDesktop"); await render(); } catch (err) { showErr(err); } };
$("desktopToggle").onclick = async (e) => { e.preventDefault(); try { await call($("desktopToggle").dataset.on ? "desktopOff" : "desktopOn"); await render(); } catch (err) { showErr(err); } };
$("signOut").onclick = (e) => { e.preventDefault(); call("signOut").then(render, showErr); };
$("syncNow").onclick = (e) => { e.preventDefault(); call("sync").then(showUnlocked, showErr); };
$("q").oninput = renderAll;
for (const b of document.querySelectorAll(".tab")) b.onclick = () => switchTab(b.dataset.tab);
$("genLen").oninput = () => { $("genLenV").textContent = $("genLen").value; newPassword().catch(showErr); };
$("genSpecial").onchange = () => newPassword().catch(showErr);
$("genNew").onclick = () => newPassword().catch(showErr);
$("genCopy").onclick = () => copy($("genOut").value).catch(showErr);
$("sendMake").onclick = async () => {
  const text = $("sendText").value.trim(); if (!text) return;
  try {
    const link = await call("sendText", { name: text.split("\n")[0].slice(0, 40), text, days: +$("sendDays").value, oneView: $("sendOnce").checked });
    $("sendLink").value = link; $("sendLink").hidden = false; await copy(link); $("sendText").value = "";
    showErr(new Error(t("sendCopied")));
  } catch (e) { showErr(e); }
};
render().catch(showErr);

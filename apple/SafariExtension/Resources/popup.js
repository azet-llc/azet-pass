// Popup: asks the app's native handler for the logins of the open site, then fills the page's sign-in box.
const $ = (s) => document.querySelector(s);
const t = (k) => browser.i18n.getMessage(k) || k;
let tab;

const ask = (msg) => browser.runtime.sendNativeMessage("io.azet.pass.safari", { ...msg, url: tab?.url ?? "" });

function show(r) {
  $("#host").textContent = r.host || "";
  for (const s of ["signedOut", "locked", "unlocked"]) $("#" + s).hidden = r.state !== s;
  $("#lockBtn").hidden = r.state !== "unlocked";
  if (r.state === "locked") {
    $("#touch").hidden = !r.touchID;
    $("#err").textContent = r.error || "";
    $("#pw").focus();
  }
  if (r.state === "unlocked") render(r.logins || []);
}

function button(label, onClick) {
  const b = document.createElement("button");
  b.textContent = label;
  b.addEventListener("click", onClick);
  return b;
}

async function copy(b, text) {
  await navigator.clipboard.writeText(text);
  b.textContent = t("copied");
}

function render(logins) {
  $("#none").hidden = logins.length > 0;
  $("#list").replaceChildren(...logins.map((l) => {
    const li = document.createElement("li");
    const who = document.createElement("div"); who.className = "who";
    const name = document.createElement("b"); name.textContent = l.name;
    const user = document.createElement("span"); user.textContent = l.username;
    who.append(name, user);
    const acts = document.createElement("div"); acts.className = "acts";
    acts.append(button(t("fill"), () => fill(l)));
    const cp = button(t("copyPassword"), () => copy(cp, l.password)); cp.className = "secondary"; acts.append(cp);
    if (l.totp) { const cc = button(`${t("copyCode")} ${l.totp}`, () => copy(cc, l.totp)); cc.className = "secondary"; acts.append(cc); }
    li.append(who, acts);
    return li;
  }));
}

async function fill(l) {
  const results = await browser.scripting.executeScript({ target: { tabId: tab.id, allFrames: true }, func: fillPage, args: [l.username, l.password] });
  if (results.some((r) => r.result)) window.close();
  else $("#note").textContent = t("noForm");
}

// Runs in the page: the visible password box, and the text box just before it as the username.
function fillPage(user, pass) {
  const visible = (e) => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
  const set = (e, v) => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(e, v);
    e.dispatchEvent(new Event("input", { bubbles: true }));
    e.dispatchEvent(new Event("change", { bubbles: true }));
  };
  const pw = [...document.querySelectorAll("input[type=password]")].find(visible);
  const scope = pw?.form ?? document;
  const users = [...scope.querySelectorAll("input:not([type]), input[type=text], input[type=email], input[type=tel]")].filter(visible);
  const u = pw ? users.filter((e) => e.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING).pop() : users[0];
  if (u && user) set(u, user);
  if (pw && pass) set(pw, pass);
  (pw ?? u)?.focus();
  return !!(u || pw);
}

document.querySelectorAll("[data-i18n]").forEach((e) => (e.textContent = t(e.dataset.i18n)));
document.querySelectorAll("[data-i18n-placeholder]").forEach((e) => (e.placeholder = t(e.dataset.i18nPlaceholder)));
$("#unlockForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const password = $("#pw").value;
  $("#pw").value = "";
  show(await ask({ cmd: "unlock", password }));
});
$("#touch").addEventListener("click", async () => show(await ask({ cmd: "unlock" })));
$("#lockBtn").addEventListener("click", async () => show(await ask({ cmd: "lock" })));

(async () => {
  [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  show(await ask({ cmd: "logins" }));
})();

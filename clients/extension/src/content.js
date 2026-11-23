// AZET Pass page script: fills what the person picked, notices a sign-in being submitted, and shows the
// "save to AZET Pass" bar. It never reads the vault; it only gets the one item the person chose.
(() => {
  if (window.__azetPass) return;
  window.__azetPass = true;
  const send = (m) => chrome.runtime.sendMessage(m).catch(() => {});

  const visible = (el) => !!el && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== "hidden" && !el.disabled && !el.readOnly;
  const inputs = (root = document) => [...root.querySelectorAll("input")].filter(visible);
  const passwordFields = () => inputs().filter((i) => i.type === "password");

  /** The username box: autocomplete says so, or the text/email box right before the password. */
  function usernameFor(pw) {
    const all = inputs(pw?.form || document).filter((i) => /^(text|email|tel|)$/.test(i.type));
    const tagged = all.find((i) => /username|email/.test(i.autocomplete));
    if (tagged) return tagged;
    const before = all.filter((i) => pw && (i.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING));
    return before.pop() || all.find((i) => /user|mail|login|id/i.test(i.name + i.id)) || null;
  }

  // React and friends listen to the native setter plus input/change events.
  function set(el, value) {
    if (!el || value == null) return;
    el.focus();
    const proto = el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, "value").set.call(el, value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    el.blur();
  }

  const AC = {
    "cc-name": (c) => c.cardholderName, "cc-number": (c) => c.number, "cc-csc": (c) => c.code,
    "cc-exp-month": (c) => c.expMonth, "cc-exp-year": (c) => c.expYear,
    "cc-exp": (c) => c.expMonth && c.expYear && `${String(c.expMonth).padStart(2, "0")}/${String(c.expYear).slice(-2)}`,
    "given-name": (_, i) => i.firstName, "family-name": (_, i) => i.lastName, name: (_, i) => [i.firstName, i.lastName].filter(Boolean).join(" "),
    email: (_, i) => i.email, tel: (_, i) => i.phone, organization: (_, i) => i.company, "street-address": (_, i) => [i.address1, i.address2].filter(Boolean).join(" "),
    "address-line1": (_, i) => i.address1, "address-line2": (_, i) => i.address2, "address-level1": (_, i) => i.state,
    "address-level2": (_, i) => i.city, "postal-code": (_, i) => i.postalCode, country: (_, i) => i.country, "country-name": (_, i) => i.country,
  };
  // Pages without autocomplete attributes: guess from the field's name.
  const GUESS = [[/card.?(num|no)|cardnumber|ccnum/i, "cc-number"], [/cvc|cvv|csc|security.?code/i, "cc-csc"], [/(exp|valid).*(month|mm)/i, "cc-exp-month"],
    [/(exp|valid).*(year|yy)/i, "cc-exp-year"], [/holder|name.?on.?card/i, "cc-name"], [/first.?name|given/i, "given-name"], [/last.?name|surname|family/i, "family-name"],
    [/e.?mail/i, "email"], [/phone|mobile|tel/i, "tel"], [/zip|postal|postcode/i, "postal-code"], [/city|town/i, "address-level2"], [/address|street/i, "address-line1"]];

  function fillProfile(card, identity) {
    let n = 0;
    for (const el of document.querySelectorAll("input, select")) {
      if (!visible(el) || el.type === "password" || el.type === "hidden") continue;
      const key = el.autocomplete?.split(" ").pop() || GUESS.find(([r]) => r.test(el.name + " " + el.id + " " + (el.placeholder || "")))?.[1];
      const value = key && AC[key]?.(card || {}, identity || {});
      if (value) { set(el, value); n++; }
    }
    return n;
  }

  function fill({ username, password, card, identity }) {
    if (card || identity) return fillProfile(card, identity);
    const pw = passwordFields()[0];
    set(usernameFor(pw), username);
    set(pw, password);
    return pw ? 1 : 0;
  }

  // Sign-in capture: on submit (or a click on the form's button) read the boxes once.
  let lastSent = "";
  function capture(form) {
    const pw = (form ? [...form.querySelectorAll("input[type=password]")] : passwordFields()).find((i) => i.value);
    if (!pw) return;
    const user = usernameFor(pw)?.value || "";
    const key = user + "\n" + pw.value;
    if (key === lastSent) return;
    lastSent = key;
    send({ type: "submitted", url: location.href, username: user, password: pw.value });
  }
  document.addEventListener("submit", (e) => capture(e.target), true);
  document.addEventListener("click", (e) => {
    const b = e.target.closest?.("button, input[type=submit], [role=button]");
    if (b && passwordFields().some((i) => i.value)) capture(b.form || b.closest("form"));
  }, true);
  document.addEventListener("keydown", (e) => { if (e.key === "Enter" && e.target?.type === "password") capture(e.target.form); }, true);

  // Our bars sit in a closed shadow root so the page can neither style nor read them; clicks must be real (isTrusted).
  function bar() {
    document.getElementById("azet-pass-bar")?.remove();
    const holder = Object.assign(document.createElement("div"), { id: "azet-pass-bar" });
    const root = holder.attachShadow({ mode: "closed" });
    const t = (k) => chrome.i18n.getMessage(k) || k;
    root.innerHTML = `<style>
      .bar{position:fixed;top:12px;right:12px;z-index:2147483647;display:flex;flex-wrap:wrap;gap:8px;align-items:center;padding:10px 12px;border-radius:10px;
      background:#fff;color:#15191c;box-shadow:0 6px 24px rgba(0,0,0,.18);font:13px system-ui,sans-serif;max-width:380px}
      @media (prefers-color-scheme:dark){.bar{background:#1c1f21;color:#f1f3f4}}
      img{width:20px;height:20px}span{flex:1;min-width:160px}.acts{display:flex;flex-wrap:wrap;gap:6px}
      button{border:0;border-radius:7px;padding:6px 10px;font:inherit;font-weight:600;cursor:pointer}
      .yes{background:#0d7d66;color:#fff}.no{background:transparent;color:inherit;border:1px solid #c9ced1}</style>
      <div class="bar" role="dialog"><img alt=""><span></span><div class="acts"></div></div>`;
    root.querySelector("img").src = chrome.runtime.getURL("images/icon-48.png");
    return { holder, root, t };
  }

  function offerSave(update, host) {
    const { holder, root, t } = bar();
    root.querySelector("span").textContent = t(update ? "barUpdate" : "barSave").replace("{host}", host);
    const acts = root.querySelector(".acts");
    for (const [label, cls, type] of [[t(update ? "update" : "save"), "yes", "acceptOffer"], [t("notNow"), "no", "declineOffer"]]) {
      const b = Object.assign(document.createElement("button"), { textContent: label, className: cls });
      b.onclick = (ev) => { if (!ev.isTrusted) return; send({ type }); holder.remove(); };
      acts.append(b);
    }
    document.documentElement.append(holder);
    setTimeout(() => holder.remove(), 30000);
  }

  // Passkey requests from the page script (page-webauthn.js). Nothing is signed without a real click in our bar.
  window.addEventListener("message", async (e) => {
    const m = e.data;
    if (e.source !== window || !m?.azetPasskey || !m.id) return;
    const answer = (result) => window.postMessage({ azetPasskeyReply: m.id, result }, location.origin);
    const kind = m.azetPasskey === "create" ? "create" : "get";
    const prep = await chrome.runtime.sendMessage({ type: "passkeyPrepare", kind, req: m.req }).catch(() => null);
    if (!prep?.ok || !prep.result.use) return answer(null);
    const choice = await passkeyBar(kind, prep.result);
    if (!choice) return answer(null);
    const done = await chrome.runtime.sendMessage({ type: "passkeyComplete", kind, req: m.req, choice: choice === true ? null : choice }).catch(() => null);
    answer(done?.ok ? { response: done.result } : null);
  });

  function passkeyBar(kind, { host, choices }) {
    return new Promise((resolve) => {
      const { holder, root, t } = bar();
      root.querySelector("span").textContent = t(kind === "create" ? "pkSave" : "pkUse").replace("{host}", host);
      const acts = root.querySelector(".acts");
      const button = (label, cls, value) => {
        const b = Object.assign(document.createElement("button"), { textContent: label, className: cls });
        b.onclick = (ev) => { if (!ev.isTrusted) return; holder.remove(); resolve(value); };
        acts.append(b);
      };
      if (kind === "create") button(t("save"), "yes", true);
      else for (const c of choices.slice(0, 4)) button(c.userName, "yes", { itemId: c.itemId, credentialId: c.credentialId });
      button(t("pkOther"), "no", null);
      document.documentElement.append(holder);
      setTimeout(() => { if (holder.isConnected) { holder.remove(); resolve(null); } }, 120000);
    });
  }

  chrome.runtime.onMessage.addListener((m, _s, reply) => {
    if (m?.azet === "fill") reply({ filled: fill(m.data) });
    else if (m?.azet === "offerSave") offerSave(m.update, m.host);
  });
})();

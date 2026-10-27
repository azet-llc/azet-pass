// AZET: email ownership check for sign-up (Bitwarden's emailed-token flow).
// send-verification-email mails a link with a signed token; verification-email-clicked and
// register(/finish) accept only a valid, unexpired token for that same address.
// Token = base64url(JSON {e: email, x: expiry ms}) + "." + base64url(HMAC-SHA256(JWT_SECRET, "pass-signup." + payload)).

const TTL_MS = 24 * 60 * 60 * 1000;
const enc = new TextEncoder();
const b64u = (bytes) => btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const unb64u = (s) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
const norm = (email) => (typeof email === "string" ? email.trim().toLowerCase() : "");

const hmacKey = (secret) =>
  crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
const hmac = async (secret, data) =>
  new Uint8Array(await crypto.subtle.sign("HMAC", await hmacKey(secret), enc.encode("pass-signup." + data)));

export async function makeSignupToken(secret, email, now = Date.now()) {
  const payload = b64u(enc.encode(JSON.stringify({ e: norm(email), x: now + TTL_MS })));
  return payload + "." + b64u(await hmac(secret, payload));
}

// "ok" | "expired" | "invalid"
export async function checkSignupToken(secret, email, token, now = Date.now()) {
  if (typeof token !== "string" || !email) return "invalid";
  const [payload, sig] = token.split(".");
  if (!payload || !sig) return "invalid";
  try {
    const good = await crypto.subtle.verify("HMAC", await hmacKey(secret), unb64u(sig), enc.encode("pass-signup." + payload));
    if (!good) return "invalid";
    const { e, x } = JSON.parse(new TextDecoder().decode(unb64u(payload)));
    if (e !== norm(email)) return "invalid";
    return now > x ? "expired" : "ok";
  } catch {
    return "invalid";
  }
}

const json = (status, body) =>
  new Response(body === null ? null : JSON.stringify(body), { status, headers: body === null ? {} : { "content-type": "application/json" } });
// Bitwarden ErrorResponse reads `message`; the client routes "Expired link" to its signup-link-expired page.
const error = (message) => json(400, { message, validationErrors: null, object: "error" });
const EXPIRED = "Expired link. Please restart registration or try logging in. You may already have an account";
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

async function limited(env, key) {
  if (!env.LOGIN_RATE_LIMITER) return false;
  const { success } = await env.LOGIN_RATE_LIMITER.limit({ key });
  return !success;
}

// Handles the sign-up routes that need the token; returns null for everything else.
// For register(/finish) it only checks the token and returns null so the request goes on to Rust.
export async function signupGate(request, env, url, ctx) {
  const p = url.pathname;
  if (request.method !== "POST") return null;
  const isSend = p === "/identity/accounts/register/send-verification-email";
  const isClick = p === "/identity/accounts/register/verification-email-clicked";
  const isRegister = p === "/identity/accounts/register" || p === "/identity/accounts/register/finish";
  if (!isSend && !isClick && !isRegister) return null;

  let body;
  try {
    body = await request.clone().json();
  } catch {
    return error("Invalid request.");
  }
  const email = norm(body?.email);
  const secret = env.JWT_SECRET;

  if (isSend) {
    if (!EMAIL_RE.test(email) || email.length > 254) return error("The Email field is not a valid e-mail address.");
    const ip = request.headers.get("cf-connecting-ip") || "unknown";
    if ((await limited(env, "signup-mail-ip:" + ip)) || (await limited(env, "signup-mail:" + email))) {
      return json(429, { message: "Too many requests. Please try again later.", object: "error" });
    }
    // An address that already has an account gets no mail, and the answer is the same (no account lookup by sign-up).
    const exists = await env.vault1.prepare("SELECT 1 FROM users WHERE email = ?1").bind(email).first();
    if (!exists) {
      const token = await makeSignupToken(secret, email);
      // redirect-connector form, as Bitwarden mails it: Android App Links cannot match a "#/" route, the web page forwards to it
      const link = `https://${url.host}/redirect-connector.html#finish-signup?token=${encodeURIComponent(token)}&email=${encodeURIComponent(email)}&fromEmail=true`;
      // sent after the answer, as AZET Shield does: the mail API takes seconds and the page waits on this call
      ctx.waitUntil(sendMail(env, email, link).catch((e) => console.error("pass-signup-mail", String(e))));
    }
    return json(204, null);
  }

  if (body?.email !== body?.email?.trim()) return error("The Email field is not a valid e-mail address.");
  // AZET families: a family invite link (sent by the organizer over KakaoTalk/SMS) stands in for the mail link, so a
  // parent signs up straight from the invite. Only for the exact address the organizer invited, while it is open.
  // ponytail: the address is vouched for by the organizer, not proven by mail; add a mail check if squatting shows up.
  if (isRegister && body?.orgInviteToken && body?.organizationUserId) {
    const open = await env.vault1
      .prepare("SELECT 1 FROM org_members WHERE id = ?1 AND invite_token = ?2 AND status = 0 AND email = ?3")
      .bind(String(body.organizationUserId), String(body.orgInviteToken), email)
      .first();
    return open ? null : error("This invite link has expired. Ask for a new one.");
  }
  const state = await checkSignupToken(secret, email, body?.emailVerificationToken ?? body?.token);
  if (state === "expired") return error(EXPIRED);
  if (state !== "ok") return error("Invalid email verification link. Please restart registration.");
  return isClick ? json(200, null) : null;
}

async function sendMail(env, to, link) {
  const lines = [
    "Confirm your email address to finish creating your AZET Pass account.",
    "The link works for 24 hours.",
  ];
  const foot = "If you did not ask to create an AZET Pass account, ignore this message. No account is made without this link.";
  const text = [...lines, "", `Finish creating your account: ${link}`, "", foot, "", "AZET Pass, AZET LLC"].join("\n");
  const html = `<div style="font:15px/1.6 -apple-system,Segoe UI,sans-serif;color:#0d0d0d;max-width:560px">${lines
    .map((l) => `<p style="margin:0 0 10px">${l}</p>`)
    .join("")}<p style="margin:18px 0"><a href="${link.replace(/&/g, "&amp;").replace(/"/g, "&quot;")}" style="background:#175ddc;color:#fff;text-decoration:none;padding:10px 18px;border-radius:999px;font-weight:600">Finish creating your account</a></p><div style="color:#5d5d5d;font-size:13px;border-top:1px solid #e5e5e5;margin-top:20px;padding-top:12px">${foot}<br>AZET Pass, AZET LLC</div></div>`;
  await sendPlainMail(env, { to, subject: "Confirm your email for AZET Pass", text, html });
}

export async function sendPlainMail(env, {to, subject, text, html}) {
  const msg = { from: { email: env.MAIL_FROM || "pass@azet.io", name: "AZET Pass" }, to, subject, text, ...(html ? {html} : {}) };
  if (env.MAIL_WEBHOOK) {
    const response = await fetch(env.MAIL_WEBHOOK, {method: "POST", headers: {"content-type": "application/json"}, body: JSON.stringify(msg)});
    if (!response.ok) throw new Error(`Mail webhook HTTP ${response.status}`);
  } else await env.EMAIL.send(msg);
}

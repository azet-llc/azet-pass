// Password check (Samsung Pass "safety"): weak, reused and old passwords, worst first. Values never leave here.
const YEAR = 365 * 864e5;
export function strength(pw) {
  if (!pw) return 0;
  const classes = [/[a-z]/, /[A-Z]/, /\d/, /[^A-Za-z0-9]/].filter((r) => r.test(pw)).length;
  const common = /^(password|qwerty|123456|111111|abc123|iloveyou|admin|letmein)/i.test(pw);
  return common ? 0 : Math.min(4, Math.floor(pw.length / 4) + classes - 2);
}
export async function passwordHealth(v) {
  const logins = v.list.filter((i) => i.type?.login).slice(0, 2000);
  const views = await Promise.all(logins.map((i) => v.view(i.id).catch(() => null)));
  const byPw = new Map();
  for (const c of views) if (c?.login?.password) byPw.set(c.login.password, (byPw.get(c.login.password) || 0) + 1);
  const rows = views.filter((c) => c?.login?.password).map((c) => {
    const pw = c.login.password, age = Date.now() - Date.parse(c.login.passwordRevisionDate || c.revisionDate);
    return { id: c.id, name: c.name, weak: strength(pw) < 2, reused: byPw.get(pw) > 1, old: age > YEAR };
  }).filter((r) => r.weak || r.reused || r.old);
  rows.sort((a, b) => b.weak + b.reused + b.old - (a.weak + a.reused + a.old));
  return { checked: views.length, weak: rows.filter((r) => r.weak).length, reused: rows.filter((r) => r.reused).length, old: rows.filter((r) => r.old).length, rows };
}

// AZET Pass browser helper (Chrome native messaging host io.azet.pass) on a Mac with AZET Desktop.
// The extension keeps its user key wrapped with a random key; this helper keeps only that wrapping key, in a private file,
// and hands it back after AZET Pass on the Mac approves (`azet-desktop pass confirm`: Touch ID, the paired phone, or at
// once in bypass mode). It never sees the vault or the user key.
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export const DIR = path.join(os.homedir(), "Library/Application Support/azet-desktop/azet-pass/browser-unlock");
const CLI = process.env.AZET_DESKTOP_CLI || "/Applications/AZET Desktop.app/Contents/Resources/bin/azet-desktop";
const ID = /^[0-9a-f-]{36}$/;

export function handle(msg, { approve = defaultApprove, dir = DIR } = {}) {
  const file = (id) => path.join(dir, `${id}.key`);
  switch (msg?.op) {
    case "ping": return { ok: true, desktop: fs.existsSync(CLI) };
    case "store": {
      if (!ID.test(msg.id || "") || !/^[A-Za-z0-9+/=]{40,64}$/.test(msg.key || "")) return { ok: false, error: "bad request" };
      fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
      fs.writeFileSync(file(msg.id), msg.key, { mode: 0o600 });
      return { ok: true };
    }
    case "release": {
      if (!ID.test(msg.id || "") || !fs.existsSync(file(msg.id))) return { ok: false, error: "not set up on this Mac" };
      if (!approve(String(msg.reason || "unlock AZET Pass in the browser").slice(0, 120))) return { ok: false, error: "not approved" };
      return { ok: true, key: fs.readFileSync(file(msg.id), "utf8") };
    }
    case "forget": {
      if (ID.test(msg.id || "")) fs.rmSync(file(msg.id), { force: true });
      return { ok: true };
    }
    default: return { ok: false, error: "unknown op" };
  }
}

function defaultApprove(reason) {
  const r = spawnSync(CLI, ["pass", "confirm", "--reason", reason], { stdio: "ignore", timeout: 150_000 });
  return r.status === 0;
}

// Chrome's framing: a 4-byte little-endian length, then that many bytes of JSON, on stdin and stdout.
function main() {
  let buf = Buffer.alloc(0);
  process.stdin.on("data", (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    while (buf.length >= 4) {
      const n = buf.readUInt32LE(0);
      if (buf.length < 4 + n) break;
      let reply;
      try { reply = handle(JSON.parse(buf.subarray(4, 4 + n).toString("utf8"))); } catch (e) { reply = { ok: false, error: String(e.message || e) }; }
      buf = buf.subarray(4 + n);
      const out = Buffer.from(JSON.stringify(reply)); const len = Buffer.alloc(4); len.writeUInt32LE(out.length);
      process.stdout.write(Buffer.concat([len, out]));
    }
  });
}
if (import.meta.url === `file://${process.argv[1]}`) main();

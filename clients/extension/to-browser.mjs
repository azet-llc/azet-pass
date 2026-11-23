// node to-browser.mjs [browser repo] — copies dist/chrome into AZET Browser's daemon/builtin/azet-pass with a fixed
// extension id (manifest "key"), so the built-in copy keeps its sign-in across updates. Run `node build.mjs` first.
// The store packages never carry this key; only the copy that ships inside AZET Browser does.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import os from "node:os";

// Public half of the id key (the private half is not needed: nothing here is packed as a CRX).
export const KEY = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAmoa8HuHYDxcWZKGzqXU9tVmsfGJAbz5jk4xitRPxFqyPnVQKao1eEH5AMrME6MHwWo85ToJQUfklbY6PmL1umDVnCGNzh2LK9XsgJ6XXZUTn+SVDwQRCf9yZyaQFNd4M7nJuHKYKzrV2r9Xmcbz9EHVc7HjeiBxAsRLGGmIYTVkQxaXE5TWKwzqvUmdokhTFidGoSvpt3b/BiIpFHluaqqK8Um1dLFW2SbHK8A82ShqsCekfMv3uzenRcEYoykSoua4s1G4puSu2Ax4Ocbc/kN4dLMFjdJE1mDDaJ3vvOQibBM9r7SCSz0BP+8Lg7+lijNeEiYualnHcXSCfHvz16wIDAQAB";
export const idOf = (key) => [...crypto.createHash("sha256").update(Buffer.from(key, "base64")).digest("hex").slice(0, 32)].map((c) => "abcdefghijklmnop"[parseInt(c, 16)]).join("");

if (import.meta.url === `file://${process.argv[1]}`) {
  const repo = process.argv[2] || path.join(os.homedir(), "Code/azet-browser-perm");
  const src = new URL("./dist/chrome/", import.meta.url).pathname, out = path.join(repo, "daemon/builtin/azet-pass");
  if (!fs.existsSync(path.join(src, "manifest.json"))) throw new Error("dist/chrome is missing: run node build.mjs");
  fs.rmSync(out, { recursive: true, force: true }); fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.cpSync(src, out, { recursive: true });
  const m = JSON.parse(fs.readFileSync(path.join(out, "manifest.json"), "utf8"));
  fs.writeFileSync(path.join(out, "manifest.json"), JSON.stringify({ ...m, key: KEY }, null, 2) + "\n");
  console.log(`${out} · AZET Pass ${m.version} · id ${idOf(KEY)}`);
}

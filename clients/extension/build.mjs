// node build.mjs -> dist/chrome (Chrome, Edge, Whale, Opera) and dist/firefox, plus a zip of each for the stores.
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
const sdk = "node_modules/@bitwarden/sdk-internal";
const base = JSON.parse(readFileSync("manifest.base.json", "utf8"));
const targets = {
  chrome: { ...base, background: { service_worker: "background.js", type: "module" }, minimum_chrome_version: "120" },
  firefox: { ...base, background: { scripts: ["background.js"], type: "module" },
    browser_specific_settings: { gecko: { id: "pass@azet.io", strict_min_version: "128.0", data_collection_permissions: { required: ["authenticationInfo"] } } } },
};
rmSync("dist", { recursive: true, force: true });
for (const [name, manifest] of Object.entries(targets)) {
  const out = `dist/${name}`;
  cpSync("src", out, { recursive: true });
  mkdirSync(`${out}/sdk`, { recursive: true });
  for (const f of ["bitwarden_wasm_internal_bg.js", "bitwarden_wasm_internal_bg.wasm", "LICENSE"]) cpSync(`${sdk}/${f}`, `${out}/sdk/${f}`);
  writeFileSync(`${out}/manifest.json`, JSON.stringify(manifest, null, 2));
  execFileSync("zip", ["-qr", `../azet-pass-${name}-${base.version}.zip`, "."], { cwd: out });
  console.log(`${out} + dist/azet-pass-${name}-${base.version}.zip`);
}

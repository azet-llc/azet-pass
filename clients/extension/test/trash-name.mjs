// node test/trash-name.mjs <item name> < creds.json : moves every item with that name to the trash (restorable).
import { createRequire } from "node:module";
import { Vault } from "../src/vault-core.mjs";
const sdk = createRequire(import.meta.url)("@bitwarden/sdk-internal");
let input = ""; for await (const c of process.stdin) input += c;
const { email, password } = JSON.parse(input);
const v = new Vault({ sdk, base: "https://pass.azet.io", deviceId: crypto.randomUUID() });
await v.signIn(email, password); await v.sync();
for (const i of v.list.filter((x) => x.name === process.argv[2])) { await v.api("PUT", `/api/ciphers/${i.id}/delete`); console.log("trashed", i.id); }
console.log("items left", (await v.sync()).items);

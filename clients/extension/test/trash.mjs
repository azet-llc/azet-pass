// node test/trash.mjs <cipher id> < creds.json : moves a test item to the trash (restorable).
import { createRequire } from "node:module";
import { Vault } from "../src/vault-core.mjs";
const sdk = createRequire(import.meta.url)(process.env.AZET_SDK_NODE ?? "@bitwarden/sdk-internal");
let input = ""; for await (const c of process.stdin) input += c;
const { email, password } = JSON.parse(input);
const v = new Vault({ sdk, base: "https://pass.azet.io", deviceId: crypto.randomUUID() });
await v.signIn(email, password);
await v.api("PUT", `/api/ciphers/${process.argv[2]}/delete`);
console.log("trashed", process.argv[2], "items left", (await v.sync()).items);

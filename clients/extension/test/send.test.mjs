// Live: makes a one-view text Send, prints whether a link came back, deletes it.  node test/send.test.mjs < creds.json
import { createRequire } from "node:module";
import { Vault } from "../src/vault-core.mjs";
const sdk = createRequire(import.meta.url)("@bitwarden/sdk-internal");
let input = ""; for await (const c of process.stdin) input += c;
const { email, password } = JSON.parse(input);
const v = new Vault({ sdk, base: "https://pass.azet.io", deviceId: crypto.randomUUID() });
await v.signIn(email, password);
const link = await v.sendText({ name: "e2e send", text: "hello from the extension test", days: 1, oneView: true });
console.log("link", link.replace(/#\/send\/([^/]+)\/.+/, "#/send/$1/(key)"));
const id = v.lastSendId; await v.api("DELETE", `/api/sends/${id}`); console.log("deleted", id);

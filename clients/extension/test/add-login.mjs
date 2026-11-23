// node test/add-login.mjs <name> <uri> <username> [totp] < creds.json : saves one test login (prints its id only).
import { createRequire } from "node:module";
import { Vault } from "../src/vault-core.mjs";
const sdk = createRequire(import.meta.url)("@bitwarden/sdk-internal");
let input = ""; for await (const c of process.stdin) input += c;
const { email, password } = JSON.parse(input);
const [name, uri, username, totp] = process.argv.slice(2);
const v = new Vault({ sdk, base: "https://pass.azet.io", deviceId: crypto.randomUUID() });
await v.signIn(email, password); await v.sync();
console.log(await v.saveLogin({ name, uri, username, password: "x", totp }));

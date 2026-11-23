# AZET Pass browser extension (Chrome, Edge, Whale, Opera, Firefox)

Our own extension: popup, page fill (logins, cards, addresses), save-or-update after a sign-in, one-time codes,
password generator, password check, auto-lock, Ctrl/Cmd+Shift+L to fill.

- `npm install && npm run build` → `dist/chrome`, `dist/firefox` and a store zip of each.
- `npm test` → unit tests. Live check against pass.azet.io: `node test/vault-core.test.mjs < creds.json`
  with `AZET_SDK_NODE` pointing at the SDK's `node/bitwarden_wasm_internal.js`.

Crypto runs in `@bitwarden/sdk-internal` 0.2.0-main.978 (GPL-3.0, revision 9794da5, the same one the iPhone app uses),
copied into `sdk/` with its LICENSE. This extension is GPL-3.0 as well.

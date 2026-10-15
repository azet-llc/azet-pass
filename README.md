# AZET Pass

[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/15530/badge)](https://www.bestpractices.dev/projects/15530)

Source code of the AZET Pass apps (GPL-3.0) and of its sync server (MIT). How to rebuild each published app: [clients/SOURCE.md](clients/SOURCE.md).

Password manager and authenticator codes for Mac, Windows, Android, iPhone and browsers, with sync on Cloudflare.

Licence route: the clients are Bitwarden's own GPL-3.0 clients, rebranded and pointed at our server, published under GPL-3.0; the server is our Cloudflare Worker (warden-worker, MIT) with end-to-end encryption. Money comes from Premium, unlocked by an AZET licence key (suite-api product `pass`), not from selling the client code.

- `server/` — Cloudflare Worker + D1 (+ Durable Objects, KV). Vendored from warden-worker 7a9f6b9 (MIT) plus AZET glue (`src/handlers/azet.rs`, migration 0014). Tests: `server/test/e2ee.sh` (official `bw` CLI through a recording proxy; the server never sees plaintext), `server/test/premium.sh` (Premium follows the AZET licence), `cargo test --lib`.
- `clients/` — pinned upstream tags, rebrand patches and build scripts for the browser extension, desktop (Mac, Windows), Android and iOS.
- `docs/THREAT-MODEL.md` — what the server sees and does not see.

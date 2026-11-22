# AZET Pass sync server

The Cloudflare Worker behind pass.azet.io. Clients encrypt every item on the device; this server stores and syncs the ciphertext and never holds anything that opens a vault (see `../docs/THREAT-MODEL.md`).

Built on warden-worker 7a9f6b9 (MIT, see `LICENSE`), with AZET's additions: emailed sign-up confirmation (`src/signup.js`), Premium by AZET licence key (`src/handlers/azet.rs`, migration 0014), family and team shared vaults with accounts for AI agents and an access log (migrations 0016–0018), and the public gateway in `gw/` that serves the web vault, `/team` and `/invite`.

## Layout

- `src/` — Rust backend (routes in `router.rs`, one file per feature in `handlers/`), private: reached only through the gateway.
- `gw/` — public gateway Worker for pass.azet.io: static web vault, `/team`, `/invite`, app-link files, security headers.
- `sql/schema.sql`, `migrations/` — D1 schema.
- `scripts/azet-deploy.sh` — build and deploy the backend; the gateway deploys with `npx wrangler deploy -c gw/wrangler.jsonc`.

## Tests

Each script starts this Worker locally with a throwaway database and drives it with the official command line client through a proxy that records every byte.

| Script | What it proves |
|---|---|
| `test/e2ee.sh` | no plaintext of any item field or the master password reaches the wire or the database |
| `test/e2ee-live.sh` | the same against production, with a test account that is removed afterwards |
| `test/signup.sh` | an account is created only with the token mailed to that address |
| `test/premium.sh` | Premium follows the AZET licence key |
| `test/family.sh`, `test/team.sh` | shared vaults: invite, fingerprint-checked key handover, read-only members, seats, AI-agent access that runs out, the tamper-evident access log |
| `test/desktop-vault.sh` | AZET Desktop's `pass` commands and browser references (keys, cards, identities) against this server |

## Not built

Single sign-on, Key Connector, an admin panel, two-step login by email, Duo or security key. The authenticator app (TOTP) is the supported second step.

Operations: `docs/deployment.md`, `docs/db-backup-recovery.md`. Reporting a vulnerability: `../SECURITY.md`.

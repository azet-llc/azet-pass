# Security policy — AZET Pass

AZET Pass is Bitwarden's open-source password manager clients (GPL-3.0), rebranded and connected to AZET's sync server at pass.azet.io (the Cloudflare Worker in `server/`, MIT). Vaults are end-to-end encrypted on the device; the server stores only encrypted data.

## Reporting a vulnerability

- Preferred: GitHub private vulnerability reporting — Security tab → "Report a vulnerability" on https://github.com/azet-llc/azet-pass.
- Or email hello@azet.io with "security" in the subject. AZET's disclosure policy: https://azet.io/safety (security.txt: https://azet.io/.well-known/security.txt).
- Do not open a public issue with exploit details, and do not test against other people's accounts or run denial-of-service tests on pass.azet.io.

We acknowledge a report within 3 business days and aim to ship a fix for a confirmed high-severity issue within 30 days, then credit the reporter if they wish.

## Scope

- `server/`: the sync server (authentication, crypto handling, database access, rate limits).
- `clients/`: our build scripts, branding and the AZET-specific changes listed in `clients/SOURCE.md`. A flaw in Bitwarden's own client code should also be reported upstream: https://bitwarden.com/help/security/.

## Supported versions

The latest release on https://github.com/azet-llc/azet-pass/releases and the `main` branch.

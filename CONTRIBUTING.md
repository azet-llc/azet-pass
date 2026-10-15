# Contributing to AZET Pass

Bug reports and pull requests are welcome.

## Reporting bugs and requesting features

Open an issue at https://github.com/azet-llc/azet-pass/issues with the app and version (Android, browser extension, web vault), the steps that show the problem and what you expected. Security problems go through [SECURITY.md](SECURITY.md), not a public issue.

## Pull requests

1. Fork the repository and branch from `main`.
2. Keep each pull request to one fix or one feature.
3. Server changes (`server/`): add or update tests next to the code you change and run `cargo test` in `server/`.
4. Client changes: AZET Pass follows Bitwarden's clients; changes we carry on top are listed in `clients/SOURCE.md`. Prefer sending general client fixes to Bitwarden upstream.
5. Open the pull request against `main`. A maintainer reviews it before merge; CodeQL code scanning runs on every push.

## Licence

Contributions to `clients/` are licensed under GPL-3.0 and contributions to `server/` under MIT, the licences of those directories.

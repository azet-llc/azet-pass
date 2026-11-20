# Third-party notices

| Part | Version | Licence | Where | How it is used |
|---|---|---|---|---|
| bitwarden/clients (browser extension, web vault, desktop) | browser-v2026.9.3, desktop-v2026.9.1 | GPL-3.0 (files under `bitwarden_license/` are removed, never built) | built by `clients/build-*.sh` from the upstream tag | rebranded by `clients/rebrand.mjs`; our changes are GPL-3.0 (`clients/LICENSE`) |
| bitwarden/android | v2026.9.1-bwpm | GPL-3.0 | `clients/build-android.sh` | rebranded by `clients/rebrand-android.mjs` |
| bitwarden/sdk-internal, crate `bitwarden-uniffi` and its GPL crates | abc84458 with 8b9fa3e2 reverted | GPL-3.0 (no `bitwarden_license/` crate in the dependency tree) | `clients/build-android.sh` | Android crypto core |
| bitwarden/sdk-internal, crate `bitwarden-uniffi` and its GPL crates (Apple) | 9794da5 with `apple/sdk/sdk-internal-9794da5.patch`; AZET additions `azet_family.rs`, `azet_json.rs` | GPL-3.0 (no `bitwarden_license/` crate in the dependency tree) | `apple/sdk/build-sdk.sh` | iPhone and Mac crypto core (`BitwardenFFI.xcframework`) |
| Bitwarden CLI (`bw`), the OSS build | cli-v2026.10.1 (official `bw-oss-macos-arm64` binary, used unchanged) | GPL-3.0 | repackaged by `clients/pack-reader.sh`; published as the `pass-reader` release asset | the AZET Pass reader the Mac app fetches so it can run the vault without Terminal |
| warden-worker | 7a9f6b9 | MIT (Copyright (c) 2025 Deep Gaurav), `server/LICENSE` | `server/` | sync server on Cloudflare Workers; AZET changes in `server/src/handlers/azet.rs`, migration 0014 |
| Inter | as shipped in bitwarden/clients `libs/components/src/webfonts/inter.woff2` | SIL OFL-1.1 | `clients/brand/wordmark.py` | outlines of "AZET Pass" / "Password Manager" for logo slots |
| DuckDuckGo favicon service | public endpoint | service, no code | `server/src/handlers/azet.rs` (icon) | site icons, fetched server-side by domain only |

Source for every binary we distribute is this repository plus the pinned upstream tags in `clients/pins.env`. Before any public download is offered, this repository is made public (GPL-3.0 section 6).

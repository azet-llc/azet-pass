# Source code for the AZET Pass apps (GPL-3.0)

The source for every published AZET Pass binary is in this repository.

Apps written by AZET (their crypto core is bitwarden/sdk-internal `9794da58`, GPL-3.0, with the patch in `sdk-patches/`):

| App | Source | Build |
|---|---|---|
| iPhone, iPad and Mac `io.azet.pass` (SwiftUI) with its Safari extension | `apple/` | `apple/project.yml`, `fastlane/` |
| Android `io.azet.pass` 2026.11.0 and later (Kotlin, Compose) | `android/` | `android/tools/release.sh` |
| Browser extension 2026.11.0 and later (Chrome, Edge, Whale, Opera, Firefox `pass@azet.io`) | `clients/extension/` | `clients/extension/build.mjs` |
| Touch ID helper for the extension (native messaging host `io.azet.pass`) | `clients/desktop-host/` | none (one script) |
| Sync server | `server/` | `server/wrangler.toml` |

Apps still built from Bitwarden's GPL-3.0 clients with AZET's changes:

| App | Upstream (GPL-3.0) | Our changes | Build |
|---|---|---|---|
| Mac and Windows desktop 2026.10.402 | bitwarden/clients `desktop-v2026.10.4` | `rebrand.mjs` | `ship-desktop-mac.sh`, `ship-desktop-win.sh` |
| Web vault (pass.azet.io) | bitwarden/clients `browser-v2026.10.2` | `rebrand.mjs` (removes `bitwarden_license/`) | `build-web.sh` |
| Android on Google Play `io.azet.pass.lite` 2026.11.0-azet2 to azet4, and `io.azet.pass` 2026.11.0-azet1 | bitwarden/android `v2026.11.0-bwpm`; crypto core bitwarden/sdk-internal `abc84458` with commit `8b9fa3e2` reverted, GPL crates only | `rebrand-android.mjs` | `build-android.sh`, `build-android-lite.sh` |
| Browser extension up to 2026.10.2.1 | bitwarden/clients `browser-v2026.10.2` | `rebrand.mjs` | `build-extension.sh` |

Each GitHub release of this repository also carries a source archive of the exact patched tree used for that release's binaries.

Licence: GPL-3.0 (`clients/LICENSE`). The sync server in `server/` is MIT (`server/LICENSE`). Bitwarden is a trademark of Bitwarden Inc.; AZET Pass is not affiliated with or endorsed by Bitwarden Inc.

Written offer: for three years from the date we distribute a binary, AZET LLC will give anyone the complete corresponding source for it on request at hello@azet.io, at no charge beyond the cost of the medium, in addition to the copies published here.

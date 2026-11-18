# Source code for the AZET Pass apps (GPL-3.0)

AZET Pass apps are Bitwarden's GPL-3.0 clients with AZET's changes. Everything needed to rebuild a published binary is here:

| App | Upstream (GPL-3.0) | Our changes | Build |
|---|---|---|---|
| Android `io.azet.pass` 2026.9.1-azet1 | bitwarden/android `v2026.9.1-bwpm` | `rebrand-android.mjs` | `build-android.sh` |
| Android crypto core (`libbitwarden_uniffi.so`) | bitwarden/sdk-internal `abc84458` with commit `8b9fa3e2` reverted; only GPL crates (`bitwarden-uniffi`, no `bitwarden_license/` crate); stripped with `llvm-strip --strip-all` | none | `build-android.sh` |
| Browser extension (Chrome, Firefox `pass@azet.io`) and web vault | bitwarden/clients `browser-v2026.10.2` | `rebrand.mjs` (removes `bitwarden_license/`) | `build-extension.sh`, `build-web.sh` |
| Mac and Windows desktop | bitwarden/clients `desktop-v2026.10.4` | `rebrand.mjs` | `ship-desktop-mac.sh`, `ship-desktop-win.sh` |

Each GitHub release of this repository also carries a source archive of the exact patched tree used for that release's binaries.

Licence: GPL-3.0 (`clients/LICENSE`). The sync server in `server/` is MIT (`server/LICENSE`). Bitwarden is a trademark of Bitwarden Inc.; AZET Pass is not affiliated with or endorsed by Bitwarden Inc.

Written offer: for three years from the date we distribute a binary, AZET LLC will give anyone the complete corresponding source for it on request at hello@azet.io, at no charge beyond the cost of the medium, in addition to the copies published here.

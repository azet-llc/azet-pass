# Decision needed: GPL-3.0 code on the App Store, and what to keep public

Two open questions for the owner. Neither is changed in code here — this memo records the facts so the
decision can be made. Nothing below blocks the desktop (Mac/Windows) or Android apps, which are not affected.

## 1. GPL-3.0 crypto core shipped through the App Store

### The possible conflict
The Apple apps link Bitwarden's `sdk-internal` crypto core, which is **GPL-3.0** (built with no
`bitwarden_license/` crate — see `apple/sdk/README.md` and `THIRD_PARTY_NOTICES.md`). GPL-3.0 §6 and §10
forbid the distributor from imposing "any further restrictions" on the recipient's exercise of the granted
rights.

The App Store's terms (Apple Media Services Terms / Licensed Application End User License Agreement) are widely
read as imposing Usage Rules — binding a copy to a limited number of a user's Apple-ID devices — which may be
such a "further restriction", putting GPL-3.0 and App Store distribution in conflict. This is the conflict that
led to VLC's removal from the App Store in 2011. **The exact current terms should be read before relying on
this** — the detail here is from memory. Note that the distributor can only pass on GPL rights it holds, and
**AZET LLC is not the copyright holder of `sdk-internal`** (Bitwarden is), so AZET cannot waive the conflict or
add a store exception on its own (relicensing or a §7 exception needs the copyright holder).

### Where it reaches
`apple/project.yml` links `BitwardenSdk` (the GPL `sdk-internal` core, statically) into its Apple targets
(lines 20–21, 31, 73, 113, 173). The App Store upload scripts archive two of them:
- `apple/tools/testflight.sh` → iOS App Store, scheme `AZETPass` (`io.azet.pass`) + its AutoFill extension.
- `apple/tools/testflight-mac.sh` → Mac App Store, scheme `AZETPassMac` (`io.azet.pass.safari`) + its Safari
  extension.

These apps are AZET's own SwiftUI code (no Bitwarden UI code); the only GPL part in them is the **linked**
`sdk-internal` crypto core. Separately, `clients/build-ios.sh` produces a *wholly* GPL app (the rebranded
bitwarden/ios client) but it is **simulator-only today** ("no App Store build until the Apple enrolment") — not
a current store path, but it would be a second, larger one if it ever ships. (`SOURCE.md` and `apple/project.yml`
describe the `io.azet.pass.safari` Safari target's origin differently — worth reconciling, but either way the
archived app links GPL `sdk-internal`.)

### Options
1. **Move the GPL part to a separate binary outside the app.** The app's GPL crypto core is *linked in*, not a
   separate process: Android builds it straight into the app as `libbitwarden_uniffi.so` (`build-android.sh`),
   and the Apple apps statically link it. The only separate-binary precedent is the Mac *reader* (`bw`), a whole
   CLI, not the app's own crypto. For iPhone/iPad this option **cannot work at all**: App Store apps cannot
   download and execute native code, and all linked libraries must ship inside the signed bundle. On Mac the MAS
   sandbox and no-downloaded-code rule make it impractical too.
2. **Remove the GPL part from the store build.** Not currently possible: the crypto is Bitwarden's GPL
   `sdk-internal`; there is no in-house, non-GPL replacement.
3. **Do not ship the Apple apps on the App Store.** Distribute the Mac app with a Developer ID + notarization
   (outside MAS), as the Electron desktop already is. For iPhone/iPad there is **no public non-App-Store route**
   (only enterprise/ad-hoc, which do not serve the general public) — so this option drops public iPhone
   distribution.
4. **Get written permission from Bitwarden.** As the copyright holder, Bitwarden could grant a GPL-3.0 §7
   additional permission ("App Store exception") allowing App Store distribution. Only Bitwarden can do this.

### Recommendation
Until either (4) Bitwarden grants an App Store additional permission, or (3) distribution moves off the App
Store, **do not submit the GPL-linked Apple apps to the App Store / TestFlight public track.** Ask Bitwarden for
a §7 App Store exception first — it is the only option that keeps iPhone distribution. The desktop and Android
apps are unaffected and need no change.

## 2. What stays in the public repo (information exposure, low severity)

No secret **values** are in the repo (re-checked with a redacted pattern scan: no keys, tokens or passwords).
What is exposed is internal *structure* — build-host paths, vault key names, internal comments, and live
Cloudflare resource ids. The files that carry it:

- `server/wrangler.toml` — live Cloudflare resource ids (D1, KV, rate-limit namespaces) and internal comments.
  (Resource ids are not secrets on their own — they grant nothing without account auth — but they reveal the
  backend layout.)
- `clients/ship-desktop-win.sh`, `clients/build-android.sh`, `clients/build-android-lite.sh`,
  `clients/test-ios-login.sh`, `apple/tools/testflight*.sh`, `server/test/*-live.sh`,
  `clients/tools/keystore-inventory.py`, `clients/tools/azet-pass-key` — reference the internal secrets tooling
  and vault **key names** (not values).

Already generalized in this branch (HEAD only): `clients/tools/keystore-inventory.py` and
`clients/ship-desktop-mac.sh` now read a `$SECRETS_ENV` env var instead of a hardcoded host path;
`apple/tools/testflight*.sh` default output moved off an internal host path.

**Decision needed:** whether to move the operational scripts (`clients/*.sh`, `clients/tools/keystore-inventory.py`)
and the `server/wrangler.toml` resource ids out of the public repo entirely — e.g. a separate private ops repo or
deploy-time env-var injection. Note that editing files at HEAD does **not** remove these strings from git
history; the exposure is only truly removed by moving the files to a private repo (and, if it matters, rewriting
history). Vault key names and resource ids were left unchanged in-place here because renaming/removing them would
break the live vault bindings and deploys.

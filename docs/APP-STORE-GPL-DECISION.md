# Decision needed: GPL-3.0 code on the App Store, and what to keep public

Two open questions for the owner. Neither is changed in code here — this memo records the facts so the
decision can be made. Nothing below blocks the desktop (Mac/Windows) or Android apps, which are not affected.

## 1. GPL-3.0 crypto core shipped through the App Store

### The conflict
The Apple apps link Bitwarden's `sdk-internal` crypto core, which is **GPL-3.0** (built with no
`bitwarden_license/` crate — see `apple/sdk/README.md` and `THIRD_PARTY_NOTICES.md`). GPL-3.0 §6 and §10
forbid the distributor from imposing "any further restrictions" on the recipient's exercise of the granted
rights.

The App Store's terms (Apple Media Services Terms / Licensed Application End User License Agreement) impose
Usage Rules — binding the app to a limited number of Apple-ID devices and forbidding redistribution. Those are
"further restrictions". The distributor can only pass on GPL rights it holds, and **AZET LLC is not the
copyright holder of `sdk-internal`** (Bitwarden is), so AZET cannot waive the conflict or add a store exception
on its own. This is the same conflict that removed VLC from the App Store in 2011; projects have since resolved
it only by relicensing (which requires holding the copyright) or by leaving the store.

### Where it reaches
`apple/project.yml` links `BitwardenSdk` into every Apple target (lines 20–21, 31, 73, 113, 173): the iPhone/iPad
app `io.azet.pass`, its AutoFill extension, the Mac app, and the Safari extension. The store-export paths are:
- `apple/tools/testflight.sh` → iOS App Store (`io.azet.pass`)
- `apple/tools/testflight-mac.sh` → Mac App Store (`io.azet.pass.safari`)

### Options
1. **Move the GPL part to a separate binary outside the app.** This is the route the Android crypto core and the
   Mac reader (`bw`) already take (fetched/run as a standalone GPL binary with its own source offer). **It does
   not work for iPhone/iPad**: App Store apps cannot download and execute native code, and all linked libraries
   must live inside the signed bundle. On Mac it is also constrained by the MAS sandbox and the no-downloaded-code
   rule. So this option is, at best, Mac-only and awkward.
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
What is exposed is internal *structure* — paths, vault key names, and live Cloudflare resource ids:

- `server/wrangler.toml` — a live D1 `database_id` and KV namespace `id`, rate-limit `namespace_id`s, and Korean
  internal comments describing the private gateway split and the name of a vault key. (Resource ids are not
  secrets on their own — they grant nothing without account auth — but they reveal the backend layout.)
- `clients/ship-desktop-win.sh`, `clients/build-android.sh`, `clients/build-android-lite.sh`,
  `clients/test-ios-login.sh`, `apple/tools/testflight*.sh`, `server/test/*-live.sh`,
  `clients/tools/keystore-inventory.py`, `clients/tools/azet-pass-key` — reference the internal secrets tooling
  (`tkt`) and vault **key names** (not values).

Already generalized in this branch (HEAD only): `clients/tools/keystore-inventory.py` and
`clients/ship-desktop-mac.sh` now read `$SECRETS_ENV` instead of a hardcoded `~/.secrets/master.env`;
`apple/tools/testflight*.sh` default output moved off the internal `~/.dooyou/lane…` path.

**Decision needed:** whether to move the operational scripts (`clients/*.sh`, `clients/tools/keystore-inventory.py`)
and the Cloudflare D1/KV ids out of the public repo entirely — e.g. a separate private ops repo or deploy-time
env-var injection. Note that editing files at HEAD does **not** remove these strings from git history; the
exposure is only truly removed by moving the files to a private repo (and, if it matters, rewriting history).
Vault key names and D1/KV ids were left unchanged here because renaming/removing them would break the live
vault bindings and deploys.

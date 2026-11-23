# AZET Pass for Android (our own app)

Native Kotlin + Jetpack Compose. Crypto: sdk-internal (GPL-3.0, 9794da58) with `../sdk-patches`, the same SDK and helpers as the iPhone app.

- Sign in (with authenticator code), unlock with the account password or fingerprint/face (user key sealed by a Keystore key that needs strong biometrics), auto-lock, screenshot block.
- Items: logins, cards, identities, notes; search and filters (codes, passkeys); detail with copy (marked sensitive, cleared after 60 s), live one-time codes and counter (HOTP) codes, edit, favorite, trash, one-view share link.
- One-time code keys from the camera or from a photo (QR), password generator (characters or words), password check (weak, reused, over a year old), Send (encrypted text links).
- Autofill service for apps and browsers: matching logins, "search AZET Pass", unlock from the autofill row, save or update after a sign-in, the one-time code copied after a fill.

Build: `tools/sdk.sh` (Rust 1.97.1 + NDK 27, writes `app/sdk-gen`), then `./gradlew :app:assembleRelease`. `testform/` is a one-screen login form for testing autofill on an emulator; it is not shipped.

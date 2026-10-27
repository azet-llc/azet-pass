# Bitwarden SDK for AZET Pass iOS

The app links `bitwarden/sdk-internal` at **9794da5** (the revision bitwarden/ios v2026.9.1-bwpm pins), built from
source under GPL-3.0 with no `bitwarden_license` crate (the uniffi crate never enables `bitwarden-license`).

AZET additions (GPL-3.0): `azet_family.rs` (family key make/wrap/unwrap, organizer recovery — thin wrappers over
bitwarden-crypto) and `azet_json.rs` (server JSON in/out through the SDK's own API-model conversions).

Rebuild:
```
git clone https://github.com/bitwarden/sdk-internal.git && cd sdk-internal && git checkout 9794da5
git apply ../sdk-internal-9794da5.patch && cp ../azet_family.rs ../azet_json.rs crates/bitwarden-uniffi/src/
./build-sdk.sh            # → crates/bitwarden-uniffi/swift/BitwardenFFI.xcframework
ln -sfn "$PWD/crates/bitwarden-uniffi/swift" ../../Vendor/BitwardenSdk
```
Tests: `cargo test -p bitwarden-uniffi azet`.

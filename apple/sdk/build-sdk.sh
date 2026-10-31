#!/bin/bash
set -eo pipefail
cd "${SDK_DIR:-$PWD}"
export PATH="$HOME/.rustup/toolchains/1.97.1-aarch64-apple-darwin/bin:$PATH"
export IPHONEOS_DEPLOYMENT_TARGET=13.0 MACOSX_DEPLOYMENT_TARGET=14.0 RUSTFLAGS="-C link-arg=-Wl,-application_extension"
cargo build -p bitwarden-uniffi --target aarch64-apple-ios-sim --release
cargo build -p bitwarden-uniffi --target aarch64-apple-ios --release
cargo build -p bitwarden-uniffi --target aarch64-apple-darwin --release   # AZET Pass for Safari (Mac)
cd crates/bitwarden-uniffi/swift && rm -rf tmp
cargo run -p uniffi-bindgen generate ../../../target/aarch64-apple-ios-sim/release/libbitwarden_uniffi.dylib --language swift --no-format --out-dir tmp/bindings
mv tmp/bindings/*.swift Sources/BitwardenSdk/
mkdir tmp/Headers && mv tmp/bindings/*.h tmp/Headers/ && cat tmp/bindings/*.modulemap > tmp/Headers/module.modulemap
T=../../../target
# into tmp first: the app keeps building against the old xcframework if this step fails
xcodebuild -create-xcframework -library $T/aarch64-apple-ios/release/libbitwarden_uniffi.a -headers tmp/Headers \
  -library $T/aarch64-apple-ios-sim/release/libbitwarden_uniffi.a -headers tmp/Headers \
  -library $T/aarch64-apple-darwin/release/libbitwarden_uniffi.a -headers tmp/Headers -output tmp/BitwardenFFI.xcframework
rm -rf BitwardenFFI.xcframework && mv tmp/BitwardenFFI.xcframework BitwardenFFI.xcframework
rm -rf tmp; echo SDK_OK

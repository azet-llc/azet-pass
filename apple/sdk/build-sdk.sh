#!/bin/bash
set -eo pipefail
cd "${SDK_DIR:-$PWD}"
export PATH="$HOME/.rustup/toolchains/1.97.1-aarch64-apple-darwin/bin:$PATH"
export IPHONEOS_DEPLOYMENT_TARGET=13.0 RUSTFLAGS="-C link-arg=-Wl,-application_extension"
cargo build -p bitwarden-uniffi --target aarch64-apple-ios-sim --release
cargo build -p bitwarden-uniffi --target aarch64-apple-ios --release
cd crates/bitwarden-uniffi/swift && rm -rf tmp BitwardenFFI.xcframework
cargo run -p uniffi-bindgen generate ../../../target/aarch64-apple-ios-sim/release/libbitwarden_uniffi.dylib --language swift --no-format --out-dir tmp/bindings
mv tmp/bindings/*.swift Sources/BitwardenSdk/
mkdir tmp/Headers && mv tmp/bindings/*.h tmp/Headers/ && cat tmp/bindings/*.modulemap > tmp/Headers/module.modulemap
xcodebuild -create-xcframework -library ../../../target/aarch64-apple-ios/release/libbitwarden_uniffi.a -headers tmp/Headers -library ../../../target/aarch64-apple-ios-sim/release/libbitwarden_uniffi.a -headers tmp/Headers -output BitwardenFFI.xcframework
rm -rf tmp; echo SDK_OK

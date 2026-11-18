#!/usr/bin/env bash
# AZET Pass for iPhone: simulator build from this Mac (no App Store build until the Apple enrolment, board 524).
# Clones the pinned bitwarden/ios tag and its sdk-internal revision, builds the Rust SDK, rebrands, builds for a simulator.
# usage: build-ios.sh <work dir> <simulator udid>     needs: brew install mint swiftgen sourcery xcodegen librsvg
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); . "$here/pins.env"
W=${1:?work dir}; U=${2:?simulator udid}; mkdir -p "$W"; cd "$W"
[ -d ios ] || git clone --depth 1 --branch "$IOS_TAG" "$IOS_REPO" ios
# the SDK revision is the one the iOS tag pins (project-common.yml comment "<version>-<n>-<sha>")
sdk=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-[0-9a-f]{7}' ios/project-common.yml | head -1 | cut -d- -f3)
[ -n "$sdk" ] || { echo "no SDK revision found in ios/project-common.yml"; exit 1; }
[ -d sdk-internal ] || { git clone --filter=blob:none https://github.com/bitwarden/sdk-internal.git sdk-internal && git -C sdk-internal checkout "$sdk"; }
tc=$(sed -n 's/^channel *= *"\(.*\)"/\1/p' sdk-internal/rust-toolchain.toml)
rustup target add --toolchain "$tc" aarch64-apple-ios-sim aarch64-apple-ios x86_64-apple-ios
# the Rust build must find the iPhone SDK itself: a macOS SDK path left in the shell, or the command line tools as the
# active developer folder, makes the linker pull macOS libraries into the simulator build
unset SDKROOT; export DEVELOPER_DIR=${DEVELOPER_DIR:-$(ls -d /Applications/Xcode*.app/Contents/Developer | sort -V | tail -1)}
(cd sdk-internal && PATH="$HOME/.rustup/toolchains/$tc-aarch64-apple-darwin/bin:$PATH" bash crates/bitwarden-uniffi/swift/build.sh)
node "$here/rebrand-ios.mjs" ios
(cd ios && LOCAL_SDK=true xcodegen --spec project-bwk.yml && LOCAL_SDK=true xcodegen --spec project-pm.yml)
# Xcode phases call `mint run <tool>`: point them at the Homebrew binaries of the Mintfile versions and the LicensePlist release
mkdir -p tools
[ -x tools/license-plist ] || { curl -sL -o tools/lp.zip https://github.com/mono0926/LicensePlist/releases/download/3.27.2/portable_licenseplist.zip && unzip -oq tools/lp.zip -d tools && rm tools/lp.zip; }
cat > tools/mint <<'SH'
#!/bin/sh
[ "$1" = run ] || exec /opt/homebrew/bin/mint "$@"
shift; tool=$1; shift
case "$tool" in LicensePlist) shift; exec "$(dirname "$0")/license-plist" "$@" ;; *) exec "/opt/homebrew/bin/$tool" "$@" ;; esac
SH
chmod +x tools/mint
# no -sdk (it would force the watch widget onto the iOS SDK); watchOS 9 because Xcode 27 dropped 8; CI=1 skips the lint
# phase; ad-hoc signing keeps the app-group entitlement (without it the app stops at launch in DataStore)
CI=1 PATH="$PWD/tools:$PATH" xcodebuild -workspace ios/Bitwarden.xcworkspace -scheme Bitwarden -configuration Debug \
  -destination "platform=iOS Simulator,id=$U" -derivedDataPath ./DerivedData CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= WATCHOS_DEPLOYMENT_TARGET=9.0 build
echo "app: $W/DerivedData/Build/Products/Debug-iphonesimulator/Bitwarden.app (xcrun simctl install $U <app>; launch io.azet.pass)"

#!/bin/zsh
# Release APK signed with the AZET Pass key from the vault (same key as the earlier Android builds). Prints the APK path.
set -e
cd "$(dirname "$0")/.."
export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@21} ANDROID_HOME=${ANDROID_HOME:-$HOME/Library/Android/sdk}
V=$(grep -o 'versionName = "[^"]*"' app/build.gradle.kts | cut -d'"' -f2)
./gradlew -q :app:assembleRelease --console=plain
bt=$(ls -d $ANDROID_HOME/build-tools/* | sort -V | tail -1); out=dist/azet-pass-android-$V.apk; mkdir -p dist
$bt/zipalign -f -p 4 app/build/outputs/apk/release/app-release-unsigned.apk dist/aligned.apk
ks=$(mktemp); trap 'rm -f "$ks" dist/aligned.apk' EXIT
tkt get AZET_PASS_ANDROID_KEYSTORE_B64 | base64 -d > "$ks"; export KS_PW=$(tkt get AZET_PASS_ANDROID_KEYSTORE_PASSWORD)
$bt/apksigner sign --ks "$ks" --ks-pass env:KS_PW --ks-key-alias azet-pass --out "$out" dist/aligned.apk
$bt/apksigner verify "$out" && echo "$out"

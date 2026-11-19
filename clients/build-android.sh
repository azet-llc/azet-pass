#!/usr/bin/env bash
# AZET Pass for Android, built on this Mac (GitHub Actions is off for lane repos).
# 1) Bitwarden SDK from source, GPL crates only (`bitwarden-uniffi` pulls nothing from bitwarden_license/),
#    at the commit the Android tag asks for (pins.env ANDROID_SDK_COMMIT).
#    The prebuilt com.bitwarden:sdk-android sits in GitHub Packages (needs a read:packages token) and its licence is not stated.
# 2) pinned bitwarden/android tag + rebrand-android.mjs, F-Droid flavour plus Firebase Cloud Messaging only (push), release build.
# 3) zipalign + apksigner with the AZET Pass key (vault: AZET_PASS_ANDROID_KEYSTORE_B64 / _PASSWORD).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); . "$here/pins.env"
W=${1:-$here/../../azet-pass-work}; mkdir -p "$W/dist"
export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:/opt/homebrew/opt/openjdk@21/bin:$PATH
export JAVA_HOME=/opt/homebrew/opt/openjdk@21 ANDROID_HOME=$HOME/Library/Android/sdk
export ANDROID_NDK_HOME=$(ls -d "$ANDROID_HOME"/ndk/* | sort -V | tail -1)
sdk="$W/sdk"
[ -d "$sdk" ] || git clone -q --filter=blob:none https://github.com/bitwarden/sdk-internal.git "$sdk"
git -C "$sdk" fetch -q origin && git -C "$sdk" checkout -q -f "$ANDROID_SDK_COMMIT"
(cd "$sdk" && rustup target add aarch64-linux-android >/dev/null 2>&1 && cargo ndk -t arm64-v8a -o crates/bitwarden-uniffi/kotlin/sdk/src/main/jniLibs build -p bitwarden-uniffi --release)
(cd "$sdk/crates/bitwarden-uniffi/kotlin" && bash build-schemas.sh && ./gradlew sdk:publishToMavenLocal -Pversion=LOCAL -q)
m=~/.m2/repository/com/bitwarden; rm -rf "$m/sdk-android"; cp -R "$m/sdk-android.dev" "$m/sdk-android"
(cd "$m/sdk-android/LOCAL" && for f in sdk-android.dev-LOCAL*; do mv "$f" "${f/sdk-android.dev/sdk-android}"; done
 sed -i '' 's/<artifactId>sdk-android.dev</<artifactId>sdk-android</' sdk-android-LOCAL.pom
 sed -i '' 's/"module": "sdk-android.dev"/"module": "sdk-android"/; s/sdk-android.dev-LOCAL/sdk-android-LOCAL/g' sdk-android-LOCAL.module)
a="$W/android"
[ -d "$a" ] || git clone -q --depth 1 --branch "$ANDROID_TAG" "$ANDROID_REPO" "$a"
git -C "$a" checkout -q -- . && git -C "$a" clean -qfd -e user.properties
node "$here/rebrand-android.mjs" "$a"
echo "localSdk=true" > "$a/user.properties"
tkt get AZET_PASS_GOOGLE_SERVICES_JSON_B64 | base64 -d > "$a/app/src/fdroid/google-services.json"   # push: Firebase project azet-mobile
(cd "$a" && ./gradlew :app:assembleFdroidRelease --no-daemon -q)
bt=$(ls -d "$ANDROID_HOME"/build-tools/* | sort -V | tail -1); ks=$(mktemp)
tkt get AZET_PASS_ANDROID_KEYSTORE_B64 | base64 -d > "$ks"; export KS_PW=$(tkt get AZET_PASS_ANDROID_KEYSTORE_PASSWORD)
"$bt/zipalign" -f 4 "$a"/app/build/outputs/apk/fdroid/release/io.azet.pass*-fdroid.apk "$W/dist/aligned.apk"
"$bt/apksigner" sign --ks "$ks" --ks-pass env:KS_PW --ks-key-alias azet-pass --out "$W/dist/azet-pass-android.apk" "$W/dist/aligned.apk"
rm -f "$ks" "$W/dist/aligned.apk"; "$bt/apksigner" verify --print-certs "$W/dist/azet-pass-android.apk" | head -2

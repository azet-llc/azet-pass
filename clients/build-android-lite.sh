#!/usr/bin/env bash
# AZET Pass Lite for Google Play (io.azet.pass.lite): the same build as build-android.sh with AZET_LITE=1, plus the
# signed app bundle Play takes. -> <work>/dist/azet-pass-lite-android.apk (for the emulator) and azet-pass-lite-<code>.aab
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
W=${1:-$here/../../azet-pass-work}; a="$W/android"
main="$W/dist/azet-pass-android.apk"; keep=$(mktemp); [ -f "$main" ] && cp "$main" "$keep"   # the build writes over the full app's APK
AZET_LITE=1 bash "$here/build-android.sh" "$W"
mv "$main" "$W/dist/azet-pass-lite-android.apk"; [ -s "$keep" ] && mv "$keep" "$main"
export JAVA_HOME=/opt/homebrew/opt/openjdk@21 ANDROID_HOME=$HOME/Library/Android/sdk
(cd "$a" && ./gradlew :app:bundleFdroidRelease --no-daemon -q)
code=$(grep -o 'appVersionCode = "[0-9]*"' "$a/gradle/libs.versions.toml" | grep -o '[0-9]*')
aab=$(ls "$a"/app/build/outputs/bundle/fdroidRelease/*.aab | head -1); out="$W/dist/azet-pass-lite-$code.aab"
ks=$(mktemp); tkt get AZET_PASS_ANDROID_KEYSTORE_B64 | base64 -d > "$ks"; export KS_PW=$(tkt get AZET_PASS_ANDROID_KEYSTORE_PASSWORD)
cp "$aab" "$out"; "$JAVA_HOME/bin/jarsigner" -keystore "$ks" -storepass:env KS_PW -sigalg SHA256withRSA -digestalg SHA-256 "$out" azet-pass >/dev/null
rm -f "$ks"; "$JAVA_HOME/bin/jarsigner" -verify "$out" | tail -1; ls -l "$out" "$W/dist/azet-pass-lite-android.apk"

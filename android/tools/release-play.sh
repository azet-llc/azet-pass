#!/bin/zsh
# App bundle for the Play listing (its id there is io.azet.pass.lite), signed with the AZET Pass key from the vault. Prints the path.
set -e
cd "$(dirname "$0")/.."
export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@21} ANDROID_HOME=${ANDROID_HOME:-$HOME/Library/Android/sdk}
V=$(grep -o 'versionName = "[^"]*"' app/build.gradle.kts | cut -d'"' -f2)
./gradlew -q :app:bundleRelease -PappId=io.azet.pass.lite --console=plain
out=dist/azet-pass-play-$V.aab; mkdir -p dist; cp app/build/outputs/bundle/release/app-release.aab "$out"
ks=$(mktemp); trap 'rm -f "$ks"' EXIT
tkt get AZET_PASS_ANDROID_KEYSTORE_B64 | base64 -d > "$ks"; export KS_PW=$(tkt get AZET_PASS_ANDROID_KEYSTORE_PASSWORD)
"$JAVA_HOME/bin/jarsigner" -keystore "$ks" -storepass:env KS_PW -sigalg SHA256withRSA -digestalg SHA-256 "$out" azet-pass >/dev/null
"$JAVA_HOME/bin/jarsigner" -verify "$out" | tail -1; echo "$out"

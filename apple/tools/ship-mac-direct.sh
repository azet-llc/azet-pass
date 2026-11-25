#!/bin/zsh
# AZET Pass for Mac (our SwiftUI app) as a download outside the App Store: archive, sign with AZET LLC's Developer ID,
# notarize, staple, and pack a disk image. With --publish it also makes the GitHub release the site links to.
#   zsh apple/tools/ship-mac-direct.sh [--publish]
# Needs: the macOS slice in Vendor/BitwardenSdk (sdk/build-sdk.sh), the Developer ID certificate in the keychain,
# the App Store Connect API key (tkt) for the Developer ID profiles and for notarization.
set -euo pipefail
cd "${0:A:h}/.."
KID=$(tkt get APPLE_AZET_ASC_API_KEY_ID); ISS=$(tkt get APPLE_AZET_ASC_ISSUER_ID); KEY=~/.appstoreconnect/private_keys/AuthKey_$KID.p8
AUTH=(-authenticationKeyPath $KEY -authenticationKeyID $KID -authenticationKeyIssuerID $ISS)
V=$(grep -o 'MARKETING_VERSION: "[^"]*"' project.yml | cut -d'"' -f2)
OUT=${OUT:-$HOME/Library/Caches/azet-pass-mac-direct-$V}
rm -rf $OUT/export $OUT/AZETPassMac.xcarchive; mkdir -p $OUT
xcodegen -q
# The Release settings name the App Store profiles; a direct download is signed with Developer ID profiles Xcode makes.
xcodebuild -project AZETPass.xcodeproj -scheme AZETPassMacDirect -configuration Release -destination generic/platform=macOS \
  -archivePath $OUT/AZETPassMac.xcarchive -derivedDataPath $OUT/dd -allowProvisioningUpdates -allowProvisioningDeviceRegistration $AUTH \
  CODE_SIGN_STYLE=Automatic PROVISIONING_PROFILE_SPECIFIER= CODE_SIGN_IDENTITY="Apple Development" archive | grep -E "error:|ARCHIVE" || true
[ -d $OUT/AZETPassMac.xcarchive ] || { echo "SHIP STOPPED: no archive"; exit 1; }
cat > $OUT/export.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>teamID</key><string>95P4H2RG24</string>
<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>Developer ID Application</string>
<key>provisioningProfiles</key><dict>
<key>io.azet.pass</key><string>io.azet.pass developer-id</string>
<key>io.azet.pass.safari-extension</key><string>io.azet.pass.safari-extension developer-id</string>
</dict>
</dict></plist>
PLIST
# The two Developer ID profiles (made once, fetched again when they are missing on this Mac).
mkdir -p $OUT/sigh/fastlane $OUT/sigh/out
cat > $OUT/sigh/fastlane/Fastfile <<'RUBY'
lane :devid do
  app_store_connect_api_key(key_id: ENV["KID"], issuer_id: ENV["ISS"], key_filepath: ENV["KEYP"])
  ["io.azet.pass", "io.azet.pass.safari-extension"].each do |id|
    sigh(platform: "macos", developer_id: true, app_identifier: id, provisioning_name: "#{id} developer-id", output_path: ENV["OUTP"])
  end
end
RUBY
(cd $OUT/sigh && KID=$KID ISS=$ISS KEYP=$KEY OUTP=$OUT/sigh/out FASTLANE_SKIP_UPDATE_CHECK=1 fastlane devid >/dev/null 2>&1) || { echo "SHIP STOPPED: Developer ID profiles"; exit 1; }
xcodebuild -exportArchive -archivePath $OUT/AZETPassMac.xcarchive -exportOptionsPlist $OUT/export.plist -exportPath $OUT/export \
  | grep -E "error:|EXPORT" || true
APP="$OUT/export/AZET Pass.app"
[ -d "$APP" ] || { echo "SHIP STOPPED: no exported app"; exit 1; }
codesign --verify --deep --strict "$APP"
DMG=$OUT/AZET-Pass-$V-mac.dmg; rm -f $DMG
STAGE=$(mktemp -d); cp -R "$APP" $STAGE/; ln -s /Applications $STAGE/Applications
hdiutil create -quiet -volname "AZET Pass" -srcfolder $STAGE -ov -format UDZO $DMG; rm -rf $STAGE
codesign --sign "Developer ID Application: AZET LLC (95P4H2RG24)" --timestamp $DMG
xcrun notarytool submit $DMG --key $KEY --key-id $KID --issuer $ISS --wait | grep -E "status:|id:" | tail -2
xcrun stapler staple $DMG >/dev/null
spctl -a -t open --context context:primary-signature -v $DMG 2>&1 | tail -1
echo "$DMG"; shasum -a 256 $DMG | cut -d' ' -f1; stat -f %z $DMG
# The update feed installed copies read (Info.plist SUFeedURL): this dmg, signed with the Sparkle key from the vault.
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
tkt get AZET_PASS_SPARKLE_ED_KEY | python3 "${0:A:h}/sparkle-appcast.py" "$DMG" "$V" "$BUILD" \
  "https://github.com/azet-llc/azet-pass/releases/download/v$V-mac/AZET-Pass-$V-mac.dmg" > $OUT/appcast-mac.xml || { echo "SHIP STOPPED: appcast"; exit 1; }
[ "${1:-}" = "--publish" ] || exit 0
TAG=v$V-mac
gh release view $TAG -R azet-llc/azet-pass >/dev/null 2>&1 && { echo "SHIP STOPPED: $TAG is already published"; exit 1; }
gh release create $TAG -R azet-llc/azet-pass --title "AZET Pass $V for Mac" \
  --notes "AZET Pass for Mac $V, for Apple silicon Macs on macOS 14 or later. Signed with AZET LLC's Developer ID and notarized by Apple." $DMG
gh release upload desktop-feed $OUT/appcast-mac.xml --clobber -R azet-llc/azet-pass # what installed copies check
echo "published $TAG"

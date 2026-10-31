#!/bin/zsh
# AZET Pass for Safari (Mac): archive and upload to App Store Connect (TestFlight). Upload only — review is a separate step.
# Needs: the macOS slice in Vendor/BitwardenSdk (sdk/build-sdk.sh), the two "…mac" App Store profiles, the ASC API key, tkt.
set -euo pipefail
cd "${0:A:h}/.."
KID=$(tkt get APPLE_AZET_ASC_API_KEY_ID); ISS=$(tkt get APPLE_AZET_ASC_ISSUER_ID)
AUTH=(-authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_$KID.p8 -authenticationKeyID $KID -authenticationKeyIssuerID $ISS)
OUT=${OUT:-$HOME/.dooyou/lane649/release-mac}
mkdir -p $OUT
xcodegen -q
xcodebuild -project AZETPass.xcodeproj -scheme AZETPassMac -configuration Release -destination generic/platform=macOS \
  -archivePath $OUT/AZETPassMac.xcarchive -derivedDataPath $OUT/dd archive
cat > $OUT/export.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>${DEST:-upload}</string>
<key>teamID</key><string>95P4H2RG24</string>
<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>Apple Distribution</string>
<key>installerSigningCertificate</key><string>3rd Party Mac Developer Installer</string>
<key>provisioningProfiles</key><dict>
<key>io.azet.pass.safari</key><string>io.azet.pass.safari mac</string>
<key>io.azet.pass.safari.extension</key><string>io.azet.pass.safari.extension mac</string>
</dict>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath $OUT/AZETPassMac.xcarchive -exportOptionsPlist $OUT/export.plist -exportPath $OUT/export $AUTH

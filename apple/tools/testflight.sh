#!/bin/zsh
# Archive and upload to App Store Connect (TestFlight). Upload only — submitting for review is a separate, manual step.
# Needs: Vendor/BitwardenSdk (see sdk/README.md), the ASC API key in ~/.appstoreconnect/private_keys, tkt.
set -euo pipefail
cd "${0:A:h}/.."
KID=$(tkt get APPLE_AZET_ASC_API_KEY_ID); ISS=$(tkt get APPLE_AZET_ASC_ISSUER_ID)
AUTH=(-allowProvisioningUpdates -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_$KID.p8 -authenticationKeyID $KID -authenticationKeyIssuerID $ISS)
OUT=${OUT:-$HOME/.dooyou/lane649/release}
mkdir -p $OUT
xcodegen -q
xcodebuild -project AZETPass.xcodeproj -scheme AZETPass -configuration Release -destination generic/platform=iOS \
  -archivePath $OUT/AZETPass.xcarchive -derivedDataPath $OUT/dd archive $AUTH
cat > $OUT/export.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>upload</string>
<key>teamID</key><string>95P4H2RG24</string>
<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>Apple Distribution</string>
<key>provisioningProfiles</key><dict>
<key>io.azet.pass</key><string>AZET Pass AppStore 2026.10</string>
<key>io.azet.pass.autofill</key><string>AZET Pass AutoFill AppStore 2026.10</string>
</dict>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath $OUT/AZETPass.xcarchive -exportOptionsPlist $OUT/export.plist -exportPath $OUT/export ${AUTH[2,-1]}

#!/bin/sh
# Archive, export with Developer ID, notarize, staple, zip.
#
# One-time setup:
#   1. Config/Signing.xcconfig with EVAULT_TEAM_ID
#   2. xcrun notarytool store-credentials evault-notary --apple-id you@example.com --team-id TEAMID
#   3. In CloudKit Console, deploy the Development schema to Production
#      (Developer ID builds use the Production container environment).
set -eu
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/.*MARKETING_VERSION: \(.*\)/\1/p' project.yml | head -1)
OUT=dist
rm -rf "$OUT" && mkdir -p "$OUT"

xcodebuild -project eVault.xcodeproj -scheme eVault-iCloud -configuration Release-iCloud \
  -archivePath "$OUT/eVault.xcarchive" -allowProvisioningUpdates archive | tail -3
xcodebuild -exportArchive -archivePath "$OUT/eVault.xcarchive" \
  -exportOptionsPlist Config/ExportOptions.plist -exportPath "$OUT/export" -allowProvisioningUpdates | tail -3

ditto -c -k --keepParent "$OUT/export/eVault.app" "$OUT/eVault-$VERSION.zip"
xcrun notarytool submit "$OUT/eVault-$VERSION.zip" --keychain-profile evault-notary --wait
xcrun stapler staple "$OUT/export/eVault.app"
ditto -c -k --keepParent "$OUT/export/eVault.app" "$OUT/eVault-$VERSION.zip"
# Sparkle appcast: signs the zip with the EdDSA key from the keychain.
GA=$(find build/SourcePackages -name generate_appcast -type f | head -1)
if [ -n "$GA" ]; then
  "$GA" --download-url-prefix "https://github.com/dinhkhanh/eVault/releases/download/v$VERSION/" "$OUT" >/dev/null
  echo "appcast: $OUT/appcast.xml"
else
  echo "warning: generate_appcast not found; resolve packages first (make gen && xcodebuild -resolvePackageDependencies)"
fi
echo "Done: $OUT/eVault-$VERSION.zip"

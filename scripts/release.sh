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
# Refunded keys stop working on this release: refresh the compiled-in list first.
scripts/sync-revocations.sh
VERSION=$(sed -n 's/.*MARKETING_VERSION: \(.*\)/\1/p' project.yml | head -1)
# The bundled CLI reports its own version; keep it in step with the app.
grep -q "let evaultVersion = \"$VERSION\"" Packages/eVaultKit/Sources/evault/CLISupport.swift \
  || { echo "evaultVersion in Packages/eVaultKit/Sources/evault/CLISupport.swift is not $VERSION"; exit 1; }
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
# Disk image with the stapled app; signed and notarized on its own so Gatekeeper accepts the dmg too.
mkdir -p "$OUT/dmg" && cp -R "$OUT/export/eVault.app" "$OUT/dmg/" && ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname "eVault $VERSION" -srcfolder "$OUT/dmg" -ov -format UDZO "$OUT/eVault-$VERSION.dmg" >/dev/null
rm -rf "$OUT/dmg"
IDENTITY=$(codesign -dvv "$OUT/export/eVault.app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)/\1/p' | head -1)
codesign --sign "$IDENTITY" --timestamp "$OUT/eVault-$VERSION.dmg"
xcrun notarytool submit "$OUT/eVault-$VERSION.dmg" --keychain-profile evault-notary --wait
xcrun stapler staple "$OUT/eVault-$VERSION.dmg"
(cd "$OUT" && shasum -a 256 eVault-$VERSION.dmg eVault-$VERSION.zip) | tee "$OUT/SHA256SUMS"
# Sparkle appcast: signs the zip with the EdDSA key from the keychain.
GA=$(find build/SourcePackages -name generate_appcast -type f | head -1)
if [ -n "$GA" ]; then
  # Sparkle wants exactly one archive per version: feed it the zip only.
  rm -rf "$OUT/appcast-src" && mkdir -p "$OUT/appcast-src"
  cp "$OUT/eVault-$VERSION.zip" "$OUT/appcast-src/"
  "$GA" --download-url-prefix "https://github.com/dinhkhanh/eVault/releases/download/v$VERSION/" -o "$OUT/appcast.xml" "$OUT/appcast-src" >/dev/null
  rm -rf "$OUT/appcast-src"
  echo "appcast: $OUT/appcast.xml"
else
  echo "warning: generate_appcast not found; resolve packages first (make gen && xcodebuild -resolvePackageDependencies)"
fi
echo "Done: $OUT/eVault-$VERSION.zip"

#!/bin/sh
# Archive, export with Developer ID, notarize, staple; zip + dmg + SHA256SUMS + appcast.
#
# One-time setup:
#   1. Config/Signing.xcconfig with ENVAULT_TEAM_ID
#   2. xcrun notarytool store-credentials evault-notary --apple-id you@example.com --team-id TEAMID
#   3. In CloudKit Console, deploy the Development schema to Production
#      (Developer ID builds use the Production container environment).
set -eu
cd "$(dirname "$0")/.."
# Refunded keys stop working on this release: refresh the compiled-in list first.
scripts/sync-revocations.sh
VERSION=$(sed -n 's/.*MARKETING_VERSION: \(.*\)/\1/p' project.yml | head -1)
# The bundled CLI reports its own version; keep it in step with the app.
grep -q "let envaultVersion = \"$VERSION\"" Packages/EnVaultKit/Sources/envault/CLISupport.swift \
  || { echo "envaultVersion in Packages/EnVaultKit/Sources/envault/CLISupport.swift is not $VERSION"; exit 1; }
OUT=dist
rm -rf "$OUT" && mkdir -p "$OUT"

xcodebuild -project EnVault.xcodeproj -scheme EnVault-iCloud -configuration Release-iCloud \
  -archivePath "$OUT/EnVault.xcarchive" -allowProvisioningUpdates archive | tail -3
xcodebuild -exportArchive -archivePath "$OUT/EnVault.xcarchive" \
  -exportOptionsPlist Config/ExportOptions.plist -exportPath "$OUT/export" -allowProvisioningUpdates | tail -3
codesign --verify --deep --strict "$OUT/export/EnVault.app"

# notarytool can exit 0 when Apple rejects the upload; check the status line.
notarize() {
  xcrun notarytool submit "$1" --keychain-profile evault-notary --wait | tee "$OUT/notary.log"
  grep -q "status: Accepted" "$OUT/notary.log" \
    || { echo "notarization failed for $1 (see: xcrun notarytool log <id> --keychain-profile evault-notary)"; exit 1; }
}

ditto -c -k --keepParent "$OUT/export/EnVault.app" "$OUT/EnVault-$VERSION.zip"
notarize "$OUT/EnVault-$VERSION.zip"
xcrun stapler staple "$OUT/export/EnVault.app"
ditto -c -k --keepParent "$OUT/export/EnVault.app" "$OUT/EnVault-$VERSION.zip"
# Disk image with the stapled app; signed and notarized on its own so Gatekeeper accepts the dmg too.
mkdir -p "$OUT/dmg" && cp -R "$OUT/export/EnVault.app" "$OUT/dmg/" && ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname "EnVault $VERSION" -srcfolder "$OUT/dmg" -ov -format UDZO "$OUT/EnVault-$VERSION.dmg" >/dev/null
rm -rf "$OUT/dmg"
IDENTITY=$(codesign -dvv "$OUT/export/EnVault.app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)/\1/p' | head -1)
codesign --sign "$IDENTITY" --timestamp "$OUT/EnVault-$VERSION.dmg"
notarize "$OUT/EnVault-$VERSION.dmg"
xcrun stapler staple "$OUT/EnVault-$VERSION.dmg"
# Gatekeeper's verdict on what users will download.
spctl --assess --type execute -v "$OUT/export/EnVault.app"
spctl --assess --type open --context context:primary-signature -v "$OUT/EnVault-$VERSION.dmg"
# Unversioned copy: the website links to releases/latest/download/EnVault.dmg.
cp "$OUT/EnVault-$VERSION.dmg" "$OUT/EnVault.dmg"
(cd "$OUT" && shasum -a 256 EnVault-$VERSION.dmg EnVault.dmg EnVault-$VERSION.zip) | tee "$OUT/SHA256SUMS"
# Sparkle appcast: signs the zip with the EdDSA key from the keychain
# (account ed25519, or $SPARKLE_ACCOUNT; it must match SUPublicEDKey).
GA=$(find build/SourcePackages -name generate_appcast -type f | head -1)
if [ -n "$GA" ]; then
  # Sparkle wants exactly one archive per version: feed it the zip only.
  rm -rf "$OUT/appcast-src" && mkdir -p "$OUT/appcast-src"
  cp "$OUT/EnVault-$VERSION.zip" "$OUT/appcast-src/"
  "$GA" --account "${SPARKLE_ACCOUNT:-ed25519}" --download-url-prefix "https://github.com/dinhkhanh/EnVault/releases/download/v$VERSION/" -o "$OUT/appcast.xml" "$OUT/appcast-src" >/dev/null
  # eVault (builds 17 and below) has another bundle id, so Sparkle can't install EnVault over it;
  # for those builds the update is informational and links to the download page.
  perl -0pi -e 's{(\s*)</item>}{$1    <sparkle:informationalUpdate><sparkle:belowVersion>18</sparkle:belowVersion></sparkle:informationalUpdate>$1    <link>https://envault.app/</link>$1</item>}' "$OUT/appcast.xml"
  grep -q edSignature "$OUT/appcast.xml" || { echo "appcast is unsigned: the keychain key does not match SUPublicEDKey (generate_keys -p)"; exit 1; }
  rm -rf "$OUT/appcast-src"
  echo "appcast: $OUT/appcast.xml"
else
  echo "warning: generate_appcast not found; resolve packages first (make gen && xcodebuild -resolvePackageDependencies)"
fi
echo "Done: $OUT/EnVault-$VERSION.zip, .dmg and EnVault.dmg (Developer ID signed, notarized)"

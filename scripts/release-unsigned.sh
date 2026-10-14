#!/bin/sh
# Build the Release configuration with ad-hoc signing and package it.
# Produces dist/eVault-<version>.zip and dist/eVault-<version>.dmg.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/.*MARKETING_VERSION: \(.*\)/\1/p' project.yml | head -1)
OUT=dist
rm -rf "$OUT" && mkdir -p "$OUT/dmg"

xcodebuild -project eVault.xcodeproj -scheme eVault -configuration Release \
  -derivedDataPath build build CODE_SIGN_IDENTITY=- | tail -2
APP=build/Build/Products/Release/eVault.app
codesign --verify --deep --strict "$APP"

ditto -c -k --keepParent "$APP" "$OUT/eVault-$VERSION.zip"

cp -R "$APP" "$OUT/dmg/"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname "eVault $VERSION" -srcfolder "$OUT/dmg" -ov -format UDZO "$OUT/eVault-$VERSION.dmg" >/dev/null
rm -rf "$OUT/dmg"
shasum -a 256 "$OUT"/eVault-$VERSION.* | tee "$OUT/SHA256SUMS"
# Sparkle appcast: signs the zip with the EdDSA key from the keychain.
GA=$(find build/SourcePackages -name generate_appcast -type f | head -1)
if [ -n "$GA" ]; then
  "$GA" --download-url-prefix "https://github.com/dinhkhanh/eVault/releases/download/v$VERSION/" "$OUT" >/dev/null
  echo "appcast: $OUT/appcast.xml"
else
  echo "warning: generate_appcast not found; resolve packages first (make gen && xcodebuild -resolvePackageDependencies)"
fi
echo "Done: $OUT/eVault-$VERSION.zip and .dmg (unsigned: right-click > Open on first launch)"

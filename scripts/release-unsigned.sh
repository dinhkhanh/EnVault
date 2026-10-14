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
echo "Done: $OUT/eVault-$VERSION.zip and .dmg (unsigned: right-click > Open on first launch)"

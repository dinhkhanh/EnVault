#!/bin/sh
# Build the Release configuration with ad-hoc signing and package it.
# Produces dist/eVault-<version>.zip and dist/eVault-<version>.dmg.
set -eu
cd "$(dirname "$0")/.."
# Refunded keys stop working on this release: refresh the compiled-in list first.
scripts/sync-revocations.sh
VERSION=$(sed -n 's/.*MARKETING_VERSION: \(.*\)/\1/p' project.yml | head -1)
OUT=dist
rm -rf "$OUT" && mkdir -p "$OUT/dmg"

xcodebuild -project eVault.xcodeproj -scheme eVault -configuration Release \
  -derivedDataPath build build CODE_SIGN_IDENTITY=- | tail -2
APP=build/Build/Products/Release/eVault.app

# Ad-hoc signed apps can only load ad-hoc signed code under library validation,
# so re-sign Sparkle's nested XPC services, helper app and framework, innermost
# first, keeping their own entitlements, then re-sign the app itself.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  find "$SPARKLE" -depth \( -name "*.xpc" -o -name "*.app" -o -name "Autoupdate" \) \
    -exec codesign --force --sign - --preserve-metadata=entitlements,flags {} \;
  codesign --force --sign - --preserve-metadata=entitlements,flags "$SPARKLE"
fi
codesign --force --sign - --preserve-metadata=entitlements,flags "$APP"
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
  # Sparkle wants exactly one archive per version: feed it the zip only.
  rm -rf "$OUT/appcast-src" && mkdir -p "$OUT/appcast-src"
  cp "$OUT/eVault-$VERSION.zip" "$OUT/appcast-src/"
  "$GA" --download-url-prefix "https://github.com/dinhkhanh/eVault/releases/download/v$VERSION/" -o "$OUT/appcast.xml" "$OUT/appcast-src" >/dev/null
  rm -rf "$OUT/appcast-src"
  echo "appcast: $OUT/appcast.xml"
else
  echo "warning: generate_appcast not found; resolve packages first (make gen && xcodebuild -resolvePackageDependencies)"
fi
echo "Done: $OUT/eVault-$VERSION.zip and .dmg (unsigned: right-click > Open on first launch)"

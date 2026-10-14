.PHONY: gen build run test release-unsigned build-icloud run-icloud archive clean

# --- unsigned local builds (folder sync only) ---------------------------------
gen: Config/Signing.xcconfig
	xcodegen generate

build: gen
	xcodebuild -project eVault.xcodeproj -scheme eVault -configuration Debug -derivedDataPath build build CODE_SIGN_IDENTITY=- | tail -3

run: build
	open build/Build/Products/Debug/eVault.app

test:
	cd Packages/eVaultKit && swift test

# Release build without a Developer ID: ad-hoc signed, folder sync only.
# Recipients must right-click > Open the first time (Gatekeeper).
release-unsigned: gen
	scripts/release-unsigned.sh

# --- signed builds with iCloud sync (needs Config/Signing.xcconfig) -----------
Config/Signing.xcconfig:
	@cp Config/Signing.xcconfig.example Config/Signing.xcconfig
	@echo ">> Created Config/Signing.xcconfig — put your team id in it for iCloud builds."

build-icloud: gen
	xcodebuild -project eVault.xcodeproj -scheme eVault-iCloud -configuration Debug-iCloud -derivedDataPath build -allowProvisioningUpdates build | tail -3

run-icloud: build-icloud
	open build/Build/Products/Debug-iCloud/eVault.app

archive: gen
	scripts/release.sh

clean:
	rm -rf build eVault.xcodeproj Packages/eVaultKit/.build dist

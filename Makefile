.PHONY: gen build test run clean

gen:
	xcodegen generate

build: gen
	xcodebuild -project eVault.xcodeproj -scheme eVault -configuration Debug -derivedDataPath build build CODE_SIGN_IDENTITY=- | tail -5

test:
	cd Packages/eVaultKit && swift test

run: build
	open build/Build/Products/Debug/eVault.app

clean:
	rm -rf build eVault.xcodeproj Packages/eVaultKit/.build

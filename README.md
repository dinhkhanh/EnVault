# eVault

A native macOS app for developers: store `.env` files and secrets in an
encrypted vault, get them back on any of your Macs through iCloud Drive (or any
synced folder), and never let the sync transport see plaintext.

Design and rationale: [docs/PLAN.md](docs/PLAN.md).

## Build

Requires Xcode 16+ (built with Xcode 27 / Swift 6.4) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
make build        # unsigned local build: folder sync only
make run          # build + open the app
make test         # swift test for the packages
```

`make gen` only regenerates the project; the `.xcodeproj` is git-ignored and
comes from `project.yml`.

### Unsigned release (no Developer ID yet)

```sh
make release-unsigned   # dist/eVault-<version>.zip and .dmg, ad-hoc signed
```

Gatekeeper blocks unsigned apps on first launch: right-click the app and
choose Open once. Folder sync works; iCloud (CloudKit) mode needs the signed build.

### Signed build with iCloud sync

With an Apple Developer account:

1. `cp Config/Signing.xcconfig.example Config/Signing.xcconfig` and put your
   team id in it (the file is git-ignored).
2. `make build-icloud` / `make run-icloud` — configuration `Debug-iCloud`,
   signed with "Apple Development", entitled for CloudKit container
   `iCloud.dk.dinhkhanh.evault` and silent push. Xcode's automatic signing
   registers the container on first build (`-allowProvisioningUpdates`).
3. `make archive` — `Release-iCloud` with Developer ID, notarized and stapled
   into `dist/` (see `scripts/release.sh` for the one-time `notarytool`
   credential setup). Developer ID builds talk to the **Production** CloudKit
   environment: deploy the schema from Development in the CloudKit Console
   first. The schema is just one record type, `VaultFile`, with `path`,
   `data` and `asset` fields; it is created just-in-time in Development.

The app detects the iCloud entitlement at runtime, so the same code runs in
folder-only mode when unsigned.

## Layout

```
App/                      SwiftUI app (views, view model, services, tools)
Packages/eVaultKit/
  Sources/VaultCore       crypto, vault format, VaultStore actor, Keychain cache
  Sources/EnvKit          dotenv parser / serializer / diff / export
  Sources/VaultSync       FSEvents folder watcher, iCloud Drive locations
  Sources/ToolKit         Tool protocol + registry (the plugin API)
  Sources/evault          command-line companion
  Tests/                  Swift Testing suites
docs/PLAN.md              architecture, security model, roadmap
```

## Sync modes

| Mode | Where the vault lives | Transport | Needs |
|---|---|---|---|
| Folder | any folder you pick (iCloud Drive by default) | the folder's own sync (iCloud Drive, Dropbox, Syncthing, git) | nothing |
| iCloud | app container, mirrored to your private CloudKit database | CloudKit, with silent push + 5-minute polling + sync on activate | signed build |

Both modes use the same on-disk format. In iCloud mode a `CloudMirror` uploads
every new local file once and downloads every new remote file once; because
files are immutable there is nothing to merge. Compaction deletes records,
and a passphrase change replaces the `vault.json` record.

## How it works

- A vault is a folder. `vault.json` holds the KDF parameters and the vault key
  wrapped by a key derived from your passphrase (PBKDF2-HMAC-SHA256, 600k
  iterations). Every change to an item is a new immutable, AES-256-GCM
  encrypted `.evr` file. Nothing is ever overwritten, so iCloud Drive, Dropbox
  or git never produce conflict copies; the newest revision wins per item and
  the full history stays available in the app.
- On a second Mac: install the app, open the same folder, enter the
  passphrase. Optionally cache the key behind Touch ID.
- The app is sandboxed, hardened, and has no network entitlement.

## CLI

```sh
swift build -c release --package-path Packages/eVaultKit --product evault
export EVAULT_PASSPHRASE=…            # or get prompted
evault ls
evault pull my-saas .env.local         # writes ./.env.local (mode 600)
evault push my-saas .env.local .env.local
evault run  my-saas .env.production -- npm start
evault history my-saas .env.local
```

The vault folder defaults to `~/Library/Mobile Documents/com~apple~CloudDocs/eVault`;
override with `--vault DIR` or `EVAULT_DIR`.

## Adding a tool

Conform to `Tool` (see `App/Tools/`), add one line to `ToolRegistry.all`. It
appears in the sidebar under its category and gets a read-only `ToolContext`
with the unlocked projects/items and a concealed-clipboard helper.

## Dev notes

- Debug builds accept `-vaultPath DIR [-passphrase PW]` to open or create a
  vault without the folder picker, and `-fakeCloud YES [-createICloud YES
  -passphrase PW]` to exercise the iCloud flow against an in-memory cloud.
- `scripts/make-icon.swift` renders the app icon; the asset catalog is checked in.
- Ad-hoc signed builds fall back from the data-protection keychain to a legacy
  keychain item with app-enforced Touch ID; Developer ID builds use the
  keychain-enforced `.biometryCurrentSet` item.

# eVault — Plan & Solution

A native macOS app for developers to store `.env` files and other secrets in an
encrypted local vault, and get them back on any of their Macs via iCloud (or any
synced folder), without the sync transport ever seeing plaintext.

Status: **proposal, nothing built yet.** Date: 2026-10-14.

---

## 1. Goals and non-goals

**Goals**

- Store `.env` files (and generic secrets: API keys, tokens, certs) per project.
- Retrieve them on another Mac with only the app + passphrase.
- Zero-knowledge sync: iCloud/Dropbox/git only ever carries ciphertext.
- Fast daily use: Touch ID unlock, menu-bar quick copy, drag-and-drop import,
  "write this `.env` into that folder" export.
- Extendable: adding a small developer tool (JWT decoder, UUID generator,
  env diff, …) is a new file conforming to one protocol, not a refactor.

**Non-goals for v1**

- Team sharing / multi-user vaults (design leaves room for it; see §9).
- iOS app (core is platform-agnostic Swift so it stays possible).
- Browser extension, SSH agent, password-manager features.

---

## 2. Environment facts that shaped the design

| Fact | Consequence |
|---|---|
| Xcode 27, Swift 6.4 | Swift 6 strict concurrency, SwiftUI, Swift Testing. |
| iCloud Drive enabled on this Mac | `~/Library/Mobile Documents/com~apple~CloudDocs/` is a usable sync folder today. |
| No code-signing identity installed | CloudKit / iCloud ubiquity-container entitlements need a paid Apple Developer team. Cannot ship CloudKit sync in v1. |
| No xcodegen/tuist installed | Need either `brew install xcodegen` or a hand-built `.xcodeproj`. Recommend XcodeGen (reproducible `project.yml` in git). |

**Decision:** v1 syncs through an **encrypted file layout in a user-chosen
folder** (default: an `eVault` folder inside iCloud Drive). This works with
iCloud Drive, Dropbox, Syncthing, a git repo, or a USB stick, needs no
entitlements, and is zero-knowledge by construction. CloudKit becomes a second
`SyncBackend` implementation once a developer account exists.

---

## 3. Architecture overview

```
┌──────────────────────────────────────────────────────────────────┐
│  eVault.app (SwiftUI, macOS 15+)                                 │
│  ┌──────────────┐ ┌────────────────┐ ┌─────────────────────────┐ │
│  │ Vault UI     │ │ Menu bar extra │ │ Tools (plugin registry) │ │
│  └──────┬───────┘ └───────┬────────┘ └───────────┬─────────────┘ │
│         └─────────────────┴──────────────────────┘               │
│                           │  AppCore (view models, services)      │
├───────────────────────────┼──────────────────────────────────────┤
│  Swift packages (no UI, fully unit-tested)                       │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────┐ ┌─────────────┐  │
│  │ VaultCore    │ │ VaultSync    │ │ EnvKit   │ │ ToolKit     │  │
│  │ crypto,      │ │ SyncBackend  │ │ dotenv   │ │ Tool proto, │  │
│  │ models,      │ │ protocol +   │ │ parse /  │ │ registry    │  │
│  │ store format │ │ FolderBackend│ │ diff     │ │             │  │
│  └──────────────┘ └──────────────┘ └──────────┘ └─────────────┘  │
├──────────────────────────────────────────────────────────────────┤
│  evault (CLI, phase 4) — links VaultCore + EnvKit                 │
└──────────────────────────────────────────────────────────────────┘
```

Rules:

- Packages never import AppKit/SwiftUI. Everything below the line is testable
  with `swift test` and reusable by the CLI and a future iOS app.
- The app talks to the vault only through `VaultStore` (an `actor`). No view
  ever touches ciphertext or keys.
- Every on-disk structure carries a `version` field so formats can evolve.

---

## 4. Data model

```
Vault
 └─ Project            (id, name, slug, tags, createdAt)      e.g. "my-saas"
     └─ Item           (id, projectId, kind, name, tags, revisions)
         ├─ kind .envFile    name ".env.local"   payload: raw dotenv text
         ├─ kind .secret     name "STRIPE_KEY"   payload: single value + notes
         └─ kind .note       name "deploy notes" payload: markdown
```

- `Item.kind` is an enum with an `unknown(String)` case so new kinds added
  later don't break older clients.
- `.envFile` payload is the **raw file text**, so comments, ordering, quoting,
  and blank lines round-trip byte-for-byte. `EnvKit` parses it on demand for
  the structured view (masking, copy-one-value, diff).
- Every change to an item produces a new immutable **revision** (see §6).
  History/restore is free.

---

## 5. Cryptography

Goal: ciphertext on disk and in the cloud is useless without the passphrase;
day-to-day unlock uses Touch ID; changing the passphrase does not re-encrypt
everything.

**Key hierarchy**

```
passphrase ──KDF──▶ KEK (256-bit)
                       │ unwraps
                       ▼
                 Vault Key VK (random 256-bit, generated once)
                       │ encrypts
                       ▼
            every item revision (AES-256-GCM, random 12-byte nonce)
```

| Piece | Choice | Why |
|---|---|---|
| Cipher | AES-256-GCM via CryptoKit | Hardware-accelerated, AEAD, Apple-native. |
| AAD | `vaultId ‖ itemId ‖ revisionId ‖ formatVersion` | A revision file can't be moved/renamed to impersonate another. |
| KDF | PBKDF2-HMAC-SHA256, ≥600k iterations, 32-byte salt (CommonCrypto) | CryptoKit has no Argon2; PBKDF2 is NIST/OWASP-acceptable. KDF id + params are stored in the vault header, so Argon2id can be added later as `kdf: "argon2id"` without migration pain. |
| VK wrapping | AES-256-GCM with KEK | Passphrase change = re-wrap 32 bytes. |
| Touch ID unlock | VK cached in Keychain: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + `SecAccessControl(.biometryCurrentSet)` | Never leaves this device; invalidated if biometrics change. |
| Verification | Wrapped VK's GCM tag doubles as passphrase check | No separate "verifier" to attack. |

**Hygiene**

- Plaintext lives only in memory while unlocked; auto-lock after N minutes /
  on sleep / on screen lock.
- Clipboard copies are marked transient (`org.nspasteboard.ConcealedType`) and
  auto-cleared after 30 s.
- App Sandbox on, Hardened Runtime on, no network entitlement at all in v1
  (the app literally cannot phone home).
- Secrets masked by default in UI; reveal is per-field and times out.

---

## 6. On-disk format and conflict-free sync

The vault is a directory. The same directory is both the local store and the
synced store; the "sync backend" is just where that directory lives.

```
eVault/                          ← the synced folder
  vault.json                     ← header: vaultId, formatVersion, kdf params,
                                   salt, wrapped VK. Public-safe (ciphertext only).
  projects/
    <projectId>/
      meta/<revisionULID>.evr    ← encrypted project metadata revisions
      items/
        <itemId>/
          <revisionULID>.evr     ← one encrypted blob per change, never rewritten
          <revisionULID>.evr
  devices/
    <deviceId>.json              ← device name, last-seen (ciphertext, cosmetic)
```

Why this shape:

- **Append-only, immutable files.** A device never modifies a file another
  device may be writing. File-sync services (iCloud Drive included) therefore
  never produce "conflicted copy" files. Merging is: for each item, latest
  ULID wins. ULIDs are time-sortable and unique per device, so ordering is
  deterministic even when two devices edit offline.
- Deletion is a **tombstone revision**. Compaction (dropping old revisions)
  is an explicit user action, not automatic, so sync is never racing it.
- Each `.evr` = small header (plain, versioned: `magic`, `formatVersion`,
  `nonce`) + GCM ciphertext of a JSON payload. Entire payload incl. item name
  and tags is encrypted; only ids and timestamps are visible.
- iCloud Drive "evicted" files are handled by `NSFileCoordinator` +
  `startDownloadingUbiquitousItem` when reading.

`SyncBackend` protocol (VaultSync):

```swift
protocol SyncBackend: Sendable {
    func list(prefix: String) async throws -> [RemotePath]
    func read(_ path: RemotePath) async throws -> Data
    func write(_ path: RemotePath, data: Data) async throws   // create-only
    func watch() -> AsyncStream<ChangeEvent>
}
```

v1 ships `FolderBackend` (local dir, iCloud Drive dir, anything). Planned:
`CloudKitBackend` (same immutable-revision model maps 1:1 to `CKRecord`s),
`GitBackend` (each revision a commit; nice for teams already on git).

**Onboarding a second Mac:** install app → choose the same folder → enter
passphrase → optionally enable Touch ID. Nothing else.

---

## 7. App UX (v1)

- **Lock screen**: passphrase or Touch ID. Create-vault flow on first run
  (choose folder, set passphrase, show recovery hint about "no reset").
- **Main window** (`NavigationSplitView`, 3 columns):
  - Sidebar: Projects (+ tags, search). Tools section at bottom.
  - Middle: items in the project (`.env.local`, `.env.production`, secrets).
  - Detail: editor. For env files: a code editor with dotenv highlighting,
    values masked by default, per-line copy/reveal, structured side-panel,
    "History" drawer to view/restore revisions, "Diff vs. revision".
- **Import**: drag a `.env` onto a project; "Import from folder" scans for
  `.env*` files. **Export**: "Write to directory…" and "Copy as `export`
  lines" for a shell.
- **Menu bar extra**: search → copy a single value, no window needed.
- **Settings**: vault folder, auto-lock timing, clipboard timeout, Touch ID,
  change passphrase, compaction.

---

## 8. Extensibility model ("tiny developer features")

```swift
public protocol Tool: Identifiable, Sendable {
    var id: String { get }            // "jwt-decoder"
    var title: String { get }
    var systemImage: String { get }
    var category: ToolCategory { get }
    @MainActor func makeView(context: ToolContext) -> AnyView
}
```

- `ToolRegistry` is a static list in the app target; adding a tool = one new
  file + one line in the registry. Tools appear in the sidebar "Tools" section
  and in the menu bar extra automatically.
- `ToolContext` gives read-only access to the unlocked vault (e.g. "diff
  `.env.local` against `.env.production`"), clipboard helper, and a scratch
  key-value store (`UserDefaults`-backed, namespaced by tool id).
- Likely first tools: env diff, JWT decoder, UUID/ULID generator, base64/hex,
  random secret generator, `.env` → `export` / JSON / YAML converter.
- Larger future features (CloudKit, CLI, sharing) plug in at the package
  layer via protocols (`SyncBackend`, `ItemKind`), not via the tool registry.

---

## 9. Future (designed for, not built)

- **CloudKit backend** when a developer account is available.
- **CLI** `evault` (`evault pull my-saas .env.local`, `evault run -- npm dev`
  injecting env). Reads the same folder; gets VK from Keychain via a shared
  access group or prompts for passphrase.
- **Sharing a project**: per-project key wrapped for each recipient's public
  key (Curve25519). The item format already keys on `projectId` so this is a
  wrapping change, not a format change.
- **iOS companion** (read-only quick copy) — packages have no AppKit deps.

---

## 10. Project layout & tooling

```
eVault/
  project.yml                 ← XcodeGen spec → eVault.xcodeproj (generated, git-ignored)
  App/                        ← SwiftUI app target
    eVaultApp.swift, Views/, ViewModels/, Tools/, Resources/, eVault.entitlements
  Packages/
    VaultCore/   (Sources, Tests)
    VaultSync/   (Sources, Tests)
    EnvKit/      (Sources, Tests)
    ToolKit/     (Sources)
  docs/PLAN.md
  Makefile                    ← `make gen`, `make build`, `make test`
```

- Swift 6 language mode, strict concurrency, `VaultStore` as an actor.
- Tests: Swift Testing for packages (crypto round-trips, KDF vectors, dotenv
  parser fixtures, sync merge scenarios incl. two-device offline edits).
- Deployment target macOS 15. Unsigned/ad-hoc-signed local builds work for
  personal use; Developer ID signing when distributing.

---

## 11. Phases

| Phase | Deliverable | Rough size |
|---|---|---|
| 0 | Repo scaffold, packages, XcodeGen project, Makefile, CI-less build passes | small |
| 1 | `VaultCore`: crypto, key hierarchy, `.evr` format, `VaultStore` actor, tests | medium |
| 2 | `EnvKit`: dotenv parse/serialize/diff with fixtures | small |
| 3 | App: create/unlock, Touch ID, projects, items, env editor, import/export, auto-lock, clipboard hygiene | large |
| 4 | `VaultSync` folder backend over iCloud Drive, revision merge, history/restore UI, second-device onboarding | medium |
| 5 | Menu bar extra, `ToolRegistry` + 3 starter tools | small |
| 6 | `evault` CLI | medium |

Phases 0–2 can be built and tested without opening Xcode's UI at all.

---

## 12. Open questions for you

1. **Sync v1 = encrypted folder in iCloud Drive** (no Apple developer account
   needed) with CloudKit as a later backend. OK?
2. **Install XcodeGen via Homebrew** to generate the `.xcodeproj` from a
   checked-in `project.yml`? (Alternative: commit a hand-maintained project.)
3. **Minimum macOS 15** (Sequoia)? Could go 14 or 26.
4. Name/bundle id: `eVault`, `dk.dinhkhanh.evault`?

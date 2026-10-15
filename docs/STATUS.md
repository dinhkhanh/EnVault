# eVault — current state

Snapshot as of **2026-10-15**. Update this file whenever something ships,
blocks, or changes hands. Design and rationale live in [PLAN.md](PLAN.md);
this is the "where are we" page.

## Shipped

| What | Where | State |
|---|---|---|
| App v0.3.3 (unsigned, ad-hoc) | [GitHub release](https://github.com/dinhkhanh/eVault/releases/tag/v0.3.3): dmg, zip, SHA256SUMS, appcast.xml | live; Sparkle feed resolves to 0.3.3 (build 7). Adds URL encode/decode and password generator tools. Keys rotated in 0.3.2; 0.3.1 installs must reinstall by hand |
| Website + pricing + privacy | https://dinhkhanh.github.io/eVault/ (GitHub Pages from `main:/docs`) | live |
| Packages `VaultCore`, `EnvKit`, `VaultSync`, `ToolKit`, `LicenseKit` | `Packages/eVaultKit` | 51 tests passing |
| CLI `evault`, vendor tool `evault-license` | same package | done |
| Store Worker (Polar checkout, webhooks, email, refunds, resend, admin) | `store/` | written, 12 unit tests + local end-to-end passing; **not deployed** |
| Revocation list + 12-month update window in the app | `App/RevokedLicenses.swift`, `LicenseManager` | shipped in 0.3.1 (list empty) |

## Decisions in force

- Free: 3 projects, folder sync, editor, history, Touch ID, CLI. Pro $29 one-time: unlimited projects, CloudKit sync, menu bar quick copy, developer tools, shell integration, 12 months of updates. Team: later, subscription with seats.
- Sync v1 = encrypted folder in iCloud Drive; CloudKit mirror is the Pro backend.
- Licenses: offline Ed25519 keys (`EVL1.payload.sig`), no activation server, no analytics, no network entitlement in the app.
- **Payments: Polar** (merchant of record; seller in Vietnam; Polar lists Vietnam as a payout country, pays VND to a local bank). **Paddle is the fallback** (USD payouts, Payoneer or USD account). Lemon Squeezy rejected.
- Refunds: 14 days. A full refund revokes the key in the store; the id ships in the next app release.

## Blocked, and on whom

| Item | Blocked on | Unblocks |
|---|---|---|
| Signed, notarized builds; `make archive`; CloudKit against a real account; Touch ID via data-protection keychain | Apple Developer account activation (team KJ8A3B7BM7), then sign into Xcode | Real Pro iCloud sync, Gatekeeper-clean installs |
| Store deployment | Polar account (org, product, checkout link, webhook secret); Cloudflare login; D1 id; Resend verified sending domain; `store.evault.dinhkhanh.dk` | Taking money |
| Buy button on the site | Store deployment | same |

## Next actions (in order)

1. Polar: create org (payout country Vietnam, bank in your registered name), product "eVault Pro" $29 one-time with metadata `plan = pro`, checkout link with success URL `https://store.evault.dinhkhanh.dk/thanks`.
2. Deploy the store: follow `store/README.md` (D1 create, five secrets, `npm run deploy`, Polar webhook endpoint). Put the admin token in the keychain for `scripts/store.sh`.
3. Resend: verify `dinhkhanh.dk` (or change `FROM_EMAIL`).
4. Sandbox purchase on Polar → key arrives → activates in the app. Then announce.
5. When the Apple account activates: sign into Xcode, `make run-icloud`, deploy the CloudKit schema to Production, `make archive`, release a signed build.
6. Later: Team plan (subscription with seats), iOS companion, Mac App Store or Setapp.

## Vendor secrets (never in the repo)

| Secret | Location |
|---|---|
| License signing key (Ed25519 private) | login keychain `dk.dinhkhanh.evault.license-signing`; backup in password manager; also becomes the Worker secret `LICENSE_PRIVATE_KEY` |
| License public key | `App/LicensePublicKey.swift`, `store/wrangler.toml` (`LICENSE_PUBLIC_KEY`) |
| Sparkle EdDSA key | login keychain, account `ed25519` (from `generate_keys`); backup in password manager; public key in `project.yml` (`SUPublicEDKey`) |
| Store admin token | Worker secret `ADMIN_TOKEN`; keychain `dk.dinhkhanh.evault.store-admin` |
| Polar / Paddle / Resend secrets | Worker secrets only |
| Apple team id | git-ignored `Config/Signing.xcconfig` |
| Offline license ledger | `~/Library/Application Support/eVault Vendor/licenses.jsonl` (fallback only; D1 is the ledger of record) |

Back up both keychain keys. Losing the license key means no new keys can be issued; losing the Sparkle key means existing installs cannot update.
This already happened once: both originals went missing and both pairs were rotated in 0.3.2 (2026-10-15), before any sale. Keys from the old license pair no longer verify.

Restore on a new Mac or after a keychain reset:
- License key: `security add-generic-password -s dk.dinhkhanh.evault.license-signing -a evault -w '<key>'`
- Sparkle key: save it to a file, then `build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -f <file>` (export with `-x <file>`)

## Routine operations

- Release: bump `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, `EVAULT_RELEASE_DATE` (quoted) in `project.yml`; `make release-unsigned` (or `make archive` when signed); tag `vX.Y.Z`; `gh release create` with dmg, zip, SHA256SUMS, appcast.xml. The release scripts pull revoked ids from the store first.
- Customers: `scripts/store.sh list [query]`, `issue --email E --name N`, `revoke --email E --reason R`, `resend --email E`. Self-service: `/resend` on the store.
- Tests: `make test` (Swift), `make store-test` (Worker).

## Known gaps

See [PLAN.md §13](PLAN.md#13-known-gaps). Highlights: CloudKit untested against a real account; ad-hoc builds use the legacy keychain fallback; raw editor has basic highlighting only; no second physical Mac verified through iCloud Drive yet.

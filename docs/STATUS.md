# EnVault — current state

Snapshot as of **2026-10-16**. Update this file whenever something ships,
blocks, or changes hands. Design and rationale live in [PLAN.md](PLAN.md);
this is the "where are we" page.

## Shipped

| What | Where | State |
|---|---|---|
| App v0.4.0 (**Developer ID signed, notarized**, macOS 14+) | [GitHub release](https://github.com/dinhkhanh/EnVault/releases/tag/v0.4.0): dmg, zip, SHA256SUMS, appcast.xml | 0.4.0 (build 15): CLI bundled in the app (`Contents/Helpers/envault`, installed from Settings › Command Line) and unlocked through the app with Touch ID (Mach-port agent); `envault import` (JSON, Doppler, 1Password, .env.vault), `envault protect` / `scan --staged` pre-commit hook; quick copy panel on a global shortcut (⌥⌘E) searching keys, secrets, notes and values with recents; Import Projects from Folder on first run; env files kept in sync in project folders (Pro); editor line numbers, lint warnings, key comparison with sibling files. 0.3.10 only prompts Touch ID while EnVault is frontmost, once per lock. 0.3.9 fixes Touch ID unlock in signed builds (0.3.7–0.3.8 never found the saved key after relaunch). 0.3.8 redesigns the license key input (multi-line box, Paste, live status; wrapped keys accepted). 0.3.7 was the first signed build: iCloud (CloudKit, Production) available to Pro, no right-click > Open. 0.3.6 introduced the current license (`LR48…`) and Sparkle (`SRLH…`) keys; 0.3.2–0.3.5 installs must reinstall by hand |
| App v0.5.1: AI agents | [GitHub release](https://github.com/dinhkhanh/EnVault/releases/tag/v0.5.1) (build 17, signed, notarized) | Agents detected from their env (`CLAUDECODE`, `CURSOR_AGENT`, `GEMINI_CLI`, `CODEX_SANDBOX`, `ENVAULT_AGENT`): no prompts, `run` output redacted, values only with Touch ID; `envault mcp` (stdio MCP server), `keys`, `set`/`unset` (`--generate`), `--json`, stable exit codes, `agent-guide [--skill]`; Settings › AI Agents (values ask/never/no extra prompt, writes, approval window, recent requests); `docs/llms.txt`. Free. Shipped 2026-10-16 in 0.5.0; 0.5.1 reads iCloud-mode vaults through the app (`AppVaultStorage` over the agent port: reads and create-only writes), so the CLI/MCP work from hosts without macOS's "access data from other apps" permission, and prefers the app's vault over an old iCloud Drive one |
| App v0.6.0: **renamed EnVault** (.env + vault) | GitHub release v0.6.0 (build 18, signed, notarized) | New bundle id `dk.dinhkhanh.envault`, iCloud container `iCloud.dk.dinhkhanh.envault`, `envault` CLI and `ENVAULT_*` variables; clean break, no `evault` alias. eVault installs can't update in place (Sparkle refuses a different bundle id): the appcast marks every release informational for builds ≤ 17 with a link to the site. Moving over: welcome screen › "Used eVault? Move a vault from it…" copies an iCloud vault from `iCloud.dk.dinhkhanh.evault` (read-only entitlement) into the new container; folder vaults open with "Open from a Folder…"; license keys must be pasted again (new defaults domain). The repo is `dinhkhanh/EnVault`; GitHub redirects the old git and release URLs (so eVault's feed still resolves), the old Pages URL does not redirect |
| Domain `envault.app` | Cloudflare zone (Tran@dinhkhanh.dk's Account) | Apex A/AAAA and `www` CNAME to GitHub Pages (DNS only); `store` is the Worker's custom domain; Resend domain `envault.app` (DKIM `resend._domainkey`, `send` MX/SPF, `rsend` CNAME, `_dmarc` p=none). License mail comes from `license@envault.app` |
| Website + pricing + privacy | https://envault.app/ (GitHub Pages from `main:/docs`, `docs/CNAME`) | live |
| Packages `VaultCore`, `EnvKit`, `VaultSync`, `ToolKit`, `LicenseKit` | `Packages/EnVaultKit` | 75 tests passing |
| CLI `envault`, vendor tool `envault-license` | same package | done |
| Store Worker (Polar checkout, webhooks, email, refunds, resend, admin) | `store/` | **deployed** 2026-10-15; https://store.envault.app since 0.6.0, the old https://store.evault.dinhkhanh.dk stays attached (eVault builds, Polar webhook, old emails) (D1, `LICENSE_PRIVATE_KEY`, `ADMIN_TOKEN`, `RESEND_API_KEY` set; mail from verified `updates.dinhkhanh.dk`). `/buy` redirects to the production Polar checkout link; Polar webhook secret set and signature checks verified live |
| Revocation list + 12-month update window in the app | `App/RevokedLicenses.swift`, `LicenseManager` | shipped in 0.3.1 (list empty) |

## Decisions in force

- Free: 3 projects, folder sync, editor, history, Touch ID, CLI, AI agent support (MCP). Pro $29 one-time: unlimited projects, CloudKit sync, menu bar quick copy, developer tools, shell integration, 12 months of updates. Team: later, subscription with seats.
- Sync v1 = encrypted folder in iCloud Drive; CloudKit mirror is the Pro backend.
- Licenses: offline Ed25519 keys (`EVL1.payload.sig`), no activation server, no analytics, no network entitlement in the app.
- **Payments: Polar** (merchant of record; seller in Vietnam; Polar lists Vietnam as a payout country, pays VND to a local bank). **Paddle is the fallback** (USD payouts, Payoneer or USD account). Lemon Squeezy rejected.
- Refunds: 14 days. A full refund revokes the key in the store; the id ships in the next app release.

## Blocked, and on whom

| Item | Blocked on | Unblocks |
|---|---|---|
| First real sale verified | One purchase through the site's Buy button (then refund it in Polar): webhook → key → email → activates in 0.3.6 | Announcing |
| iCloud sync in 0.6.0 release builds | Deploy the `VaultFile` schema of `iCloud.dk.dinhkhanh.envault` to Production in the CloudKit Console (Development gets it from the first debug-build upload) | New and moved iCloud vaults |
| Buy button on the site | nothing: live since 2026-10-15 (production checkout, real charges) | — |

## Next actions (in order)

1. Done 2026-10-15: Polar org, product "eVault Pro" $29, production checkout link (in `wrangler.toml`), webhook `https://store.evault.dinhkhanh.dk/webhooks/polar` (secret in the Worker). Done 2026-10-16 after the rename: product renamed "EnVault Pro" in Polar (the plan comes from metadata or "team" in the name, so the store doesn't care).
2. Done 2026-10-15: store deployed with all secrets (license key, admin token, Resend, Polar webhook).
3. Buy once through the site, check the key email and activation in 0.3.6, refund in Polar and check the key turns revoked (`scripts/store.sh list`). Then announce.
4. Done 2026-10-15: Apple account active, CloudKit schema in Production, `make archive` (Developer ID, notarized; notary profile `evault-notary` in the keychain) shipped 0.3.7. Releases from now on: `make archive`, not `release-unsigned`.
5. Later: Team plan (subscription with seats), iOS companion, Mac App Store or Setapp.

## Vendor secrets (never in the repo)

| Secret | Location |
|---|---|
| License signing key (Ed25519 private) | login keychain `dk.dinhkhanh.evault.license-signing`; backup in password manager; also becomes the Worker secret `LICENSE_PRIVATE_KEY` |
| License public key | `App/LicensePublicKey.swift`, `store/wrangler.toml` (`LICENSE_PUBLIC_KEY`) |
| Sparkle EdDSA key | login keychain, account `ed25519` (from `generate_keys`); backup in password manager; public key in `project.yml` (`SUPublicEDKey`) |
| Store admin token | Worker secret `ADMIN_TOKEN`; keychain `dk.dinhkhanh.evault.store-admin` |
| Polar / Paddle / Resend secrets | Worker secrets only (Resend key "envault-store (Cloudflare Worker)", sending-only, scoped to `envault.app`) |
| Apple team id | git-ignored `Config/Signing.xcconfig` |
| Offline license ledger | `~/Library/Application Support/EnVault Vendor/licenses.jsonl` (fallback only; D1 is the ledger of record) |

Back up both keychain keys. Losing the license key means no new keys can be issued; losing the Sparkle key means existing installs cannot update.
Rotations so far, all before any sale: 0.3.2 rotated both pairs on another machine (`Oh6B…`/`sEM9…`) because the originals looked missing there; those private halves never reached this Mac, so 0.3.6 (2026-10-15) rotated both again here. Keys are per machine: before releasing or issuing, check the keychain's public key against the repo (`generate_keys -p` vs `SUPublicEDKey`; the license seed vs `App/LicensePublicKey.swift`). Retired keys kept in the keychain: license `dk.dinhkhanh.evault.license-signing.old-2026-10-14`, Sparkle account `ed25519-old-2026-10-14` (both the pre-0.3.2 pairs).

Restore on a new Mac or after a keychain reset:
- License key: `security add-generic-password -s dk.dinhkhanh.evault.license-signing -a envault -w '<key>'`
- Sparkle key: save it to a file, then `build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -f <file>` (export with `-x <file>`)

## Routine operations

- Release: bump `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, `ENVAULT_RELEASE_DATE` (quoted) in `project.yml`; `make archive` (signed, notarized; `make release-unsigned` only as a fallback); tag `vX.Y.Z`; `gh release create` with dmg, zip, SHA256SUMS, appcast.xml. The release scripts pull revoked ids from the store first.
- Customers: `scripts/store.sh list [query]`, `issue --email E --name N`, `revoke --email E --reason R`, `resend --email E`. Self-service: `/resend` on the store.
- Tests: `make test` (Swift), `make store-test` (Worker).

## Known gaps

See [PLAN.md §13](PLAN.md#13-known-gaps). Highlights: ad-hoc builds use the legacy keychain fallback; no second physical Mac verified through iCloud Drive (folder mode) yet. CloudKit sync confirmed working by the owner on 2026-10-15.

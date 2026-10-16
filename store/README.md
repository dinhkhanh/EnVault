# EnVault license store

A Cloudflare Worker that turns a paid order into a license key and emails it,
revokes keys on refund, and lets customers re-send their key. Polar is the
merchant of record; Paddle is wired as the fallback behind the same interface.

```
customer → /buy ─302→ Polar checkout ─webhook order.paid→ /webhooks/polar
                                                            │ sign EVL1 key (Ed25519, same scheme the app verifies)
                                                            │ insert into D1 (ledger)
                                                            └ email via Resend
refund in Polar ─webhook order.refunded→ revoke in D1 → /revocations.json → scripts/sync-revocations.sh → next app release
lost email → /resend (form) → active keys for that address re-sent, 3 per day per address
```

No activation server: the app never talks to this Worker. Revocation rides on
app updates (`App/RevokedLicenses.swift`), and keys carry `updatesUntil`
(12 months by default), so a refunded key stops working on the next release
and an old key cannot unlock versions released after its window.

## Routes

| Route | What |
|---|---|
| `GET /buy[?customer_email=&discount_code=&utm_*=]` | 302 to the checkout link of `CHECKOUT_PROVIDER` (polar or paddle). The site's Buy button points here, so switching provider is a config change. |
| `GET /thanks` | Success page (set it as the Polar checkout link's Success URL). |
| `GET /resend`, `POST /resend` | "Lost your key?" form. Always answers "check your inbox". |
| `POST /webhooks/polar` | Standard Webhooks signature (also the pre-September-2026 Polar HMAC). `order.paid` issues, `order.refunded` (full) revokes, `subscription.revoked` revokes. |
| `POST /webhooks/paddle` | `Paddle-Signature` HMAC. `transaction.completed` issues (customer fetched from the Paddle API), approved full refund `adjustment.*` revokes, `subscription.canceled` revokes. |
| `GET /revocations.json` | Public list of revoked license ids. |
| `GET /admin/licenses?q=` | Ledger search. Bearer `ADMIN_TOKEN`. |
| `POST /admin/issue` | `{email, name, plan?, seats?, updatesUntil?, expiresAt?, notify?}` hand-issue (gifts, support). |
| `POST /admin/revoke` | `{id}` or `{email}`, plus `reason`. |
| `POST /admin/resend` | `{email}`. |
| `GET /health` | `ok`. |

`scripts/store.sh list|issue|revoke|resend` wraps the admin routes.

## Deploy (once)

1. **Cloudflare**: `cd store && npm install && npx wrangler login`.
   `npx wrangler d1 create evault-store` → paste the id into `wrangler.toml`.
   `npm run db:init` creates the tables.
2. **Secrets** (`npx wrangler secret put NAME`):
   - `LICENSE_PRIVATE_KEY`: `security find-generic-password -s dk.dinhkhanh.evault.license-signing -w`.
     The Worker checks it against `LICENSE_PUBLIC_KEY` on first use and refuses to start on a mismatch.
   - `ADMIN_TOKEN`: `openssl rand -base64 32`. Also store it locally:
     `security add-generic-password -s dk.dinhkhanh.evault.store-admin -a admin -w TOKEN`.
   - `RESEND_API_KEY`: from resend.com after verifying the sending domain used in `FROM_EMAIL`
     (add the DNS records Resend shows for `dinhkhanh.dk`, or change `FROM_EMAIL` to a verified domain).
   - `POLAR_WEBHOOK_SECRET`: see step 4.
3. `npm run deploy`. The custom domain in `wrangler.toml` (`store.envault.app`) is
   attached automatically because the zone is on Cloudflare; until then the printed
   `*.workers.dev` URL works and the site/app links need that host instead.
4. **Polar** (polar.sh, organization for EnVault, payout country Vietnam):
   - Products → New: "EnVault Pro", one-time, $29. Metadata `plan = pro`.
     (Later: "EnVault Team", subscription with seats, metadata `plan = team`.)
   - Checkout Links → New Link for the product. Success URL `https://store.envault.app/thanks`,
     Return URL `https://envault.app/#pricing`. Paste the link into `wrangler.toml`
     as `POLAR_CHECKOUT_URL` and redeploy.
   - Settings → Webhooks → Add endpoint: `https://store.envault.app/webhooks/polar`,
     format Raw, generate a secret → `wrangler secret put POLAR_WEBHOOK_SECRET`.
     Events: `order.paid`, `order.refunded`, `subscription.revoked`.
   - Test in the Polar **sandbox** first (sandbox.polar.sh has its own org, products, links and
     webhook secret; point a `wrangler dev` or a second Worker at it). A sandbox purchase with a
     test card must produce a key you can activate in the app.
5. **Site**: `docs/index.html` already links the Buy button to `/buy` and "Lost your key?" to `/resend`.

### Paddle fallback

If Polar rejects the payout account: create the product and a checkout in Paddle, set
`CHECKOUT_PROVIDER = "paddle"`, `PADDLE_CHECKOUT_URL`, secrets `PADDLE_WEBHOOK_SECRET`
(notification destination `https://store.envault.app/webhooks/paddle`, events
`transaction.completed`, `adjustment.updated`, `subscription.canceled`) and `PADDLE_API_KEY`
(read access to customers), `PADDLE_SANDBOX = "true"` while testing. Nothing else changes.

## Operating it

- **A customer did not get the email**: `scripts/store.sh list their@email`, then
  `scripts/store.sh resend --email their@email`. Or send them to `/resend`.
- **Refund**: refund in the Polar dashboard. The webhook marks the key revoked; the next app
  release ships the id (the release scripts run `scripts/sync-revocations.sh`). No action needed.
- **Gift or support key**: `scripts/store.sh issue --email E --name N` (add `--no-notify` to
  deliver it yourself). Lands in the same ledger.
- **Revoke by hand**: `scripts/store.sh revoke --email E --reason "chargeback"`.
- **Key rotation**: never rotate `LICENSE_PRIVATE_KEY` casually; every issued key would stop
  verifying. If it leaks, generate a new pair (`envault-license keygen`), ship the new public
  key in the app, re-issue keys to all active customers from the ledger.
- **Offline fallback**: `scripts/issue-license.sh` still signs with the keychain key and writes
  the local `licenses.jsonl`; use it only when the store is down.

## Development

```
npm test                     # unit tests (node --test): signing, signatures, handlers
npx tsc -p tsconfig.json     # type check
npm run db:init:local        # local D1
cp .dev.vars.example .dev.vars   # test key pair, MAIL_MODE=log, test webhook secret
npm run dev                  # http://localhost:8787
```

With `MAIL_MODE=log` the email is printed to the wrangler console instead of sent.
Signing in tests uses a throwaway key pair; `test/helpers.ts` makes one. The key shape
(sorted JSON keys, second-precision ISO dates, uppercase UUID) is pinned by a test on
both sides: `test/license.test.ts` here and `LicenseKitTests.workerIssuedKeyShape` in Swift.

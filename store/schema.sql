CREATE TABLE IF NOT EXISTS licenses (
  id            TEXT PRIMARY KEY,          -- UUID inside the key
  email         TEXT NOT NULL,
  name          TEXT NOT NULL,
  plan          TEXT NOT NULL,             -- pro | team
  seats         INTEGER NOT NULL DEFAULT 1,
  issued_at     TEXT NOT NULL,             -- ISO 8601
  updates_until TEXT,
  expires_at    TEXT,
  key           TEXT NOT NULL,             -- EVL1.payload.sig
  provider      TEXT NOT NULL,             -- polar | paddle | manual
  order_id      TEXT,                      -- provider order / transaction id
  customer_id   TEXT,
  subscription_id TEXT,              -- provider subscription id (Team plan)
  status        TEXT NOT NULL DEFAULT 'active', -- active | revoked
  revoked_at    TEXT,
  revoke_reason TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS licenses_order ON licenses(provider, order_id) WHERE order_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS licenses_email ON licenses(email);

-- Webhook deliveries seen, for idempotent retries.
CREATE TABLE IF NOT EXISTS events (
  provider    TEXT NOT NULL,
  event_id    TEXT NOT NULL,
  type        TEXT NOT NULL,
  received_at TEXT NOT NULL,
  PRIMARY KEY (provider, event_id)
);

-- "Resend my key" requests, for rate limiting.
CREATE TABLE IF NOT EXISTS resend_requests (
  email        TEXT NOT NULL,
  requested_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS resend_requests_email ON resend_requests(email, requested_at);

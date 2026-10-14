import { signLicense, isoSeconds, addMonths, type Plan } from "./license.ts";
import type { Store, LicenseRow } from "./store.ts";
import type { Mailer, MailContext } from "./mail.ts";
import { licenseMail } from "./mail.ts";
import type { Action, Order } from "./providers/types.ts";

export interface Services {
  store: Store;
  mailer: Mailer;
  signingKey: CryptoKey;
  updatesMonths: number;
  mail: MailContext;
  now?: () => Date;
}

export interface IssueRequest {
  provider: string; orderId: string | null; customerId: string | null; subscriptionId: string | null;
  email: string; name: string; plan: Plan; seats: number; periodEnd: string | null;
  /** Hand-issued keys can override updates/expiry. */
  updatesUntil?: string | null; expiresAt?: string | null;
}

export async function issue(s: Services, r: IssueRequest, notify = true): Promise<LicenseRow> {
  const now = (s.now ?? (() => new Date()))();
  const issuedAt = isoSeconds(now);
  const updatesUntil = r.updatesUntil === undefined ? isoSeconds(addMonths(now, s.updatesMonths)) : r.updatesUntil;
  // Subscriptions expire a week after the paid period so a late renewal does not lock anyone out.
  const expiresAt = r.expiresAt !== undefined ? r.expiresAt
    : r.periodEnd ? isoSeconds(new Date(new Date(r.periodEnd).getTime() + 7 * 86400e3)) : null;
  const id = crypto.randomUUID().toUpperCase();
  const key = await signLicense({
    id, email: r.email, name: r.name, plan: r.plan, issuedAt,
    updatesUntil: updatesUntil ?? undefined, expiresAt: expiresAt ?? undefined, seats: r.seats,
  }, s.signingKey);
  const row: LicenseRow = {
    id, email: r.email, name: r.name, plan: r.plan, seats: r.seats, issued_at: issuedAt,
    updates_until: updatesUntil, expires_at: expiresAt, key, provider: r.provider, order_id: r.orderId,
    customer_id: r.customerId, subscription_id: r.subscriptionId, status: "active", revoked_at: null, revoke_reason: null,
  };
  await s.store.insertLicense(row);
  if (notify) await s.mailer.send(licenseMail([row], s.mail, "new"));
  return row;
}

export interface Outcome { status: number; body: string; }

/** Applies a provider action. Idempotent per event id and per order id. */
export async function applyAction(s: Services, provider: string, eventId: string, type: string, action: Action): Promise<Outcome> {
  const fresh = await s.store.recordEvent(provider, eventId, type);
  if (!fresh) return { status: 200, body: "duplicate event" };
  switch (action.kind) {
    case "ignore":
      return { status: 200, body: `ignored: ${action.why}` };
    case "issue": {
      const o: Order = action.order;
      if (await s.store.byOrder(o.provider, o.orderId)) return { status: 200, body: "order already licensed" };
      const row = await issue(s, { ...o });
      return { status: 201, body: `issued ${row.id}` };
    }
    case "revoke": {
      const rows: LicenseRow[] = [];
      if (action.orderId) { const r = await s.store.byOrder(provider, action.orderId); if (r) rows.push(r); }
      if (action.subscriptionId) rows.push(...await s.store.bySubscription(provider, action.subscriptionId));
      const active = rows.filter((r) => r.status === "active");
      for (const r of active) await s.store.revoke(r.id, action.reason);
      return { status: 200, body: active.length ? `revoked ${active.map((r) => r.id).join(",")}` : "nothing to revoke" };
    }
  }
}

export const RESEND_DAILY_LIMIT = 3;

/** Re-sends active keys for an address. Always "succeeds" from the outside so addresses cannot be probed. */
export async function resendKeys(s: Services, email: string): Promise<"sent" | "none" | "limited"> {
  const e = email.trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e)) return "none";
  const since = new Date(Date.now() - 86400e3).toISOString();
  if (await s.store.resendCount(e, since) >= RESEND_DAILY_LIMIT) return "limited";
  await s.store.recordResend(e);
  const rows = (await s.store.byEmail(e)).filter((r) => r.status === "active");
  if (!rows.length) return "none";
  await s.mailer.send(licenseMail(rows, s.mail, "resend"));
  return "sent";
}

import { signLicense, signVaultEntitlement, isoSeconds, addMonths, type Plan, type LicensePayload } from "./license.ts";
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

export async function issue(s: Services, r: IssueRequest, notify = true, mail: MailKind = "new"): Promise<LicenseRow> {
  const now = (s.now ?? (() => new Date()))();
  const issuedAt = isoSeconds(now);
  const updatesUntil = r.updatesUntil === undefined ? isoSeconds(addMonths(now, s.updatesMonths)) : r.updatesUntil;
  // Subscriptions expire a week after the paid period so a late renewal does not lock anyone out.
  const expiresAt = r.expiresAt !== undefined ? r.expiresAt
    : r.periodEnd ? isoSeconds(new Date(new Date(r.periodEnd).getTime() + 7 * 86400e3)) : null;
  const id = crypto.randomUUID().toUpperCase();
  const payload: LicensePayload = {
    id, email: r.email, name: r.name, plan: r.plan, issuedAt,
    updatesUntil: updatesUntil ?? undefined, expiresAt: expiresAt ?? undefined, seats: r.seats,
  };
  if (r.plan === "team") payload.vaultEntitlement = await signVaultEntitlement(payload, s.signingKey);
  const key = await signLicense(payload, s.signingKey);
  const row: LicenseRow = {
    id, email: r.email, name: r.name, plan: r.plan, seats: r.seats, issued_at: issuedAt,
    updates_until: updatesUntil, expires_at: expiresAt, key, provider: r.provider, order_id: r.orderId,
    customer_id: r.customerId, subscription_id: r.subscriptionId, status: "active", revoked_at: null, revoke_reason: null,
  };
  await s.store.insertLicense(row);
  // A failed send throws with the row kept: the key stays revocable and findable by /resend,
  // and the provider's retry finds the order and mails it again.
  if (notify) await s.mailer.send(licenseMail([row], s.mail, mail));
  return row;
}

type MailKind = "new" | "renewal" | "seats";

/** A new key for a subscription's new seat count; the keys it replaces are revoked. */
async function reissueForSeats(s: Services, provider: string, subscriptionId: string, seats: number, periodEnd: string | null, orderId: string | null): Promise<Outcome> {
  const active = (await s.store.bySubscription(provider, subscriptionId)).filter((r) => r.status === "active")
    .sort((a, b) => b.issued_at.localeCompare(a.issued_at));
  const latest = active[0];
  if (!latest) return { status: 200, body: "no license for that subscription" };
  // The same count again (the order for a change already applied, or any other edit): nothing to issue.
  if (latest.seats === seats) return { status: 200, body: "seats unchanged" };
  const row = await issue(s, {
    provider, orderId, customerId: latest.customer_id, subscriptionId, email: latest.email, name: latest.name,
    plan: latest.plan, seats, periodEnd: periodEnd ?? null, expiresAt: periodEnd ? undefined : latest.expires_at,
  }, false);
  // Revoked before mailing, so a failed send can't leave the replaced keys active.
  for (const r of active) await s.store.revoke(r.id, `replaced by ${row.id} (${seats} seats)`);
  await s.mailer.send(licenseMail([row], s.mail, "seats"));
  return { status: 201, body: `issued ${row.id}` };
}

export interface Outcome { status: number; body: string; }

/** Applies a provider action. Idempotent per event id and per order id. */
export async function applyAction(s: Services, provider: string, eventId: string, type: string, action: Action): Promise<Outcome> {
  const fresh = await s.store.recordEvent(provider, eventId, type);
  if (!fresh) return { status: 200, body: "duplicate event" };
  try {
    return await handle(s, provider, action);
  } catch (e) {
    // Not handled: let the provider's retry through instead of dropping it as a duplicate.
    await s.store.forgetEvent(provider, eventId);
    throw e;
  }
}

async function handle(s: Services, provider: string, action: Action): Promise<Outcome> {
  switch (action.kind) {
    case "ignore":
      return { status: 200, body: `ignored: ${action.why}` };
    case "issue": {
      const o: Order = { ...action.order };
      const kind: MailKind = o.reason === "renewal" ? "renewal" : o.reason === "seats" && o.subscriptionId ? "seats" : "new";
      const licensed = await s.store.byOrder(o.provider, o.orderId);
      if (licensed) {
        // Also the retry after a failed send: mail the key that order already has.
        if (licensed.status === "active") await s.mailer.send(licenseMail([licensed], s.mail, kind));
        return { status: 200, body: "order already licensed" };
      }
      // A renewal whose payload doesn't say how many seats keeps the subscription's count.
      if (o.seats < 1) {
        const prior = o.subscriptionId ? (await s.store.bySubscription(o.provider, o.subscriptionId)).filter((r) => r.status === "active")
          .sort((a, b) => b.issued_at.localeCompare(a.issued_at))[0] : undefined;
        o.seats = prior?.seats ?? 1;
      }
      if (o.reason === "seats" && o.subscriptionId) return reissueForSeats(s, o.provider, o.subscriptionId, o.seats, o.periodEnd, o.orderId);
      const row = await issue(s, { ...o }, true, kind);
      return { status: 201, body: `issued ${row.id}` };
    }
    case "reseat":
      return reissueForSeats(s, provider, action.subscriptionId, action.seats, action.periodEnd, null);
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

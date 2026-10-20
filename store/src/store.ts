import type { Plan } from "./license.ts";

export interface LicenseRow {
  id: string; email: string; name: string; plan: Plan; seats: number;
  issued_at: string; updates_until: string | null; expires_at: string | null;
  key: string; provider: string; order_id: string | null; customer_id: string | null;
  subscription_id: string | null;
  status: "active" | "revoked"; revoked_at: string | null; revoke_reason: string | null;
}

export interface Store {
  /** Returns false if (provider, eventId) was already recorded. */
  recordEvent(provider: string, eventId: string, type: string): Promise<boolean>;
  /** Undoes recordEvent when handling the event failed, so the provider's retry is handled. */
  forgetEvent(provider: string, eventId: string): Promise<void>;
  insertLicense(row: LicenseRow): Promise<void>;
  byOrder(provider: string, orderId: string): Promise<LicenseRow | null>;
  bySubscription(provider: string, subscriptionId: string): Promise<LicenseRow[]>;
  byEmail(email: string): Promise<LicenseRow[]>;
  byId(id: string): Promise<LicenseRow | null>;
  revoke(id: string, reason: string): Promise<void>;
  revokedIds(): Promise<string[]>;
  list(q: string, limit: number): Promise<LicenseRow[]>;
  resendCount(email: string, sinceIso: string): Promise<number>;
  recordResend(email: string): Promise<void>;
}

export class MemoryStore implements Store {
  licenses: LicenseRow[] = [];
  events = new Set<string>();
  resends: { email: string; at: string }[] = [];
  async recordEvent(p: string, id: string, _t: string) { const k = `${p}:${id}`; if (this.events.has(k)) return false; this.events.add(k); return true; }
  async forgetEvent(p: string, id: string) { this.events.delete(`${p}:${id}`); }
  async insertLicense(r: LicenseRow) {
    if (r.order_id && this.licenses.some((l) => l.provider === r.provider && l.order_id === r.order_id)) throw new Error("UNIQUE constraint failed: licenses_order");
    this.licenses.push({ ...r });
  }
  async byOrder(p: string, o: string) { return this.licenses.find((l) => l.provider === p && l.order_id === o) ?? null; }
  async bySubscription(p: string, s: string) { return this.licenses.filter((l) => l.provider === p && l.subscription_id === s); }
  async byEmail(e: string) { return this.licenses.filter((l) => l.email.toLowerCase() === e.toLowerCase()); }
  async byId(id: string) { return this.licenses.find((l) => l.id === id) ?? null; }
  async revoke(id: string, reason: string) { const l = await this.byId(id); if (l) { l.status = "revoked"; l.revoked_at = new Date().toISOString(); l.revoke_reason = reason; } }
  async revokedIds() { return this.licenses.filter((l) => l.status === "revoked").map((l) => l.id); }
  async list(q: string, limit: number) { const s = q.toLowerCase(); return this.licenses.filter((l) => !s || JSON.stringify(l).toLowerCase().includes(s)).slice(-limit).reverse(); }
  async resendCount(email: string, since: string) { return this.resends.filter((r) => r.email === email.toLowerCase() && r.at >= since).length; }
  async recordResend(email: string) { this.resends.push({ email: email.toLowerCase(), at: new Date().toISOString() }); }
}

export class D1Store implements Store {
  private db: D1Database;
  constructor(db: D1Database) { this.db = db; }
  async forgetEvent(provider: string, eventId: string) {
    await this.db.prepare("DELETE FROM events WHERE provider = ?1 AND event_id = ?2").bind(provider, eventId).run();
  }
  async recordEvent(provider: string, eventId: string, type: string) {
    try {
      await this.db.prepare("INSERT INTO events (provider, event_id, type, received_at) VALUES (?1, ?2, ?3, ?4)")
        .bind(provider, eventId, type, new Date().toISOString()).run();
      return true;
    } catch (e) {
      if (String(e).includes("UNIQUE")) return false;
      throw e;
    }
  }
  async insertLicense(r: LicenseRow) {
    await this.db.prepare(`INSERT INTO licenses (id, email, name, plan, seats, issued_at, updates_until, expires_at, key, provider, order_id, customer_id, subscription_id, status)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, 'active')`)
      .bind(r.id, r.email, r.name, r.plan, r.seats, r.issued_at, r.updates_until, r.expires_at, r.key, r.provider, r.order_id, r.customer_id, r.subscription_id).run();
  }
  async byOrder(p: string, o: string) { return (await this.db.prepare("SELECT * FROM licenses WHERE provider = ?1 AND order_id = ?2").bind(p, o).first<LicenseRow>()) ?? null; }
  async bySubscription(p: string, s: string) { return (await this.db.prepare("SELECT * FROM licenses WHERE provider = ?1 AND subscription_id = ?2").bind(p, s).all<LicenseRow>()).results; }
  async byEmail(e: string) { return (await this.db.prepare("SELECT * FROM licenses WHERE lower(email) = lower(?1) ORDER BY issued_at DESC").bind(e).all<LicenseRow>()).results; }
  async byId(id: string) { return (await this.db.prepare("SELECT * FROM licenses WHERE id = ?1").bind(id).first<LicenseRow>()) ?? null; }
  async revoke(id: string, reason: string) {
    await this.db.prepare("UPDATE licenses SET status = 'revoked', revoked_at = ?2, revoke_reason = ?3 WHERE id = ?1").bind(id, new Date().toISOString(), reason).run();
  }
  async revokedIds() { return (await this.db.prepare("SELECT id FROM licenses WHERE status = 'revoked' ORDER BY revoked_at").all<{ id: string }>()).results.map((r) => r.id); }
  async list(q: string, limit: number) {
    return (await this.db.prepare("SELECT * FROM licenses WHERE (?1 = '' OR lower(email) LIKE ?2 OR lower(name) LIKE ?2 OR id LIKE ?2 OR order_id LIKE ?2) ORDER BY issued_at DESC LIMIT ?3")
      .bind(q, `%${q.toLowerCase()}%`, limit).all<LicenseRow>()).results;
  }
  async resendCount(email: string, since: string) {
    const r = await this.db.prepare("SELECT COUNT(*) AS n FROM resend_requests WHERE email = lower(?1) AND requested_at >= ?2").bind(email, since).first<{ n: number }>();
    return r?.n ?? 0;
  }
  async recordResend(email: string) {
    await this.db.prepare("INSERT INTO resend_requests (email, requested_at) VALUES (lower(?1), ?2)").bind(email, new Date().toISOString()).run();
  }
}

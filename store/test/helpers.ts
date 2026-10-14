import { MemoryStore } from "../src/store.ts";
import { LogMailer } from "../src/mail.ts";
import { importSigningKey, importVerifyKey, b64url } from "../src/license.ts";
import type { Services } from "../src/handlers.ts";

/** Fresh Ed25519 pair as base64 seed / base64 public key (what the app and Worker config use). */
export async function testKeyPair(): Promise<{ seed: string; pub: string }> {
  const kp = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const jwk = await crypto.subtle.exportKey("jwk", kp.privateKey);
  const raw = new Uint8Array(await crypto.subtle.exportKey("raw", kp.publicKey));
  const std = (s: string) => { let b = s.replace(/-/g, "+").replace(/_/g, "/"); while (b.length % 4) b += "="; return b; };
  return { seed: std(jwk.d!), pub: btoa(String.fromCharCode(...raw)) };
}

export async function testServices(seed?: string, pub?: string): Promise<Services & { store: MemoryStore; mailer: LogMailer; pub: CryptoKey }> {
  const kp = seed && pub ? { seed, pub } : await testKeyPair();
  return {
    store: new MemoryStore(),
    mailer: new LogMailer(),
    signingKey: await importSigningKey(kp.seed),
    pub: await importVerifyKey(kp.pub),
    updatesMonths: 12,
    mail: { siteUrl: "https://example.test/", storeUrl: "https://store.test", supportEmail: "help@example.test" },
  };
}

export const polarOrderPaid = (over: Record<string, unknown> = {}) => ({
  type: "order.paid", timestamp: "2026-10-15T10:00:00Z", api_version: "2026-10",
  data: {
    id: "ord_1", status: "paid", paid: true, total_amount: 2900, refunded_amount: 0, currency: "usd",
    billing_name: "Ada Lovelace", customer_id: "cus_1", product_id: "prod_1", subscription_id: null, checkout_id: "chk_1",
    customer: { id: "cus_1", email: "ada@example.com", name: "Ada Lovelace" },
    product: { id: "prod_1", name: "eVault Pro", metadata: {} },
    seats: null, subscription: null, ...over,
  },
});

export { b64url };

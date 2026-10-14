import type { Action } from "./types.ts";
import { planFrom, nameFrom } from "./types.ts";

/* Paddle Billing webhooks: https://developer.paddle.com/webhooks/overview
   transaction.completed carries customer_id only, so the customer is fetched from the API. */
export interface PaddleApi { customer(id: string): Promise<{ email: string; name: string | null }>; }

export function paddleApi(apiKey: string, sandbox: boolean): PaddleApi {
  const base = sandbox ? "https://sandbox-api.paddle.com" : "https://api.paddle.com";
  return {
    async customer(id) {
      const res = await fetch(`${base}/customers/${id}`, { headers: { authorization: `Bearer ${apiKey}` } });
      if (!res.ok) throw new Error(`Paddle customers/${id}: ${res.status}`);
      const j: any = await res.json();
      return { email: j.data.email, name: j.data.name ?? null };
    },
  };
}

export async function paddleAction(event: any, api: PaddleApi): Promise<Action> {
  const d = event?.data ?? {};
  switch (event?.event_type) {
    case "transaction.completed": {
      if (!d.customer_id) return { kind: "ignore", why: "transaction without customer" };
      const item = d.items?.[0] ?? {};
      const c = await api.customer(d.customer_id);
      return {
        kind: "issue",
        order: {
          provider: "paddle",
          orderId: d.id,
          customerId: d.customer_id,
          subscriptionId: d.subscription_id ?? null,
          email: c.email,
          name: nameFrom(c.name, d.custom_data?.name, c.email.split("@")[0]),
          plan: planFrom(item.price?.custom_data?.plan ?? d.custom_data?.plan, item.price?.name ?? item.product?.name),
          seats: Math.max(1, Number(item.quantity ?? 1) || 1),
          periodEnd: d.billing_period?.ends_at ?? null,
        },
      };
    }
    case "adjustment.updated":
    case "adjustment.created": {
      if (d.action !== "refund" || d.status !== "approved") return { kind: "ignore", why: "adjustment not an approved refund" };
      if (d.type === "partial") return { kind: "ignore", why: "partial refund keeps the license" };
      return { kind: "revoke", orderId: d.transaction_id, reason: "refunded" };
    }
    case "subscription.canceled":
      return { kind: "revoke", subscriptionId: d.id, reason: "subscription canceled" };
    default:
      return { kind: "ignore", why: `unhandled event ${event?.event_type}` };
  }
}

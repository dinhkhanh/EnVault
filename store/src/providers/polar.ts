import type { Action } from "./types.ts";
import { planFrom, nameFrom } from "./types.ts";

/* Polar webhook payloads: https://polar.sh/docs/api-reference/webhooks */
export function polarAction(event: any): Action {
  const d = event?.data ?? {};
  switch (event?.type) {
    case "order.paid": {
      const email = d.customer?.email;
      if (!email) return { kind: "ignore", why: "order without customer email" };
      if (d.paid === false) return { kind: "ignore", why: "order not paid" };
      return {
        kind: "issue",
        order: {
          provider: "polar",
          orderId: d.id,
          customerId: d.customer_id ?? d.customer?.id ?? null,
          subscriptionId: d.subscription_id ?? null,
          email,
          name: nameFrom(d.customer?.name, d.billing_name, d.customer?.billing_name, email.split("@")[0]),
          plan: planFrom(d.product?.metadata?.plan, d.product?.name),
          seats: Math.max(1, Number(d.seats ?? d.subscription?.seats ?? 1) || 1),
          periodEnd: d.subscription?.current_period_end ?? null,
        },
      };
    }
    case "order.refunded": {
      const full = d.status === "refunded" || (Number(d.refunded_amount ?? 0) >= Number(d.total_amount ?? 0) && Number(d.total_amount ?? 0) > 0);
      if (!full) return { kind: "ignore", why: "partial refund keeps the license" };
      return { kind: "revoke", orderId: d.id, reason: "refunded" };
    }
    case "subscription.revoked":
      return { kind: "revoke", subscriptionId: d.id, reason: "subscription revoked" };
    default:
      return { kind: "ignore", why: `unhandled event ${event?.type}` };
  }
}

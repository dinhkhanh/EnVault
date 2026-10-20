import type { Plan } from "../license.ts";

/** What a payment provider event asks the store to do. */
export type Action =
  | { kind: "issue"; order: Order }
  /** A subscription's seat count changed without a new order: a key for the new count replaces the old. */
  | { kind: "reseat"; subscriptionId: string; seats: number; periodEnd: string | null }
  | { kind: "revoke"; orderId?: string; subscriptionId?: string; reason: string }
  | { kind: "ignore"; why: string };

export interface Order {
  provider: "polar" | "paddle";
  orderId: string;
  customerId: string | null;
  subscriptionId: string | null;
  email: string;
  name: string;
  plan: Plan;
  seats: number;
  /** Subscriptions: end of the paid period; one-time purchases: null. */
  periodEnd: string | null;
  /** Why it was charged: a first purchase, a yearly renewal, or a change of seats. */
  reason?: "purchase" | "renewal" | "seats";
}

export function planFrom(metaPlan: unknown, productName: unknown): Plan {
  if (metaPlan === "team" || metaPlan === "pro") return metaPlan;
  if (typeof productName === "string" && /team/i.test(productName)) return "team";
  return "pro";
}

export function nameFrom(...candidates: unknown[]): string {
  for (const c of candidates) if (typeof c === "string" && c.trim()) return c.trim();
  return "EnVault user";
}

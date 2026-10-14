import { test } from "node:test";
import assert from "node:assert/strict";
import { applyAction, issue, resendKeys, RESEND_DAILY_LIMIT } from "../src/handlers.ts";
import { polarAction } from "../src/providers/polar.ts";
import { paddleAction } from "../src/providers/paddle.ts";
import { verifyLicense } from "../src/license.ts";
import { testServices, polarOrderPaid } from "./helpers.ts";

test("polar order.paid issues one key, emails it, and is idempotent", async () => {
  const s = await testServices();
  const ev = polarOrderPaid();
  let out = await applyAction(s, "polar", "evt_1", ev.type, polarAction(ev));
  assert.equal(out.status, 201);
  assert.equal(s.store.licenses.length, 1);
  const row = s.store.licenses[0];
  assert.equal(row.email, "ada@example.com"); assert.equal(row.plan, "pro"); assert.equal(row.seats, 1);
  assert.equal(row.order_id, "ord_1"); assert.equal(row.expires_at, null);
  assert.equal(row.updates_until?.slice(0, 4), String(new Date().getUTCFullYear() + 1));
  const lic = await verifyLicense(row.key, s.pub);
  assert.equal(lic.id, row.id); assert.equal(lic.email, row.email); assert.equal(lic.updatesUntil, row.updates_until);
  assert.equal(s.mailer.sent.length, 1);
  assert.equal(s.mailer.sent[0].to, "ada@example.com");
  assert.ok(s.mailer.sent[0].text.includes(row.key));
  // same event redelivered
  out = await applyAction(s, "polar", "evt_1", ev.type, polarAction(ev));
  assert.equal(out.body, "duplicate event");
  // different event id, same order (e.g. order.updated → paid again)
  out = await applyAction(s, "polar", "evt_2", ev.type, polarAction(ev));
  assert.equal(out.body, "order already licensed");
  assert.equal(s.store.licenses.length, 1); assert.equal(s.mailer.sent.length, 1);
});

test("plan from product metadata or name; seats from order", async () => {
  const s = await testServices();
  const ev = polarOrderPaid({ id: "ord_2", product: { name: "eVault Team", metadata: {} }, seats: 5 });
  await applyAction(s, "polar", "evt_3", ev.type, polarAction(ev));
  assert.equal(s.store.licenses[0].plan, "team"); assert.equal(s.store.licenses[0].seats, 5);
  const ev2 = polarOrderPaid({ id: "ord_3", product: { name: "Whatever", metadata: { plan: "team" } } });
  await applyAction(s, "polar", "evt_4", ev2.type, polarAction(ev2));
  assert.equal(s.store.licenses[1].plan, "team");
});

test("subscription orders get an expiry a week after the period end", async () => {
  const s = await testServices();
  const ev = polarOrderPaid({ id: "ord_s", subscription_id: "sub_1", subscription: { id: "sub_1", current_period_end: "2026-11-15T00:00:00Z" } });
  await applyAction(s, "polar", "evt_s", ev.type, polarAction(ev));
  assert.equal(s.store.licenses[0].expires_at, "2026-11-22T00:00:00Z");
  assert.equal(s.store.licenses[0].subscription_id, "sub_1");
  const rev = await applyAction(s, "polar", "evt_s2", "subscription.revoked", polarAction({ type: "subscription.revoked", data: { id: "sub_1" } }));
  assert.match(rev.body, /^revoked/);
  assert.equal(s.store.licenses[0].status, "revoked");
});

test("full refund revokes, partial refund does not, unknown order is a no-op", async () => {
  const s = await testServices();
  const ev = polarOrderPaid();
  await applyAction(s, "polar", "evt_1", ev.type, polarAction(ev));
  const partial = { type: "order.refunded", data: { id: "ord_1", status: "partially_refunded", total_amount: 2900, refunded_amount: 1000 } };
  let out = await applyAction(s, "polar", "evt_5", partial.type, polarAction(partial));
  assert.match(out.body, /partial refund/);
  assert.equal(s.store.licenses[0].status, "active");
  const full = { type: "order.refunded", data: { id: "ord_1", status: "refunded", total_amount: 2900, refunded_amount: 2900 } };
  out = await applyAction(s, "polar", "evt_6", full.type, polarAction(full));
  assert.equal(out.body, `revoked ${s.store.licenses[0].id}`);
  assert.equal(s.store.licenses[0].status, "revoked"); assert.equal(s.store.licenses[0].revoke_reason, "refunded");
  assert.deepEqual(await s.store.revokedIds(), [s.store.licenses[0].id]);
  out = await applyAction(s, "polar", "evt_7", full.type, polarAction({ type: "order.refunded", data: { id: "ord_nope", status: "refunded", total_amount: 1, refunded_amount: 1 } }));
  assert.equal(out.body, "nothing to revoke");
});

test("unhandled events are acknowledged, not errors", async () => {
  const s = await testServices();
  const out = await applyAction(s, "polar", "evt_x", "checkout.created", polarAction({ type: "checkout.created", data: {} }));
  assert.equal(out.status, 200); assert.match(out.body, /ignored/);
});

test("paddle transaction.completed looks the customer up, refund adjustment revokes", async () => {
  const s = await testServices();
  const api = { async customer(id: string) { assert.equal(id, "ctm_1"); return { email: "grace@example.com", name: "Grace Hopper" }; } };
  const tx = { event_id: "evt_p1", event_type: "transaction.completed", data: { id: "txn_1", customer_id: "ctm_1", subscription_id: null, items: [{ quantity: 2, price: { name: "eVault Pro", custom_data: {} } }] } };
  let out = await applyAction(s, "paddle", tx.event_id, tx.event_type, await paddleAction(tx, api));
  assert.equal(out.status, 201);
  assert.equal(s.store.licenses[0].email, "grace@example.com"); assert.equal(s.store.licenses[0].name, "Grace Hopper"); assert.equal(s.store.licenses[0].seats, 2);
  const adj = { event_id: "evt_p2", event_type: "adjustment.updated", data: { action: "refund", status: "approved", type: "full", transaction_id: "txn_1" } };
  out = await applyAction(s, "paddle", adj.event_id, adj.event_type, await paddleAction(adj, api));
  assert.match(out.body, /^revoked/);
  const pending = { event_id: "evt_p3", event_type: "adjustment.created", data: { action: "refund", status: "pending_approval", type: "full", transaction_id: "txn_1" } };
  assert.match((await paddleAction(pending, api) as any).why, /not an approved refund/);
});

test("manual issue without notification, and resend with rate limit", async () => {
  const s = await testServices();
  await issue(s, { provider: "manual", orderId: null, customerId: null, subscriptionId: null, email: "Dev@Example.com", name: "Dev", plan: "pro", seats: 1, periodEnd: null, updatesUntil: null }, false);
  assert.equal(s.mailer.sent.length, 0);
  assert.equal(s.store.licenses[0].updates_until, null);
  assert.equal(await resendKeys(s, "nobody@example.com"), "none");
  assert.equal(await resendKeys(s, "not an email"), "none");
  assert.equal(await resendKeys(s, " dev@example.com "), "sent");
  assert.equal(s.mailer.sent.length, 1);
  assert.ok(s.mailer.sent[0].text.includes(s.store.licenses[0].key));
  for (let i = 1; i < RESEND_DAILY_LIMIT; i++) assert.equal(await resendKeys(s, "dev@example.com"), "sent");
  assert.equal(await resendKeys(s, "dev@example.com"), "limited");
  // revoked keys are not resent
  await s.store.revoke(s.store.licenses[0].id, "refunded");
  s.store.resends = [];
  assert.equal(await resendKeys(s, "dev@example.com"), "none");
});

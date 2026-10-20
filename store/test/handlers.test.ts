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
  // replies reach a real inbox; the sending subdomain has no MX
  assert.equal(s.mailer.sent[0].replyTo, "help@example.test");
  assert.equal(s.mailer.sent[0].subject, "Your EnVault Pro purchase");
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
  const ev = polarOrderPaid({ id: "ord_2", product: { name: "EnVault Team", metadata: {} }, seats: 5 });
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
  const tx = { event_id: "evt_p1", event_type: "transaction.completed", data: { id: "txn_1", customer_id: "ctm_1", subscription_id: null, items: [{ quantity: 2, price: { name: "EnVault Pro", custom_data: {} } }] } };
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

test("team renewals and seat changes: renewal mail, new key per seat count, old one revoked", async () => {
  const s = await testServices();
  const team = { name: "EnVault Team", metadata: { plan: "team" } };
  const sub = { id: "sub_t", current_period_end: "2027-10-20T00:00:00Z" };
  const first = polarOrderPaid({ id: "ord_t1", product: team, seats: 3, subscription_id: "sub_t", subscription: sub, billing_reason: "subscription_create" });
  await applyAction(s, "polar", "evt_t1", first.type, polarAction(first));
  assert.equal(s.mailer.sent.at(-1)!.subject, "Your EnVault Team purchase");

  // Seats go up mid-year: Polar bills the difference with billing_reason subscription_update.
  const more = polarOrderPaid({ id: "ord_t2", product: team, seats: 5, subscription_id: "sub_t", subscription: sub, billing_reason: "subscription_update" });
  await applyAction(s, "polar", "evt_t2", more.type, polarAction(more));
  const [a, b] = s.store.licenses;
  assert.equal(b.seats, 5); assert.equal(b.plan, "team"); assert.equal(b.order_id, "ord_t2");
  assert.equal(a.status, "revoked"); assert.match(a.revoke_reason ?? "", /replaced/);
  assert.equal(s.mailer.sent.at(-1)!.subject, "Your EnVault Team key for 5 seats");

  // Seats go down with no charge: subscription.updated.
  const fewer = { type: "subscription.updated", data: { id: "sub_t", seats: 4, status: "active", current_period_end: sub.current_period_end } };
  await applyAction(s, "polar", "evt_t3", fewer.type, polarAction(fewer));
  assert.equal(s.store.licenses.length, 3);
  assert.equal(s.store.licenses[2].seats, 4); assert.equal(s.store.licenses[1].status, "revoked");
  // The same count again (any other subscription change) issues nothing.
  const same = { type: "subscription.updated", data: { id: "sub_t", seats: 4, status: "active" } };
  assert.equal((await applyAction(s, "polar", "evt_t4", same.type, polarAction(same))).body, "seats unchanged");

  // Yearly renewal: a new key with a new expiry, worded as a renewal.
  const renew = polarOrderPaid({ id: "ord_t3", product: team, seats: 4, subscription_id: "sub_t",
    subscription: { id: "sub_t", current_period_end: "2028-10-20T00:00:00Z" }, billing_reason: "subscription_cycle" });
  await applyAction(s, "polar", "evt_t5", renew.type, polarAction(renew));
  assert.equal(s.store.licenses[3].expires_at, "2028-10-27T00:00:00Z");
  assert.equal(s.mailer.sent.at(-1)!.subject, "Your EnVault Team renewal");
  assert.ok(s.mailer.sent.at(-1)!.text.includes("renewed"));
});

test("team keys carry a vault entitlement that names nobody; pro keys don't", async () => {
  const s = await testServices();
  const team = polarOrderPaid({ id: "ord_v", product: { name: "EnVault Team", metadata: { plan: "team" } }, seats: 6 });
  await applyAction(s, "polar", "evt_v", team.type, polarAction(team));
  const lic = await verifyLicense(s.store.licenses[0].key, s.pub);
  assert.ok(lic.vaultEntitlement);
  const ent = await verifyLicense(lic.vaultEntitlement!, s.pub);
  assert.equal(ent.plan, "team-vault"); assert.equal(ent.id, lic.id); assert.equal(ent.seats, 6);
  assert.equal(ent.email, ""); assert.equal(ent.name, ""); assert.equal(ent.expiresAt, lic.expiresAt);
  const pro = polarOrderPaid({ id: "ord_p" });
  await applyAction(s, "polar", "evt_p", pro.type, polarAction(pro));
  assert.equal((await verifyLicense(s.store.licenses[1].key, s.pub)).vaultEntitlement, undefined);
});

test("a failed event can be retried; a renewal without a seat count keeps the subscription's", async () => {
  const s = await testServices();
  const team = { name: "EnVault Team", metadata: { plan: "team" } };
  const sub = { id: "sub_r", current_period_end: "2027-10-20T00:00:00Z" };
  const first = polarOrderPaid({ id: "ord_r1", product: team, seats: 6, subscription_id: "sub_r", subscription: sub });
  // The mailer fails once: the key isn't lost, and the retry is handled, not dropped.
  const send = s.mailer.send.bind(s.mailer);
  let failures = 1;
  s.mailer.send = async (m) => { if (failures-- > 0) throw new Error("mail down"); return send(m); };
  await assert.rejects(applyAction(s, "polar", "evt_r1", first.type, polarAction(first)));
  assert.equal(s.store.licenses.length, 0);  // undelivered, so not kept
  const retry = await applyAction(s, "polar", "evt_r1", first.type, polarAction(first));
  assert.equal(retry.status, 201);
  assert.equal(s.mailer.sent.length, 1);     // the customer got their key

  const renew = polarOrderPaid({ id: "ord_r2", product: team, subscription_id: "sub_r", billing_reason: "subscription_cycle",
    subscription: { id: "sub_r", current_period_end: "2028-10-20T00:00:00Z" } });
  delete (renew.data as any).seats;
  await applyAction(s, "polar", "evt_r2", renew.type, polarAction(renew));
  assert.equal(s.store.licenses.at(-1)!.seats, 6);

  // A seat-change order for the count already in effect issues nothing.
  const same = polarOrderPaid({ id: "ord_r3", product: team, seats: 6, subscription_id: "sub_r", subscription: sub, billing_reason: "subscription_update" });
  assert.equal((await applyAction(s, "polar", "evt_r3", same.type, polarAction(same))).body, "seats unchanged");
});

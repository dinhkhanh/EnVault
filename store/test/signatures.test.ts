import { test } from "node:test";
import assert from "node:assert/strict";
import { verifyStandardWebhook, signStandardWebhook, verifyPaddle, signPaddle } from "../src/signatures.ts";

const enc = new TextEncoder();
const body = '{"type":"order.paid","data":{"id":"ord_1"}}';
const h = (o: Record<string, string>) => ({ id: o["webhook-id"], timestamp: o["webhook-timestamp"], signature: o["webhook-signature"] });

test("standard webhooks: base64 secret with whsec_ prefix", async () => {
  const secret = "whsec_" + Buffer.from("0123456789abcdef0123456789abcdef").toString("base64");
  const headers = await signStandardWebhook(body, secret);
  assert.equal(await verifyStandardWebhook(enc.encode(body), h(headers), secret), true);
  assert.equal(await verifyStandardWebhook(enc.encode(body + " "), h(headers), secret), false);
  assert.equal(await verifyStandardWebhook(enc.encode(body), h(headers), "whsec_" + Buffer.from("other-secret-other-secret-other!").toString("base64")), false);
  // stale timestamp
  const old = await signStandardWebhook(body, secret, "msg_1", Math.floor(Date.now() / 1000) - 3600);
  assert.equal(await verifyStandardWebhook(enc.encode(body), h(old), secret), false);
  // multiple signatures in the header, one valid
  const multi = { ...headers, "webhook-signature": "v1,AAAA " + headers["webhook-signature"] };
  assert.equal(await verifyStandardWebhook(enc.encode(body), h(multi), secret), true);
});

test("legacy Polar HMAC: key is the UTF-8 secret string itself", async () => {
  const secret = "whsec_legacy-not-base64!";
  const headers = await signStandardWebhook(body, secret); // helper falls back to utf-8 for non-base64
  assert.equal(await verifyStandardWebhook(enc.encode(body), h(headers), secret), true);
});

test("paddle signature", async () => {
  const secret = "pdl_ntfset_abc_secret";
  const sig = await signPaddle(body, secret);
  assert.equal(await verifyPaddle(enc.encode(body), sig, secret), true);
  assert.equal(await verifyPaddle(enc.encode(body), sig, "wrong"), false);
  assert.equal(await verifyPaddle(enc.encode(body + "x"), sig, secret), false);
  assert.equal(await verifyPaddle(enc.encode(body), null, secret), false);
  assert.equal(await verifyPaddle(enc.encode(body), await signPaddle(body, secret, 1), secret), false);
});

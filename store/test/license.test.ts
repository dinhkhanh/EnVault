import { test } from "node:test";
import assert from "node:assert/strict";
import { signLicense, verifyLicense, isoSeconds, addMonths, importSigningKey, importVerifyKey, assertKeyPair, b64url, unb64url } from "../src/license.ts";
import { testKeyPair } from "./helpers.ts";

test("sign/verify round trip with sorted keys and second-precision dates", async () => {
  const kp = await testKeyPair();
  const priv = await importSigningKey(kp.seed), pub = await importVerifyKey(kp.pub);
  const issuedAt = isoSeconds(new Date("2026-10-15T10:11:12.345Z"));
  assert.equal(issuedAt, "2026-10-15T10:11:12Z");
  const key = await signLicense({ id: "0A9F4C6E-2B7D-4E1A-9C3F-5D8B2A1E7F60", email: "a@b.c", name: "A", plan: "pro", issuedAt, updatesUntil: isoSeconds(addMonths(new Date(issuedAt), 12)), seats: 1 }, priv);
  assert.match(key, /^EVL1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
  const payloadJson = Buffer.from(key.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"), "base64").toString();
  assert.equal(payloadJson, '{"email":"a@b.c","id":"0A9F4C6E-2B7D-4E1A-9C3F-5D8B2A1E7F60","issuedAt":"2026-10-15T10:11:12Z","name":"A","plan":"pro","seats":1,"updatesUntil":"2027-10-15T10:11:12Z"}');
  const back = await verifyLicense(key, pub);
  assert.equal(back.plan, "pro");
  const [p0, p1, p2] = key.split(".");
  const sig = unb64url(p2); sig[0] ^= 0xff;
  await assert.rejects(verifyLicense([p0, p1, b64url(sig)].join("."), pub), /bad signature/);
  await assert.rejects(verifyLicense("EVL0.a.b", pub), /malformed/);
});

test("assertKeyPair rejects a mismatched public key", async () => {
  const a = await testKeyPair(), b = await testKeyPair();
  await assertKeyPair(await importSigningKey(a.seed), await importVerifyKey(a.pub));
  await assert.rejects(assertKeyPair(await importSigningKey(a.seed), await importVerifyKey(b.pub)));
});

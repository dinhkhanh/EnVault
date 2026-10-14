// Webhook signature checks. Raw body bytes only; never re-serialize.

const enc = new TextEncoder();

export function constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

async function hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, data));
}

function fromBase64(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function fromHex(s: string): Uint8Array {
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(s.substr(i * 2, 2), 16);
  return out;
}

export const TOLERANCE_SECONDS = 300;

export interface StandardWebhookHeaders { id: string | null; timestamp: string | null; signature: string | null; }

/**
 * Standard Webhooks (https://www.standardwebhooks.com), as used by Polar.
 * Polar secrets created before 2026-09-08 use "Polar HMAC": the key is the UTF-8 bytes
 * of the whole `whsec_...` string. Newer ones are standard: base64 after the prefix.
 * Both are tried.
 */
export async function verifyStandardWebhook(body: Uint8Array, h: StandardWebhookHeaders, secret: string, now = Date.now()): Promise<boolean> {
  if (!h.id || !h.timestamp || !h.signature) return false;
  const ts = Number(h.timestamp);
  if (!Number.isFinite(ts) || Math.abs(now / 1000 - ts) > TOLERANCE_SECONDS) return false;
  const signed = new Uint8Array(enc.encode(`${h.id}.${h.timestamp}.`).length + body.length);
  signed.set(enc.encode(`${h.id}.${h.timestamp}.`)); signed.set(body, signed.length - body.length);
  const keys: Uint8Array[] = [enc.encode(secret)];
  if (secret.startsWith("whsec_")) { try { keys.unshift(fromBase64(secret.slice(6))); } catch { /* not base64 */ } }
  const presented = h.signature.split(" ").filter((p) => p.startsWith("v1,")).map((p) => p.slice(3));
  for (const key of keys) {
    const mac = await hmacSha256(key, signed);
    for (const p of presented) {
      try { if (constantTimeEqual(mac, fromBase64(p))) return true; } catch { /* bad base64 */ }
    }
  }
  return false;
}

/** Paddle: `Paddle-Signature: ts=<unix>;h1=<hex>`; HMAC-SHA256(secret, `${ts}:${body}`). */
export async function verifyPaddle(body: Uint8Array, header: string | null, secret: string, now = Date.now()): Promise<boolean> {
  if (!header) return false;
  const parts = Object.fromEntries(header.split(";").map((kv) => kv.split("=") as [string, string]));
  const ts = Number(parts.ts);
  if (!parts.h1 || !Number.isFinite(ts) || Math.abs(now / 1000 - ts) > TOLERANCE_SECONDS) return false;
  const prefix = enc.encode(`${parts.ts}:`);
  const signed = new Uint8Array(prefix.length + body.length);
  signed.set(prefix); signed.set(body, prefix.length);
  const mac = await hmacSha256(enc.encode(secret), signed);
  return constantTimeEqual(mac, fromHex(parts.h1));
}

/** Test helper: produce the headers Polar would send for `body`. */
export async function signStandardWebhook(body: string, secret: string, id = "msg_test", ts = Math.floor(Date.now() / 1000)): Promise<Record<string, string>> {
  let key = enc.encode(secret);
  if (secret.startsWith("whsec_")) { try { key = fromBase64(secret.slice(6)); } catch { /* legacy Polar HMAC: utf-8 key */ } }
  const mac = await hmacSha256(key, enc.encode(`${id}.${ts}.${body}`));
  let s = ""; for (const b of mac) s += String.fromCharCode(b);
  return { "webhook-id": id, "webhook-timestamp": String(ts), "webhook-signature": `v1,${btoa(s)}` };
}

export async function signPaddle(body: string, secret: string, ts = Math.floor(Date.now() / 1000)): Promise<string> {
  const mac = await hmacSha256(enc.encode(secret), enc.encode(`${ts}:${body}`));
  return `ts=${ts};h1=${Array.from(mac).map((b) => b.toString(16).padStart(2, "0")).join("")}`;
}

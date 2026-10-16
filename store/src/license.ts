// License signing compatible with Packages/EnVaultKit/Sources/LicenseKit (EVL1.payload.sig).
// Ed25519 via WebCrypto; works in Cloudflare Workers and Node 20+.

export type Plan = "pro" | "team";

export interface LicensePayload {
  id: string;            // UUID
  email: string;
  name: string;
  plan: Plan;
  issuedAt: string;      // ISO 8601, seconds precision (Swift's .iso8601 decoder rejects fractions)
  updatesUntil?: string;
  expiresAt?: string;
  seats: number;
}

const enc = new TextEncoder();

export function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
export function unb64url(s: string): Uint8Array {
  let b = s.replace(/-/g, "+").replace(/_/g, "/");
  while (b.length % 4) b += "=";
  return b64decode(b);
}
export function b64decode(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** ISO 8601 without fractional seconds, e.g. 2026-10-15T09:30:00Z. */
export function isoSeconds(d: Date): string {
  return d.toISOString().replace(/\.\d{3}Z$/, "Z");
}

export function addMonths(d: Date, months: number): Date {
  const r = new Date(d.getTime());
  r.setUTCMonth(r.getUTCMonth() + months);
  return r;
}

// PKCS#8 wrapper for a raw 32-byte Ed25519 seed (RFC 8410).
const PKCS8_PREFIX = Uint8Array.from([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]);

export async function importSigningKey(seedBase64: string): Promise<CryptoKey> {
  const seed = b64decode(seedBase64.trim());
  if (seed.length !== 32) throw new Error("LICENSE_PRIVATE_KEY must be a base64 32-byte Ed25519 seed");
  const der = new Uint8Array(PKCS8_PREFIX.length + 32);
  der.set(PKCS8_PREFIX); der.set(seed, PKCS8_PREFIX.length);
  return crypto.subtle.importKey("pkcs8", der, { name: "Ed25519" }, false, ["sign"]);
}

export async function importVerifyKey(publicBase64: string): Promise<CryptoKey> {
  const raw = b64decode(publicBase64.trim());
  if (raw.length !== 32) throw new Error("LICENSE_PUBLIC_KEY must be a base64 32-byte Ed25519 public key");
  return crypto.subtle.importKey("raw", raw, { name: "Ed25519" }, false, ["verify"]);
}

/** Canonical JSON: sorted keys, no undefined, matching Swift's .sortedKeys output shape. */
function canonical(p: LicensePayload): string {
  const o: Record<string, unknown> = {};
  for (const k of Object.keys(p).sort()) {
    const v = (p as unknown as Record<string, unknown>)[k];
    if (v !== undefined && v !== null) o[k] = v;
  }
  return JSON.stringify(o);
}

export async function signLicense(p: LicensePayload, key: CryptoKey): Promise<string> {
  const payload = enc.encode(canonical(p));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, key, payload));
  return ["EVL1", b64url(payload), b64url(sig)].join(".");
}

export async function verifyLicense(key: string, pub: CryptoKey): Promise<LicensePayload> {
  const parts = key.trim().split(".");
  if (parts.length !== 3 || parts[0] !== "EVL1") throw new Error("malformed");
  const payload = unb64url(parts[1]), sig = unb64url(parts[2]);
  if (!(await crypto.subtle.verify({ name: "Ed25519" }, pub, sig, payload))) throw new Error("bad signature");
  return JSON.parse(new TextDecoder().decode(payload)) as LicensePayload;
}

/** Signs a test payload and checks it with the public key; fails fast on a key mismatch. */
export async function assertKeyPair(priv: CryptoKey, pub: CryptoKey): Promise<void> {
  const k = await signLicense({ id: crypto.randomUUID(), email: "x@y.z", name: "x", plan: "pro", issuedAt: isoSeconds(new Date()), seats: 1 }, priv);
  await verifyLicense(k, pub);
}

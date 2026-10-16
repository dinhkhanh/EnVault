import { importSigningKey, importVerifyKey, assertKeyPair } from "./license.ts";
import { verifyStandardWebhook, verifyPaddle } from "./signatures.ts";
import { D1Store } from "./store.ts";
import { ResendMailer, LogMailer, type Mailer } from "./mail.ts";
import { polarAction } from "./providers/polar.ts";
import { paddleAction, paddleApi } from "./providers/paddle.ts";
import { applyAction, issue, resendKeys, type Services } from "./handlers.ts";
import { resendForm, resendDone, thanks } from "./pages.ts";

export interface Env {
  DB: D1Database;
  LICENSE_PUBLIC_KEY: string; LICENSE_PRIVATE_KEY: string;
  SITE_URL: string; STORE_URL?: string; POLAR_CHECKOUT_URL: string; PADDLE_CHECKOUT_URL: string; CHECKOUT_PROVIDER: string;
  FROM_EMAIL: string; SUPPORT_EMAIL: string; UPDATES_MONTHS: string; MAIL_MODE: string;
  POLAR_WEBHOOK_SECRET?: string; PADDLE_WEBHOOK_SECRET?: string; PADDLE_API_KEY?: string; PADDLE_SANDBOX?: string;
  RESEND_API_KEY?: string; ADMIN_TOKEN?: string;
}

let keyCache: { priv: CryptoKey; checked: boolean } | null = null;
async function signingKey(env: Env): Promise<CryptoKey> {
  if (keyCache) return keyCache.priv;
  if (!env.LICENSE_PRIVATE_KEY) throw new Error("LICENSE_PRIVATE_KEY secret is not set");
  const priv = await importSigningKey(env.LICENSE_PRIVATE_KEY);
  await assertKeyPair(priv, await importVerifyKey(env.LICENSE_PUBLIC_KEY));
  keyCache = { priv, checked: true };
  return priv;
}

const logMailer = new LogMailer();
function mailer(env: Env): Mailer {
  if (env.MAIL_MODE === "log") return logMailer;
  if (!env.RESEND_API_KEY) throw new Error("RESEND_API_KEY secret is not set");
  return new ResendMailer(env.RESEND_API_KEY, env.FROM_EMAIL);
}

async function services(env: Env, req: Request): Promise<Services> {
  return {
    store: new D1Store(env.DB),
    mailer: mailer(env),
    signingKey: await signingKey(env),
    updatesMonths: Number(env.UPDATES_MONTHS || 12),
    mail: { siteUrl: env.SITE_URL, storeUrl: env.STORE_URL || new URL(req.url).origin, supportEmail: env.SUPPORT_EMAIL },
  };
}

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o, null, 2), { status, headers: { "content-type": "application/json" } });
const html = (s: string, status = 200) => new Response(s, { status, headers: { "content-type": "text/html; charset=utf-8" } });
const text = (s: string, status = 200) => new Response(s, { status });

function isAdmin(req: Request, env: Env): boolean {
  const auth = req.headers.get("authorization") ?? "";
  if (!env.ADMIN_TOKEN || !auth.startsWith("Bearer ")) return false;
  const a = new TextEncoder().encode(auth.slice(7)), b = new TextEncoder().encode(env.ADMIN_TOKEN);
  if (a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i];
  return d === 0;
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";
    try {
      if (req.method === "GET" && path === "/health") return text("ok");

      // Checkout entry point: one stable URL, provider chosen by config.
      if (req.method === "GET" && path === "/buy") {
        const target = env.CHECKOUT_PROVIDER === "paddle" ? env.PADDLE_CHECKOUT_URL : env.POLAR_CHECKOUT_URL;
        if (!target) return html(thanks(env.SITE_URL, env.SUPPORT_EMAIL).replace("Thank you for buying EnVault Pro", "Checkout is not open yet").replace(/<p>Your license key[^]*?<\/p>/, `<p>Email <a href="mailto:${env.SUPPORT_EMAIL}">${env.SUPPORT_EMAIL}</a> to get a key.</p>`), 503);
        const t = new URL(target);
        for (const k of ["customer_email", "customer_name", "discount_code", "reference_id", "utm_source", "utm_medium", "utm_campaign"]) {
          const v = url.searchParams.get(k); if (v) t.searchParams.set(k, v);
        }
        return Response.redirect(t.toString(), 302);
      }
      if (req.method === "GET" && path === "/thanks") return html(thanks(env.SITE_URL, env.SUPPORT_EMAIL));

      if (path === "/resend" || path === "/") {
        if (req.method === "GET") return html(resendForm(env.SITE_URL));
        if (req.method === "POST") {
          const form = await req.formData();
          const email = String(form.get("email") ?? "");
          const s = await services(env, req);
          const r = await resendKeys(s, email);
          console.log(`resend ${email}: ${r}`);
          return html(resendDone(env.SITE_URL, env.SUPPORT_EMAIL));
        }
      }

      // Revoked license ids, embedded in app releases by scripts/sync-revocations.sh.
      if (req.method === "GET" && path === "/revocations.json") {
        const ids = await new D1Store(env.DB).revokedIds();
        return json({ generatedAt: new Date().toISOString(), revoked: ids });
      }

      if (req.method === "POST" && path === "/webhooks/polar") {
        if (!env.POLAR_WEBHOOK_SECRET) return text("POLAR_WEBHOOK_SECRET not set", 500);
        const body = new Uint8Array(await req.arrayBuffer());
        const ok = await verifyStandardWebhook(body, {
          id: req.headers.get("webhook-id"), timestamp: req.headers.get("webhook-timestamp"), signature: req.headers.get("webhook-signature"),
        }, env.POLAR_WEBHOOK_SECRET);
        if (!ok) return text("bad signature", 403);
        const event = JSON.parse(new TextDecoder().decode(body));
        const s = await services(env, req);
        const out = await applyAction(s, "polar", req.headers.get("webhook-id")!, event.type, polarAction(event));
        console.log(`polar ${event.type}: ${out.body}`);
        return text(out.body, out.status);
      }

      if (req.method === "POST" && path === "/webhooks/paddle") {
        if (!env.PADDLE_WEBHOOK_SECRET || !env.PADDLE_API_KEY) return text("PADDLE_WEBHOOK_SECRET / PADDLE_API_KEY not set", 500);
        const body = new Uint8Array(await req.arrayBuffer());
        if (!(await verifyPaddle(body, req.headers.get("paddle-signature"), env.PADDLE_WEBHOOK_SECRET))) return text("bad signature", 403);
        const event = JSON.parse(new TextDecoder().decode(body));
        const s = await services(env, req);
        const action = await paddleAction(event, paddleApi(env.PADDLE_API_KEY, env.PADDLE_SANDBOX === "true"));
        const out = await applyAction(s, "paddle", event.event_id, event.event_type, action);
        console.log(`paddle ${event.event_type}: ${out.body}`);
        return text(out.body, out.status);
      }

      if (path.startsWith("/admin/")) {
        if (!isAdmin(req, env)) return text("unauthorized", 401);
        const store = new D1Store(env.DB);
        if (req.method === "GET" && path === "/admin/licenses") {
          return json(await store.list(url.searchParams.get("q") ?? "", Number(url.searchParams.get("limit") ?? 100)));
        }
        if (req.method === "POST" && path === "/admin/issue") {
          const b: any = await req.json();
          if (!b.email || !b.name) return json({ error: "email and name required" }, 400);
          const s = await services(env, req);
          const row = await issue(s, {
            provider: "manual", orderId: b.orderId ?? null, customerId: null, subscriptionId: null,
            email: String(b.email), name: String(b.name), plan: b.plan === "team" ? "team" : "pro",
            seats: Math.max(1, Number(b.seats ?? 1) || 1), periodEnd: null,
            updatesUntil: b.updatesUntil, expiresAt: b.expiresAt,
          }, b.notify !== false);
          return json(row, 201);
        }
        if (req.method === "POST" && path === "/admin/revoke") {
          const b: any = await req.json();
          const rows = b.id ? [await store.byId(String(b.id))].filter(Boolean) : b.email ? await store.byEmail(String(b.email)) : [];
          const active = (rows as any[]).filter((r) => r.status === "active");
          for (const r of active) await store.revoke(r.id, String(b.reason ?? "manual"));
          return json({ revoked: active.map((r) => r.id) });
        }
        if (req.method === "POST" && path === "/admin/resend") {
          const b: any = await req.json();
          const s = await services(env, req);
          return json({ result: await resendKeys(s, String(b.email ?? "")) });
        }
        return text("not found", 404);
      }
      return text("not found", 404);
    } catch (e) {
      console.error(e);
      return text(`error: ${e instanceof Error ? e.message : String(e)}`, 500);
    }
  },
} satisfies ExportedHandler<Env>;

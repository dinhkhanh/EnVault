import type { LicenseRow } from "./store.ts";

export interface Mail { to: string; subject: string; text: string; html: string; }
export interface Mailer { send(m: Mail): Promise<void>; }

export class ResendMailer implements Mailer {
  private apiKey: string; private from: string;
  constructor(apiKey: string, from: string) { this.apiKey = apiKey; this.from = from; }
  async send(m: Mail) {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { authorization: `Bearer ${this.apiKey}`, "content-type": "application/json" },
      body: JSON.stringify({ from: this.from, to: [m.to], subject: m.subject, text: m.text, html: m.html }),
    });
    if (!res.ok) throw new Error(`Resend ${res.status}: ${await res.text()}`);
  }
}

/** Local dev / tests: keeps mails in memory and logs them. */
export class LogMailer implements Mailer {
  sent: Mail[] = [];
  async send(m: Mail) { this.sent.push(m); console.log(`[mail] to=${m.to} subject=${m.subject}\n${m.text}`); }
}

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));

export interface MailContext { siteUrl: string; storeUrl: string; supportEmail: string; }

export function licenseMail(rows: LicenseRow[], ctx: MailContext, kind: "new" | "resend"): Mail {
  const first = rows[0];
  const plan = first.plan === "team" ? "Team" : "Pro";
  const keys = rows.map((r) => r.key);
  const updates = first.updates_until ? first.updates_until.slice(0, 10) : null;
  const intro = kind === "new"
    ? `Thanks for buying eVault ${plan}. Here is your license key:`
    : `Here ${rows.length === 1 ? "is the license key" : "are the license keys"} registered to this address:`;
  const steps = [
    `1. Download eVault: ${ctx.siteUrl}`,
    `2. Open eVault > Settings > License (or any Pro feature), paste the key, click Activate.`,
    `3. The key is verified on your Mac. No account, no activation server.`,
  ].join("\n");
  const text = `${intro}\n\n${keys.join("\n\n")}\n\n${steps}\n\n` +
    (updates ? `Licensed to ${first.name} <${first.email}>, ${first.seats} seat(s). Covers all updates released until ${updates}; versions released before that date keep working forever.\n\n` : "") +
    `Lost this email? Get your key again at ${ctx.storeUrl}/resend\nQuestions or refunds (14 days): ${ctx.supportEmail}`;
  const html = `<div style="font:15px/1.5 -apple-system,Helvetica,Arial,sans-serif;color:#111;max-width:600px">
<p>${esc(intro)}</p>
${keys.map((k) => `<pre style="background:#f4f4f5;border:1px solid #e4e4e7;border-radius:8px;padding:12px;white-space:pre-wrap;word-break:break-all;font-size:13px">${esc(k)}</pre>`).join("")}
<ol>
<li><a href="${esc(ctx.siteUrl)}">Download eVault</a></li>
<li>Open eVault &gt; Settings &gt; License (or any Pro feature), paste the key, click Activate.</li>
<li>The key is verified on your Mac. No account, no activation server.</li>
</ol>
${updates ? `<p style="color:#555">Licensed to ${esc(first.name)} &lt;${esc(first.email)}&gt;, ${first.seats} seat(s). Covers all updates released until <b>${updates}</b>; versions released before that date keep working forever.</p>` : ""}
<p style="color:#555">Lost this email? <a href="${esc(ctx.storeUrl)}/resend">Get your key again</a>. Questions or refunds (14 days): <a href="mailto:${esc(ctx.supportEmail)}">${esc(ctx.supportEmail)}</a></p>
</div>`;
  return { to: first.email, subject: kind === "new" ? `Your eVault ${plan} license key` : "Your eVault license key", text, html };
}

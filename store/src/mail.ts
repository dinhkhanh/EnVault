import type { LicenseRow } from "./store.ts";

export interface Mail { to: string; subject: string; text: string; html: string; replyTo?: string; }
export interface Mailer { send(m: Mail): Promise<void>; }

export class ResendMailer implements Mailer {
  private apiKey: string; private from: string;
  constructor(apiKey: string, from: string) { this.apiKey = apiKey; this.from = from; }
  async send(m: Mail) {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { authorization: `Bearer ${this.apiKey}`, "content-type": "application/json" },
      body: JSON.stringify({ from: this.from, to: [m.to], subject: m.subject, text: m.text, html: m.html, ...(m.replyTo ? { reply_to: m.replyTo } : {}) }),
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

export function licenseMail(rows: LicenseRow[], ctx: MailContext, kind: "new" | "resend" | "renewal" | "seats"): Mail {
  const first = rows[0];
  const plan = first.plan === "team" ? "Team" : "Pro";
  const keys = rows.map((r) => r.key);
  const updates = first.updates_until ? first.updates_until.slice(0, 10) : null;
  // Plain sentences before the key: a mail that opens with an opaque blob reads as spam to filters.
  const greeting = `Hi ${first.name},`;
  const intro = kind === "new"
    ? `Thank you for buying EnVault ${plan}. Your purchase is complete, and the key below unlocks every Pro feature on your Mac. Keep this email somewhere safe; you will need the key again if you reinstall or move to a new Mac.`
    : kind === "renewal"
    ? `Your EnVault ${plan} subscription renewed. Here is the key for the new year: paste it in EnVault › Settings › License${first.plan === "team" ? " on the Mac that owns your team vaults; your team picks it up from there" : ""}.`
    : kind === "seats"
    ? `Your EnVault ${plan} subscription now has ${first.seats} seat${first.seats === 1 ? "" : "s"}. Here is the key for it; paste it in EnVault › Settings › License. It replaces your previous key.`
    : `You asked us to send your EnVault ${rows.length === 1 ? "license again. Here it is" : "licenses again. Here they are"}, exactly as issued.`;
  const steps = [
    `1. Download EnVault: ${ctx.siteUrl}`,
    `2. Open EnVault > Settings > License (or any Pro feature), paste the key, click Activate.`,
    `3. The key is verified on your Mac. No account, no activation server.`,
  ].join("\n");
  const text = `${greeting}\n\n${intro}\n\n${keys.join("\n\n")}\n\n${steps}\n\n` +
    (updates ? `Licensed to ${first.name} <${first.email}>, ${first.seats} seat(s). Covers all updates released until ${updates}; versions released before that date keep working forever.\n\n` : "") +
    `Lost this email? Get your key again at ${ctx.storeUrl}/resend\nQuestions or refunds (14 days): just reply to this email.\n\nThe EnVault team`;
  const html = `<div style="font:15px/1.5 -apple-system,Helvetica,Arial,sans-serif;color:#111;max-width:600px">
<p>${esc(greeting)}</p>
<p>${esc(intro)}</p>
${keys.map((k) => `<pre style="background:#f4f4f5;border:1px solid #e4e4e7;border-radius:8px;padding:12px;white-space:pre-wrap;word-break:break-all;font-size:13px">${esc(k)}</pre>`).join("")}
<ol>
<li><a href="${esc(ctx.siteUrl)}">Download EnVault</a></li>
<li>Open EnVault &gt; Settings &gt; License (or any Pro feature), paste the key, click Activate.</li>
<li>The key is verified on your Mac. No account, no activation server.</li>
</ol>
${updates ? `<p style="color:#555">Licensed to ${esc(first.name)} &lt;${esc(first.email)}&gt;, ${first.seats} seat(s). Covers all updates released until <b>${updates}</b>; versions released before that date keep working forever.</p>` : ""}
<p style="color:#555">Lost this email? <a href="${esc(ctx.storeUrl)}/resend">Get your key again</a>. Questions or refunds (14 days): just reply to this email.</p>
<p>The EnVault team</p>
</div>`;
  return { to: first.email, subject: kind === "new" ? `Your EnVault ${plan} purchase` : kind === "renewal" ? `Your EnVault ${plan} renewal` : kind === "seats" ? `Your EnVault ${plan} key for ${first.seats} seats` : "Your EnVault license, as requested", text, html, replyTo: ctx.supportEmail };
}

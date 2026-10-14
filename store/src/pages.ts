const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));

function page(title: string, body: string, siteUrl: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title>
<style>
:root{--bg:#fff;--fg:#111;--muted:#666;--line:#e5e5e5;--accent:#3b6cff}
@media(prefers-color-scheme:dark){:root{--bg:#121214;--fg:#eee;--muted:#999;--line:#2a2a2e}}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}
main{max-width:480px;margin:0 auto;padding:48px 16px}
h1{font-size:24px;margin:0 0 8px}p{color:var(--muted)}
input{width:100%;box-sizing:border-box;padding:10px 12px;font-size:16px;border:1px solid var(--line);border-radius:8px;background:transparent;color:var(--fg)}
button{margin-top:12px;padding:10px 16px;font-size:16px;border:0;border-radius:8px;background:var(--accent);color:#fff;cursor:pointer}
a{color:var(--accent)}
</style></head><body><main>${body}<p style="margin-top:40px;font-size:14px"><a href="${esc(siteUrl)}">eVault</a></p></main></body></html>`;
}

export function resendForm(siteUrl: string): string {
  return page("Get your eVault license key", `
<h1>Lost your license key?</h1>
<p>Enter the email you used at checkout. If it has a license, the key is on its way.</p>
<form method="post" action="/resend">
  <input type="email" name="email" placeholder="you@example.com" required autofocus>
  <button type="submit">Email my key</button>
</form>`, siteUrl);
}

export function resendDone(siteUrl: string, supportEmail: string): string {
  return page("Check your inbox", `
<h1>Check your inbox</h1>
<p>If that address has an eVault license, the key has been sent. Nothing after a few minutes? Check spam, then write to <a href="mailto:${esc(supportEmail)}">${esc(supportEmail)}</a>.</p>`, siteUrl);
}

export function thanks(siteUrl: string, supportEmail: string): string {
  return page("Thank you", `
<h1>Thank you for buying eVault Pro</h1>
<p>Your license key is on its way by email. Paste it in eVault &gt; Settings &gt; License.</p>
<p>No email after a few minutes? <a href="/resend">Resend it</a> or write to <a href="mailto:${esc(supportEmail)}">${esc(supportEmail)}</a>.</p>`, siteUrl);
}

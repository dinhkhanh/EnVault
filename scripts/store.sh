#!/bin/sh
# Talk to the license store's admin API (store/ Worker).
#   scripts/store.sh list [query]
#   scripts/store.sh issue --email E --name N [--plan pro|team] [--seats N] [--no-notify]
#   scripts/store.sh revoke (--id ID | --email E) [--reason R]
#   scripts/store.sh resend --email E
# Needs EVAULT_STORE_URL (default https://store.evault.dinhkhanh.dk) and the admin token
# in the login keychain: security add-generic-password -s dk.dinhkhanh.evault.store-admin -a admin -w TOKEN
set -eu
STORE="${EVAULT_STORE_URL:-https://store.evault.dinhkhanh.dk}"
TOKEN="${EVAULT_STORE_TOKEN:-$(security find-generic-password -s dk.dinhkhanh.evault.store-admin -w)}"
cmd="${1:-}"; [ $# -gt 0 ] && shift
auth="Authorization: Bearer $TOKEN"
case "$cmd" in
  list)
    curl -fsS -H "$auth" "$STORE/admin/licenses?q=${1:-}" | python3 -c '
import sys, json
rows = json.load(sys.stdin)
print(f"{"issued":<11} {"status":<8} {"plan":<5} {"seats":<5} {"id":<10} {"provider":<8} {"email":<30} name")
for r in rows:
    print(f"{r["issued_at"][:10]:<11} {r["status"]:<8} {r["plan"]:<5} {r["seats"]:<5} {r["id"][:8]:<10} {r["provider"]:<8} {r["email"]:<30} {r["name"]}")
print(f"\n{len(rows)} license(s)")' ;;
  issue|revoke|resend)
    json=$(python3 -c '
import sys, json
a = sys.argv[1:]; o = {}
i = 0
while i < len(a):
    k = a[i]
    if k == "--no-notify": o["notify"] = False; i += 1; continue
    o[k.lstrip("-")] = a[i + 1]; i += 2
if "seats" in o: o["seats"] = int(o["seats"])
print(json.dumps(o))' "$@")
    curl -fsS -H "$auth" -H "content-type: application/json" -d "$json" "$STORE/admin/$cmd"; echo ;;
  *) sed -n '2,8p' "$0"; exit 1 ;;
esac

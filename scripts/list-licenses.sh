#!/bin/sh
# List issued licenses from the vendor ledger, optionally filtered by a substring (email, name, id).
LEDGER="$HOME/Library/Application Support/eVault Vendor/licenses.jsonl"
[ -f "$LEDGER" ] || { echo "no licenses issued yet"; exit 0; }
python3 - "$LEDGER" "${1:-}" <<'PY'
import sys, json
path, q = sys.argv[1], sys.argv[2].lower()
rows = [json.loads(l) for l in open(path) if l.strip()]
rows = [r for r in rows if q in json.dumps(r).lower()]
print(f"{'issued':<11} {'plan':<5} {'seats':<5} {'id':<10} {'email':<30} name")
for r in rows:
    print(f"{r['issuedAt'][:10]:<11} {r['plan']:<5} {r.get('seats',1):<5} {r['id'][:8]:<10} {r['email']:<30} {r['name']}")
print(f"\n{len(rows)} license(s). Full keys are in {path}")
PY

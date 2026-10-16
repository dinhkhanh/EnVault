#!/bin/sh
# Issue a license key by hand, offline, and record it in the local vendor ledger.
# Prefer `scripts/store.sh issue` once the store Worker is deployed: keys issued there land in
# the same D1 ledger as paid orders and can be revoked/resent. Use this one when the store is down.
#   scripts/issue-license.sh --email a@b.c --name "Ada" [--plan pro|team] [--seats N] [--updates-until YYYY-MM-DD]
# Private key: login keychain item dk.dinhkhanh.evault.license-signing (from the initial keygen).
# Ledger: ~/Library/Application Support/EnVault Vendor/licenses.jsonl (one JSON object per key).
# List:   scripts/list-licenses.sh [search]
set -eu
cd "$(dirname "$0")/.."
TOOL=Packages/EnVaultKit/.build/release/envault-license
[ -x "$TOOL" ] || swift build -c release --package-path Packages/EnVaultKit --product envault-license >/dev/null

LEDGER_DIR="$HOME/Library/Application Support/EnVault Vendor"
LEDGER="$LEDGER_DIR/licenses.jsonl"
mkdir -p "$LEDGER_DIR"

KEY=$(ENVAULT_LICENSE_PRIVATE_KEY=$(security find-generic-password -s dk.dinhkhanh.evault.license-signing -w) "$TOOL" issue "$@")

# Decode the payload for the ledger (base64url → json).
PAYLOAD=$(printf '%s' "$KEY" | cut -d. -f2 | tr '_-' '/+')
case $(( ${#PAYLOAD} % 4 )) in 2) PAYLOAD="$PAYLOAD==";; 3) PAYLOAD="$PAYLOAD=";; esac
printf '%s' "$PAYLOAD" | base64 -d | python3 -c '
import sys, json
p = json.load(sys.stdin)
p["key"] = sys.argv[1]
print(json.dumps(p, sort_keys=True))' "$KEY" >> "$LEDGER"
chmod 600 "$LEDGER"

printf '%s\n' "$KEY"
echo "recorded in $LEDGER" >&2

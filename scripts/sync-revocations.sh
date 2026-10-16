#!/bin/sh
# Pull the revoked license ids from the store and write App/RevokedLicenses.swift.
# Run before every release so refunded keys stop working on the new version.
#   ENVAULT_STORE_URL=https://store.envault.app scripts/sync-revocations.sh
set -eu
cd "$(dirname "$0")/.."
STORE="${ENVAULT_STORE_URL:-https://store.envault.app}"
OUT=App/RevokedLicenses.swift
JSON=$(curl -fsS --max-time 15 "$STORE/revocations.json") || {
  echo "sync-revocations: $STORE unreachable, keeping $OUT as is" >&2
  [ -n "${ENVAULT_REVOCATIONS_STRICT:-}" ] && exit 1; exit 0; }
printf '%s' "$JSON" | python3 -c '
import sys, json
ids = sorted(set(i.upper() for i in json.load(sys.stdin)["revoked"]))
body = "".join(f"        \"{i}\",\n" for i in ids)
print(f"""import Foundation

/// License ids revoked after a refund. Regenerated before each release by
/// `scripts/sync-revocations.sh` from the store\x27s /revocations.json. Do not edit by hand.
enum RevokedLicenses {{
    static let ids: Set<String> = [
{body}    ]
}}""")
print(f"sync-revocations: {len(ids)} revoked id(s)", file=sys.stderr)' > "$OUT"

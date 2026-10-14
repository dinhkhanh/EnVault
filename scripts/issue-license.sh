#!/bin/sh
# Issue a license key by hand. Private key comes from the login keychain
# (stored there by the initial keygen). Usage:
#   scripts/issue-license.sh --email a@b.c --name "Ada" [--plan pro|team] [--seats N]
set -eu
cd "$(dirname "$0")/.."
TOOL=Packages/eVaultKit/.build/release/evault-license
[ -x "$TOOL" ] || swift build -c release --package-path Packages/eVaultKit --product evault-license >/dev/null
EVAULT_LICENSE_PRIVATE_KEY=$(security find-generic-password -s dk.dinhkhanh.evault.license-signing -w) \
  exec "$TOOL" issue "$@"

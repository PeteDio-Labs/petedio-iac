#!/usr/bin/env bash
# keys-copy.sh — copy an agent's one-header token from Vault to the Mac clipboard (PET-904).
#
# Usage: scripts/keys-copy.sh <agent>     for example: scripts/keys-copy.sh batsy
#
# It reads the `header` field of kv/callers/edge/<agent>, which keys.yml writes, and pipes it
# to pbcopy. The value never reaches the terminal. Paste it into the agent's credential form,
# for a Muse agent the API key box of its custom connector, then clear the clipboard.
# Bash 3.2 compatible, like every Mac script here.
set -euo pipefail

die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ $# -eq 1 ] || die "usage: $0 <agent>"
AGENT="$1"
printf '%s' "$AGENT" | grep -Eq '^[a-z][a-z0-9-]{1,30}$' || die "not an agent name: $AGENT"
for t in vault pbcopy security python3; do command -v "$t" >/dev/null || die "$t not in PATH."; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$SCRIPT_DIR/../environments/homelab/vault-ca.crt}"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "no Vault token: set VAULT_TOKEN or add the Keychain item vault-root-token"
export VAULT_TOKEN

# Read into a variable first, so a failed read never leaves an empty or partial clipboard.
VALUE="$(vault kv get -field=header "kv/callers/edge/$AGENT")" || die "could not read kv/callers/edge/$AGENT (sealed Vault, bad token or no such agent)"
# Parse it: both fields must be non-empty strings, and nothing else may be present.
printf '%s' "$VALUE" | python3 -c '
import json, sys
d = json.load(sys.stdin)
keys = ("cf-access-client-id", "cf-access-client-secret")
ok = isinstance(d, dict) and sorted(d) == sorted(keys) and all(isinstance(d[k], str) and d[k] for k in keys)
sys.exit(0 if ok else 1)
' 2>/dev/null || die "kv/callers/edge/$AGENT header is not the expected JSON; nothing copied"
printf '%s' "$VALUE" | pbcopy
unset VALUE
echo "Copied the header for $AGENT to the clipboard. Paste it, then copy something else to clear it."

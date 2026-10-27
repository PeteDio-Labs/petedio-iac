#!/usr/bin/env bash
# ssh-ca-sign.sh — get a short-lived SSH certificate from the Vault SSH CA (PET-771).
#
#   VAULT_TOKEN=... scripts/ssh-ca-sign.sh <role> <public-key-file>
#
# Writes <key>-cert.pub next to the public key, which ssh picks up on its own for the matching
# private key. Prints the certificate's principals and validity, so you can see what you hold.
# The roles are in environments/homelab/vault-config/ssh.tf. The `pedro` role signs only from
# the break-glass token on 247 (vault-breakglass).
#
# Exits non-zero when Vault is sealed, refuses the token, or returns no certificate. It never
# leaves an old certificate in place that could read as a fresh one.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf 'usage: %s <role> <public-key-file>\n' "${0##*/}" >&2
  exit 2
fi
ROLE="$1"
PUB="$2"
[[ -r "$PUB" ]] || { printf 'cannot read %s\n' "$PUB" >&2; exit 2; }
[[ -n "${VAULT_TOKEN:-}" ]] || { printf 'VAULT_TOKEN is not set\n' >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
VAULT_CACERT="${VAULT_CACERT:-$SCRIPT_DIR/../environments/homelab/vault-ca.crt}"
CERT="${PUB%.pub}-cert.pub"

rm -f "$CERT"
BODY="$(jq -n --rawfile k "$PUB" '{public_key: $k}')"
RESP="$(curl -sS --fail-with-body --cacert "$VAULT_CACERT" \
  -H "X-Vault-Token: $VAULT_TOKEN" -X POST -d "$BODY" \
  "$VAULT_ADDR/v1/ssh-client-signer/sign/$ROLE")" || {
  printf 'Vault refused to sign for role %s: %s\n' "$ROLE" "$RESP" >&2
  exit 1
}

SIGNED="$(jq -r '.data.signed_key // empty' <<<"$RESP")"
[[ -n "$SIGNED" ]] || { printf 'Vault returned no certificate: %s\n' "$RESP" >&2; exit 1; }
umask 022
printf '%s\n' "$SIGNED" > "$CERT"

ssh-keygen -L -f "$CERT" | grep -E 'Principals|Valid:|Critical Options|^ +[a-z]' || true
printf 'wrote %s (role %s)\n' "$CERT" "$ROLE"

#!/usr/bin/env bash
# seed-vault-oidc.sh — write Vault's auth/oidc/config from the hand-created Authentik "vault"
# application (PET-946). Run it once, after scripts/apply-vault-config.sh has mounted the method
# (environments/homelab/vault-config/oidc.tf) and before anyone signs in at vault.pdlab.dev.
#
# WHY MANUAL: like the cloudflare-access app (reseed-authentik-oidc-vault.sh), the Authentik
# provider and application are created BY HAND in the Authentik dashboard on LXC 119. Slug `vault`,
# confidential client, implicit consent, scopes `openid email profile`, and these redirect URIs:
#   https://vault.pdlab.dev/ui/vault/auth/oidc/oidc/callback
#   http://localhost:8250/oidc/callback
# Confirm the app answers before you seed:
#   curl https://auth.pdlab.dev/application/o/vault/.well-known/openid-configuration
#
# Idempotent. Prints no secrets, and the secret never appears in an argument list or in state.
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM. No prompt.
#   OIDC creds:  $VAULT_OIDC_CLIENT_ID / $VAULT_OIDC_CLIENT_SECRET, else prompt (secret not echoed)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
DISCOVERY_URL="${VAULT_OIDC_DISCOVERY_URL:-https://auth.pdlab.dev/application/o/vault/}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
command -v vault >/dev/null || die "vault not in PATH."
command -v python3 >/dev/null || die "python3 not in PATH."

step "Resolving Vault token"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || die "no Vault token: set VAULT_TOKEN or add the Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM"
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault token invalid / Vault unreachable."

step "Checking the method is mounted"
vault auth list -format=json | python3 -c 'import json,sys; sys.exit(0 if "oidc/" in json.load(sys.stdin) else 1)' \
  || die "auth/oidc is not mounted. Apply vault-config first: scripts/apply-vault-config.sh"
vault read -format=json auth/oidc/role/pedro >/dev/null 2>&1 \
  || die "role pedro is missing. Apply vault-config first: scripts/apply-vault-config.sh"

step "Reading the Authentik client"
CLIENT_ID="${VAULT_OIDC_CLIENT_ID:-}"
CLIENT_SECRET="${VAULT_OIDC_CLIENT_SECRET:-}"
[ -n "$CLIENT_ID" ] || read -r -p "Authentik client id for the vault app: " CLIENT_ID
[ -n "$CLIENT_SECRET" ] || { read -r -s -p "Authentik client secret (hidden): " CLIENT_SECRET; printf '\n'; }
[ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ] || die "client id and secret are both required."

step "Writing auth/oidc/config"
# The JSON goes through stdin, so the secret never appears in a process list.
CLIENT_ID="$CLIENT_ID" CLIENT_SECRET="$CLIENT_SECRET" DISCOVERY_URL="$DISCOVERY_URL" python3 -c '
import json, os
print(json.dumps({
    "oidc_discovery_url": os.environ["DISCOVERY_URL"],
    "oidc_client_id": os.environ["CLIENT_ID"],
    "oidc_client_secret": os.environ["CLIENT_SECRET"],
    "default_role": "pedro",
}))' | vault write auth/oidc/config - >/dev/null

step "Read-back"
vault read -format=json auth/oidc/config | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
print("discovery url :", d.get("oidc_discovery_url"))
print("client id set :", bool(d.get("oidc_client_id")))
print("default role  :", d.get("default_role"))'
printf '\nDone. No secret was printed. Sign in at https://vault.pdlab.dev with method OIDC.\n'

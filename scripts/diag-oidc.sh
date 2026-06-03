#!/usr/bin/env bash
# diag-oidc.sh — read-only dump of the GitHub-OIDC JWT auth role + backend config.
# Handy when CI's vault-action login returns 403/permission-denied: compares the role's
# bound_audiences / bound_claims and the backend's issuer/discovery against what the
# workflow sends. No writes.
#
#   Vault token: $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM, else prompt
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
JWT_PATH="${JWT_PATH:-jwt-github}"
JWT_ROLE="${JWT_ROLE:-github-actions}"

command -v vault >/dev/null || { echo "vault not in PATH" >&2; exit 1; }
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || { read -rsp "Vault token: " VAULT_TOKEN; echo; }
export VAULT_TOKEN

echo "=== auth methods (confirm the jwt mount path) ==="
vault auth list 2>&1 | sed 's/^/  /'
echo
echo "=== role: auth/$JWT_PATH/role/$JWT_ROLE ==="
vault read "auth/$JWT_PATH/role/$JWT_ROLE" 2>&1 | sed 's/^/  /'
echo
echo "=== backend config: auth/$JWT_PATH/config (issuer / discovery) ==="
vault read "auth/$JWT_PATH/config" 2>&1 | sed 's/^/  /'

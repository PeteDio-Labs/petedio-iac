#!/usr/bin/env bash
# reseed-authentik-oidc-vault.sh — (re)seed kv/iac/authentik with the OIDC client_id /
# client_secret of the hand-created Authentik "cloudflare-access" application (SSO LXC 119),
# so apply-on-merge can build cloudflare_zero_trust_access_identity_provider.authentik
# (environments/homelab/cloudflare-oidc.tf). ci-read is granted read on kv/data/iac/authentik.
#
# WHY MANUAL: the Authentik OAuth2/OpenID provider+app is created BY HAND in the Authentik
# dashboard (the automation never mutates the SSO box) — slug `cloudflare-access`, confidential
# client, redirect https://petedillo-labs.cloudflareaccess.com/cdn-cgi/access/callback,
# implicit-consent flow, scopes `openid email profile`. That app mints the two values below.
# See docs/runbooks/fleet-activity-view.md §"Swap login to Authentik OIDC".
#
# Idempotent. Prints no secrets. Reads inputs at runtime:
#   Vault token:   $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM, else prompt
#   OIDC creds:    $AUTHENTIK_OIDC_CLIENT_ID / $AUTHENTIK_OIDC_CLIENT_SECRET, else prompt
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

step(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
command -v vault >/dev/null || die "vault not in PATH."

step "Resolving Vault token"
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || { read -rsp "Vault token: " VAULT_TOKEN; echo; }
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault token invalid / Vault unreachable."

step "Collecting the Authentik OIDC client credentials"
CID="${AUTHENTIK_OIDC_CLIENT_ID:-}"
CSEC="${AUTHENTIK_OIDC_CLIENT_SECRET:-}"
[ -n "$CID" ]  || read -rp  "Authentik OIDC client_id: " CID
[ -n "$CSEC" ] || { read -rsp "Authentik OIDC client_secret: " CSEC; echo; }
[ -n "$CID" ] && [ -n "$CSEC" ] || die "Both client_id and client_secret are required."

step "Writing kv/iac/authentik (values not echoed)"
vault kv put kv/iac/authentik \
  oidc_client_id="$CID" \
  oidc_client_secret="$CSEC" >/dev/null \
  || die "vault kv put failed."

printf '\033[1;32mSeeded kv/iac/authentik (oidc_client_id, oidc_client_secret).\033[0m\n'
printf 'Next: terraform apply builds the CF Access IdP; then admin.pdlab.dev redirects to Authentik.\n'

#!/usr/bin/env bash
# reseed-openfaas-vault.sh — (re)seed kv/services/openfaas with a faasd gateway
# admin password, consumed by the faasd rollout (configure-openfaas.yml) under the
# `ansible` policy. Generates the password locally; NEVER prints it. (PET-86)
#
# Modeled on reseed-minio-frontend-vault.sh (token resolution + secret hygiene).
# Writing kv/services/* needs a privileged token — the read-only AppRoles cannot
# write here — so this resolves the Vault token the same way the other reseed
# scripts do:
#   $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM, else prompt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command -v vault >/dev/null || die "vault not in PATH."

# Vault token: env -> Keychain -> prompt. Never echoed. Use -w (emits only to the
# command-substitution capture); NEVER use -g (that prints the secret to stderr).
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || { read -rsp "Vault token: " VAULT_TOKEN; echo; }
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault token invalid / Vault unreachable."

# Gateway password: use $GATEWAY_PASSWORD if provided, else generate one.
# Held in a var only — never printed, never passed on a command line.
# NB: use a pipe-free generator — `tr </dev/urandom | head -c N` SIGPIPEs `tr`,
# which trips `set -o pipefail`/`errexit` and aborts the script before the write.
GW_PW="${GATEWAY_PASSWORD:-$(openssl rand -hex 24)}"
[ -n "$GW_PW" ] || die "empty gateway password."

# Write via STDIN (key=-) so the secret never appears in argv / the process table.
printf '%s' "$GW_PW" | vault kv put kv/services/openfaas gateway_password=- >/dev/null \
  || die "vault kv put kv/services/openfaas failed (token may lack write on kv/services/*)."

# Verify presence WITHOUT printing the value.
vault kv get -field=gateway_password kv/services/openfaas >/dev/null 2>&1 \
  && echo "kv/services/openfaas seeded (readable by the ansible policy)." \
  || die "verification read failed."

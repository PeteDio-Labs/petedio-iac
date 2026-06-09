#!/usr/bin/env bash
# reseed-admin-secrets-vault.sh — seed the co-latro-admin service secrets (PET-88):
#   kv/admin/db        { owner_password, DATABASE_URL }  — the admin Postgres DB (TF + service)
#   kv/services/admin  { token }                          — the co-latro <-> admin seam token
# Keychain root token; values via a 0600 temp JSON file (never on argv); openssl-generated.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"
export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"
PG_HOST="${PG_HOST:-192.168.50.231}"

die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command -v vault >/dev/null || die "vault not in PATH."
command -v openssl >/dev/null || die "openssl not in PATH."

if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || { read -rsp "Vault token: " VAULT_TOKEN; echo; }
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault token invalid / Vault unreachable."

# Idempotent-ish: reuse an existing admin DB password if already seeded (so we don't
# rotate it out from under a created role); otherwise generate one.
EXISTING_PW="$(vault kv get -field=owner_password kv/admin/db 2>/dev/null || true)"
DB_PW="${ADMIN_DB_PASSWORD:-${EXISTING_PW:-$(openssl rand -hex 24)}}"
DB_URL="postgres://admin:${DB_PW}@${PG_HOST}:5432/admin"
SVC_TOKEN="${ADMIN_SERVICE_TOKEN:-$(vault kv get -field=token kv/services/admin 2>/dev/null || openssl rand -hex 32)}"

J1="$(mktemp)"; J2="$(mktemp)"; chmod 600 "$J1" "$J2"; trap 'rm -f "$J1" "$J2"' EXIT
printf '{"owner_password":"%s","DATABASE_URL":"%s"}\n' "$DB_PW" "$DB_URL" > "$J1"
printf '{"token":"%s"}\n' "$SVC_TOKEN" > "$J2"

vault kv put kv/admin/db @"$J1" >/dev/null || die "failed to write kv/admin/db."
vault kv put kv/services/admin @"$J2" >/dev/null || die "failed to write kv/services/admin."

# Verify presence WITHOUT printing values.
vault kv get -field=owner_password kv/admin/db >/dev/null 2>&1 || die "verify kv/admin/db failed."
vault kv get -field=token kv/services/admin >/dev/null 2>&1 || die "verify kv/services/admin failed."
echo "seeded kv/admin/db (owner_password, DATABASE_URL) + kv/services/admin (token)."

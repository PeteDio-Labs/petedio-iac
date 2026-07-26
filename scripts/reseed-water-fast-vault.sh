#!/usr/bin/env bash
# reseed-water-fast-vault.sh — (re)seed kv/services/water-fast with the app's DB password
# and its Cloudflare Access parameters, consumed by configure-water-fast.yml under the
# `ansible` policy. Generates the DB password locally; NEVER prints it.
#
# Modeled on reseed-openfaas-vault.sh (token resolution + secret hygiene). Writing
# kv/services/* needs a privileged token — the read-only AppRoles cannot write here — so
# this resolves the Vault token the same way the other reseed scripts do:
#   $VAULT_TOKEN, else macOS Keychain item $VAULT_TOKEN_KEYCHAIN_ITEM, else prompt.
#
# Usage:
#   ./scripts/reseed-water-fast-vault.sh --aud <ACCESS_AUD> [--team-domain <domain>]
#
# The AUD comes from the Cloudflare dashboard (Access > Applications > fast.pdlab.dev) and
# only exists once cloudflare-routes.tf has applied that application.
#
# IDEMPOTENT: an existing db_password is REUSED, not rotated. Rotating it here without also
# updating the Postgres role would leave the deployed service unable to authenticate — pass
# --rotate deliberately if that's what you want, then re-sync the role and redeploy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOMELAB="$REPO_ROOT/environments/homelab"

export VAULT_ADDR="${VAULT_ADDR:-https://192.168.50.223:8200}"
export VAULT_CACERT="${VAULT_CACERT:-$HOMELAB/vault-ca.crt}"
VAULT_TOKEN_KEYCHAIN_ITEM="${VAULT_TOKEN_KEYCHAIN_ITEM:-vault-root-token}"

TEAM_DOMAIN="petedillo-labs.cloudflareaccess.com"
AUD=""
ROTATE=0

die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command -v vault >/dev/null || die "vault not in PATH."

while [ $# -gt 0 ]; do
  case "$1" in
    --aud) AUD="${2:-}"; shift 2;;
    --team-domain) TEAM_DOMAIN="${2:-}"; shift 2;;
    --rotate) ROTATE=1; shift;;
    *) die "unknown argument: $1";;
  esac
done
[ -n "$AUD" ] || die "--aud is required (Cloudflare dashboard > Access > Applications > fast.pdlab.dev)."

# Vault token: env -> Keychain -> prompt. Never echoed. Use -w (emits only to the
# command-substitution capture); NEVER use -g (that prints the secret to stderr).
if [ -z "${VAULT_TOKEN:-}" ]; then
  VAULT_TOKEN="$(security find-generic-password -s "$VAULT_TOKEN_KEYCHAIN_ITEM" -w 2>/dev/null || true)"
fi
[ -n "${VAULT_TOKEN:-}" ] || { read -rsp "Vault token: " VAULT_TOKEN; echo; }
export VAULT_TOKEN
vault token lookup >/dev/null 2>&1 || die "Vault token invalid / Vault unreachable."

# Reuse an existing password unless --rotate. Held in a var only — never printed, never
# passed on a command line.
EXISTING="$(vault kv get -field=db_password kv/services/water-fast 2>/dev/null || true)"
if [ -n "$EXISTING" ] && [ "$ROTATE" -eq 0 ]; then
  DB_PW="$EXISTING"
  echo "reusing the existing db_password (pass --rotate to generate a new one)."
else
  # NB: use a pipe-free generator — `tr </dev/urandom | head -c N` SIGPIPEs `tr`, which
  # trips pipefail/errexit and aborts before the write. Hex keeps the value safe inside the
  # postgres:// URL the service's EnvironmentFile builds.
  DB_PW="$(openssl rand -hex 24)"
  [ -n "$DB_PW" ] || die "empty db password."
  echo "generated a new db_password — re-sync the Postgres role and redeploy after this."
fi

# Write the secret via STDIN (key=-) so it never appears in argv / the process table. The
# team domain and AUD are not secrets and can go inline.
printf '%s' "$DB_PW" | vault kv put kv/services/water-fast \
  db_password=- \
  cf_access_team_domain="$TEAM_DOMAIN" \
  cf_access_aud="$AUD" >/dev/null \
  || die "vault kv put kv/services/water-fast failed (token may lack write on kv/services/*)."

# Verify presence WITHOUT printing the value.
for f in db_password cf_access_team_domain cf_access_aud; do
  vault kv get -field="$f" kv/services/water-fast >/dev/null 2>&1 || die "verification read failed for $f."
done
echo "kv/services/water-fast seeded (readable by the ansible policy)."

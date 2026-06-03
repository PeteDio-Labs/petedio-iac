#!/usr/bin/env bash
#
# vault-verify.sh — verify the bootstrap secrets are seeded and a consumer can read.
#
# operator-run; requires VAULT_ADDR/VAULT_CACERT/VAULT_TOKEN; no values are committed.
#
# Checks (PRESENCE only — never prints a secret value):
#   1. Every seeded KV path has each expected key (via `vault kv get -field=<key>`,
#      output discarded; we assert exit status + non-empty length only).
#   2. A consumer AppRole login succeeds and can READ kv/poker/db DATABASE_URL
#      (proves PET-32/PET-12 can fetch it). Uses the terraform-local AppRole, whose
#      `terraform` policy grants kv/data/poker/* (the ansible policy does NOT).
#
# Prints PASS/FAIL per check and exits non-zero if any check FAILs.
#
# Usage:
#   export VAULT_ADDR="https://192.168.50.223:8200"
#   export VAULT_CACERT="$(pwd)/environments/homelab/vault-ca.crt"
#   vault login            # or: export VAULT_TOKEN=<root/bootstrap or admin token>
#   ./scripts/vault-verify.sh
#
# AppRole creds are read from iac/.secrets/{terraform-local,ansible}.{role_id,secret_id}
# (gitignored), created per docs/runbooks/vault-seed.md. Override the dir with
# SECRETS_DIR=/abs/path if your checkout layout differs.
#
set -euo pipefail

: "${VAULT_ADDR:?set VAULT_ADDR (e.g. https://192.168.50.223:8200)}"
: "${VAULT_CACERT:?set VAULT_CACERT to the path of environments/homelab/vault-ca.crt}"
: "${VAULT_TOKEN:?run 'vault login' or export VAULT_TOKEN}"

command -v vault >/dev/null 2>&1 || { echo "FATAL: vault CLI not found on PATH" >&2; exit 1; }

SECRETS_DIR="${SECRETS_DIR:-iac/.secrets}"

fail=0
pass() { printf 'PASS  %s\n' "$1"; }
f1() { printf 'FAIL  %s\n' "$1"; fail=1; }

# Assert that kv path $1 has key $2 present and non-empty, without printing the value.
check_field() {
  local path="$1" key="$2" out
  if out="$(vault kv get -field="$key" "$path" 2>/dev/null)" && [ -n "$out" ]; then
    pass "$path has '$key' (present, ${#out} chars)"
  else
    f1 "$path missing '$key' (or unreadable)"
  fi
  unset out
}

echo "== 1. Presence checks (values never printed) =="
check_field kv/iac/proxmox          api_token
check_field kv/iac/minio            access_key
check_field kv/iac/minio            secret_key
check_field kv/iac/lxc-ssh          public_key
check_field kv/iac/lxc-ssh          private_key
check_field kv/poker/db             DATABASE_URL
check_field kv/poker/db             admin_password
check_field kv/poker/db             poker_password
check_field kv/services/qbittorrent username
check_field kv/services/qbittorrent password
check_field kv/services/authentik   secret_key
check_field kv/services/authentik   bootstrap_token
check_field kv/services/cloudflare  tunnel_token
check_field kv/services/nexus       admin_password

echo
echo "== 2. Consumer AppRole read of kv/poker/db (terraform-local role) =="
role_id_file="${SECRETS_DIR}/terraform-local.role_id"
secret_id_file="${SECRETS_DIR}/terraform-local.secret_id"

if [ ! -r "$role_id_file" ] || [ ! -r "$secret_id_file" ]; then
  f1 "AppRole creds not found at ${role_id_file} / ${secret_id_file} — provision them (see runbook) then re-run"
else
  role_id="$(cat "$role_id_file")"
  secret_id="$(cat "$secret_id_file")"
  # Log in via AppRole in a SUBSHELL so the scoped token never leaks into this script's
  # env or the operator's shell. Capture only the consumer-read result.
  if consumer_url="$(
        VAULT_TOKEN="$(vault write -field=token auth/approle/login \
            role_id="$role_id" secret_id="$secret_id" 2>/dev/null)" \
        vault kv get -field=DATABASE_URL kv/poker/db 2>/dev/null
      )" && [ -n "$consumer_url" ]; then
    pass "terraform-local AppRole logged in and read kv/poker/db DATABASE_URL (${#consumer_url} chars)"
    # Sanity-check the FORMAT without printing the password: must start postgresql://
    # and end with the expected host/db/sslmode. We check the non-secret tail only.
    case "$consumer_url" in
      postgresql://poker:*@192.168.50.231:5432/poker\?sslmode=disable)
        pass "DATABASE_URL matches expected shape (postgresql://poker:***@192.168.50.231:5432/poker?sslmode=disable)"
        ;;
      *)
        f1 "DATABASE_URL does not match expected shape (host/db/sslmode) — re-check the seed"
        ;;
    esac
  else
    f1 "terraform-local AppRole could not read kv/poker/db DATABASE_URL (login failed or policy gap)"
  fi
  unset role_id secret_id consumer_url
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "ALL CHECKS PASS — secrets seeded and a consumer can read kv/poker/db via AppRole."
  exit 0
else
  echo "SOME CHECKS FAILED — see FAIL lines above. Do not consider PET-27 done until all PASS."
  exit 1
fi

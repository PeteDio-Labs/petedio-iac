#!/usr/bin/env bash
#
# vault-verify.sh — verify the bootstrap secrets are seeded and a consumer can read.
#
# operator-run; requires VAULT_ADDR, VAULT_CACERT and a token from `vault login` or
# VAULT_TOKEN; no values are committed.
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
# (gitignored), created per docs/runbooks/vault-seed.md. The script finds that
# directory from its own path, so any working directory works. To read the creds
# from somewhere else, set SECRETS_DIR=/abs/path.
#
set -euo pipefail

: "${VAULT_ADDR:?set VAULT_ADDR (e.g. https://192.168.50.223:8200)}"
: "${VAULT_CACERT:?set VAULT_CACERT to the path of environments/homelab/vault-ca.crt}"

command -v vault >/dev/null 2>&1 || { echo "FATAL: vault CLI not found on PATH" >&2; exit 1; }

# Vault seals nightly. Check the seal first, so a sealed Vault does not read as a
# missing token below.
if ! vault status >/dev/null 2>&1; then
  echo "FATAL: 'vault status' failed — Vault unreachable or sealed. Check VAULT_ADDR/CACERT and unseal." >&2
  exit 1
fi

# Ask the CLI for the token, not VAULT_TOKEN. `vault login` stores its token with the
# token helper and exports nothing, so a check of the variable refused that route
# (PET-452). The CLI reads VAULT_TOKEN first and the helper second.
if ! vault token lookup >/dev/null 2>&1; then
  echo "FATAL: no usable Vault token. Run 'vault login', or export VAULT_TOKEN." >&2
  exit 1
fi

# The default was the relative path iac/.secrets, which resolves only from the
# workspace root. The usage above runs from iac/, where section 2 failed (PET-452).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_DIR="${SECRETS_DIR:-$REPO_ROOT/.secrets}"

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
# The path qBittorrent's gluetun sidecar reads. It replaced kv/services/qbittorrent,
# which held a username and password nothing ever read (PET-452). This check is red
# until the seed runs — `scripts/seed-qbittorrent-vault.sh` — and red is the correct
# answer while the VPN credentials are absent.
check_field kv/services/media/qbittorrent wireguard_private_key
check_field kv/services/media/qbittorrent wireguard_addresses
check_field kv/services/authentik   secret_key
check_field kv/services/authentik   bootstrap_token
check_field kv/services/cloudflare  tunnel_token
check_field kv/services/registry    password

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
  #
  # The subshell exits before the read when the login fails. The CLI treats an empty
  # VAULT_TOKEN as unset and falls back to the token helper, where `vault login` left
  # your own token, so the read would pass with it and report a working AppRole.
  if consumer_url="$(
        approle_token="$(vault write -field=token auth/approle/login \
            role_id="$role_id" secret_id="$secret_id" 2>/dev/null)" || exit 1
        [ -n "$approle_token" ] || exit 1
        VAULT_TOKEN="$approle_token" vault kv get -field=DATABASE_URL kv/poker/db 2>/dev/null
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
